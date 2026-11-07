// The Gungnir Core host for PPSSPP on Android. See GungnirHost.h and ext/gungnir-core/docs/HOST.md.
//
// Threads, as HOST.md asks:
// - The emu thread runs the game, its vblanks (where we tick), save state loads, NativeFrame (where we
//   tick while paused) and PPSSPP's UI (the pack picker). Start, tick, stop, the GnCore functions and
//   everything about packs happen there.
// - The audio thread calls GungnirHost_MixAudio. gn_runtime_mix_audio expects the emu thread and
//   takes no lock against gn_runtime_stop, so here it's guarded by g_audioLock: stop can't free the
//   runtime while a mix is inside it.
//
// Folders under the app root:
//   packs/<id>/          installed packs and libraries, by ID, as Core looks for libraries
//   packdata/<id>/       each pack's storage and log
//   choices/<game>.txt   the player's pack for a game: a folder, or "none"; no file is automatic

#include "android/jni/GungnirHost.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <set>
#include <vector>

#include <zip.h>

#include "gn_core.h"
#include "gn_runtime.h"

#include "Common/Data/Format/JSONReader.h"
#include "Common/File/DirListing.h"
#include "Common/File/FileUtil.h"
#include "Common/File/Path.h"
#include "Common/File/VFS/ZipFileReader.h"
#include "Common/Log.h"
#include "Core/Config.h"
#include "Core/Core.h"
#include "Core/ELF/ParamSFO.h"
#include "Core/HLE/sceCtrl.h"
#include "Core/HLE/sceDisplay.h"
#include "Core/MIPS/MIPS.h"
#include "Core/MemMap.h"
#include "Core/SaveState.h"
#include "Core/System.h"

const char *const GUNGNIR_CHOICE_AUTO = "";
const char *const GUNGNIR_CHOICE_NONE = "none";

