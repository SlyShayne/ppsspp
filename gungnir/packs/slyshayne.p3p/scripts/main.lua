-- Persona 3 Portable (USA, ULUS10512): the title screen and Config on the second screen.
-- Reads the game's state from memory (gungnir/notes/p3p-ULUS10512-memory.md) and turns taps into the
-- button presses the player would make: move the cursor by the shortest way, then confirm or switch.

local TITLE_PHASE = 0x093BAF30  -- 5 fading in, 7 PRESS ANY BUTTON, 9 menu, 14 LOAD GAME, 15 then 16 Config
local TITLE_ART   = 0x093BAF48  -- 1 female protagonist, 0 male
local MENU_CURSOR = 0x093BAF58  -- 0 NEW GAME, 1 LOAD GAME, 2 CONFIG, 3 DATA INSTALL
local TITLE_CROSSFADE = 0x093BAF64  -- float: 0 PRESS ANY BUTTON, 1 the menu, eased a fifth of the way a game frame
local CFG_CURSOR  = 0x093C1C8C  -- 0..6, Confirm last
local CFG_VALUES  = 0x093C1CA4  -- six words, 1 ON
local CFG_SIDES   = 0x093C1CBC  -- six words, 1 - the value
-- Config's object. Its heap slot is reused by others (LOAD GAME's file loading, for one), which also
-- point to themselves, so it's only Config's when its first word, the allocation size, is 0x4A0 too.
local CFG_OBJECT  = 0x093C1C40
local CFG_SIZE    = 0x4A0
local CFG_ALPHA   = CFG_OBJECT + 0x20  -- 0xFF00 while Config shows: its opacity, all of it
local CFG_FADE_PANEL = CFG_OBJECT + 0xB0  -- bits 16-23: the panel's fade (its first 8 game frames in)
local CFG_FADE_ROWS  = CFG_OBJECT + 0xE0  -- bits 16-23: the rows' fade (the next 4); both go out in 5
local MENU_PILL   = 0x093BAF60  -- 16.16: the menu highlight's row, eased halfway to the cursor a game frame
local MENU_ALPHA  = 0x093BAF68  -- float: the menu's opacity, eased out as Config opens and back as it closes

