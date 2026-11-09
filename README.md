Gungnir Portable
================

A PSP emulator for dual-screen Android handhelds, such as the AYN Thor. It's a fork of
[PPSSPP](https://github.com/hrydgard/ppsspp) with [Gungnir Core](https://github.com/Unix-Epoch/gungnir-core) built in.

Gungnir, Odin's spear, never misses its mark. Here it aims at the second screen: while the game plays on the
main display, a **companion pack** reads the running game's memory and draws a live screen of its own on the other
one. A pack can show stats, maps, calendars and menus, take taps and send them back to the game as input, and hide
parts of the game's own screen it has moved down.

The first pack is a companion for Persona 3 Portable (ULUS10512):
- A home screen for the town: the protagonist's status, mood and social stats; the equipped Persona; a calendar of
  the month; and the Social Links you've started, each with its card and person.
- A touch keyboard for the name entry screen.
- Dialogue choices laid out for touch, with the protagonist beside them.

Each screen follows the protagonist's colours, in the game's own font and art.

Packs
-----

A pack is a folder (or a .zip of one) of JSON, Lua and assets. The format is documented in Gungnir Core's
[FORMAT.md](https://github.com/Unix-Epoch/gungnir-core/blob/main/docs/FORMAT.md).

To install one, drop it into `PSP/GUNGNIR/packs/` on the memory stick. Packs are copied into the app when a game
starts. A game's info page in the main menu chooses which pack it uses, or none; a choice applies from the game's
next launch.

Keep one copy of a pack in that folder. A folder and a .zip of the same pack both install under one ID, and
replace each other.

Packs that draw the game's own art (like the Persona 3 Portable one) don't ship it. Their tools build it from your
copy of the game; see `gungnir/tools/`.

What's here
-----------

| Path | What |
|---|---|
| `android/jni/GungnirHost.cpp` | The Gungnir host: PPSSPP behind Gungnir Core's host interface (memory, input, frames, audio) |
| `ext/gungnir-core` | Gungnir Core (submodule): the companion runtime |
| `gungnir/packs/` | Packs, starting with `slyshayne.p3p`, the Persona 3 Portable companion |
| `gungnir/tools/` | Builds a pack's art and fonts from the game's data |
| `gungnir/notes/` | What's known about a game's memory, for writing its pack |

Everything else is PPSSPP.

Building
--------

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/SlyShayne/gungnir-portable.git
```

The companion is Android only. Build the APK with Gradle from the repository root:

```bash
./gradlew assembleOptimizedRelease
```

PPSSPP's own build instructions, for other platforms and the tests, are in [docs/building.md](docs/building.md).

Credits
-------

Gungnir Portable is built on **PPSSPP**, the fast and portable PSP emulator, created by Henrik Rydgård with code by
many contributors (see the Credits screen in the app). PPSSPP was first released under the GPL 2.0 (and later) in
November 2012, and this fork is under the same license.

- PPSSPP website: https://www.ppsspp.org/
- PPSSPP source: https://github.com/hrydgard/ppsspp
- PPSSPP Discord: https://discord.gg/5NJB6dD

Gungnir Core is by [Unix-Epoch](https://github.com/Unix-Epoch).

This fork isn't affiliated with or supported by the PPSSPP project. Please report problems with it here, not to
PPSSPP.

Persona 3 Portable is a trademark of Atlus. No game data is included in this repository.
