// The Gungnir Core host: PPSSPP behind gungnir-core's host interface (ext/gungnir-core/docs/HOST.md),
// so a pack can read the running PSP game's memory and draw a companion screen (a map, buttons,
// character stats) on a dual-screen handheld's second display. Android only.
//
// Packs: the player drops pack folders or .zip files into <memory stick>/PSP/GUNGNIR/packs/. They're
// copied into an app folder Core can open with plain file calls (a memory stick on an SD card is a
// content:// URI), at boot and when the pause menu's picker opens. The pause menu chooses the pack
// per game.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

// How the host asks the Java side for something: "gungnir_companion" with "show" or "hide", and
// "gungnir_haptic" with the haptic's number (1 tap ... 6 heavy). Called on the emu thread.
typedef void (*GungnirCommandSink)(const char *command, const char *param);

// Once, at startup. [appRoot] is an app-private folder: installed packs, their data, and choices.
void GungnirHost_Init(const std::string &appRoot, GungnirCommandSink sink);

// Emu thread, after every host frame (NativeFrame). Keeps the companion ticking while the game is
// paused, under PPSSPP's menu: taps, timelines and read-only pages keep working.
void GungnirHost_AfterHostFrame();

// Audio thread, after PPSSPP has mixed the game's audio: adds the pack's sounds. Interleaved stereo.
void GungnirHost_MixAudio(int16_t *stereo, int frames, int sampleRateHz);

// Where installed packs live (<appRoot>/packs), and where the player puts them. For the log and the docs.
std::string GungnirHost_PacksRoot();
std::string GungnirHost_DropFolder();

// ---- the pause menu's picker. Emu thread (PPSSPP's UI runs on it too). ----

struct GungnirPackEntry {
	std::string folder;  // its folder under packs/: its ID
	std::string name;    // package.json's "name"
};

// Whether a game with a disc ID is running, so there's something to choose a pack for.
bool GungnirHost_HasGame();
// Brings packs in from the drop folder, then lists the installed ones that list this game, by name.
std::vector<GungnirPackEntry> GungnirHost_RefreshPacksForGame();
// The same list without looking in the drop folder: cheap, for showing the current pack's name.
std::vector<GungnirPackEntry> GungnirHost_PacksForGame();
// This game's choice: GUNGNIR_CHOICE_AUTO (the first pack that lists it), GUNGNIR_CHOICE_NONE, or a folder.
extern const char *const GUNGNIR_CHOICE_AUTO;
extern const char *const GUNGNIR_CHOICE_NONE;
std::string GungnirHost_Choice();
// Saves this game's choice and switches the companion to it now.
void GungnirHost_SetChoice(const std::string &choice);
// The pack running now, by folder; "" for none.
std::string GungnirHost_RunningPack();
