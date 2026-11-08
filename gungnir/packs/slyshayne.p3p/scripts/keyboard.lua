-- The name keyboard: when the game asks for the protagonist's name, its keyboard (four blocks of keys, A-Z,
-- a-z, 0-9 and symbols, and the Del, OK, L, R and End buttons) is on this screen instead, two blocks a page,
-- under a copy of the name being written. Tapping a key puts the game's cursor on it and presses Cross, so the
-- game types it as it would; the buttons press the game's. On the game's screen the keyboard's art and its
-- cursor's glow are made transparent (psp_textures) and its buttons' draw call is skipped, leaving the name.
--
-- The keyboard is the game's task "M_Name_KeyProc": while it runs, the game's run list has an entry of its update
-- function (0x08874E24), 0, then the task. The task's +0x38 is the keyboard's block: +0x14 its state (0 coming
-- in, 1 typing, 3 after End: "Proceed?" and its Yes/No; No goes back to 1), +0x1C the cursor's column (0-19,
-- five a block), +0x20 its row (0-5).
local M = {}

local RUN_LIST, RUN_LIST_SIZE = 0x08F90000, 0x10000
local UPDATE = 0x08874E24
local TASK_NAME = "M_Name_KeyProc"
local TASK_DATA = 0x38
local STATE, COL, ROW = 0x14, 0x1C, 0x20
-- The name as it's written: two lines of 8 letters, 16 bits each, 0x8080 a blank, and the text cursor (0-7 the
-- first name, 8-15 the last). End works only with a letter in each line.
local FIRST_NAME, LAST_NAME = 0x08C3BD90, 0x08C3BD7C
local TEXT_CURSOR = 0x08C3BD74
local BLANK = 0x8080
-- jal 0x08873ECC in the keyboard's code, which draws its buttons: skipped. Checked first, so another version of
-- the game is left alone.
local BUTTONS_CALL, BUTTONS_JAL = 0x08875148, 0x0E21CFB3
-- Keys a row in each block (the rest of a row is empty).
local KEYS = { { 5, 5, 5, 5, 5, 1 }, { 5, 5, 5, 5, 5, 1 }, { 5, 5, 0, 0, 0, 0 }, { 5, 5, 5, 5, 2, 0 } }
-- A letter's code is 0x80 then a byte: ASCII + 0x60 for letters and digits; the symbols' bytes, and those of the
-- four with 0x82 first instead, give their key (block * 30 + row * 5 + column).
local SYMBOLS = { [0x8B] = 90, [0x9D] = 94, [0x8E] = 95, [0x8C] = 96, [0x88] = 97, [0x89] = 98, [0x9F] = 99,
    [0x81] = 100, [0x83] = 101, [0x84] = 102, [0x85] = 103, [0x86] = 104, [0x8A] = 105, [0x8F] = 106,
    [0x82] = 107, [0x87] = 108, [0x9A] = 110, [0x9B] = 111 }
local SYMBOLS_82 = { [0xAC] = 91, [0xAE] = 92, [0xB0] = 93, [0x8A] = 109 }
local TYPING, ASKING = 1, 3
local HOLD = 4

-- Where it's drawn on this screen (4x the game's): the page's picture with its top left at PSP (0, 112), the
-- name under the page buttons with PSP (184, 69) at its top left, as the game lays its name out.
local KX, KY = 96, 216
local NX, NY = 336, 40
local function kx(x) return KX + 4 * x end
local function ky(y) return KY + 4 * (y - 112) end

-- Frames (60 a second), measured on the game's screen. As it comes in: the frame fades in; each row fades in
-- after the one above; then the cursor and the buttons that can be used light up.
local IN_FADE = 40           -- the blue over the green
local FRAME_IN = { 0, 8 }
local ROW_IN, ROW_STEP, ROW_FADE = 16, 11, 8
local CURSOR_IN = 100
-- A row the cursor leaves goes back from yellow to blue over this many frames.
local TRAIL = 36
local TRAILS = 3
-- The cursor's glow: once the cursor has rested GLOW_WAIT frames, a soft black disc round the ball grows from 30
-- to 44 PSP pixels and to alpha 0.48 over a second, shrinks back over a second, and is gone for one; again.
local GLOW_WAIT, GLOW_STEP = 170, 60
local GLOW_ALPHA = 0.48
-- Dimmed under the game's question; to black with the game's screen after Yes (it starts 12 frames after the
-- choice closes and takes 72).
local DIM = 0.45
local OUT_FADE = { 12, 84 }

