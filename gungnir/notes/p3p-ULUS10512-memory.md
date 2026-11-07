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

## NEW GAME and the protagonist select

Choosing NEW GAME takes the title phase to 10 (2 frames), 11 (the title fades to black, about 28
frames at 60 Hz) and 20, then the title is freed. About 8 frames later the select's object appears, and
it runs the "Welcome to the world of P3P" dialogue and then the choice.

| Address | What | Values |
|---|---|---|
| `0x09363AD0` | The select's object: first word (allocation size) | 0xC0; it points to itself at +0x1C (check both, as with Config) |
| `0x09363B00` (+0x30) | The choice's fade-in | 0 → 0xFF over its 10 game frames |
| `0x09363B04` (+0x34) | State | 1, 2, 3 the dialogue, 4 the choice appearing, 5 choosing |
| `0x09363B08` (+0x38) | Cursor | 0 the male protagonist, 1 the female |
| `0x09363B0C`, `0x09363B10` | Floats: the two portraits' x offsets | animate as the cursor moves |
| `0x09363B14` (+0x44) | Float: the hover | 0 him, 1 her, eased (1 − cos) over 10 game frames as the cursor moves; also 1 → 0 as the choice appears |
| `0x09363B18` (+0x48) | Float | 1.0 while he's hovered, 0 while she is (jumps) |

The backgrounds are `#509BF9` (his, left) and `#FB8BDE` (hers, right); the unselected portrait's
silhouette is `#1E83FE` (his) or `#F961D2` (hers). State 2 holds black for its 30 game frames; the
screen fades back in from about 42 to 108 frames (60 Hz) after state 2 starts.

The hovered portrait trails four silhouette copies away from the middle (from a 30 fps recording): 20 PSP
px apart, all moving out one spacing a second while a new one comes out from behind the portrait. A copy
at d spacings out is flat, from about `#1579F4` (his) or `#F059C9` (hers) to the background, by
smoothstep((d − 0.5) / 3.5), so the farthest is gone at 4. Their edges ripple; not found in memory (the
select's object holds no timer for it). Choosing (Cross) takes
the state to 6, "Begin the story as the ... main character?".

Orpheus art: `data/camp/persona/pst_001.tmx` (his) and `pst_0AE.tmx` (hers) in `PSP_GAME/USRDIR/umd0.cpk`
(a CRI CPK, CRILAYLA-compressed entries): 256x256 TMX0, 8-bit with a PS2-swizzled 256-colour CLUT and
alpha 0..0x80. `pst_0A9` is a third recolour.

## Conversations and choices (message windows)

Found with the WebSocket debugger on the emulator (log-only memory breakpoints, backtraces from pausing
ones). Static data, the same in every scene.

| Address | What |
|---|---|
| `0x08C3E73C` + 0xC | The first of a list of message windows (11 at the protagonist select). A node's +0x4 is the next, +0xC its window. Windows are 0x130 apart from `0x08EED4F0`; the conversation's was `0x08EEDFA0` |
| window + 0x0 | State. Bits 0–2: 3 or more while its text draws. Bits 3–5: the options' text, 0x18 appearing, 0x20 shown. Bits 10–11: 0x800 while it's asking a question (set once when the choice opens; the choice's input runs on it, so clearing it freezes the cursor) |
| window + 0x4 | The scene's message file (`MSG1`, Atlus BMD: a table of type/pointer pairs, type 1 a choice such as `msg_YN`) |
| window + 0x1C | The message being shown |
| window + 0x20, + 0x40 | The conversation text's and the options' layout: runs of glyphs. A run's +0x8 is its line's y (options sort by it), +0x18 its glyph count, +0x1C its first glyph, +0x24 the next run. A glyph's +0x0 (u16) is its letter (ASCII; `0x83F6` trails), +0x10 its colour as RRGGBBAA, +0x28 the next glyph |
| window + 0x48 (u16) | How many options |
| window + 0x4A, + 0x4C (u16) | The cursor. Writing both moves it; the highlight follows |
| `0x08E68298` | Game flags: flag n is bit n & 31 of the word at + (n >> 5) * 4 (`0x0880C150`). Flag `0x1007` (bit 7 of `0x08E68498`) is the female protagonist |

How a choice is drawn: the window loop at `0x08985510` draws the conversation (`0x0897E34C`) and the
options' text (`jal 0x0897E33C` at `0x08985698`, a1 = 1, more than 0 once all of it is in; that moves
bits 3–5 from 0x18 to 0x20). The box and the highlight bar are queued from the window code around
`0x0898BB5C` (`jal 0x0898973C`, the box at alpha 0xFF) and `0x0898BBA0` (`jal 0x08989828`, the bar:
`#EC447F` with the female protagonist, else `#428AFF`; unselected options' text `#1058CD` for him).
Replacing those two with `nop` and the text call with `li v0, 1` leaves the conversation as it was (dimmed
behind the question) and the choice working with nothing of it drawn. The box: 272 x (14 + 21 per
option) PSP px at (13, 144) for two options, rim `#C7D0C9`, inner `#CDD5CF`, the bar 250 x 20 from 8 px
in, an 8 px shadow below; it grows up from its bottom edge over about 8 frames as it opens.

## Draw lists (not state)

`0x08D60000`–`0x08D80000` and its double buffer `0x08DB0000`–`0x08DD0000` hold the game's per-frame
sprite lists (counts, colours); they change with everything drawn and are rebuilt every frame, so
they're no use for reading state or for hiding things.