-- The protagonist select after NEW GAME (its object, checked like Config's).
local SEL_OBJECT  = 0x09363AD0
local SEL_SIZE    = 0xC0
local SEL_STATE   = SEL_OBJECT + 0x34  -- 1, 2, 3 the dialogue, 4 the choice appearing (10 game frames), 5 choosing
local SEL_CURSOR  = SEL_OBJECT + 0x38  -- 0 him, 1 her
local SEL_HOVER   = SEL_OBJECT + 0x44  -- float: 0 him, 1 her, eased over 10 game frames as the cursor moves
-- Floats, him then her: how far forward (toward the middle) each portrait is, in PSP px; about 9.3 while
-- hovered and -29.3 while not, eased as the cursor moves.
local SEL_OFFSETS = SEL_OBJECT + 0x3C
local SCALE_X = 4  -- this screen's pixels per PSP pixel
-- After the choice: 6 its question, 7 one chosen (the other portrait slides off its side, 15 PSP px a frame,
-- straight), 8 to 10 the difficulty, 11 it confirmed (the game's screen fades to black, straight, in about
-- 58 frames), 12 on.
local SEL_CHOSEN = 7
local SEL_CONFIRMED = 11
local SLIDE_OUT = 15 * 4  -- this screen's pixels a frame
local STORY_FADE = { 0, 58 }
-- After NEW GAME, frames: black as the title fades out (phases 10, 11, 20 last ~36); then white as the
-- game's screen fades back in, measured from the select's state 2 (it holds black, then fades).
local BLACK_FADE = { 0, 34 }
local WHITE_FADE = { 42, 108 }
-- The portraits' trails on the game's screen (measured from a recording): four copies 20 PSP px apart,
-- each moving out one spacing a second, its colour eased from a darker shade to the background's.
local TRAIL_COPIES = 4
local TRAIL_PERIOD = 60

local BREATH_CLOCK = 0x093BAF3C -- counts half a unit a frame, wraps at 540 (18 s): the background's breathing

local MENU_ITEMS = 4
local CFG_ROWS = 7
local CONFIRM_ROW = 6
local HOLD = 4          -- frames a press is held
local STEP = 8          -- frames from one press to the next

-- The game's fade-in, measured on its top screen, in frames from the start of phase 5 (which lasts 358):
-- the character art first, then the gradient and moon, then PRESS ANY BUTTON, done as phase 7 begins.
local ART_FADE  = { 0, 110 }
local BG_FADE   = { 130, 340 }
local TEXT_FADE = { 270, 330 }

-- The breathing, over the clock's 540 units: back up from near black, hold, then down again.
local BREATH_UP, BREATH_HOLD = 186, 375
local BREATH_FLOOR = 0.0  -- the darkest is a flat #020328, a rect under the gradient

local function ramp(t, span)
    if t <= span[1] then return 0.0 end
    if t >= span[2] then return 1.0 end
    return (t - span[1]) / (span[2] - span[1])
end

local function breath()
    local c = mem.u32(BREATH_CLOCK) % 540
    local b
    if c < BREATH_UP then
        b = c / BREATH_UP
    elseif c < BREATH_HOLD then
        b = 1.0
    else
        b = (540 - c) / (540 - BREATH_HOLD)
    end
    -- Eased like the game's: slow at both ends.
    b = 0.5 - 0.5 * math.cos(math.pi * b)
    return BREATH_FLOOR + (1.0 - BREATH_FLOOR) * b
end

local frame = 0          -- the last update's game frame
local busyUntil = 0      -- a tap's presses run until this frame
local screen = "idle"
local fadeStart = nil
local blackStart = 0
local whiteStart = nil

local function float(address)
    local x = string.unpack("<f", string.pack("<I4", mem.u32(address)))
    if x ~= x or x < 0 then return 0 elseif x > 1 then return 1 end  -- not a number while it's set up
    return x
end

local function configObject()
    return mem.u32(CFG_OBJECT) == CFG_SIZE and mem.u32(CFG_OBJECT + 0x1C) == CFG_OBJECT
end

local function selectObject()
    return mem.u32(SEL_OBJECT) == SEL_SIZE and mem.u32(SEL_OBJECT + 0x1C) == SEL_OBJECT
end

-- Each Orpheus's offsets at the select: where the game last had it back and forward ({ back, front }).
local reach = {}
local stateSince = {}  -- the frame the select first reached each state
local chosen = nil     -- the protagonist chosen (0 him, 1 her), from state 7 on

local function rawFloat(address)
    local x = string.unpack("<f", string.pack("<I4", mem.u32(address)))
    if x ~= x or x < -1000 or x > 1000 then return 0 end  -- not a number while it's set up
    return x
end

-- The protagonist select, laid out as the game's screen: him (Orpheus-M here) on the left in blue, her
-- (Orpheus-F) on the right in pink, white between. Through the dialogue both are in colour, trailing
-- outward. From the choice on, the hovered one comes forward in colour, and the other goes back, flat in
-- its colour, its trail drawn in. The flat colour wipes over a portrait from the middle out to its side, and
-- off again the other way. Both move together, on the game's eased hover (0 him, 1 her).
local function select()
    local state = mem.u32(SEL_STATE)
    if not stateSince[state] then stateSince[state] = frame end
    -- Black, then the scene as the game's screen fades in from black (timed from state 2's start); and black
    -- again as the difficulty is confirmed and the game's screen fades out (state 11).
    if state == 2 and not whiteStart then whiteStart = frame end
    local white = whiteStart and ramp(frame - whiteStart, WHITE_FADE) or (state >= 3 and 1 or 0)
    local out = state >= SEL_CONFIRMED and ramp(frame - stateSince[SEL_CONFIRMED], STORY_FADE) or 0
    publish("shade", math.max(1 - white, out))
    local x = float(SEL_HOVER)
    local himFlat, herFlat = 0, 0
    if state == 4 then
        herFlat = 1 - x  -- as the choice appears (x 1 to 0), she goes flat
    elseif state >= 5 then
        himFlat, herFlat = x, 1 - x
    end
    publish("him_flat", himFlat)
    publish("her_flat", herFlat)
    -- How far each is forward (toward the middle), at 4x. The game's own (-10 PSP px each through the
    -- dialogue), but from the choice on each goes between where the game last had it back and where it last
    -- had it forward, on the hover, so the one going back moves with the one coming forward (the game jumps
    -- it there, hidden by its flat colour).
    -- The protagonist under the cursor: the word's low half (the difficulty list keeps its own cursor in the
    -- high half), and from the choice on, the one chosen then, whatever the cursor does after.
    local cursor = mem.u32(SEL_CURSOR) & 0xFFFF
    if state >= SEL_CHOSEN then
        chosen = chosen or cursor
        cursor = chosen
    end
    local function forward(side, address, weight)
        local at = SCALE_X * rawFloat(address)
        if state < 5 then
            reach[side] = { back = at, front = at }
            return at
        end
        local r = reach[side] or { back = at, front = at }
        if cursor == (side == "her" and 1 or 0) then r.front = at else r.back = at end
        reach[side] = r
        return r.back + (r.front - r.back) * weight
    end
    local him, her = forward("him", SEL_OFFSETS, 1 - x), forward("her", SEL_OFFSETS + 4, x)
    -- Once one is chosen (state 7), the other slides off its side at the game's speed, its colour with it.
    if state >= SEL_CHOSEN then
        local gone = math.min(SLIDE_OUT * (frame - stateSince[SEL_CHOSEN]), 2000)
        if cursor == 0 then her = her - gone else him = him - gone end
    end
    publish("him_dx", him)
    publish("her_dx", her)
    -- Each Orpheus's trail, like the portraits' on the game's screen: TRAIL_COPIES silhouettes drift away
    -- one spacing every TRAIL_PERIOD frames, blending into the background as they go (gone by the last
    -- spacing), while a new one comes out from behind. Copy i is drawn farthest first.
    local t = (frame % TRAIL_PERIOD) / TRAIL_PERIOD
    for i = 0, TRAIL_COPIES - 1 do
        local d = (TRAIL_COPIES - 1 - i) + t
        local f = math.min(1, math.max(0, (d - 0.5) / (TRAIL_COPIES - 0.5)))
        publish("trail_d" .. i, d)
        publish("trail_f" .. i, f * f * (3 - 2 * f))
    end
