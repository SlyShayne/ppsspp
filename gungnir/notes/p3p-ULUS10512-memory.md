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
| `0x09363B04` (+0x34) | State | 1, 2, 3 the dialogue, 4 the choice appearing, 5 choosing, 6 its question, 7 one chosen (the other portrait slides off its side as the box finishes closing, 15 PSP px a 60 Hz frame, straight), 8 to 10 the difficulty (10 its question), 11 confirmed (the screen fades to black, straight, in about 58 frames), 12 "Now, please enjoy the game." |
| `0x09363B08` (+0x38) | Cursor | 0 the male protagonist, 1 the female |
| `0x09363B0C`, `0x09363B10` | Floats, him then her: how far forward (toward the middle) each portrait is, in PSP px | -10 each through the dialogue; as the choice appears he eases to 5, then 9.2 while hovered and -28.8 while not (she stays at -10 until first switched to) |
| `0x09363B14` (+0x44) | Float: the hover | 0 him, 1 her, eased (1 − cos) over 10 game frames as the cursor moves; also 1 → 0 as the choice appears |
| `0x09363B18` (+0x48) | Float | 1.0 while he's hovered, 0 while she is (jumps) |

The backgrounds are `#509BF9` (his, left) and `#FB8BDE` (hers, right); the unselected portrait's
silhouette is `#1E83FE` (his) or `#F961D2` (hers). State 2 holds black for its 30 game frames; the
screen fades back in from about 42 to 108 frames (60 Hz) after state 2 starts.

Through the dialogue both portraits are in colour, each trailing outward; each side's colour runs from its
edge to behind its portrait, white between. From the choice on, the one not hovered is a flat silhouette in
its shade with no trail. The flat colour wipes across a portrait from its middle-facing side out to its outer
side as it goes flat, and back the other way as it comes into colour, on the hover: the one coming in over
hover 0.5 of the way, then the one going out (so as the choice appears, with the hover going 1 to 0, she
goes flat and he stays in colour).

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
| window + 0x20, + 0x40 | The conversation text's and the options' layout: runs of glyphs. A run's +0x8 is its line's y (options sort by it), +0x18 its glyph count, +0x1C its first glyph, +0x24 the next run. A glyph's +0x0 (u16) is its letter (ASCII, and `0x83F6` a space), +0x10 its colour as RRGGBBAA, +0x28 the next glyph |
| window + 0x48 (u16) | How many options |
| window + 0x4A, + 0x4C (u16) | The cursor. Writing both moves it; the highlight follows |
| `0x08E68298` | Game flags: flag n is bit n & 31 of the word at + (n >> 5) * 4 (`0x0880C150`). Flag `0x1007` (bit 7 of `0x08E68498`) is the female protagonist |

