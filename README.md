Vajra
=====

PPSSPP for dual-screen Android handhelds, such as the AYN Thor.

The vajra of myth is a thunderbolt you hold in one hand, with a head at each end. This fork of
[PPSSPP](https://github.com/hrydgard/ppsspp) gives a handheld PSP both of its screens: the game plays on the main
display while the second one shows a live **companion screen** built for that game.

Companion screens
-----------------

A companion screen comes from a **pack**, run by [Gungnir Core](https://github.com/Unix-Epoch/gungnir-core). A pack
reads the running game's memory and draws whatever helps on the second screen: stats, maps, calendars, menus. It can
take taps and send them back to the game as input, patch the game, and hide parts of the game's own screen it has
moved down. Anyone can write one for any PSP game; a pack is a folder of JSON, Lua and assets, in the format
documented in Gungnir Core's [FORMAT.md](https://github.com/Unix-Epoch/gungnir-core/blob/main/docs/FORMAT.md).

Without a pack, Vajra is PPSSPP, and the game stays on the main display.

### Installing a pack

Drop the pack (its folder, or a .zip of it) into `PSP/GUNGNIR/packs/` on the memory stick. Packs are copied into
the app when a game starts. A game's info page in the main menu chooses which pack it uses, or none; a choice applies
from the game's next launch.

Keep one copy of a pack in that folder. A folder and a .zip of the same pack both install under one ID, and replace
each other.

### Packs in this repository

- `gungnir/packs/slyshayne.p3p`: Persona 3 Portable (ULUS10512). A home screen with the protagonist's status, social
  stats, Persona, calendar and Social Links; a touch keyboard for name entry; and dialogue choices laid out for
  touch.

Packs that draw a game's own art don't ship it. Their tools in `gungnir/tools/` build it from your copy of the game.

What's here
-----------

| Path | What |
|---|---|
| `android/jni/GungnirHost.cpp` | The host: PPSSPP behind Gungnir Core's host interface (memory, input, frames, audio) |
| `android/src/org/ppsspp/ppsspp/GungnirCompanionActivity.java` | Puts the companion on the second display |
| `ext/gungnir-core` | Gungnir Core (submodule): the companion runtime |
| `gungnir/packs/` | Packs |
| `gungnir/tools/` | Builds a pack's art and fonts from a game's data |
| `gungnir/notes/` | What's known about a game's memory, for writing its pack |

Everything else is PPSSPP.

Building
--------

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/SlyShayne/vajra.git
```

The second screen is Android only. Build the APK with Gradle from the repository root:

```bash
./gradlew assembleOptimizedRelease
```

PPSSPP's own build instructions, for other platforms and the tests, are in [docs/building.md](docs/building.md).

Credits
-------

Vajra is built on **PPSSPP**, the fast and portable PSP emulator, created by Henrik Rydgård with code by many
contributors (see the Credits screen in the app). PPSSPP was first released under the GPL 2.0 (and later) in
November 2012, and this fork is under the same license.

- PPSSPP website: https://www.ppsspp.org/
- PPSSPP source: https://github.com/hrydgard/ppsspp
- PPSSPP Discord: https://discord.gg/5NJB6dD

The companion runtime is [Gungnir Core](https://github.com/Unix-Epoch/gungnir-core), by Unix-Epoch.

This fork isn't affiliated with or supported by the PPSSPP project. Please report problems with it here, not to
PPSSPP.

Game names are trademarks of their owners. No game data is included in this repository.
