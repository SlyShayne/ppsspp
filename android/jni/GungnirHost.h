// The Gungnir Core host: PPSSPP behind gungnir-core's host interface (ext/gungnir-core/docs/HOST.md),
// so a pack can read the running PSP game's memory and draw a companion screen (a map, buttons,
// character stats) on a dual-screen handheld's second display. Android only.

#pragma once

#include <cstdint>
#include <string>

// How the host asks the Java side for something: "gungnir_companion" with "show" or "hide", and
// "gungnir_haptic" with the haptic's number (1 tap ... 6 heavy). Called on the emu thread.
typedef void (*GungnirCommandSink)(const char *command, const char *param);

// Once, at startup. [fallbackRoot] is where packs live when the memory stick isn't a plain folder
// (a content:// URI): an app-private folder the runtime can open files in.
void GungnirHost_Init(const std::string &fallbackRoot, GungnirCommandSink sink);

// Emu thread, after every host frame (NativeFrame). Keeps the companion ticking while the game is
// paused, under PPSSPP's menu: taps, timelines and read-only pages keep working.
void GungnirHost_AfterHostFrame();

// Audio thread, after PPSSPP has mixed the game's audio: adds the pack's sounds. Interleaved stereo.
void GungnirHost_MixAudio(int16_t *stereo, int frames, int sampleRateHz);

// Where packs are looked for: <root>/packs/<pack>/package.json. For the log and the docs.
std::string GungnirHost_PacksRoot();