local runEntry = nil    -- the run list's entry for the keyboard, once found
local page = 0
local pair = nil        -- the cursor's page last frame, to follow it when the d-pad moves it to the other
local since = nil       -- the frame it came
local intro = false     -- it came in state 0, so it builds up as the game's does
local green = 0         -- how green this screen was as it came
local asked = false     -- the game's Yes/No has been up since End
local outFrom = nil
local busyUntil = 0
local frame = 0
local block = nil
local lastRow = nil     -- { block, row } of the cursor last frame
local restSince = 0
local lastKey = nil
local trails = {}       -- rows going back to blue: { block, row, from }

local function ramp(t, span)
    if t <= span[1] then return 0 end
    if t >= span[2] then return 1 end
    return (t - span[1]) / (span[2] - span[1])
end

local function ram(a)
    return a >= 0x08800000 and a < 0x0A000000
end

local function isTask(task)
    return ram(task) and mem.read(task, #TASK_NAME + 1) == TASK_NAME .. "\0"
end

-- The keyboard's block while its task runs, or nil.
local function find()
    if not (runEntry and mem.u32(runEntry) == UPDATE and isTask(mem.u32(runEntry + 8))) then
        -- The run list's entries move as other tasks come and go (the question's windows): look again at once
        -- while the keyboard's up, otherwise every 15 frames.
        runEntry = nil
        if not since and frame % 15 ~= 0 then return nil end
        local data = mem.read(RUN_LIST, RUN_LIST_SIZE)
        local word = string.pack("<I4", UPDATE)
        local at = 1
        while true do
            local i = string.find(data, word, at, true)
            if not i then return nil end
            local entry = RUN_LIST + i - 1
            if (i - 1) % 4 == 0 and isTask(mem.u32(entry + 8)) then
                runEntry = entry
                break
            end
            at = i + 1
        end
    end
    local p = mem.u32(mem.u32(runEntry + 8) + TASK_DATA)
    if not ram(p) then return nil end
    local state, col, row = mem.u32(p + STATE), mem.u32(p + COL), mem.u32(p + ROW)
    if state > 3 or col > 19 or row > 5 then return nil end
    return p, state, col, row
end

local function hasLetter(line)
    for k = 0, 7 do
        if mem.u16(line + 2 * k) ~= BLANK then return true end
    end
    return false
end

-- The key whose letter a name's 16-bit code is, or -1 for a blank (or a code not on the keyboard).
local function keyOf(code)
    local lead, b = code & 0xFF, code >> 8
    if lead == 0x82 then return SYMBOLS_82[b] or -1 end
    if lead ~= 0x80 or code == BLANK then return -1 end
    if b >= 0xA1 and b <= 0xBA then return b - 0xA1 end
    if b >= 0xC1 and b <= 0xDA then return 30 + b - 0xC1 end
    if b >= 0x90 and b <= 0x99 then return 60 + b - 0x90 end
    return SYMBOLS[b] or -1
end

local function hide(publish)
    since, pair, asked, outFrom, lastRow, lastKey = nil, nil, false, nil, nil, nil
    trails = {}
    publish("kb_on", 0)
end

