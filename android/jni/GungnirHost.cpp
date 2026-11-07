// The Gungnir Core host for PPSSPP on Android. See GungnirHost.h and ext/gungnir-core/docs/HOST.md.
//
// Threads, as HOST.md asks:
// - The emu thread runs the game, its vblanks (where we tick), save state loads and NativeFrame
//   (where we tick while paused). Start, tick, stop and every GnCore function are only called there.
// - The audio thread calls GungnirHost_MixAudio. gn_runtime_mix_audio expects the emu thread and
//   takes no lock against gn_runtime_stop, so here it's guarded by g_audioLock: stop can't free the
//   runtime while a mix is inside it.

#include "android/jni/GungnirHost.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

#include "gn_core.h"
#include "gn_runtime.h"

#include "Common/File/DirListing.h"
#include "Common/File/FileUtil.h"
#include "Common/File/Path.h"
#include "Common/Log.h"
#include "Core/Config.h"
#include "Core/Core.h"
#include "Core/ELF/ParamSFO.h"
#include "Core/HLE/sceDisplay.h"
#include "Core/MIPS/MIPS.h"
#include "Core/MemMap.h"
#include "Core/SaveState.h"
#include "Core/System.h"

namespace {

GungnirCommandSink g_sink = nullptr;
std::string g_fallbackRoot;

// Emu thread only.
bool g_tried = false;    // looked for a pack for this boot
bool g_running = false;  // gn_runtime_start was called, and stop not yet
uint64_t g_frames = 0;   // vblanks since the runtime started: GnCore.frameCount
uint64_t g_framesAtLastHostFrame = 0;
int g_hostFramesWithoutVblank = 0;
bool g_paused = false;
GnRegion g_regions[4];
GnCore g_core;

std::mutex g_audioLock;
bool g_audioOn = false;  // under g_audioLock

// A host frame with no vblank can happen while the game runs (loading, a slow frame), so only call
// it paused after this many in a row.
constexpr int PAUSED_AFTER_HOST_FRAMES = 2;

void Send(const char *command, const char *param) {
	if (g_sink) {
		g_sink(command, param);
	}
}

void TakeHaptic() {
	int haptic = gn_runtime_take_haptic();
	if (haptic != 0) {
		char param[16];
		snprintf(param, sizeof(param), "%d", haptic);
		Send("gungnir_haptic", param);
	}
}

// ---- the GnCore: memory and frames ----

// Bytes as the game sees them, with no side effects. Unmapped bytes read as zero.
bool HostRead(void *, uint32_t address, void *out, size_t size) {
	if (!Memory::base || size > 0x10000000) {
		return false;
	}
	uint8_t *bytes = (uint8_t *)out;
	if (Memory::IsValidRange(address, (u32)size)) {
		memcpy(bytes, Memory::GetPointerUnchecked(address), size);
		return true;
	}
	for (size_t i = 0; i < size; i++) {
		const u32 a = address + (u32)i;
		bytes[i] = Memory::IsValidAddress(a) ? *Memory::GetPointerUnchecked(a) : 0;
	}
	return true;
}

// The runtime has already checked the bytes are inside one writable region (user RAM).
bool HostWrite(void *, uint32_t address, const void *in, size_t size) {
	if (!Memory::base || size > 0x10000000 || !Memory::IsValidRange(address, (u32)size)) {
		return false;
	}
	memcpy(Memory::GetPointerWriteUnchecked(address), in, size);
	// A pack writes data, but if it ever lands on code the JIT must not keep running the old copy.
	if (currentMIPS) {
		currentMIPS->InvalidateICacheRangeDeferred(address, (u32)size);
	}
	return true;
}

uint64_t HostFrameCount(void *) {
	return g_frames;
}

// PARAM.SFO's DISC_ID, as packs name PSP games: upper case, no dash ("ULUS10500").
void FillGameId(GnGameId *id) {
	memset(id, 0, sizeof(*id));
	id->platform = GN_PLATFORM_PSP;
	const std::string discId = g_paramSFO.GetDiscID();
	size_t n = 0;
	for (char c : discId) {
		if (c == '-' || c == '_' || c == ' ') {
			continue;
		}
		if (n + 1 >= sizeof(id->code)) {
			break;
		}
		id->code[n++] = (char)toupper((unsigned char)c);
	}
	id->code[n] = '\0';
}

void FillCore() {
	// Packs may change user RAM, where game data lives. The rest is there to read.
	g_regions[0] = {"ram", PSP_GetUserMemoryBase(), PSP_GetUserMemoryEnd() - PSP_GetUserMemoryBase(), true, false};
	g_regions[1] = {"kernel", PSP_GetKernelMemoryBase(), PSP_GetUserMemoryBase() - PSP_GetKernelMemoryBase(), false, false};
	g_regions[2] = {"scratchpad", PSP_GetScratchpadMemoryBase(), PSP_GetScratchpadMemoryEnd() - PSP_GetScratchpadMemoryBase(), false, false};
	g_regions[3] = {"vram", PSP_GetVidMemBase(), 0x00200000, false, false};

	memset(&g_core, 0, sizeof(g_core));
	FillGameId(&g_core.id);
	g_core.capabilities = 0;  // None of the GBA ones: packs for PSP games need only memory.
	g_core.regions = g_regions;
	g_core.regionCount = sizeof(g_regions) / sizeof(g_regions[0]);
	g_core.read = HostRead;
	g_core.write = HostWrite;
	g_core.frameCount = HostFrameCount;
}

// ---- packs ----

// The first pack, by folder name, that lists this game. "" for none.
std::string FindPack(const Path &packsDir, const GnGameId &id) {
	std::vector<File::FileInfo> entries;
	if (!File::GetFilesInDir(packsDir, &entries)) {
		return "";
	}
	std::sort(entries.begin(), entries.end(), [](const File::FileInfo &a, const File::FileInfo &b) { return a.name < b.name; });
	for (const auto &entry : entries) {
		if (!entry.isDirectory || entry.name.empty() || entry.name[0] == '.') {
			continue;
		}
		const std::string dir = entry.fullName.ToString();
		if (gn_runtime_pack_matches(dir.c_str(), &id)) {
			return entry.name;
		}
	}
	return "";
}

// ---- the game's life ----

void Start() {
	g_tried = true;
	FillCore();
	if (g_core.id.code[0] == '\0') {
		INFO_LOG(Log::System, "Gungnir: the game has no disc ID, so no pack can match it");
		return;
	}

	const Path root(GungnirHost_PacksRoot());
	const std::string pack = FindPack(root / "packs", g_core.id);
	if (pack.empty()) {
		INFO_LOG(Log::System, "Gungnir: no pack in %s/packs lists %s", root.c_str(), g_core.id.code);
		return;
	}

	const Path packDir = root / "packs" / pack;
	const Path dataDir = root / "packdata" / pack;
	File::CreateFullPath(dataDir);
	INFO_LOG(Log::System, "Gungnir: starting pack %s for %s", pack.c_str(), g_core.id.code);

	g_frames = 0;
	g_framesAtLastHostFrame = 0;
	g_hostFramesWithoutVblank = 0;
	g_paused = false;
	// Threaded: Core draws on its own worker, into the surface the Java side hands it.
	gn_runtime_start(&g_core, true, packDir.ToString().c_str(), dataDir.ToString().c_str(), false);
	g_running = true;
	{
		std::lock_guard<std::mutex> guard(g_audioLock);
		g_audioOn = true;
	}
	Send("gungnir_companion", "show");
}

void Stop() {
	if (g_running) {
		INFO_LOG(Log::System, "Gungnir: stopping the pack");
		Send("gungnir_companion", "hide");
		{
			std::lock_guard<std::mutex> guard(g_audioLock);
			g_audioOn = false;
		}
		gn_runtime_stop();
		g_running = false;
	}
	g_tried = false;
}

// The frame boundary: after the game's frame, before its vblank handlers.
void OnVblank() {
	if (!g_tried) {
		Start();
	}
	if (!g_running) {
		return;
	}
	g_frames++;
	if (g_paused) {
		gn_runtime_set_paused(false);
		g_paused = false;
	}
	gn_runtime_tick();
	TakeHaptic();
}

void OnStateLoaded() {
	if (g_running) {
		gn_runtime_state_loaded();
	}
}

void OnLifecycle(CoreLifecycle stage) {
	switch (stage) {
	case CoreLifecycle::STARTING:
		// A new boot: look for its pack on its first vblank, once PARAM.SFO and memory are ready.
		Stop();
		break;
	case CoreLifecycle::STOPPING:
		Stop();
		break;
	default:
		break;
	}
}

}  // namespace

