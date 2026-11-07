-- Persona 3 Portable (USA, ULUS10512): the title screen and Config on the second screen.
-- Reads the game's state from memory (gungnir/notes/p3p-ULUS10512-memory.md) and turns taps into the
-- button presses the player would make: move the cursor by the shortest way, then confirm or switch.

local TITLE_PHASE = 0x093BAF30  -- 5 fading in, 7 PRESS ANY BUTTON, 9 menu, 10 or 16 Config
local TITLE_ART   = 0x093BAF48  -- 1 female protagonist, 0 male
local MENU_CURSOR = 0x093BAF58  -- 0 NEW GAME, 1 LOAD GAME, 2 CONFIG, 3 DATA INSTALL
local CFG_CURSOR  = 0x093C1C8C  -- 0..6, Confirm last
local CFG_VALUES  = 0x093C1CA4  -- six words, 1 ON
local CFG_SIDES   = 0x093C1CBC  -- six words, 1 - the value

local MENU_ITEMS = 4
local CFG_ROWS = 7
local CONFIRM_ROW = 6
local HOLD = 4          -- frames a press is held
local STEP = 8          -- frames from one press to the next
local FADE_FRAMES = 360 -- the game's own fade-in takes about 6 s

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
    if phase == 5 or phase == 6 then return "fade" end
    if phase == 7 then return "pab" end
    if phase == 8 or phase == 9 then return "menu" end
    -- Config has been seen at phase 10 and at 16; its own data says whether it's up.
    if phase >= 10 and phase < 32 and configOpen() then return "config" end
    if phase < 32 then return "title" end
    return "idle"  -- 0xCCCCCCCC: no title screen (the attract mode, or the game itself)
end

function update(info)
    frame = info.frame
    local phase = mem.u32(TITLE_PHASE)
    local s = screenFor(phase)
    if s == "fade" and screen ~= "fade" then fadeStart = frame end
    screen = s
    publish("screen", s)
    publish("fade", fadeStart and math.min((frame - fadeStart) / FADE_FRAMES, 1.0) or 1.0)
    publish("busy", frame < busyUntil and 1 or 0)
    if s == "fade" or s == "pab" or s == "menu" or s == "config" or s == "title" then
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

-- Presses [button] [count] times, STEP frames apart, from [start]; returns the frame offset after them.
local function pressTimes(button, count, start)
    for k = 0, count - 1 do input.press(button, HOLD, start + k * STEP) end
    return start + count * STEP
end

-- Moves a wrapping cursor from [from] to [to] by the shorter way; returns the frame offset after it.
local function moveCursor(from, to, count)
    local down = (to - from) % count
    local up = (from - to) % count
    if up < down then return pressTimes("up", up, 0) end
    return pressTimes("down", down, 0)
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

-- The title menu: move to the item and choose it.
function tap_menu(item)
    if screen ~= "menu" or not begin() then return false end
    local t = moveCursor(mem.u32(MENU_CURSOR), item, MENU_ITEMS)
    input.press("cross", 6, t)
    finish(t + 6)
end

-- Config: a row's name selects it (and shows its help); ON and OFF switch it; OK confirms.
function tap_row(row)
    if screen ~= "config" or not begin() then return false end
    finish(moveCursor(mem.u32(CFG_CURSOR), row, CFG_ROWS))
end

function tap_switch(row, on)
    if screen ~= "config" or not begin() then return false end
    -- Auto Text has no choice while Voices is OFF (the game shows NONE).
    if row == 1 and mem.u32(CFG_VALUES) == 0 then return false end
    local t = moveCursor(mem.u32(CFG_CURSOR), row, CFG_ROWS)
    input.press(on == 1 and "left" or "right", HOLD, t)
    finish(t + HOLD)
end

function tap_confirm()
    if screen ~= "config" or not begin() then return false end
    local t = moveCursor(mem.u32(CFG_CURSOR), CONFIRM_ROW, CFG_ROWS)
    input.press("cross", 6, t)
    finish(t + 6)
end

function tap_back()
    if screen ~= "config" or not begin() then return false end
    input.press("circle", 6)
    finish(6)
end
