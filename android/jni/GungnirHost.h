// The Gungnir Core host: PPSSPP behind gungnir-core's host interface (ext/gungnir-core/docs/HOST.md),
// so a pack can read the running PSP game's memory and draw a companion screen (a map, buttons,
// character stats) on a dual-screen handheld's second display. Android only.
//
// Packs: the player drops pack folders or .zip files into <memory stick>/PSP/GUNGNIR/packs/. They're
// copied into an app folder Core can open with plain file calls (a memory stick on an SD card is a
// content:// URI), at boot and when the game screen's picker opens. The game screen (the game's info
// page in the main menu) chooses the pack per game, never while it runs.

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

// ---- the game screen's picker (UI/GameScreen.cpp), for a game that isn't running. UI thread. ----
// The pack is never switched while a game runs: a choice applies from the game's next launch.

struct GungnirPackEntry {
	std::string folder;  // its folder under packs/: its ID
	std::string name;    // package.json's "name"
};

// Lists the installed packs that list the game with this disc ID (PARAM.SFO's DISC_ID), by folder.
// [sync] first brings packs in from the drop folder; that's skipped while a game runs, as it may
// uninstall packs.
std::vector<GungnirPackEntry> GungnirHost_PacksForGame(const std::string &discId, bool sync);
// A game's choice: GUNGNIR_CHOICE_AUTO (the first pack that lists it), GUNGNIR_CHOICE_NONE, or a folder.
extern const char *const GUNGNIR_CHOICE_AUTO;
extern const char *const GUNGNIR_CHOICE_NONE;
std::string GungnirHost_ChoiceForGame(const std::string &discId);
void GungnirHost_SetChoiceForGame(const std::string &discId, const std::string &choice);
// Whether a game is running (booted, until it stops), when the picker isn't offered.
bool GungnirHost_GameRunning();
