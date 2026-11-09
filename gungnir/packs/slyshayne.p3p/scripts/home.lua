-- The home screen: what this screen shows most of the time, once a game is under way. The protagonist (level,
-- HP and SP, mood), their Persona, their social stats and funds on the left; on the right a month calendar
-- of the game's (today, Sundays and holidays, the moon) with the coming days' events, or the social links
-- begun so far. Everything is read from the game's memory (see gungnir/notes), its text from the game's own
-- tables where it has them.
local M = {}

-- The protagonist's record: names as 8 letters of the game's 16-bit code (0x80 then ASCII + 0x60), then a
-- character record (the same layout as the party's): level (+6), HP (+8), SP (+0xA), the social stats' points
-- (+0x3C, +0x3E, +0x40) and condition (+0x48).
local LAST_NAME, FIRST_NAME = 0x08E63BCC, 0x08E63BDE
local HERO = 0x08E63BF0
local LEVEL, HP, SP = HERO + 0x6, HERO + 0x8, HERO + 0xA
local STATS = HERO + 0x3C
local CONDITION = HERO + 0x48
local FUNDS = 0x08E68758
-- Max HP and SP: the game adds passive skills and accessories to a base from a table, u16 HP then SP at
-- + 4 * (11 * level + character) (the protagonist is character 1). Only the base is shown for now.
local BASE_HP_SP = 0x08BB911C
-- Personas: the stock (0x34 bytes each: +2 id, +4 level) after the index of the one equipped; names 17 bytes
-- apart, and each one's arcana a byte 14 apart, both by id.
local EQUIPPED = 0x08E64C24
local STOCK, PERSONA = 0x08E64C28, 0x34
local PERSONA_NAMES, PERSONA_ARCANA = 0x08C54530, 0x08C5B9C2
-- Social links begun: 16-byte records, +4 the link's id (0 for none) and +6 its rank. Each link's arcana is
-- a byte at +8 of its 116-byte entry, and its name 64 bytes apart, in tables the game loads (pointers held).
local LINKS, LINK, LINK_COUNT = 0x08E63C44, 16, 28
local LINK_INFO, LINK_NAMES = 0x08D40EA0, 0x08D40EA4
-- The date: days since 1 April 2009 (u16). The moon's age for each day is a byte (14 full, 0 new) from day 4;
-- holidays are (month, day) pairs ending with -1.
local DAY = 0x08E64820
local MOON, HOLIDAYS = 0x08BF9D0C, 0x08BF9BEC
local FEMALE_FLAGS = 0x08E68498  -- bit 7: the female protagonist

-- The social stats' ranks: a rank is passed once the points reach the sum of its steps (from the game's table,
-- read by 0x08A5D4DC); six ranks each, named as the game names them.
local STEPS = { { 20, 35, 45, 55, 75 }, { 15, 15, 15, 25, 30 }, { 15, 15, 15, 15, 20 } }
local RANKS = {
    { "Slacker", "Average", "Above Average", "Smart", "Intelligent", "Genius" },
    { "Plain", "Unpolished", "Confident", "Smooth", "Popular", "Charismatic" },
    { "Timid", "Ordinary", "Determined", "Tough", "Fearless", "Badass" },
}
local MOODS = { [0] = "Good", [2] = "Great", [3] = "Tired", [5] = "Sick" }
local ARCANA = { "Fool", "Magician", "Priestess", "Empress", "Emperor", "Hierophant", "Lovers", "Chariot",
    "Justice", "Hermit", "Fortune", "Strength", "Hanged Man", "Death", "Temperance", "Devil", "Tower", "Star",
    "Moon", "Sun", "Judgement", "Aeon" }
local NUMERALS = { "0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV",
    "XV", "XVI", "XVII", "XVIII", "XIX", "XX", "XXI" }
-- The game's holidays have no names in its tables; these are Japan's, and the school's breaks.
local HOLIDAY_NAMES = { ["4/29"] = "Showa Day", ["5/4"] = "Greenery Day", ["5/5"] = "Children's Day",
    ["7/20"] = "Marine Day", ["9/21"] = "Respect for the Aged Day", ["9/22"] = "Citizens' Holiday",
    ["9/23"] = "Autumnal Equinox Day", ["10/12"] = "Sports Day", ["11/3"] = "Culture Day",
    ["11/23"] = "Labor Thanksgiving Day", ["12/23"] = "Emperor's Birthday", ["1/1"] = "New Year's Day",
    ["1/11"] = "Coming of Age Day", ["2/11"] = "National Foundation Day", ["3/22"] = "Vernal Equinox Day" }