end

-- Config is up: its object is there and its data looks like itself (heap memory can hold leftovers).
local function configOpen()
    if not configObject() then return false end
    local row = mem.u32(CFG_CURSOR)
    if row >= CFG_ROWS then return false end
    for k = 0, 5 do
        local v = mem.u32(CFG_VALUES + 4 * k)
        if (v ~= 0 and v ~= 1) or mem.u32(CFG_SIDES + 4 * k) ~= 1 - v then return false end
    end
    return true
end

local function screenFor(phase)
    -- 0, 2, 3, 4: the title is being set up, black on the game's screen too (about 38 frames).
    if phase <= 4 then return "idle" end
    if phase == 5 then return "fade" end
    if phase == 6 or phase == 7 then return "pab" end
    if phase == 8 or phase == 9 then return "menu" end
    -- 15: CONFIG chosen, its object not filled in yet (a few frames); the menu is fading out.
    if phase == 15 and not configOpen() then return "menu" end
    -- Config's own data says whether it's up.
    if phase >= 10 and phase < 32 and configOpen() then return "config" end
    -- NEW GAME chosen: 10, then 11 while the title fades to black (28 game frames), then 20.
    if phase == 10 or phase == 11 or phase == 20 then return "newgame" end
    -- The title gone, the protagonist select's object up (from its dialogue on).
    if phase >= 32 and selectObject() then return "select" end
    -- Anything else (the data install prompt, a phase not seen yet, or 0xCCCCCCCC and heap pointers
    -- when there's no title at all) stays black rather than guessing.
    return "idle"
end

-- The protagonists swap each time PRESS ANY BUTTON and the menu change places: the incoming one fades in
-- while sliding from 48 PSP px (192 here) to the left, as the outgoing one fades out where it is, on the
-- game's crossfade (0 on PRESS ANY BUTTON, 1 on the menu, eased). This screen shows the other protagonist.
local SLIDE = 192
local function portraits(s)
    local x = float(TITLE_CROSSFADE)
    local p = (s == "menu") and x or 1 - x  -- how far the current one is in
    if s == "config" then p = 1 end
    local current = 1 - mem.u32(TITLE_ART)  -- 1 female, 0 male; the game's is the other
    local female = current == 1
    publish("female_op", female and p or 1 - p)
    publish("male_op", female and 1 - p or p)
    publish("female_dx", female and -SLIDE * (1 - p) or 0)
    publish("male_dx", female and 0 or -SLIDE * (1 - p))
end

-- The Dark Hour clock, whenever the game shows it (scripts/clock.lua).
local clock = pack.require("scripts/clock")

-- Choices in conversations (Yes/No and the like): this screen draws the box, the game's doesn't. Each
-- message window is in a list (WIN_LIST + 0xC: the first node; a node's +0x4 the next, +0xC its window).
-- A window's first word is its state: bits 0xC00 are 0x800 while it's asking, and its +0x40 then holds
-- the options' text, laid out as runs of glyphs (a run's +0x8 its line's y, +0x18 its glyph count, +0x1C
-- its first glyph, +0x24 the next run; a glyph's +0x0 its letter, +0x10 its colour as RRGGBBAA, +0x28
-- the next glyph). +0x48 (u16) is how many options there are and +0x4A, +0x4C the cursor.
local WIN_LIST     = 0x08C3E73C
local WIN_ASKING   = 0x800
local CHOICE_MAX   = 8
-- Frames the box takes to open (eased, a quarter sine) and to close (straight), as the game's: 6 and 5 of
-- its 30 Hz frames.
local CHOICE_OPEN  = 12
local CHOICE_CLOSE = 10
local FEMALE_FLAGS = 0x08E68498  -- bit 7: the female protagonist (game flag 0x1007), who has pink highlights
-- The game's code that draws a choice, in the window code at 0x0898B0F4 and the window loop at 0x08985510
-- (US 1.00): each is checked to be the instruction expected before it's replaced, so another version is
-- left alone.
local CHOICE_PATCHES = {
    { 0x0898BB5C, 0x0E2625CF, 0x00000000 },  -- jal 0x0898973C, queueing the box: nothing
    { 0x0898BBA0, 0x0E26260A, 0x00000000 },  -- jal 0x08989828, queueing the highlight bar: nothing
    -- jal 0x0897E33C, drawing the options' text (more than 0 once all of it is in): li v0, 1, so the
    -- game takes it as shown at once and goes on to take input as before.
    { 0x08985698, 0x0E25F8CF, 0x24020001 },
    { 0x0898B848, 0x0E2625CF, 0x00000000 },  -- jal 0x0898973C, the box as it opens: nothing
    { 0x0898B644, 0x0E2625CF, 0x00000000 },  -- jal 0x0898973C, the box as it closes: nothing
    { 0x0898B688, 0x0E26260A, 0x00000000 },  -- jal 0x08989828, its bar as it closes: nothing
}

local choiceWindow = nil  -- the window asking, if one is
local choiceSince = nil   -- the frame its box started opening here
local choiceGone = nil    -- the frame it stopped asking, while its box closes here

local function ram(a)
    return a >= 0x08800000 and a < 0x0A000000
end

local function patchChoices()
    for _, p in ipairs(CHOICE_PATCHES) do
        if mem.u32(p[1]) == p[2] then mem.write32(p[1], p[3]) end
    end
end

local function askingWindow()
    local node = mem.u32(WIN_LIST + 0xC)
    for _ = 1, 32 do  -- 11 seen
        if not ram(node) then return nil end
        local w = mem.u32(node + 0xC)
        if ram(w) and (mem.u32(w) & 0xC00) == WIN_ASKING and ram(mem.u32(w + 0x40)) then return w end
        node = mem.u32(node + 0x4)
    end
    return nil
end

-- The options, top to bottom: { text, colour } each, from the glyphs the game laid out.
local function options(w)
    local runs = {}
    local run = mem.u32(w + 0x40)
    for _ = 1, 4 * CHOICE_MAX do
        if not ram(run) then break end
        local y = mem.u32(run + 0x8)
        local line = runs[y]
        if not line then
            line = { y = y, text = "", colour = nil }
            runs[y] = line
            runs[#runs + 1] = line
        end
        local glyph = mem.u32(run + 0x1C)
        for _ = 1, math.min(mem.u32(run + 0x18), 64) do
            if not ram(glyph) then break end
            local c = mem.u16(glyph)
            if c >= 0x20 and c < 0x7F then line.text = line.text .. string.char(c) end
            line.colour = line.colour or (mem.u32(glyph + 0x10) >> 8)
            glyph = mem.u32(glyph + 0x28)
        end
        run = mem.u32(run + 0x24)
    end
    table.sort(runs, function(a, b) return a.y < b.y end)
    return runs
end

local function choice()
    local w = askingWindow()
    choiceWindow = w
    if not w then
        -- Closing: the box shrinks as it was last shown, bar and all, without its text.
        if choiceSince then choiceGone, choiceSince = frame, nil end
        local left = choiceGone and 1 - ramp(frame - choiceGone, { 0, CHOICE_CLOSE }) or 0
        if left == 0 then choiceGone = nil end
        publish("ch_open", left)
        publish("ch_text", 0)
        return
    end
    choiceSince = choiceSince or frame
    choiceGone = nil
    local n = math.min(mem.u16(w + 0x48), CHOICE_MAX)
    local cursor = mem.u16(w + 0x4A)
    local female = (mem.u32(FEMALE_FLAGS) >> 7) & 1 == 1
    local lines = options(w)
    local open = ramp(frame - choiceSince, { 0, CHOICE_OPEN })
    publish("ch_open", math.sin(open * math.pi / 2))
    publish("ch_text", open >= 1 and 1 or 0)
    publish("ch_n", n)
    publish("ch_cursor", cursor)
    publish("ch_bar", female and "#EC447F" or "#428AFF")
    for i = 0, CHOICE_MAX - 1 do
        local line = lines[i + 1]
        publish("ch_t" .. i, line and (line.text:gsub("%s+$", "")) or "")
        -- Each colour is a font of its own (see gungnir/tools/p3p_font.py): white under the cursor, otherwise
        -- the colour the game gave the option, his blue or her pink.
        local colour = line and line.colour and line.colour & 0xFFFFFF
        local font = "white"
        if i ~= cursor then font = (colour == 0xEC447F or (colour == nil and female)) and "her" or "him" end
        publish("ch_f" .. i, font)
    end
end

function update(info)
    frame = info.frame
    patchChoices()
    choice()
    clock.update(publish)
    local phase = mem.u32(TITLE_PHASE)
    local s = screenFor(phase)
    -- Between the title going and the select's object coming (about 8 frames), stay black.
    if s == "idle" and screen == "newgame" and frame - blackStart < 120 then s = "newgame" end
    if s == "newgame" and screen ~= "newgame" then blackStart = frame end
    if s ~= "select" then
        whiteStart = nil
        reach = {}
        stateSince = {}
        chosen = nil
    end
    -- Config is on this screen instead: zero its opacity on the game's, each frame, which hides all of it
    -- and leaves the title behind (its taps and buttons work as before). Its object is checked from when
    -- it's made, before its first frame is drawn.
    local cfg = phase >= 10 and phase < 32 and configObject()
    if cfg then
        mem.write32(CFG_ALPHA, 0)
    end
    if s == "fade" and screen ~= "fade" then fadeStart = frame end
    if s == "idle" then fadeStart = nil end
    screen = s
    publish("screen", s)
    -- Staged fade-in; a title reached without the fade (loading back from Config) shows at once.
    local t = (s == "fade" and fadeStart) and (frame - fadeStart) or 1e9
    publish("fade_art", ramp(t, ART_FADE))
    publish("fade_bg", ramp(t, BG_FADE))
    publish("fade_text", ramp(t, TEXT_FADE))
    publish("breath", breath())
    publish("busy", frame < busyUntil and 1 or 0)
    if s == "newgame" then
        publish("shade", ramp(frame - blackStart, BLACK_FADE))
    elseif s == "select" then
        select()
    end
    if s ~= "idle" and s ~= "select" then
        portraits(s)
        local cursor = mem.u32(MENU_CURSOR)
        publish("cursor", cursor < MENU_ITEMS and cursor or 1)
        local pill = mem.u32(MENU_PILL) / 65536
        publish("pill", (pill >= 0 and pill <= MENU_ITEMS - 1) and pill or 1)
        publish("menu_op", float(MENU_ALPHA))
    end
    if s == "config" then
        -- Config fades in (the panel, then its rows) and out as the game's does.
        publish("cfg_panel", ((mem.u32(CFG_FADE_PANEL) >> 16) & 0xFF) / 255)
        publish("cfg_rows", ((mem.u32(CFG_FADE_ROWS) >> 16) & 0xFF) / 255)
        local row = mem.u32(CFG_CURSOR)
        publish("row", row)
        for k = 0, 5 do publish("v" .. k, mem.u32(CFG_VALUES + 4 * k)) end
    end
end

-- Puts a cursor straight on [to], as the game would have it after moving there: its previous position
-- too, so the game doesn't animate a move. Writes happen at the frame boundary, before the game reads
-- them. Returns the frames to wait before pressing a button on it.
local SNAP = 2
local function snapCursor(cursorAddress, to)
    mem.write32(cursorAddress, to)
    mem.write32(cursorAddress + 4, to)
    return SNAP
end

-- A tap while an earlier one's presses still run is refused (false plays the "refused" haptic).
local function begin()
    return frame >= busyUntil
end

local function finish(offset)
    busyUntil = frame + offset + STEP
end

-- PRESS ANY BUTTON: anywhere on the screen.
function tap_any()
    if screen ~= "pab" or not begin() then return false end
    input.press("cross", 6)
    finish(6)
end

-- The title menu: snap to the item and choose it.
function tap_menu(item)
    if screen ~= "menu" or not begin() then return false end
    local t = snapCursor(MENU_CURSOR, item)
    input.press("cross", 6, t)
    finish(t + 6)
end

-- Config: a row's name selects it (and shows its help); ON and OFF switch it; OK confirms.
function tap_row(row)
    row = tonumber(row)  -- from a repeat's {i}
    if screen ~= "config" or not begin() then return false end
    finish(snapCursor(CFG_CURSOR, row))
end

function tap_switch(row, on)
    row, on = tonumber(row), tonumber(on)  -- from a repeat's {i}
    if screen ~= "config" or not begin() then return false end
    -- Auto Text has no choice while Voices is OFF (the game shows NONE).
    if row == 1 and mem.u32(CFG_VALUES) == 0 then return false end
    local t = snapCursor(CFG_CURSOR, row)
    input.press(on == 1 and "left" or "right", HOLD, t)
    finish(t + HOLD)
end

function tap_confirm()
    if screen ~= "config" or not begin() then return false end
    local t = snapCursor(CFG_CURSOR, CONFIRM_ROW)
    input.press("cross", 6, t)
    finish(t + 6)
end

function tap_back()
    if screen ~= "config" or not begin() then return false end
    input.press("circle", 6)
    finish(6)
end

-- The protagonist select (while the choice is up): tap the one not hovered to hover them, the hovered
-- one to choose them. Pressed as the player would, so the game's own switch plays.
-- A choice's option: the cursor goes straight to it; tapping the one it's on chooses it.
function tap_choice(i)
    i = tonumber(i)
    local w = choiceWindow
    if not w or w ~= askingWindow() or i >= mem.u16(w + 0x48) or not begin() then return false end
    if mem.u16(w + 0x4A) == i then
        input.press("cross", HOLD)
        finish(HOLD)
    else
        mem.write16(w + 0x4A, i)
        mem.write16(w + 0x4C, i)
        finish(0)
    end
end

function tap_pick(side)
    side = tonumber(side)
    if screen ~= "select" or mem.u32(SEL_STATE) ~= 5 or not begin() then return false end
    if mem.u32(SEL_CURSOR) == side then
        input.press("cross", 6)
    else
        input.press(side == 0 and "left" or "right", 6)
    end
    finish(6)
end
