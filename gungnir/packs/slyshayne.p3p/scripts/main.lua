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
local WIDTH = 1240
local WHITE_FADE = { 0, 34 }  -- frames: the bottom goes white as the title goes (phases 10, 11, 20 last ~36)

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
local whiteStart = 0

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

-- The protagonist select: white through its dialogue; then the hovered protagonist's colour floods the
-- screen from their side (him from the left, her from the right), on the game's own eased hover
-- (0 him, 1 her), which also brings him in as the choice first appears.
local function select()
    local state = mem.u32(SEL_STATE)
    local x = float(SEL_HOVER)
    local blue, pink = 0, 0
    if state == 4 then
        blue = (1 - x) * WIDTH
    elseif state >= 5 then
        blue, pink = (1 - x) * WIDTH, x * WIDTH
    end
    publish("flood_blue", blue)
    publish("flood_pink", pink)
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

function update(info)
    frame = info.frame
    local phase = mem.u32(TITLE_PHASE)
    local s = screenFor(phase)
    -- Between the title going and the select's object coming (about 8 frames), stay white.
    if s == "idle" and screen == "newgame" and frame - whiteStart < 120 then s = "newgame" end
    if s == "newgame" and screen ~= "newgame" then whiteStart = frame end
    -- Config is on this screen instead: zero its opacity on the game's, each frame, which hides all of it
    -- and leaves the title behind (its taps and buttons work as before). Its object is checked from when
    -- it's made, before its first frame is drawn.
    local cfg = phase >= 10 and phase < 32 and configObject()
    if cfg then
        mem.write32(CFG_ALPHA, 0)    end
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
        publish("white", ramp(frame - whiteStart, WHITE_FADE))
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