How a choice is drawn: the window loop at `0x08985510` draws the conversation (`0x0897E34C`) and the
options' text (`jal 0x0897E33C` at `0x08985698`, a1 = 1, more than 0 once all of it is in; that moves
bits 3–5 from 0x18 to 0x20). The box and the highlight bar are queued from the window code around
`0x0898BB5C` (`jal 0x0898973C`, the box at alpha 0xFF) and `0x0898BBA0` (`jal 0x08989828`, the bar:
`#EC447F` with the female protagonist, else `#428AFF`; unselected options' text `#1058CD` for him).
Opening and closing are drawn by other calls: `jal 0x0898973C` at `0x0898B848` (the box as it opens, 6
frames at 30 Hz, scaled by a quarter sine of a counter at `0x08C3EF5E`) and `0x0898B644`, with its bar at
`0x0898B688` (`jal 0x08989828`), as it closes (5 frames, straight). Replacing all five queue calls with `nop`
and the text call with `li v0, 1` leaves the conversation as it was (dimmed behind the question) and the
choice working with nothing of it drawn. The box: 272 x (14 + 21 per option) PSP px at (13, 144) for two
options, both from its bottom edge. An opaque `#C7D0C9` rim, 5 px wide (11 at the right, 7 at the
bottom), round a panel of the same colour at about 90% opacity (`#CDD5CF` over white, `#B6BEB8` over
near-black); the bar 250 x 20 from 8 px in; an 8 px shadow below.

## The Dark Hour clock

Seen on the first night (the station, "It's almost midnight..."): a pink clock on black ticks to XII, the screen
turns green at midnight, and the clock bursts apart, its pieces flying off every edge before the green fades to
black. All of it is 2D (through-mode) geometry the game works out itself, and it goes on drawing pieces well off the
screen (y past 500).

| Address | What |
|---|---|
| `0x08E96780` | Pointer to the clock's block while it's up (`0x09410110` here); its piece records start at +0x10. Also at `0x08F8CE44` |
| record (0x34 bytes, 36 of them, slot 31 unused) | +0x4, +0x8 position; +0xC, +0x10 velocity a frame; +0x14 angle (degrees, clockwise); +0x18 its turn a frame; +0x1C zoom (shared: 1 until the burst, then up 0.03 a 30 Hz frame); +0x20 that step; +0x24.. per kind |

Records 0-2 are the hands (all three at 360 the moment it's midnight), 3-14 the numerals (+0x2C, +0x30: 15.5, 8.5,
half their size; each a 31x17 cell of the 128x128 atlas at `0x093A1C70`, tinted `#0B6D2B`, not scaled by the zoom),
15-26 the triangle markers, 27-30 the inner ring's arcs and 32-35 the outer ring's (+0x24, +0x28 their start and end
angles). Every piece but the numerals scales with the zoom; each is rigid in its own frame, which is how the pack
redraws them (`gungnir/tools/p3p_clock.py`). The fill colour is `#0C6E2C`. The background: black until the hands
reach 360, then `#001400`, whose alpha falls from full at zoom 2.79 to none at 4.03; the block is freed at the end.

Game flag `0x1429` (word `0x08E6851C`, bit 9) is the Dark Hour: the only flag that changes across the scene, set
early in it (before midnight) and still on in the green scenes after. After the clock the game's screen holds
black about 58 frames, then fades the green station in over about 38. Game flag n is bit `n & 31` of the word at
`0x08E68298 + (n >> 5) * 4`; the pack reads it with `gameFlag()` in `scripts/main.lua`.

## The name keyboard

Seen on the first night at the dorm's desk ("Below it is a blank to sign your name..."). Four blocks of 5 x 6 keys
(A-Z, a-z, 0-9, symbols), then Del (circle), OK (cross), L, R (the text cursor) and End (start).

| Address | What |
|---|---|
| task `M_Name_KeyProc` | The keyboard is this task. Tasks are 0x54-byte entries named at +0 (`0x08F8CDB8` here), +0x30 and +0x34 their functions, +0x38 their data: the keyboard's block. While it runs, the run list (around `0x08F94B7C`) has an entry of its update function `0x08874E24`, 0, then the task. Entries move as other tasks come and go. A pool slot keeps its old contents after its task ends, so a fixed slot like `0x08F8CDF0` isn't enough to tell the keyboard is up |
| block + 0x14 | State: 0 coming in (about 2 s), 1 typing, 3 after End ("Proceed?" and its Yes/No). No goes back to 1; Yes stays 3 until the block goes |
| block + 0x1C, + 0x20 | The cursor's column (0-19, five a block) and row (0-5). Writing them moves it; the game works + 0x24 out again |
| block + 0x24 | Its key: block * 30 + row * 5 + column in the block. + 0x28.. the same three again, + 0x34.. the previous |
| `0x08C3BD90`, `0x08C3BD7C` | The first and last name: 8 letters of 16 bits each, `0x8080` a blank (`0xA180` A, `0xC180` a) |
| `0x08C3BD74` | The text cursor: 0-7 the first name, 8-15 the last. L and R move it; Del blanks the letter under it |

A letter's code is 0x80 then ASCII + 0x60 for letters, digits and most symbols; the minus, ×, ÷ and the middle dot
have 0x82 first instead (`0x82AC`, `0x82AE`, `0x82B0`, `0x828A`, high byte first).

Its animations, at 60 frames a second: coming in (state 0) the frame fades in over 8 frames, then each row
fades in over 8, 11 apart from 16, and at 100 the cursor and the buttons that can be used light up. A row the
cursor leaves goes from yellow back to blue over 36. Once the cursor has rested about 170 frames, a soft black
disc (texture dump name `075839fcf519dff4`) pulses round the ball: from 30 to 44 PSP pixels and alpha 0 to
0x7B over 60 frames, back over 60, gone for 60. L is lit unless the text cursor is at 0, R unless at 15; a
button that can't be used is drawn with the same art 88 to the left and 33 down in the frame texture.

End works only with a letter in each name (the start handler at `0x08875C14` counts blanks with `0x0887333C`).
The keyboard's code is the task at `0x08874E24`. Its buttons are drawn by `jal 0x08873ECC` at `0x08875148`:
`nop` there leaves everything else, including the name's underlines and text cursor, which use the buttons'
icon texture. Its frame, font atlas and cursor ball are textures of their own (PPSSPP dump names, less the
address: `761e13dcd727d831`, `d71abe705af2670d`, `7be1e7f570d06089`), so making those transparent hides the
rest. After Yes the screen fades to black about 12 frames after the choice closes, over 72, then holds black
about 40 more before the next scene fades in.

## The protagonist, Personas, social stats and links (the home screen)

Found from the town save (4/22 after school) with the menus open, starting from the CWCheat list for ULUS10512
(almarsguides.com), whose addresses are these less 0x08000000 plus 0x00800000.

| Address | What |
|---|---|
| `0x08E63BCC`, `0x08E63BDE` | Last and first name: 8 letters of 16 bits, 0x80 then ASCII + 0x60 (`0x80AD` M) |
| `0x08E63BF0` | The protagonist's character record (the party's are `0x08E68BB8 + 0x118 * (character - 2)`, Yukari 2, Aigis 3, Mitsuru 4, Junpei 5, Fuuka 6, Akihiko 7, Ken 8, Shinjiro 9, Koromaru 10): +6 level (byte), +8 HP, +0xA SP, +0x3C/+0x3E/+0x40 Academics, Charm and Courage points (the protagonist's), +0x44 EXP, +0x48 condition: 0 Good, 2 Great, 3 Tired, 5 Sick (1 and 4 draw nothing). A companion's Persona is at +0x88 |
| `0x08BB911C + 4 * (11 * level + character)` | Base max HP, then SP (u16 each). `0x08A324A0` adds passive skills (0x219, 0x21A, 0x21B, 0x26C, 0x237, 0x238) and accessory boosts (`0x08A2EA6C` with 0x1A..0x1E, 0x8E) |
| `0x08E68758` | Funds (u32). `0x08E6875C`.. the party's other three slots (character numbers, u16) |
| `0x08E64C24` | The protagonist's Persona in use: an index into the stock at `0x08E64C28`, 0x34 bytes each: +0 in use, +2 id, +4 level, +8 EXP, +0xC skills (u16 x 8), +0x1C St Ma En Ag Lu (bytes) |
| `0x08E64ECC + 0x34 * (id - 1)` | The compendium, by id, the same layout |
| `0x08C54530 + 17 * id` | Persona names. `0x08C5B9C2 + 14 * id` is each one's arcana (1 Fool .. 22 Aeon; the 14-byte entry is its base data) |
| `0x08E63C44` | Social links begun: 28 records of 16 bytes, +4 the link's id (0 none), +6 its rank. The S.LINK list sorts them by arcana |
| `[0x08D40EA0] + 8 + 116 * id` | A link's entry: byte +0 its arcana. `[0x08D40EA4] + 8 + 64 * id` its name ("SEES", "Classmate", ...). Both tables are loaded data; the pointers are static |
| `0x08E64820` | The date: days since 1 April 2009 (u16; `0x08E64818` holds the same). `0x08E6481A` the time of day (byte, 4 After School). 1 April 2009 was a Wednesday |
| `0x08BF9D0C + max(0, day - 4)` | The moon's age, 0..29: 14 full (the HUD's "Next" counts days to the next 14), 7 and 22 half, 29 new as the calendar draws them |
| `0x08BF9BEC` | Holidays: (month, day) s16 pairs ending with -1. Sundays and these are red (`0x08819C58`) |

