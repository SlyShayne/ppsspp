-- The Dark Hour clock: at midnight the game's clock turns green, bursts apart and its pieces fly off the
-- game's screen. This draws the ones that would be below it on this screen, as if it carried on under the
-- game's (this screen is 310 PSP px wide at 4x, centred under it), and the green behind them, fading out
-- with the game's. Wherever the game shows the clock, since it finds it through the game's own pointer.
--
-- The game keeps the clock as 36 piece records (0x34 bytes each; slot 31 unused) in a block a static pointer
-- holds: each a position, a velocity, an angle (degrees, clockwise), its turn a frame, a zoom shared by all
-- (1 until the burst, then up 0.03 a frame) and that zoom's step. A piece is its shape (from the game's own
-- drawing, made by gungnir/tools/p3p_clock.py into assets/game/clock_shapes.lua) turned by its angle and,
-- but for the numerals, scaled by the zoom, at its position.
local M = {}

local POINTER = 0x08E96780  -- the clock's block (its records at +0x10) while it's up
local RECORD = 0x34
local COUNT = 36
local VIEW_X, VIEW_Y = 85, 272  -- this screen's top left, in the game's screen's PSP pixels
local SCALE = 4
local WIDTH, HEIGHT = 1240, 1080
local NUMERAL_W, NUMERAL_H = 124, 68
-- The green the game turns the screen at midnight, and the zoom over which it fades back to black
-- (measured: its alpha falls from full at zoom 2.79 to none at 4.03).
local TINT_FADE = { 2.79, 4.03 }
-- At midnight the green comes in over about 22 frames, fast then slowing (measured on the game's screen).
local TINT_IN = 22
local midnightSince = nil  -- the frame it turned midnight

local ok, shapes = pcall(pack.require, "assets/game/clock_shapes")
if not ok then
    log("the clock's pieces aren't built (gungnir/tools/p3p_clock.py): " .. tostring(shapes))
    shapes = nil
end

local function ram(a)
    return a >= 0x08800000 and a < 0x0A000000
end

-- The records, or nil while there's no clock: each { x, y, angle, zoom } (nil for an unused slot).
local function records()
    local base = mem.u32(POINTER)
    if not ram(base) or not ram(base + 0x10 + RECORD * COUNT) then return nil end
    local data = mem.read(base + 0x10, RECORD * COUNT)
    local out = {}
    local zoom0
    for k = 0, COUNT - 1 do
        local x, y, _, _, ang, _, zoom, step = string.unpack("<ffffffff", data, k * RECORD + 5)
        if zoom == 0 then
            out[k] = nil
        else
            -- Freed memory or a block that isn't the clock: not numbers, or out of any sensible range.
            if zoom ~= zoom or zoom < 1 or zoom > 20 or step < 0 or step > 0.1 or x ~= x or math.abs(x) > 1e5 then
                return nil
            end
            zoom0 = zoom0 or zoom
            out[k] = { x = x, y = y, ang = ang, zoom = zoom, step = step }
        end
    end
    if not zoom0 or not out[0] or not out[1] or not out[2] then return nil end
    return out
end

-- Publishes the clock's values; false while there's none. [frame] is the game frame.
function M.update(publish, frame)
    local recs = shapes and records()
    if not recs then
        midnightSince = nil
        publish("clk_on", 0)
        return false
    end
    publish("clk_on", 1)
    -- Green from midnight (the hands at 360, or the burst begun), coming in eased, fading out as the pieces leave.
    local zoom = recs[0].zoom
    local midnight = recs[0].step > 0 or (recs[0].ang >= 359.99 and recs[1].ang >= 359.99 and recs[2].ang >= 359.99)
    if midnight then midnightSince = midnightSince or frame else midnightSince = nil end
    local into = midnightSince and math.min(1, (frame - midnightSince) / TINT_IN) or 0
    into = 1 - (1 - into) * (1 - into)
    local fade = math.min(1, math.max(0, (zoom - TINT_FADE[1]) / (TINT_FADE[2] - TINT_FADE[1])))
    publish("clk_tint", into * (1 - fade))
    -- The filled pieces, as one path in this screen's pixels; those wholly off it are left out.
    local parts = {}
    for _, piece in ipairs(shapes.pieces) do
        local r = recs[piece.rec]
        if r then
            local a = math.rad(r.ang)
            local c, s, z = math.cos(a) * r.zoom, math.sin(a) * r.zoom, r.zoom
            for _, poly in ipairs(piece.polys) do
                local pts, inside = {}, false
                for i = 1, #poly, 2 do
                    local lx, ly = poly[i], poly[i + 1]
                    local bx = (r.x + lx * c - ly * s - VIEW_X) * SCALE
                    local by = (r.y + lx * s + ly * c - VIEW_Y) * SCALE
                    if bx > -40 and bx < WIDTH + 40 and by > -40 and by < HEIGHT + 40 then inside = true end
                    pts[#pts + 1] = string.format("%.1f %.1f", bx, by)
                end
                if inside then parts[#parts + 1] = "M " .. table.concat(pts, " L ") .. " Z" end
            end
        end
    end
    publish("clk_path", #parts > 0 and table.concat(parts, " ") or "M 0 0 Z")
    -- The numerals: unscaled, each turned about its middle.
    for n, num in ipairs(shapes.numerals) do
        local i = n - 1
        local r = recs[num.rec]
        if r then
            local a = math.rad(r.ang)
            local bx = (r.x + num.x * math.cos(a) - num.y * math.sin(a) - VIEW_X) * SCALE
            local by = (r.y + num.x * math.sin(a) + num.y * math.cos(a) - VIEW_Y) * SCALE
            local seen = bx > -NUMERAL_W and bx < WIDTH + NUMERAL_W and by > -NUMERAL_W and by < HEIGHT + NUMERAL_W
            publish("clk_x" .. i, bx)
            publish("clk_y" .. i, by)
            publish("clk_r" .. i, r.ang + num.turn)
            publish("clk_v" .. i, seen and 1 or 0)
        else
            publish("clk_v" .. i, 0)
        end
    end
    return true
end

return M
