-- "HOW MUCH HAVE I ACTUALLY SAVED, AND WHEN?"
--
--   Run: lua tools/test_savings_stats.lua
--
-- The savings panel could show exactly one number: the balance. savingCoins is
-- a running total with no ledger behind it, so by the time a player asked what
-- they had saved on Monday, Monday was indistinguishable from every other day
-- that had ever happened. The server now records each credit against a date;
-- these cover the client side of reading it back.
--
-- Most of this RUNS the shaping code rather than grepping for it — which is
-- the reason modules/savings_stats.lua exists as its own module with nothing
-- Defold-specific in it. The last section is unavoidably structural: the
-- drawing and the input dispatch live in files that need a live gui context.
package.path = "./?.lua;" .. package.path
local S = require("modules.savings_stats")

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end
local function eq(label, got, want)
    check(label .. "  (" .. tostring(got) .. ")", got == want,
        got ~= want and ("wanted " .. tostring(want)) or nil)
end

-- ---------------------------------------------------------------------------
print("")
print("DATES ARE THE POINT OF THE WHOLE SCREEN, SO THEY HAD BETTER BE RIGHT")

-- The keys arrive already in Nairobi time. Nothing here may go near os.date:
-- reinterpreting a Nairobi date in the device's timezone shifts a travelling
-- player's whole history by a day.
local shaping_code = (function()
    -- Comments stripped: the module's own note explains why it avoids these
    -- two, and a check that its explanation counts as a violation is a check
    -- that punishes documenting the rule.
    local out = {}
    for line in slurp("modules/savings_stats.lua"):gmatch("[^\n]*") do
        out[#out+1] = line:gsub("%-%-.*$", "")
    end
    return table.concat(out, "\n")
end)()
check("no clock calls anywhere in the shaping",
    not shaping_code:find("os%.date") and not shaping_code:find("os%.time"),
    "the server already decided the day boundary; the device must not re-decide it")

eq("2026-08-05 is a Wednesday", S.DAYS_SHORT[S.weekday("2026-08-05")], "Wed")
eq("2026-08-03 is a Monday",    S.DAYS_SHORT[S.weekday("2026-08-03")], "Mon")
eq("2026-08-09 is a Sunday",    S.DAYS_SHORT[S.weekday("2026-08-09")], "Sun")
eq("and 2000-01-01 was a Saturday", S.DAYS_SHORT[S.weekday("2000-01-01")], "Sat")
eq("a leap day lands right too", S.DAYS_SHORT[S.weekday("2028-02-29")], "Tue")

eq("day_diff counts forward", S.day_diff("2026-08-01", "2026-08-05"), 4)
eq("and backward",            S.day_diff("2026-08-05", "2026-08-01"), -4)
eq("across a month",          S.day_diff("2026-07-31", "2026-08-01"), 1)
eq("across a year",           S.day_diff("2026-12-31", "2027-01-01"), 1)
eq("and over a leap year",    S.day_diff("2028-02-28", "2028-03-01"), 2)

eq("a date reads as a date", S.format_day("2026-08-05"), "Wed 5 Aug")
eq("today says Today",       S.format_day_relative("2026-08-05", "2026-08-05"), "Today")
eq("yesterday says Yesterday", S.format_day_relative("2026-08-04", "2026-08-05"), "Yesterday")
eq("and anything older says its date",
    S.format_day_relative("2026-08-03", "2026-08-05"), "Mon 3 Aug")
check("with no anchor, nothing is claimed to be today",
    S.format_day_relative("2026-08-05", nil) == "Wed 5 Aug",
    "a device with a wrong clock must not be able to mislabel a row")

eq("a week inside one month collapses the month name",
    S.format_week("2026-08-03", "2026-08-09"), "3 - 9 Aug")
eq("and one that straddles two keeps both",
    S.format_week("2026-07-27", "2026-08-02"), "27 Jul - 2 Aug")
eq("months read as months", S.format_month("2026-08"), "August 2026")

eq("thousands are grouped", S.commas(1234567), "1,234,567")
eq("and small numbers are left alone", S.commas(999), "999")
eq("zero is zero", S.commas(0), "0")

check("malformed dates return empty rather than throwing",
    S.format_day("nonsense") == "" and S.format_day(nil) == "" and S.weekday("13") == nil,
    "the payload is not something this file controls")

-- ---------------------------------------------------------------------------
print("")
print("THE DAY LIST")

local stats = {
    banked = 8000,
    today        = { credited = 40, credits = 2, autoCharge = 15, dailyBonus = 25 },
    thisWeek     = { credited = 90, credits = 4 },
    thisMonth    = { credited = 300, credits = 9 },
    allTime      = { credited = 1000, credits = 30,
                     autoCharge = 250, dailyBonus = 250, seasonPoints = 400, manual = 100 },
    daily = {
        { date = "2026-08-03", credited = 50, credits = 1, seasonPoints = 50, runningTotal = 950 },
        { date = "2026-08-04", credited = 0,  credits = 0, runningTotal = 950 },
        { date = "2026-08-05", credited = 40, credits = 2, autoCharge = 15, dailyBonus = 25, runningTotal = 990 },
    },
    weekly = {
        { weekStart = "2026-08-03", weekEnd = "2026-08-09", credited = 90, daysSaved = 2 },
        { weekStart = "2026-07-27", weekEnd = "2026-08-02", credited = 210, daysSaved = 5 },
    },
    monthly = {
        { month = "2026-08", credited = 300, daysSaved = 4 },
        { month = "2026-07", credited = 700, daysSaved = 19 },
    },
    recordedFrom = "2026-03-09", lastSavedOn = "2026-08-05",
    bestDay = { date = "2026-06-11", credited = 400 },
    daysSaved = 24, currentStreak = 3, longestStreak = 9,
    averagePerDay = 6, averagePerActiveDay = 41, averagePerCredit = 33,
    unrecorded = 7000,
}

local rows, skipped = S.day_rows(stats, { today = "2026-08-05" })
eq("newest day first", rows[1].date, "2026-08-05")
eq("and it is labelled Today", rows[1].label, "Today")
eq("the older one keeps its date", rows[2].label, "Mon 3 Aug")
eq("days with nothing are not listed", #rows, 2)
eq("but they are counted, so the screen can still say so", skipped, 1)

-- A dense series is right for a CHART — a line joining the points either side
-- of a quiet day draws a slope where there was a gap. A LIST is the opposite
-- case: thirty rows of "0" is thirty rows nobody wants to scroll past.
check("the server's series really was dense", #stats.daily == 3,
    "the dropping happens at display, not in the data")

eq("a day knows its routes", #rows[1].sources, 2)
eq("biggest first", rows[1].sources[1].short, "Bonus")
eq("and the amounts are per route", rows[1].sources[1].value, 25)
eq("a single-route day says just the one", #rows[2].sources, 1)
eq("named for what it was", rows[2].sources[1].short, "Season")

local limited = S.day_rows(stats, { today = "2026-08-05", limit = 1 })
eq("a limit is honoured", #limited, 1)

-- ---------------------------------------------------------------------------
print("")
print("THE HEADLINES ARE TOTALS, NOT SUMS OF WHAT IS ON SCREEN")

local h = S.headlines(stats)
eq("four of them", #h, 4)
eq("today",      h[1].value, 40)
eq("this week",  h[2].value, 90)
eq("this month", h[3].value, 300)
eq("all time",   h[4].value, 1000)
-- The visible series is three days long and adds to 90. If "all time" were
-- computed from it, a player's lifetime savings would change with the window.
check("all time is not the visible series",
    h[4].value ~= (rows[1].credited + rows[2].credited),
    "the server totals the whole history; the window is only what is drawn")

-- ---------------------------------------------------------------------------
print("")
print("WHERE THE COINS CAME FROM")

local br = S.breakdown(stats)
eq("one row per route, always", #br, 4)
eq("auto-save",  br[1].value, 250)
eq("its share",  br[1].percent, 25)
eq("season",     br[3].value, 400)
eq("its share",  br[3].percent, 40)
local pct = 0
for _, b in ipairs(br) do pct = pct + b.percent end
eq("and the shares account for the recorded total", pct, 100)

-- Dividing by the BALANCE instead would leave four shares visibly failing to
-- reach 100, because everything banked before the ledger existed is in the
-- balance and in no route at all.
check("the percentages are of the recorded total, not the balance",
    br[3].percent == 40, "8000 would have made this 5%")

local zero = S.breakdown({ allTime = { credited = 0 } })
eq("nothing saved is 0%, not a division by zero", zero[1].percent, 0)
check("and the empty routes are still listed", #zero == 4,
    "'you have never used auto-save' is information; a missing row cannot say it")

-- ---------------------------------------------------------------------------
print("")
print("WEEKS AND MONTHS")

local w = S.week_rows(stats)
eq("newest week first", w[1].weekStart, "2026-08-03")
eq("labelled as a range", w[1].label, "3 - 9 Aug")
eq("with the days saved in it", w[1].daysSaved, 2)
eq("a week across a month boundary keeps both names", w[2].label, "27 Jul - 2 Aug")

local mo = S.month_rows(stats)
eq("newest month first", mo[1].month, "2026-08")
eq("spelled out", mo[1].label, "August 2026")
eq("with its total", mo[1].credited, 300)

-- ---------------------------------------------------------------------------
print("")
print("THE FACTS UNDERNEATH")

local facts = S.facts(stats)
local seen = {}
for _, f in ipairs(facts) do seen[f.key] = f.value end
eq("the current streak", seen.streak, "3 days")
check("the best day, with its date", seen.best == "400 on Thu 11 Jun",
    "got: " .. tostring(seen.best))
eq("how many days they have saved on", seen.days, "24 days")
eq("and what a saving day is worth", seen.avg, "41 coins")
eq("the longest run", seen.longest, "9 days")
eq("and when tracking began", seen.since, "Mon 9 Mar")

local nofacts = S.facts({})
check("a player with no history gets no facts, not blank ones", #nofacts == 0,
    "'Best day: 0 on ' is worse than nothing")

check("a streak of one day is singular",
    S.facts({ currentStreak = 1 })[1].value == "1 day")

-- ---------------------------------------------------------------------------
print("")
print("THE BALANCE AND THE LEDGER ARE DIFFERENT NUMBERS, AND IT SAYS SO")

-- Every account already had a savings balance when the daily ledger was added.
-- Without this line the screen shows "ALL TIME 1,000" beside a balance of
-- 8,000 with no explanation, which reads as a bug.
check("the gap is explained, not hidden",
    S.unrecorded_note(stats) == "7,000 coins were saved before daily tracking began",
    "got: " .. tostring(S.unrecorded_note(stats)))
check("and nothing is said when there is nothing to explain",
    S.unrecorded_note({ unrecorded = 0 }) == nil
        and S.unrecorded_note({}) == nil)

-- ---------------------------------------------------------------------------
print("")
print("THREE DIFFERENT NOTHINGS")

local k1 = S.empty_reason(nil, true)
eq("still loading", k1, "loading")
local k2 = S.empty_reason(nil, false)
eq("the server could not answer", k2, "unavailable")
local k3 = S.empty_reason({ daysSaved = 0 }, false)
eq("or they have genuinely never saved", k3, "never")
check("and a player with history gets no empty state at all",
    S.empty_reason(stats, false) == nil)
-- A player who has never saved needs an invitation, one whose data is loading
-- needs to be told to wait, and one the server failed for needs to know it is
-- not their fault. One shared "nothing here" says none of those.
check("the three messages are actually different", (function()
    local _, m1 = S.empty_reason(nil, true)
    local _, m2 = S.empty_reason(nil, false)
    local _, m3 = S.empty_reason({ daysSaved = 0 }, false)
    return m1 ~= m2 and m2 ~= m3 and m1 ~= m3
end)())

-- ---------------------------------------------------------------------------
print("")
print("A MISSING PAYLOAD DRAWS AN EMPTY SCREEN, NEVER AN ERROR")

-- The stats block is explicitly allowed to be absent: the server returns the
-- savings panel without it rather than failing the whole push when a statistic
-- cannot be read. So every accessor has to survive nil.
local ok = pcall(function()
    S.headlines(nil); S.breakdown(nil); S.facts(nil)
    S.day_rows(nil, {}); S.week_rows(nil); S.month_rows(nil)
    S.headlines("not a table"); S.day_rows({ daily = "nope" }, {})
end)
check("nothing throws on a missing or malformed payload", ok)
eq("and the headlines are zeros", S.headlines(nil)[1].value, 0)

-- ---------------------------------------------------------------------------
print("")
print("THE WIRING")

local right   = slurp("modules/online_right.lua")
local online  = slurp("main/online.gui_script")
local wsm     = slurp("modules/websocket_manager.lua")

check("the panel asks the server for the longer history",
    wsm:find('M%.send_message%("GET_SAVINGS_HISTORY"'))
check("and parks the reply",
    wsm:find('elseif t == "SAVINGS_HISTORY" then'))
check("clearing the pending flag whichever way it went",
    wsm:find('M%.savings_history_pending = false'),
    "a spinner that never stops is worse than an empty state that says so")

check("the savings row opens the history",
    right:find('id = "savings_stats"'))
check("registered BEFORE the i and + icons",
    right:find('id = "savings_stats"%s*,?%s*}') and
        (right:find('id = "savings_stats"') < right:find('mkbtn%(self, "savings_info"')),
    "input walks the button list backwards, so the last one registered wins")

check("there is a modal to open",
    right:find("local function draw_savings_stats%(self, ctx%)"))
check("and it is actually drawn",
    right:find("\n    draw_savings_stats%(self, ctx%)"))

check("the dispatch opens it", online:find('id == "savings_stats" then'))
check("and closes it, scrim included",
    online:find('id == "savings_stats_close" or id == "savings_stats_block"'))
check("the tabs switch", online:find('savings_stats_tab_DAYS'))
check("and reset the page when they do",
    online:match('savings_stats_tab_DAYS.-st%.page = 0'),
    "page 3 of the days list is an empty page in the months list")
check("the flag is cleared when the screen is re-entered",
    online:find("self%.savings_plans_open, self%.savings_stats_open = true"),
    "a modal left open across a screen change reopens over the wrong content")

-- The modal falls back to the fortnight that came with SAVINGS_STATUS so it is
-- useful the instant it opens, rather than after a round trip.
check("it renders from the status payload before the history arrives",
    right:find("ws%.current_savings_status or {}%)%.stats"))
check("and prefers the longer one once it lands",
    right:find("ws%.current_savings_history"))

-- ---------------------------------------------------------------------------
print("")
print("AND THE MODAL ACTUALLY DRAWS")
--
-- This file has already shipped a savings dialog that drew its panel, its
-- dividers, its progress bar and both its buttons around NO WORDS AT ALL —
-- one indexed lookup threw and took the rest of the body with it, and nothing
-- outside the engine could see it. So this one is rendered, against a stub
-- that records every element, rather than being read.

_G.vmath = _G.vmath or {
    vector3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end,
    vector4 = function(a, b, c, d) return { x = a, y = b, z = c, w = d } end,
}
_G.gui = _G.gui or { set_pivot = function() end, PIVOT_W = 1, PIVOT_E = 2, delete_node = function() end }
_G.hash = _G.hash or function(s) return s end
_G.sys = _G.sys or {
    get_sys_info = function() return { system_name = "Linux" } end,
    get_config_string = function(_, d) return d or "" end,
}
_G.msg = _G.msg or { post = function() end, url = function() return {} end }
_G.timer = _G.timer or { delay = function() return 0 end, cancel = function() end }

local right_M = require("modules.online_right")
local wsmod   = require("modules.websocket_manager")

local function render(self_over, status, history, pending)
    local drawn = { text = {}, boxes = 0, panels = 0 }
    local function node(kind) return { kind = kind } end
    local ctx = {
        track = function(self, n) self.nodes[#self.nodes+1] = n; return n end,
        ui = {
            box = function() drawn.boxes = drawn.boxes + 1; return node("box") end,
            panel9 = function() drawn.panels = drawn.panels + 1; return node("panel") end,
            pie = function() return node("pie") end,
            btn9 = function() return node("btn") end,
            grad_backdrop = function() return node("grad") end,
            text = function(_, str) drawn.text[#drawn.text+1] = tostring(str); return node("text") end,
        },
        txtL = function(_, _, _, str) drawn.text[#drawn.text+1] = tostring(str) end,
        txtR = function(_, _, _, str) drawn.text[#drawn.text+1] = tostring(str) end,
        mkbtn = function(self, id, _, _, label)
            self.buttons[#self.buttons+1] = { id = id }
            if label then drawn.text[#drawn.text+1] = tostring(label) end
            return node("btn")
        end,
        commas = S.commas,
        C = setmetatable({}, { __index = function() return _G.vmath.vector4(1, 1, 1, 1) end }),
        CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
    }

    wsmod.current_savings_status  = status
    wsmod.current_savings_history = history
    wsmod.savings_history_pending = pending and true or false

    local self = { nodes = {}, buttons = {}, savings_stats_open = true }
    for k, v in pairs(self_over or {}) do self[k] = v end

    local ok, err = pcall(right_M._draw_savings_stats, self, ctx)
    return ok, err, drawn, self
end

local function shows(drawn, needle)
    for _, t in ipairs(drawn.text) do if t:find(needle, 1, true) then return true end end
    return false
end

local ok1, err1, d1, self1 = render(nil, { stats = stats })
check("a full history renders without throwing", ok1, tostring(err1))
check("the balance is on it", shows(d1, "8,000"))
check("the headline labels are on it",
    shows(d1, "TODAY") and shows(d1, "THIS WEEK") and shows(d1, "ALL TIME"))
check("today's row is labelled Today", shows(d1, "Today"))
check("a day's routes are broken out", shows(d1, "25 Bonus"))
check("the unrecorded balance is explained on screen",
    shows(d1, "before daily tracking began"))
check("and the streak is shown", shows(d1, "3 days"))

local function has_button(self, id)
    for _, b in ipairs(self.buttons) do if b.id == id then return true end end
    return false
end
check("the scrim closes it", has_button(self1, "savings_stats_block"))
check("so does CLOSE", has_button(self1, "savings_stats_close"))
check("all three tabs are pressable",
    has_button(self1, "savings_stats_tab_DAYS")
        and has_button(self1, "savings_stats_tab_WEEKS")
        and has_button(self1, "savings_stats_tab_MONTHS"))

-- The three empty states, rendered rather than reasoned about.
local ok2, err2, d2 = render(nil, {}, nil, true)
check("a loading history renders", ok2, tostring(err2))
check("and says so", shows(d2, "Loading"))

local ok3, err3, d3 = render(nil, { stats = { daysSaved = 0, banked = 0 } }, nil, false)
check("a player who has never saved renders", ok3, tostring(err3))
check("and is invited rather than shown a blank", shows(d3, "not saved anything yet"))

-- The one that matters most: no payload at all. The server is explicitly
-- allowed to return the savings panel without stats when a statistic cannot
-- be read, so this is a real state and not a defensive hypothetical.
local ok4, err4, d4 = render(nil, nil, nil, false)
check("no payload at all still renders", ok4, tostring(err4))
check("with the balance line still drawn", shows(d4, "SAVINGS BALANCE"))

-- Paging, driven through the real row count.
local many = { banked = 100, allTime = { credited = 100 }, daily = {} }
for i = 1, 20 do
    many.daily[i] = { date = string.format("2026-07-%02d", i), credited = 10, credits = 1, manual = 10 }
end
local ok5, err5, d5, self5 = render({ savings_stats = { tab = "DAYS", page = 0 } }, { stats = many })
check("twenty days renders", ok5, tostring(err5))
check("paged, not crammed", has_button(self5, "savings_stats_next"))
check("and the page count is shown", shows(d5, "/ 3"))

-- A page number left over from another tab must not show an empty page.
local ok6, err6, d6 = render({ savings_stats = { tab = "MONTHS", page = 7 } }, { stats = stats })
check("an out-of-range page is clamped, not drawn empty", ok6, tostring(err6))
check("and the month is still on screen", shows(d6, "August 2026"))

-- The history reply is preferred over the fortnight that came with the status.
local ok7, err7, d7 = render(nil,
    { stats = { banked = 1, allTime = { credited = 1 }, daily = {} } },
    { stats = { banked = 4321, allTime = { credited = 4321 }, daily = {} } })
check("the longer history renders", ok7, tostring(err7))
check("and wins over the status payload", shows(d7, "4,321"))

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
