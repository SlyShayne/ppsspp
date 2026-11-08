-- The name keyboard: when the game asks for the protagonist's name, its keyboard (four blocks of keys, A-Z,
-- a-z, 0-9 and symbols, and the Del, OK, L, R and End buttons) is on this screen instead, two blocks a page.
-- Tapping a key puts the game's cursor on it and presses Cross, so the game types it as it would; the buttons
-- press the game's. On the game's screen the keyboard's art is made transparent (psp_textures) and its buttons'
-- draw call is skipped, leaving the name being written.
--
-- The keyboard's state is a block a pointer holds (the pointer's slot is used by other screens too, so the block
-- is checked to be the keyboard's): +0x14 its state (0 coming in, 1 typing, 3 after End: "Proceed?" and its
-- Yes/No; No goes back to 1), +0x1C the cursor's column (0-19, five a block), +0x20 its row (0-5), +0x24 its key
-- (block * 30 + row * 5 + column in the block, which the game works out again when the column or row is written).
local M = {}

local POINTER = 0x08F8CDF0
local STATE, COL, ROW, KEY = 0x14, 0x1C, 0x20, 0x24
-- The name as it's written: two lines of 8 letters, 16 bits each, 0x8080 a blank, and the text cursor (0-7 the
-- first name, 8-15 the last). End works only with a letter in each line.
local FIRST_NAME, LAST_NAME = 0x08C3BD90, 0x08C3BD7C
local TEXT_CURSOR = 0x08C3BD74
local BLANK = 0x8080
-- jal 0x08873ECC in the keyboard's code (0x08874E24), which draws its buttons: skipped. Checked first, so
-- another version of the game is left alone.
local BUTTONS_CALL, BUTTONS_JAL = 0x08875148, 0x0E21CFB3
-- Keys a row in each block (the rest of a row is empty).
local KEYS = { { 5, 5, 5, 5, 5, 1 }, { 5, 5, 5, 5, 5, 1 }, { 5, 5, 0, 0, 0, 0 }, { 5, 5, 5, 5, 2, 0 } }
local TYPING, ASKING = 1, 3
local HOLD = 4
-- Frames: the blue comes in over the green as the game's screen comes in from black; dimmed under the game's
-- question; to black with the game's screen after Yes (it starts 12 frames after the choice closes and takes 72,
-- measured on the game's screen).
local IN_FADE = 40
local DIM = 0.45
local OUT_FADE = { 12, 84 }
-- As the game's screen changes after Yes, the pointer's slot can hold a block that passes for the keyboard's
-- for a frame: for this long after it's gone, nothing is taken for it.
local GONE_HOLD = 120

local page = 0
local pair = nil        -- the cursor's page last frame, to follow it when the d-pad moves it to the other
local since = nil       -- the frame it came
local green = 0         -- how green this screen was as it came
local asked = false     -- the game's Yes/No has been up since End
local outFrom = nil
local goneAt = nil      -- the frame it went after Yes
local busyUntil = 0
local frame = 0
local block = nil

local function ram(a)
    return a >= 0x08800000 and a < 0x0A000000
end

-- The keyboard's block, or nil.
local function find()
    local p = mem.u32(POINTER)
    if not ram(p) then return nil end
    local state, col, row, key = mem.u32(p + STATE), mem.u32(p + COL), mem.u32(p + ROW), mem.u32(p + KEY)
    if state > 3 or col > 19 or row > 5 then return nil end
    if key ~= (col // 5) * 30 + row * 5 + col % 5 then return nil end
    return p, state, col, row
end

local function hasLetter(line)
    for k = 0, 7 do
        if mem.u16(line + 2 * k) ~= BLANK then return true end
    end
    return false
end

-- Publishes the keyboard's values; true while it's up. [choiceUp]: the game's Yes/No is showing. [tint]: how
-- green this screen is (the Dark Hour), to come in over.
function M.update(publish, f, choiceUp, tint)
    frame = f
    if mem.u32(BUTTONS_CALL) == BUTTONS_JAL then mem.write32(BUTTONS_CALL, 0) end
    local p, state, col, row = find()
    if goneAt and frame - goneAt < GONE_HOLD then p = nil end
    block = p
    if not p then
        if outFrom then goneAt = frame end
        since, pair, asked, outFrom = nil, nil, false, nil
        publish("kb_on", 0)
        return false
    end
    if not since then since, green, page = frame, tint, col // 10 end
    publish("kb_on", 1)
    publish("kb_in", math.min(1, (frame - since) / IN_FADE))
    publish("kb_green", green * (1 - math.min(1, (frame - since) / IN_FADE)))
    -- Follow the cursor to its page when it crosses.
    local now = col // 10
    if pair and now ~= pair then page = now end
    pair = now
    publish("kb_page", page)
    if now == page then
        local b, c = (col // 5) % 2, col % 5
        publish("kb_cur", 1)
        publish("kb_bar_x", 176 + 440 * b)
        publish("kb_bar_y", 254 + 64 * row)
        publish("kb_ball_x", 200 + 76 * c + 440 * b)
        publish("kb_ball_y", 246 + 64 * row)
        publish("kb_key_x", 212 + 76 * c + 440 * b)
        publish("kb_key_y", 258 + 64 * row)
    else
        publish("kb_cur", 0)
    end
    local tc = mem.u32(TEXT_CURSOR)
    local line = tc < 8 and FIRST_NAME or LAST_NAME
    publish("kb_del", (tc < 16 and mem.u16(line + 2 * (tc % 8)) ~= BLANK) and 1 or 0)
    publish("kb_end", (hasLetter(FIRST_NAME) and hasLetter(LAST_NAME)) and 1 or 0)
    -- After End: dimmed under the question; Yes (the choice gone with the state still 3) takes it to black.
    if state == ASKING then
        if choiceUp then asked = true elseif asked and not outFrom then outFrom = frame end
    else
        asked, outFrom = false, nil
    end
    publish("kb_dim", state == ASKING and DIM or 0)
    local out = 0
    if outFrom then
        local t = frame - outFrom
        out = t <= OUT_FADE[1] and 0 or math.min(1, (t - OUT_FADE[1]) / (OUT_FADE[2] - OUT_FADE[1]))
    end
    publish("kb_out", out)
    return true
end

local function typing()
    return block and mem.u32(block + STATE) == TYPING and frame >= busyUntil
end

-- A key of the page: block [b] of it (0, 1), row [r], column [c].
function tap_key(b, r, c)
    b, r, c = tonumber(b), tonumber(r), tonumber(c)
    if not typing() then return false end
    local k = page * 2 + b
    if c >= KEYS[k + 1][r + 1] then return false end
    mem.write32(block + COL, k * 5 + c)
    mem.write32(block + ROW, r)
    input.press("cross", HOLD, 2)
    busyUntil = frame + 2 + HOLD + 4
end

-- Del (circle), L, R and End (start), as the game's.
function tap_kb_button(name)
    if not typing() then return false end
    input.press(name, HOLD)
    busyUntil = frame + HOLD + 4
end

function tap_kb_page(step)
    if not block then return false end
    page = (page + tonumber(step)) % 2
end

return M