namespace {

GungnirCommandSink g_sink = nullptr;
std::string g_appRoot;

// Emu thread only.
std::atomic<bool> g_gameRunning{false};  // from STARTING to STOPPED: the pack picker isn't offered
bool g_tried = false;     // looked for a pack for this boot
bool g_running = false;   // gn_runtime_start was called, and stop not yet
std::string g_runningPack;
uint64_t g_frames = 0;    // vblanks since the runtime started: GnCore.frameCount
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

// Limits on what a dropped pack may unpack to, as gungnir-core's PackStore has them.
constexpr uint64_t MAX_PACK_BYTES = 256ULL * 1024 * 1024;
constexpr int MAX_PACK_FILES = 20000;

// In an installed pack: where it came from, so an unchanged source isn't copied again and a removed
// one is uninstalled. Packs without it were installed some other way and are left alone.
const char *const SOURCE_STAMP = ".gungnir_source";
const char *const INSTALLING = ".installing";

// DeleteDirRecursively logs an error for a folder that isn't there; the temp folder usually isn't.
void DeleteIfThere(const Path &dir) {
	if (File::Exists(dir)) {
		File::DeleteDirRecursively(dir);
	}
}

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

Path AppPath(std::string_view sub) {
	return Path(g_appRoot) / sub;
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

// Input (GN_CAP_INPUT): the buttons the pack holds, added to the player's at each pad sample. The
// PSP has no A or B; those bits are ignored.
void HostButtonsSet(void *, uint32_t held) {
	static const struct {
		uint32_t gn;
		u32 psp;
	} MAP[] = {
		{GN_BUTTON_UP, CTRL_UP}, {GN_BUTTON_DOWN, CTRL_DOWN}, {GN_BUTTON_LEFT, CTRL_LEFT}, {GN_BUTTON_RIGHT, CTRL_RIGHT},
		{GN_BUTTON_START, CTRL_START}, {GN_BUTTON_SELECT, CTRL_SELECT}, {GN_BUTTON_L, CTRL_LTRIGGER}, {GN_BUTTON_R, CTRL_RTRIGGER},
		{GN_BUTTON_CROSS, CTRL_CROSS}, {GN_BUTTON_CIRCLE, CTRL_CIRCLE}, {GN_BUTTON_SQUARE, CTRL_SQUARE}, {GN_BUTTON_TRIANGLE, CTRL_TRIANGLE},
	};
	u32 psp = 0;
	for (const auto &m : MAP) {
		if (held & m.gn) {
			psp |= m.psp;
		}
	}
	__CtrlSetHostHeld(psp);
}

// A PARAM.SFO DISC_ID as packs name PSP games: upper case, no dash ("ULUS10500").
void MakeGameId(const std::string &discId, GnGameId *id) {
	memset(id, 0, sizeof(*id));
	id->platform = GN_PLATFORM_PSP;
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
	MakeGameId(g_paramSFO.GetDiscID(), &g_core.id);
	// None of the GBA ones. Input, so a pack's touch menu can press the game's buttons.
	g_core.capabilities = GN_CAP_INPUT;
	g_core.buttonsSet = HostButtonsSet;
	g_core.regions = g_regions;
	g_core.regionCount = sizeof(g_regions) / sizeof(g_regions[0]);
	g_core.read = HostRead;
	g_core.write = HostWrite;
	g_core.frameCount = HostFrameCount;
}

// ---- package.json ----

// Pack JSON allows // and /* */ comments and trailing commas; PPSSPP's reader doesn't. As
// gungnir-core's Jsonc.clean does it: outside strings, comments go and a comma before } or ] goes.
std::string CleanJsonc(const std::string &text) {
	std::string out;
	out.reserve(text.size());
	size_t i = text.compare(0, 3, "\xEF\xBB\xBF") == 0 ? 3 : 0;
	bool inString = false;
	while (i < text.size()) {
		const char c = text[i];
		if (inString) {
			out += c;
			if (c == '\\' && i + 1 < text.size()) {
				out += text[i + 1];
				i += 2;
				continue;
			}
			if (c == '"') {
				inString = false;
			}
			i++;
			continue;
		}
		if (c == '"') {
			inString = true;
		} else if (c == '/' && i + 1 < text.size() && text[i + 1] == '/') {
			while (i < text.size() && text[i] != '\n') {
				i++;
			}
			continue;
		} else if (c == '/' && i + 1 < text.size() && text[i + 1] == '*') {
			const size_t end = text.find("*/", i + 2);
			i = end == std::string::npos ? text.size() : end + 2;
			continue;
		} else if (c == '}' || c == ']') {
			size_t k = out.size();
			while (k > 0 && isspace((unsigned char)out[k - 1])) {
				k--;
			}
			if (k > 0 && out[k - 1] == ',') {
				out.erase(k - 1, 1);
			}
		}
		out += c;
		i++;
	}
	return out;
}

// A pack ID is also its folder name, so it mustn't be able to point anywhere else.
bool IsSafeId(const std::string &id) {
	if (id.empty() || id.size() > 100 || id[0] == '.' || id.find("..") != std::string::npos) {
		return false;
	}
	for (char c : id) {
		if (!(islower((unsigned char)c) || isdigit((unsigned char)c) || c == '.' || c == '_' || c == '-')) {
			return false;
		}
	}
	return true;
}

// The pack in [dir]: its ID and name. False if there's no readable package.json with an ID.
bool ReadPackInfo(const Path &dir, std::string *id, std::string *name) {
	std::string text;
	if (!File::ReadTextFileToString(dir / "package.json", &text)) {
		return false;
	}
	const std::string clean = CleanJsonc(text);
	json::JsonReader reader(clean.data(), clean.size());
	if (!reader.ok() || !reader.root()) {
		return false;
	}
	const char *packId = reader.root().getStringOrNull("id");
	if (!packId || !*packId) {
		return false;
	}
	*id = packId;
	if (name) {
		*name = reader.root().getStringOr("name", packId);
	}
	return true;
}

// ---- bringing packs in from the drop folder ----

std::string ReadStamp(const Path &packDir) {
	std::string stamp;
	File::ReadTextFileToString(packDir / SOURCE_STAMP, &stamp);
	return stamp;
}

// A folder's files, recursively: relative path, size and time, one a line. A change to any of them
// makes the pack copy again.
bool ListTree(const Path &dir, const std::string &prefix, std::string *out, int *count) {
	std::vector<File::FileInfo> entries;
	if (!File::GetFilesInDir(dir, &entries)) {
		return false;
	}
	std::sort(entries.begin(), entries.end(), [](const File::FileInfo &a, const File::FileInfo &b) { return a.name < b.name; });
	for (const auto &entry : entries) {
		if (entry.name.empty() || entry.name[0] == '.') {
			continue;
		}
		if (++*count > MAX_PACK_FILES) {
			return false;
		}
		if (entry.isDirectory) {
			if (!ListTree(entry.fullName, prefix + entry.name + "/", out, count)) {
				return false;
			}
		} else {
			*out += prefix + entry.name + "|" + std::to_string(entry.size) + "|" + std::to_string(entry.mtime) + "\n";
		}
	}
	return true;
}

bool CopyTree(const Path &from, const Path &to, uint64_t *total) {
	if (!File::CreateFullPath(to)) {
		return false;
	}
	std::vector<File::FileInfo> entries;
	if (!File::GetFilesInDir(from, &entries)) {
		return false;
	}
	for (const auto &entry : entries) {
		if (entry.name.empty() || entry.name[0] == '.') {
			continue;
		}
		if (entry.isDirectory) {
			if (!CopyTree(entry.fullName, to / entry.name, total)) {
				return false;
			}
			continue;
		}
		*total += entry.size;
		if (*total > MAX_PACK_BYTES || !File::Copy(entry.fullName, to / entry.name)) {
			return false;
		}
	}
	return true;
}

// A name inside a zip that stays inside the folder it's unpacked to.
bool IsSafeZipName(const std::string &name) {
	if (name.empty() || name[0] == '/' || name.find('\\') != std::string::npos || name.find(':') != std::string::npos) {
		return false;
	}
	size_t start = 0;
	while (start <= name.size()) {
		size_t end = name.find('/', start);
		if (end == std::string::npos) {
			end = name.size();
		}
		if (name.compare(start, end - start, "..") == 0 && end - start == 2) {
			return false;
		}
		start = end + 1;
	}
	return true;
}

bool UnzipTo(const Path &zipPath, const Path &into, std::string *error) {
	ZipContainer z(zipPath);
	if (!z) {
		*error = "can't open the zip";
		return false;
	}
	const zip_int64_t count = zip_get_num_entries(z, 0);
	if (count < 0 || count > MAX_PACK_FILES) {
		*error = "too many files in the zip";
		return false;
	}
	uint64_t total = 0;
	std::vector<char> buffer(64 * 1024);
	for (zip_int64_t i = 0; i < count; i++) {
		const char *rawName = zip_get_name(z, (zip_uint64_t)i, 0);
		std::string name = rawName ? rawName : "";
		// Some Windows zip tools store folders with backslashes.
		std::replace(name.begin(), name.end(), '\\', '/');
		if (!IsSafeZipName(name)) {
			*error = "bad file name in the zip: " + name;
			return false;
		}
		const Path out = into / name;
		if (name.back() == '/') {
			File::CreateFullPath(out);
			continue;
		}
		zip_stat_t stat;
		if (zip_stat_index(z, (zip_uint64_t)i, 0, &stat) != 0) {
			*error = "can't read " + name;
			return false;
		}
		total += stat.size;
		if (total > MAX_PACK_BYTES) {
			*error = "the pack is too big";
			return false;
		}
		File::CreateFullPath(Path(out.GetDirectory()));
		zip_file_t *zf = zip_fopen_index(z, (zip_uint64_t)i, 0);
		FILE *f = zf ? File::OpenCFile(out, "wb") : nullptr;
		bool ok = f != nullptr;
		while (ok) {
			const zip_int64_t n = zip_fread(zf, buffer.data(), buffer.size());
			if (n < 0) {
				ok = false;
			} else if (n == 0) {
				break;
			} else if (fwrite(buffer.data(), 1, (size_t)n, f) != (size_t)n) {
				ok = false;
			}
		}
		if (f) {
			fclose(f);
		}
		if (zf) {
			zip_fclose(zf);
		}
		if (!ok) {
			*error = "can't unpack " + name;
			return false;
		}
	}
	return true;
}

// Installs the pack in [root] (inside packs/.installing) under its ID, stamped with where it came from.
bool InstallFrom(const Path &root, const std::string &stamp) {
	std::string id;
	if (!ReadPackInfo(root, &id, nullptr) || !IsSafeId(id)) {
		WARN_LOG(Log::System, "Gungnir: %s has no usable package.json id", root.c_str());
		return false;
	}
	const Path target = AppPath("packs") / id;
	if (File::Exists(target)) {
		File::DeleteDirRecursively(target);
	}
	if (!File::Rename(root, target)) {
		WARN_LOG(Log::System, "Gungnir: couldn't install %s", id.c_str());
		return false;
	}
	File::WriteStringToFile(true, stamp, target / SOURCE_STAMP);
	INFO_LOG(Log::System, "Gungnir: installed pack %s", id.c_str());
	return true;
}

// Brings in each pack folder and .zip from the drop folder that's new or changed, and uninstalls
// packs whose source is gone. A zip can hold one pack, or several in folders (a pack and its libraries).
void SyncPacks() {
	if (g_appRoot.empty()) {
		return;
	}
	const Path installed = AppPath("packs");
	File::CreateFullPath(installed);
	const Path drop(GungnirHost_DropFolder());
	if (drop.empty()) {
		return;
	}
	if (!File::Exists(drop)) {
		// So the player can see where packs go.
		File::CreateFullPath(drop);
		return;
	}
	std::vector<File::FileInfo> sources;
	if (!File::GetFilesInDir(drop, &sources)) {
		return;
	}

	// What each installed pack came from.
	std::vector<File::FileInfo> current;
	File::GetFilesInDir(installed, &current);
	std::set<std::string> installedStamps;
	for (const auto &pack : current) {
		if (pack.isDirectory && pack.name[0] != '.') {
			installedStamps.insert(ReadStamp(pack.fullName));
		}
	}

	std::set<std::string> sourceNames;
	const Path temp = installed / INSTALLING;
	for (const auto &source : sources) {
		if (source.name.empty() || source.name[0] == '.') {
			continue;
		}
		const bool isZip = !source.isDirectory && source.fullName.GetFileExtension() == ".zip";
		if (!source.isDirectory && !isZip) {
			continue;
		}
		sourceNames.insert(source.name);
		std::string stamp = "source:" + source.name + "\n";
		if (isZip) {
			stamp += std::to_string(source.size) + "|" + std::to_string(source.mtime) + "\n";
		} else {
			int count = 0;
			if (!ListTree(source.fullName, "", &stamp, &count)) {
				WARN_LOG(Log::System, "Gungnir: couldn't read %s", source.name.c_str());
				continue;
			}
		}
		if (installedStamps.count(stamp)) {
			continue;  // unchanged
		}

		DeleteIfThere(temp);
		std::string error;
		uint64_t total = 0;
		const bool unpacked = isZip ? UnzipTo(source.fullName, temp, &error) : CopyTree(source.fullName, temp, &total);
		if (!unpacked) {
			WARN_LOG(Log::System, "Gungnir: couldn't bring in %s: %s", source.name.c_str(), error.empty() ? "copy failed" : error.c_str());
			DeleteIfThere(temp);
			continue;
		}
		if (File::Exists(temp / "package.json")) {
			InstallFrom(temp, stamp);
		} else {
			// Zipping a pack's folder, or a set of them, puts each in a folder at the top.
			std::vector<File::FileInfo> roots;
			File::GetFilesInDir(temp, &roots);
			std::sort(roots.begin(), roots.end(), [](const File::FileInfo &a, const File::FileInfo &b) { return a.name < b.name; });
			bool any = false;
			for (const auto &root : roots) {
				if (root.isDirectory && File::Exists(root.fullName / "package.json")) {
					any |= InstallFrom(root.fullName, stamp);
				}
			}
			if (!any) {
				WARN_LOG(Log::System, "Gungnir: no package.json in %s", source.name.c_str());
			}
		}
		DeleteIfThere(temp);
	}

	// A pack brought in from the drop folder goes when its source does. Its data in packdata/ stays.
	for (const auto &pack : current) {
		if (!pack.isDirectory || pack.name[0] == '.') {
			continue;
		}
		const std::string stamp = ReadStamp(pack.fullName);
		if (stamp.compare(0, 7, "source:") != 0) {
			continue;
		}
		const std::string sourceName = stamp.substr(7, stamp.find('\n') - 7);
		if (!sourceNames.count(sourceName) && File::Exists(pack.fullName)) {
			INFO_LOG(Log::System, "Gungnir: %s was removed from the drop folder; uninstalling %s", sourceName.c_str(), pack.name.c_str());
			File::DeleteDirRecursively(pack.fullName);
		}
	}
}

// ---- choosing the pack ----

// Installed packs that list [game], sorted by folder.
std::vector<GungnirPackEntry> PacksForGame(const GnGameId &game) {
	std::vector<GungnirPackEntry> packs;
	std::vector<File::FileInfo> entries;
	if (game.code[0] == '\0' || !File::GetFilesInDir(AppPath("packs"), &entries)) {
		return packs;
	}
	std::sort(entries.begin(), entries.end(), [](const File::FileInfo &a, const File::FileInfo &b) { return a.name < b.name; });
	for (const auto &entry : entries) {
		if (!entry.isDirectory || entry.name.empty() || entry.name[0] == '.') {
			continue;
		}
		const std::string dir = entry.fullName.ToString();
		if (gn_runtime_pack_matches(dir.c_str(), &game)) {
			std::string id, name;
			if (!ReadPackInfo(entry.fullName, &id, &name)) {
				name = entry.name;
			}
			packs.push_back({entry.name, name});
		}
	}
	return packs;
}

Path ChoicePath(const GnGameId &game) {
	return AppPath("choices") / (std::string(game.code) + ".txt");
}

std::string ReadChoice(const GnGameId &game) {
	std::string choice;
	if (game.code[0] != '\0') {
		File::ReadTextFileToString(ChoicePath(game), &choice);
	}
	while (!choice.empty() && isspace((unsigned char)choice.back())) {
		choice.pop_back();
	}
	return choice;
}

// The pack to run: the chosen one if it still lists the game, else the first that does. "" for none.
std::string ResolvePack(const GnGameId &game) {
	const std::string choice = ReadChoice(game);
	if (choice == GUNGNIR_CHOICE_NONE) {
		return "";
	}
	const std::vector<GungnirPackEntry> packs = PacksForGame(game);
	for (const auto &pack : packs) {
		if (pack.folder == choice) {
			return pack.folder;
		}
	}
	return packs.empty() ? "" : packs[0].folder;
}

// ---- the game's life ----

void StartPack(const std::string &folder) {
	const Path packDir = AppPath("packs") / folder;
	const Path dataDir = AppPath("packdata") / folder;
	File::CreateFullPath(dataDir);
	INFO_LOG(Log::System, "Gungnir: starting pack %s for %s", folder.c_str(), g_core.id.code);

	g_frames = 0;
	g_framesAtLastHostFrame = 0;
	g_hostFramesWithoutVblank = 0;
	g_paused = false;
	// Threaded: Core draws on its own worker, into the surface the Java side hands it.
	gn_runtime_start(&g_core, true, packDir.ToString().c_str(), dataDir.ToString().c_str(), false);
	g_running = true;
	g_runningPack = folder;
	{
		std::lock_guard<std::mutex> guard(g_audioLock);
		g_audioOn = true;
	}
	Send("gungnir_companion", "show");
}

void StopPack() {
	if (!g_running) {
		return;
	}
	INFO_LOG(Log::System, "Gungnir: stopping pack %s", g_runningPack.c_str());
	Send("gungnir_companion", "hide");
	{
		std::lock_guard<std::mutex> guard(g_audioLock);
		g_audioOn = false;
	}
	gn_runtime_stop();
	// Core lets go as the pack stops; this makes sure, whatever happened.
	__CtrlSetHostHeld(0);
	g_running = false;
	g_runningPack.clear();
}

void Start() {
	g_tried = true;
	FillCore();
	if (g_core.id.code[0] == '\0') {
		INFO_LOG(Log::System, "Gungnir: the game has no disc ID, so no pack can match it");
		return;
	}
	SyncPacks();
	const std::string pack = ResolvePack(g_core.id);
	if (pack.empty()) {
		const std::string choice = ReadChoice(g_core.id);
		INFO_LOG(Log::System, "Gungnir: no pack for %s (choice: %s)", g_core.id.code, choice.empty() ? "automatic" : choice.c_str());
		return;
	}
	StartPack(pack);
}

void Stop() {
	StopPack();
	g_tried = false;
	memset(&g_core, 0, sizeof(g_core));
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
		g_gameRunning = true;
		break;
	case CoreLifecycle::STOPPING:
		Stop();
		break;
	case CoreLifecycle::STOPPED:
		g_gameRunning = false;
		break;
	default:
		break;
	}
}

}  // namespace

