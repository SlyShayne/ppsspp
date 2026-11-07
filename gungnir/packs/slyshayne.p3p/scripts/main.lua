-- Persona 3 Portable (USA, ULUS10512): the title screen and Config on the second screen.
-- Reads the game's state from memory (gungnir/notes/p3p-ULUS10512-memory.md) and turns taps into the
-- button presses the player would make: move the cursor by the shortest way, then confirm or switch.

local TITLE_PHASE = 0x093BAF30  -- 5 fading in, 7 PRESS ANY BUTTON, 9 menu, 10 or 16 Config
local TITLE_ART   = 0x093BAF48  -- 1 female protagonist, 0 male
local MENU_CURSOR = 0x093BAF58  -- 0 NEW GAME, 1 LOAD GAME, 2 CONFIG, 3 DATA INSTALL
local CFG_CURSOR  = 0x093C1C8C  -- 0..6, Confirm last
local CFG_VALUES  = 0x093C1CA4  -- six words, 1 ON
local CFG_SIDES   = 0x093C1CBC  -- six words, 1 - the value

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

local HELP = {
    [0] = "Turn event voices ON/OFF",
    [1] = "Auto advance text during voiced events",
    [2] = "Remember the cursor position during battle",
    [3] = "Remember Tactics settings after battles",
    [4] = "Invert the rotation of the battle command menu",
    [5] = "Turn Data Install ON/OFF",
    [6] = "Confirm the settings and return to the game",
}

local frame = 0          -- the last update's game frame
local busyUntil = 0      -- a tap's presses run until this frame
local screen = "idle"
local fadeStart = nil

-- Config is up: phase 10 and the screen's data looks like itself (heap memory can hold leftovers).
local function configOpen()
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
    -- Config has been seen at phase 10 and at 16; its own data says whether it's up.
    if phase >= 10 and phase < 32 and configOpen() then return "config" end
    -- Anything else (the data install prompt, a phase not seen yet, or 0xCCCCCCCC and heap pointers
    -- when there's no title at all) stays black rather than guessing.
    return "idle"
end

function update(info)
    frame = info.frame
    local phase = mem.u32(TITLE_PHASE)
    local s = screenFor(phase)
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
    if s ~= "idle" then
        publish("art", mem.u32(TITLE_ART))
        local cursor = mem.u32(MENU_CURSOR)
        publish("cursor", cursor < MENU_ITEMS and cursor or 1)
    end
    if s == "config" then
        local row = mem.u32(CFG_CURSOR)
        publish("row", row)
        for k = 0, 5 do publish("v" .. k, mem.u32(CFG_VALUES + 4 * k)) end
        publish("help", HELP[row] or "")
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
    if screen ~= "config" or not begin() then return false end
    finish(snapCursor(CFG_CURSOR, row))
end

function tap_switch(row, on)
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