EXP: the protagonist reaches level L at the u32 at `0x08BBA248 + 4 * L` (`0x0880E1CC`); NEXT EXP is that for
level + 1 less the EXP at +0x44. A Persona (but the party's, ids 0xC0..0xDF) reaches level L at
L^3 * c0 * (growth * c1 + c2) + c3 in single floats, truncated (`0x08810750`): c0..c3 are the floats at `0x08BA99A0`
(1.4, -0.019, 3.1, 10), growth the byte at +3 of its entry in `[0x08C40CDC]` (`0x08C5B9C0`, 14 bytes an id; +1 is
the arcana).

A link's person is the byte at +40 of its entry: a character number, whose picture is
`data/commu/bustup/i_bust%02X_%c.tmx` with the u16 at `0x08BE16E0 + 2 * character` for him, `0x08BE1724` for her
(`0x08933330`; flag 0x1007 picks). The cards are `data/commu/card/c_card%02x.tmx` by arcana - 1. The menus' atlas
(texture dump `09367a10d5c9ffce74e8c8c4`) holds the moods' faces (Great, Tired, Good, Sick at (1, 129), (21, 129),
(41, 129), (61, 129), 19x18) drawn over the disc at (1, 148, 22x21) tinted `#4D6B89`; the faces are tinted
`#F3FFA3` (Great), `#99F3FF` (Good, Tired) and `#FFA3CF` (Sick). The space glyph in a message is `0x83F6`.

Social stat ranks (`0x0880D184`): the first rank whose cumulative steps the points haven't reached, else 6. The
steps (from loaded data, `[0x08D40ECC] + 8`): Academics 20, 35, 45, 55, 75; Charm 15, 15, 15, 25, 30; Courage 15, 15,
15, 15, 20. The rank names are strings at `0x08BA1C9C`.. (Timid .. Badass, Plain .. Charismatic, Slacker .. Genius).

## Draw lists (not state)

`0x08D60000`–`0x08D80000` and its double buffer `0x08DB0000`–`0x08DD0000` hold the game's per-frame
sprite lists (counts, colours); they change with everything drawn and are rebuilt every frame, so
they're no use for reading state or for hiding things.