std::string GungnirHost_PacksRoot() {
	return AppPath("packs").ToString();
}

std::string GungnirHost_DropFolder() {
	const Path &memstick = g_Config.memStickDirectory;
	if (memstick.empty()) {
		return "";
	}
	return (memstick / "PSP" / "GUNGNIR" / "packs").ToString();
}

void GungnirHost_Init(const std::string &appRoot, GungnirCommandSink sink) {
	g_appRoot = appRoot;
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

bool GungnirHost_GameRunning() {
	return g_gameRunning.load();
}

std::vector<GungnirPackEntry> GungnirHost_PacksForGame(const std::string &discId, bool sync) {
	GnGameId game;
	MakeGameId(discId, &game);
	if (game.code[0] == '\0') {
		return {};
	}
	// Syncing may uninstall a pack, so never while a game (and maybe its pack) runs.
	if (sync && !g_gameRunning.load()) {
		SyncPacks();
	}
	return PacksForGame(game);
}

std::string GungnirHost_ChoiceForGame(const std::string &discId) {
	GnGameId game;
	MakeGameId(discId, &game);
	return ReadChoice(game);
}

void GungnirHost_SetChoiceForGame(const std::string &discId, const std::string &choice) {
	GnGameId game;
	MakeGameId(discId, &game);
	if (game.code[0] == '\0') {
		return;
	}
	const Path path = ChoicePath(game);
	if (choice.empty()) {
		File::Delete(path, true);
	} else {
		File::CreateFullPath(AppPath("choices"));
		File::WriteStringToFile(true, choice, path);
	}
	INFO_LOG(Log::System, "Gungnir: %s's pack is now %s, from its next launch", game.code, choice.empty() ? "automatic" : choice.c_str());
}