std::string GungnirHost_PacksRoot() {
	// Core opens pack files with plain file calls, so it needs a real folder, not a content:// URI.
	const Path &memstick = g_Config.memStickDirectory;
	if (memstick.Type() == PathType::NATIVE && !memstick.empty()) {
		return (memstick / "PSP" / "GUNGNIR").ToString();
	}
	return g_fallbackRoot;
}

void GungnirHost_Init(const std::string &fallbackRoot, GungnirCommandSink sink) {
	g_fallbackRoot = fallbackRoot;
	g_sink = sink;
	Core_ListenLifecycle(&OnLifecycle);
	__DisplaySetVblankListener(&OnVblank);
	SaveState::SetLoadListener(&OnStateLoaded);
}

void GungnirHost_AfterHostFrame() {
	if (!g_running) {
		return;
	}
	if (g_frames != g_framesAtLastHostFrame) {
		g_framesAtLastHostFrame = g_frames;
		g_hostFramesWithoutVblank = 0;
		return;
	}
	if (++g_hostFramesWithoutVblank < PAUSED_AFTER_HOST_FRAMES) {
		return;
	}
	if (!g_paused) {
		gn_runtime_set_paused(true);
		g_paused = true;
	}
	gn_runtime_tick();
	TakeHaptic();
}

void GungnirHost_MixAudio(int16_t *stereo, int frames, int sampleRateHz) {
	std::lock_guard<std::mutex> guard(g_audioLock);
	if (g_audioOn) {
		gn_runtime_mix_audio(stereo, frames, sampleRateHz);
	}
}
