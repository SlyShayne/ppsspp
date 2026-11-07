# Persona 3 Portable (ULUS10512) — memory notes for the companion

Found on PPSSPP (this fork) in an Android emulator, with GungnirHost's developer hook
(`dump`/`press`, see `android/jni/GungnirHost.cpp`) and `F:\Android\re\p3p_re.py`-style diffs of
24 MB user-RAM snapshots. US release only; other regions will differ. All values are little-endian
32-bit unless noted. The title and Config data live on the heap: they read `0xCCCCCCCC` (freed)
while that screen isn't up. Same addresses across several attract-mode loops in one boot; not yet
checked across a full restart.

## Title screen

| Address | What | Values |
|---|---|---|
| `0x093BAF30` | Title phase | 0, 2, 3, 4 setting up (about 38 frames, black on screen), 5 fading in (358 frames), 6 then 7 PRESS ANY BUTTON, 8 then 9 main menu, 10 or 16 Config (both seen, steady), 18 the data install prompt; `0xCCCCCCCC` in the attract mode (logos, opening), and heap pointers such as `0x0960B2C0` right after boot. Left idle, the menu goes back to 7 |
| `0x093BAF34` | (with the phase) | 0 while fading in, 8 after |
| `0x093BAF38` | Timer within the phase | counts up |
| `0x093BAF3C` | Background breathing clock | half a unit a frame; mod 540 (18 s): brightening 0 to ~186, bright to ~375, dimming to 540 |
| `0x093BAF48` | Title art | 1 female protagonist, 0 male (alternates between visits) |
| `0x093BAF4C` | ? | 0 on PRESS ANY BUTTON, 0x10 on the menu |
| `0x093BAF58` | Menu cursor | 0 NEW GAME, 1 LOAD GAME, 2 CONFIG, 3 DATA INSTALL (wraps) |
| `0x093BAF5C` | Previous cursor | |
| `0x093BAF60` | Menu highlight position | 16.16 fixed point, the row it's at; eases halfway to the cursor each game frame, whether the cursor was moved or written |
| `0x093BAF68` | Float: the menu's opacity | 1.0 on the menu, eases to 0 as Config opens |
| `0x093BAF64` | Float: PRESS ANY BUTTON ↔ menu crossfade | 0.0 on PRESS ANY BUTTON, 1.0 on the menu. Forcing 0.0 each frame: the menu nearly vanishes but PRESS ANY BUTTON comes back, and the game steps it toward 1.0 before drawing |
| `0x08D4BBCE` (u8) | ? | 0 before the menu, 1 on it |

Timing: Start skips the opening to the fade-in. The fade-in (~6 s) ignores buttons; PRESS ANY
BUTTON then lasts until ~12 s after Start, and the attract mode comes back. The d-pad doesn't count
as "any button"; Cross does. The menu opens with the cursor on LOAD GAME.

The fade-in, in frames from the start of phase 5, measured on the game's screen: the character art
first (0 to ~110), then the gradient and moon (~130 to ~340), then PRESS ANY BUTTON (~270 to ~330).
The background is vertex colours, not a texture: radial from the top-right corner, `#4D4FAE` to
`#05072F` about 1350 px (4x) away, breathing down to about `#020328`.

## Config screen (main menu → CONFIG)

| Address | What | Values |
|---|---|---|
| `0x093C1C8C` | Row cursor | 0 Voices, 1 Auto Text, 2 Cursor Memory, 3 Tactics Memory, 4 Invert Rotation, 5 Data Install, 6 Confirm (wraps) |
| `0x093C1C90` | Previous row | |
| `0x093C1CA4` … `0x093C1CB8` | The six options, one word each in row order | 1 ON, 0 OFF |
| `0x093C1CBC` … `0x093C1CD0` | Which side of each switch is lit | 1 − the option |
| `0x093C1C40` | The Config object's first word (its allocation size) | 0x4A0. **The slot is reused**: LOAD GAME's file loading puts an object of its own there (size 0x160), which also points to itself, so check this too before touching anything here. Writing to the loader's object crashed LOAD GAME |
| `0x093C1C5C` | The Config object's pointer to itself | set when it's made |
| `0x093C1C60` | Config's opacity | 0xFF00 while it shows. Writing 0 each frame hides all of it (flat panels, sprites, text) and leaves the title behind; input still works |
| `0x093C1CF0` (object + 0xB0) + 0x30·k, k = 0..16 | Per-element fades: bits 16–23 are the alpha | Opening: +0xB0, +0x380 and +0x3B0 (the panel) go 0x1F→0xFF in 8 game frames, then the other fourteen (the rows) 0x3F→0xFF in 4; all then read 0x00FFFFFF. Closing: all 0xCC→0 in 5, then the phase goes back to 9 |

Right sets OFF and Left sets ON (no wrap). With Voices OFF, Auto Text shows NONE (its value is
kept). Circle backs out; Confirm (row 6, Cross) applies. Each row has a help line under the list.

How it's drawn (from the game's screen at 4x and its dumped textures): the bars, plates, underlines and
slanted switch halves are flat colours (`#2695FF` header, `#6CB0F9` body, `#003B5D` dark, `#FFC347`
lit), not textures. Row `i`'s top is at y 46.25 + 23i (PSP px). The CONFIG word, ON/OFF/NONE/OK, the
help arrow and the button prompts are atlas sprites, tinted. Row names and help lines are drawn a letter
at a time, each letter its own 32x32 white texture at 0.82 scale, placed wherever the game has room
(so only the data hash in the texture's name is stable). Help lines, with the game's line breaks:
Turn event voices / ON/OFF; Auto advance text / during voiced events; Remember the cursor position /
during battle; Remember Tactics settings / after battles; Invert the rotation / of the battle command
menu; Turn Data Install / ON/OFF; Confirm the settings / and return to the game.

The title's portraits swap each time PRESS ANY BUTTON and the menu change places (`0x093BAF48` flips
as the phase becomes 8 or 6): the incoming one fades in sliding from 48 PSP px to the left, the outgoing
one fades out in place, both on the crossfade at `0x093BAF64`.

## Draw lists (not state)

`0x08D60000`–`0x08D80000` and its double buffer `0x08DB0000`–`0x08DD0000` hold the game's per-frame
sprite lists (counts, colours); they change with everything drawn and are rebuilt every frame, so
they're no use for reading state or for hiding things.