-- Publishes the keyboard's values; true while it's up. [choiceUp]: the game's Yes/No is showing. [tint]: how
-- green this screen is (the Dark Hour), to come in over.
function M.update(publish, f, choiceUp, tint)
    frame = f
    if mem.u32(BUTTONS_CALL) == BUTTONS_JAL then mem.write32(BUTTONS_CALL, 0) end
    local p, state, col, row = find()
    block = p
    if not p then
        hide(publish)
        return false
    end
    if not since then
        since, green, page, intro, restSince = frame, tint, col // 10, state == 0, frame
    end
    local t = frame - since
    publish("kb_on", 1)
    publish("kb_green", green * (1 - math.min(1, t / IN_FADE)))
    -- Coming in: the frame, then the rows one by one, then the cursor and the buttons.
    local built = not intro or t >= CURSOR_IN
    publish("kb_frame", intro and ramp(t, FRAME_IN) or 1)
    for r = 0, 5 do
        local start = ROW_IN + ROW_STEP * r
        publish("kb_row" .. r, intro and ramp(t, { start, start + ROW_FADE }) or 1)
    end
    -- Follow the cursor to its page when it crosses.
    local now = col // 10
    if pair and now ~= pair then page = now end
    pair = now
    publish("kb_page", page)
    -- A row the cursor leaves fades back to blue; the glow waits for the cursor to rest.
    local b = col // 5
    if lastRow and (lastRow[1] ~= b or lastRow[2] ~= row) then
        table.insert(trails, 1, { lastRow[1], lastRow[2], frame })
        trails[TRAILS + 1] = nil
    end
    lastRow = { b, row }
    local key = col * 8 + row
    if key ~= lastKey then restSince = frame end
    lastKey = key
    for n = 1, TRAILS do
        local tr = trails[n]
        local left = tr and 1 - (frame - tr[3]) / TRAIL or 0
        local seen = tr and left > 0 and tr[1] // 2 == page and not (tr[1] == b and tr[2] == row)
        publish("kb_t" .. (n - 1) .. "_op", seen and left or 0)
        if seen then
            publish("kb_t" .. (n - 1) .. "_x", kx(20 + 110 * (tr[1] % 2)))
            publish("kb_t" .. (n - 1) .. "_y", ky(138 + 16 * tr[2]))
        end
    end
    if built and now == page then
        local bl, c = b % 2, col % 5
        publish("kb_cur", 1)
        publish("kb_bar_x", kx(20 + 110 * bl))
        publish("kb_bar_y", ky(138 + 16 * row))
        publish("kb_ball_x", kx(26 + 19 * c + 110 * bl))
        publish("kb_ball_y", ky(136 + 16 * row))
        publish("kb_key_x", kx(29 + 19 * c + 110 * bl))
        publish("kb_key_y", ky(139 + 16 * row))
        local g = frame - restSince - GLOW_WAIT
        local k = 0
        if g >= 0 then
            local ph = g % (3 * GLOW_STEP)
            k = ph < GLOW_STEP and ph / GLOW_STEP or (ph < 2 * GLOW_STEP and (2 * GLOW_STEP - ph) / GLOW_STEP or 0)
        end
        publish("kb_glow_s", 4 * (30 + 14 * k))
        publish("kb_glow_op", GLOW_ALPHA * k)
    else
        publish("kb_cur", 0)
    end
    -- The name as it's written, and its text cursor while typing.
    local tc = mem.u32(TEXT_CURSOR)
    for i = 0, 15 do
        publish("kb_n" .. i, keyOf(mem.u16((i < 8 and FIRST_NAME or LAST_NAME) + 2 * (i % 8))))
    end
    publish("kb_tc", (state == TYPING and tc < 16) and tc or -1)
    -- Buttons: lit when the game would take them.
    local line = tc < 8 and FIRST_NAME or LAST_NAME
    local typing = built and state == TYPING
    publish("kb_del", (typing and tc < 16 and mem.u16(line + 2 * (tc % 8)) ~= BLANK) and 1 or 0)
    publish("kb_l", (typing and tc > 0) and 1 or 0)
    publish("kb_r", (typing and tc < 15) and 1 or 0)
    publish("kb_end", (typing and hasLetter(FIRST_NAME) and hasLetter(LAST_NAME)) and 1 or 0)
    -- After End: dimmed under the question; Yes (the choice gone with the state still 3) takes it to black.
    if state == ASKING then
        if choiceUp then asked = true elseif asked and not outFrom then outFrom = frame end
    else
        asked, outFrom = false, nil
    end
    publish("kb_dim", state == ASKING and DIM or 0)
    publish("kb_out", outFrom and ramp(frame - outFrom, OUT_FADE) or 0)
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