local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local SHOWN_LINKS = 7
local COMING = 3

local selDay = nil      -- the calendar's tapped day (a day number), or today
local selLink = 1
local linkTop = 0
local links = {}
local holidays = nil
local frame = 0

local function ram(a)
    return a >= 0x08800000 and a < 0x0A000000
end

local function cstring(address, max)
    local s = mem.read(address, max)
    return (s:match("^[^%z]*"))
end

-- A name in the game's code: 0x80 then ASCII + 0x60 a letter.
local function gameName(address)
    local out = {}
    for k = 0, 7 do
        local c = mem.u16(address + 2 * k)
        if c & 0xFF ~= 0x80 or c == 0x8080 then break end
        out[#out + 1] = string.char((c >> 8) - 0x60)
    end
    return table.concat(out)
end

local function rankOf(stat, points)
    local sum = 0
    for r = 1, 5 do
        sum = sum + STEPS[stat][r]
        if points < sum then return r end
    end
    return 6
end

local function commas(n)
    local s = tostring(n)
    while true do
        local t = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if t == s then return s end
        s = t
    end
end

-- Day number (days since 1 April 2009) to month, day of month, and weekday (0 Sunday; 1 April 2009 was a
-- Wednesday).
local function dateOf(day)
    local d = day % 365
    local m = 4
    while d >= MONTH_DAYS[m] do
        d = d - MONTH_DAYS[m]
        m = m % 12 + 1
    end
    return m, d + 1, (day + 3) % 7
end

local function dayOf(month, dom)
    local d, m = 0, 4
    while m ~= month do
        d = d + MONTH_DAYS[m]
        m = m % 12 + 1
    end
    return d + dom - 1
end

local function moonOf(day)
    return mem.u8(MOON + math.max(0, day - 4))
end

local function readHolidays()
    holidays = {}
    for k = 0, 120 do
        local m, d = mem.s16(HOLIDAYS + 4 * k), mem.s16(HOLIDAYS + 4 * k + 2)
        if m == -1 then break end
        holidays[m .. "/" .. d] = true
    end
end

-- What a day holds, for its note: a holiday, the full moon.
local function noteOf(day)
    local m, d = dateOf(day)
    local key = m .. "/" .. d
    local notes = {}
    if holidays[key] then notes[#notes + 1] = HOLIDAY_NAMES[key] or "No school" end
    if moonOf(day) == 14 then notes[#notes + 1] = "Full moon" end
    return table.concat(notes, ", ")
end

local function calendar(publish, today)
    local month, dom, wd = dateOf(today)
    local first = today - (dom - 1)
    local firstWd = (first + 3) % 7
    publish("cal_title", "2009 / " .. month)
    if month < 4 then publish("cal_title", "2010 / " .. month) end
    local rows = math.ceil((firstWd + MONTH_DAYS[month]) / 7)
    publish("cal_rows", rows)
    for i = 0, 41 do
        local d = i - firstWd + 1
        if d < 1 or d > MONTH_DAYS[month] then
            publish("cal_d" .. i, "")
        else
            local day = first + d - 1
            local w = i % 7
            local red = w == 0 or holidays[month .. "/" .. d]
            publish("cal_d" .. i, tostring(d))
            publish("cal_k" .. i, (day == today) and 3 or (red and 1 or (w == 6 and 2 or 0)))
            local age = moonOf(day)
            publish("cal_m" .. i, age == 14 and 1 or ((age == 7 or age == 22) and 2 or (age == 29 and 3 or 0)))
        end
    end
    -- The day tapped, or today.
    local sel = selDay and selDay >= first and selDay < first + MONTH_DAYS[month] and selDay or today
    publish("cal_sel", sel - first + firstWd)
    local sm, sd = dateOf(sel)
    publish("cal_sel_date", sm .. " / " .. sd)
    local note = noteOf(sel)
    publish("cal_note", note ~= "" and note or "Nothing planned.")
    -- Coming up: the next days with something on them.
    local n = 0
    for day = today + 1, today + 90 do
        local note_ = noteOf(day)
        if note_ ~= "" then
            local m, d = dateOf(day)
            publish("cal_up" .. n, note_)
            publish("cal_upd" .. n, m .. "/" .. d)
            n = n + 1
            if n == COMING then break end
        end
    end
    publish("cal_ups", n)
end

local function socialLinks(publish)
    links = {}
    local info, names = mem.u32(LINK_INFO), mem.u32(LINK_NAMES)
    for k = 0, LINK_COUNT - 1 do
        local id, rank = mem.u16(LINKS + LINK * k + 4), mem.u16(LINKS + LINK * k + 6)
        if id > 0 and id < 32 and rank > 0 then
            local arcana = ram(info) and mem.s8(info + 8 + 116 * id) or 0
            local name = ram(names) and cstring(names + 8 + 64 * id, 32) or ""
            links[#links + 1] = { arcana = arcana, rank = rank, name = name }
        end
    end
    table.sort(links, function(a, b) return a.arcana < b.arcana end)
    publish("sl_n", #links)
    if selLink > #links then selLink = 1 end
    linkTop = math.max(0, math.min(linkTop, #links - SHOWN_LINKS))
    publish("sl_top", linkTop)
    publish("sl_more", #links > SHOWN_LINKS and 1 or 0)
    for r = 0, SHOWN_LINKS - 1 do
        local l = links[linkTop + r + 1]
        if l then
            publish("sl_name" .. r, l.name)
            publish("sl_arc" .. r, ARCANA[l.arcana] or "")
            publish("sl_num" .. r, NUMERALS[l.arcana] or "")
            publish("sl_rank" .. r, "Rank " .. l.rank)
        end
    end
    publish("sl_sel", selLink - 1 - linkTop)
    local s = links[selLink]
    if s then
        publish("sl_s_name", s.name)
        publish("sl_s_arc", (NUMERALS[s.arcana] or "") .. " - " .. (ARCANA[s.arcana] or ""))
        publish("sl_s_rank", s.rank)
    end
end

-- True once a game is under way: the protagonist has a name and a level.
function M.active()
    local lv = mem.u16(LEVEL)
    return lv >= 1 and lv <= 99 and (mem.u16(FIRST_NAME) & 0xFF) == 0x80
end

-- The protagonist is refreshed every STATUS_EVERY frames, the calendar and the links every SLOW_EVERY (or at
-- once after a tap).
local STATUS_EVERY, SLOW_EVERY = 6, 30
local nextStatus, nextSlow = 0, 0

function M.update(publish, f)
    frame = f
    if frame < nextStatus then return end
    nextStatus = frame + STATUS_EVERY
    if not holidays then readHolidays() end
    publish("female", (mem.u32(FEMALE_FLAGS) >> 7) & 1)
    local lv = mem.u16(LEVEL)
    publish("h_name", gameName(FIRST_NAME))
    publish("h_lv", lv)
    local base = BASE_HP_SP + 4 * (11 * lv + 1)
    local hp, sp, maxHp, maxSp = mem.u16(HP), mem.u16(SP), mem.u16(base), mem.u16(base + 2)
    publish("h_hp", hp)
    publish("h_sp", sp)
    publish("h_maxhp", maxHp)
    publish("h_maxsp", maxSp)
    publish("h_hpf", maxHp > 0 and math.min(1, hp / maxHp) or 0)
    publish("h_spf", maxSp > 0 and math.min(1, sp / maxSp) or 0)
    publish("h_mood", MOODS[mem.u16(CONDITION)] or "Good")
    publish("h_funds", commas(mem.u32(FUNDS)))
    for k = 1, 3 do
        local pts = mem.u16(STATS + 2 * (k - 1))
        local r = rankOf(k, pts)
        publish("st_r" .. (k - 1), r)
        publish("st_w" .. (k - 1), RANKS[k][r])
    end
    local slot = mem.u16(EQUIPPED)
    local p = STOCK + PERSONA * math.min(slot, 11)
    local id = mem.u16(p + 2)
    if id > 0 and id < 256 then
        publish("p_name", cstring(PERSONA_NAMES + 17 * id, 17))
        publish("p_lv", mem.u16(p + 4))
        publish("p_arc", ARCANA[mem.u8(PERSONA_ARCANA + 14 * id)] or "")
    end
    if frame < nextSlow then return end
    nextSlow = frame + SLOW_EVERY
    calendar(publish, mem.u16(DAY))
    socialLinks(publish)
end

function tap_cal_day(i)
    i = tonumber(i)
    local today = mem.u16(DAY)
    local month, dom = dateOf(today)
    local first = today - (dom - 1)
    local d = i - (first + 3) % 7 + 1
    if d < 1 or d > MONTH_DAYS[month] then return false end
    selDay = first + d - 1
    nextStatus, nextSlow = 0, 0
end

function tap_link(r)
    local k = linkTop + tonumber(r) + 1
    if not links[k] then return false end
    selLink = k
    nextStatus, nextSlow = 0, 0
end

function tap_link_scroll(step)
    linkTop = linkTop + tonumber(step)
    nextStatus, nextSlow = 0, 0
end

return M
