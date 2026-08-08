-- SHAPING A PLAYER'S SAVINGS HISTORY FOR THE SCREEN.
--
-- Deliberately its own module with NO Defold dependencies — no `ui`, no
-- `vmath`, no `sys`. Everything here is dates and arithmetic on the payload
-- the server sends, and keeping it separable is what lets it be tested for
-- real (tools/test_savings_stats.lua requires this file and calls these
-- functions) instead of by grepping the drawing code for the right substring.
--
-- The drawing lives in online_right.lua and does nothing but place what these
-- return.
local M = {}

M.MONTHS_SHORT = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
M.MONTHS_LONG  = { "January", "February", "March", "April", "May", "June",
                   "July", "August", "September", "October", "November", "December" }
M.DAYS_SHORT   = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- The four routes coins take into savings, in the order they are shown. Named
-- here rather than at the call site so the labels cannot drift between the
-- breakdown and the per-day rows.
M.SOURCES = {
    { key = "autoCharge",  label = "Auto-save per game" },
    { key = "dailyBonus",  label = "Daily bonus" },
    { key = "seasonPoints", label = "Season rewards" },
    { key = "manual",      label = "You added" },
}

local SOURCE_SHORT = {
    autoCharge = "Auto",
    dailyBonus = "Bonus",
    seasonPoints = "Season",
    manual = "Added",
}

-- ── dates ───────────────────────────────────────────────────────────────────
--
-- The keys arrive as "YYYY-MM-DD" already in Nairobi time. Everything below
-- works on the string and on integer day counts; nothing goes near os.date or
-- os.time, which would reinterpret a Nairobi date in the device's timezone and
-- shift a player's history by a day for anybody travelling.

--- Split "YYYY-MM-DD" into three numbers, or nil if it is not one.
function M.parse(iso)
    local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

--- Days since 1970-01-01 for a civil date. Hinnant's algorithm — exact for
--- every date, with no table of month lengths to get wrong at a leap year.
function M.days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400                                   -- [0, 399]
    local doy = math.floor((153 * (m + ((m > 2) and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Weekday index, 1 = Monday .. 7 = Sunday. 1970-01-01 was a Thursday.
function M.weekday(iso)
    local y, m, d = M.parse(iso)
    if not y then return nil end
    return ((M.days_from_civil(y, m, d) + 3) % 7) + 1
end

--- Whole days from `a` to `b`, negative if `b` is earlier.
function M.day_diff(a, b)
    local ay, am, ad = M.parse(a)
    local by, bm, bd = M.parse(b)
    if not ay or not by then return nil end
    return M.days_from_civil(by, bm, bd) - M.days_from_civil(ay, am, ad)
end

--- "2026-08-05" -> "Wed 5 Aug". The weekday earns its place: a player scanning
--- a list of dates recognises "Sat" long before they work out that the 8th was
--- a Saturday, and "I always save at the weekend" is exactly the kind of thing
--- this screen exists to make visible.
function M.format_day(iso)
    local y, m, d = M.parse(iso)
    if not y then return "" end
    return string.format("%s %d %s", M.DAYS_SHORT[M.weekday(iso)] or "", d, M.MONTHS_SHORT[m] or m)
end

--- The same, but "Today" and "Yesterday" where those are true.
---
--- `today` is passed in rather than read from the clock: the day boundary that
--- matters is Nairobi's, the server already decided it, and a device whose
--- clock is wrong should not be able to label the wrong row "Today".
function M.format_day_relative(iso, today)
    local diff = today and M.day_diff(iso, today) or nil
    if diff == 0 then return "Today" end
    if diff == 1 then return "Yesterday" end
    return M.format_day(iso)
end

--- "2026-08" -> "August 2026".
function M.format_month(key)
    local y, m = tostring(key or ""):match("^(%d%d%d%d)-(%d%d)$")
    if not y then return tostring(key or "") end
    return string.format("%s %s", M.MONTHS_LONG[tonumber(m)] or m, y)
end

--- "2026-08-03" + "2026-08-09" -> "3 - 9 Aug". Same month collapses to one
--- month name; a week that straddles two keeps both.
function M.format_week(from, to)
    local fy, fm, fd = M.parse(from)
    local ty, tm, td = M.parse(to)
    if not fy or not ty then return "" end
    if fm == tm and fy == ty then
        return string.format("%d - %d %s", fd, td, M.MONTHS_SHORT[fm] or fm)
    end
    return string.format("%d %s - %d %s", fd, M.MONTHS_SHORT[fm] or fm, td, M.MONTHS_SHORT[tm] or tm)
end

--- 12345 -> "12,345". Negatives keep their sign outside the grouping.
function M.commas(n)
    local v = math.floor(math.abs(tonumber(n) or 0))
    local s = tostring(v)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    if (tonumber(n) or 0) < 0 then return "-" .. out end
    return out
end

-- ── reading the payload ─────────────────────────────────────────────────────
--
-- Every accessor below tolerates a missing field. The stats block rides along
-- with SAVINGS_STATUS and is explicitly allowed to be absent — the server
-- returns the panel without it rather than failing the whole push when a
-- statistic cannot be read — so "no stats" has to draw as an empty screen, not
-- as an error.

local function bucket(b)
    b = type(b) == "table" and b or {}
    return {
        credited = tonumber(b.credited) or 0,
        credits = tonumber(b.credits) or 0,
        autoCharge = tonumber(b.autoCharge) or 0,
        dailyBonus = tonumber(b.dailyBonus) or 0,
        seasonPoints = tonumber(b.seasonPoints) or 0,
        manual = tonumber(b.manual) or 0,
    }
end
M.bucket = bucket

--- The four big numbers at the top: today, this week, this month, all time.
---
--- All four are TOTALS the server computed over the whole history, not sums of
--- the visible series — so a fortnight-long series and a year-long one show
--- the same "all time", which is the only thing that word can mean.
function M.headlines(stats)
    stats = type(stats) == "table" and stats or {}
    return {
        { key = "today", label = "TODAY", value = bucket(stats.today).credited },
        { key = "week", label = "THIS WEEK", value = bucket(stats.thisWeek).credited },
        { key = "month", label = "THIS MONTH", value = bucket(stats.thisMonth).credited },
        { key = "all", label = "ALL TIME", value = bucket(stats.allTime).credited },
    }
end

--- The day-by-day list, NEWEST FIRST — the order a list is read in.
---
--- The server's series is dense (a row for every date, zeros included) because
--- a chart of a sparse one draws a lie. A LIST is different: thirty rows of
--- "0" is thirty rows nobody wants to scroll past. So the empty days are
--- dropped here, at the point of display, and the count of them is returned
--- alongside so the screen can still say how many days were quiet.
function M.day_rows(stats, opts)
    opts = opts or {}
    stats = type(stats) == "table" and stats or {}
    local daily = type(stats.daily) == "table" and stats.daily or {}

    local rows, skipped = {}, 0
    for i = #daily, 1, -1 do
        local d = daily[i]
        local b = bucket(d)
        if b.credited > 0 then
            rows[#rows + 1] = {
                date = d.date,
                label = M.format_day_relative(d.date, opts.today),
                credited = b.credited,
                credits = b.credits,
                runningTotal = tonumber(d.runningTotal) or 0,
                sources = M.sources_of(b),
            }
        else
            skipped = skipped + 1
        end
        if opts.limit and #rows >= opts.limit then break end
    end
    return rows, skipped
end

--- Which routes a single day's savings came through, biggest first.
--- "5 auto + 100 season" is a different day from "105 season", and a player
--- looking at one date wants to know which it was.
function M.sources_of(b)
    b = bucket(b)
    local out = {}
    for _, s in ipairs(M.SOURCES) do
        if b[s.key] > 0 then
            out[#out + 1] = { key = s.key, label = s.label,
                              short = SOURCE_SHORT[s.key] or s.key, value = b[s.key] }
        end
    end
    table.sort(out, function(a, c)
        if a.value ~= c.value then return a.value > c.value end
        return a.key < c.key   -- stable, so equal amounts do not shuffle between frames
    end)
    return out
end

--- All-time split by route, with each one's share. Rows with nothing in them
--- are kept: "you have never used auto-save" is information, and a row that
--- vanishes cannot say it.
function M.breakdown(stats)
    stats = type(stats) == "table" and stats or {}
    local all = bucket(stats.allTime)
    local out = {}
    for _, s in ipairs(M.SOURCES) do
        out[#out + 1] = {
            key = s.key,
            label = s.label,
            value = all[s.key],
            -- Integer percent of the recorded total. Not of the BALANCE:
            -- anything banked before the daily ledger existed is in the
            -- balance and in no route, and dividing by it would leave four
            -- shares that visibly fail to reach 100.
            percent = all.credited > 0 and math.floor((all[s.key] / all.credited) * 100 + 0.5) or 0,
        }
    end
    return out
end

--- The weekly list, newest first, straight from the server's buckets.
function M.week_rows(stats, limit)
    stats = type(stats) == "table" and stats or {}
    local weekly = type(stats.weekly) == "table" and stats.weekly or {}
    local out = {}
    for i = 1, #weekly do
        local w = weekly[i]
        local b = bucket(w)
        out[#out + 1] = {
            weekStart = w.weekStart,
            label = M.format_week(w.weekStart, w.weekEnd),
            credited = b.credited,
            daysSaved = tonumber(w.daysSaved) or 0,
        }
        if limit and #out >= limit then break end
    end
    return out
end

--- The monthly list, newest first.
function M.month_rows(stats, limit)
    stats = type(stats) == "table" and stats or {}
    local monthly = type(stats.monthly) == "table" and stats.monthly or {}
    local out = {}
    for i = 1, #monthly do
        local m = monthly[i]
        out[#out + 1] = {
            month = m.month,
            label = M.format_month(m.month),
            credited = bucket(m).credited,
            daysSaved = tonumber(m.daysSaved) or 0,
        }
        if limit and #out >= limit then break end
    end
    return out
end

--- The one-line facts under the headlines: streak, best day, averages.
--- Returned as {label, value} pairs so the drawing code places them without
--- knowing what any of them mean.
function M.facts(stats)
    stats = type(stats) == "table" and stats or {}
    local out = {}

    local streak = tonumber(stats.currentStreak) or 0
    if streak > 0 then
        out[#out + 1] = { key = "streak", label = "Saving streak",
                          value = streak .. (streak == 1 and " day" or " days") }
    end

    local best = type(stats.bestDay) == "table" and stats.bestDay or nil
    if best and (tonumber(best.credited) or 0) > 0 then
        out[#out + 1] = { key = "best", label = "Best day",
                          value = M.commas(best.credited) .. " on " .. M.format_day(best.date) }
    end

    local daysSaved = tonumber(stats.daysSaved) or 0
    if daysSaved > 0 then
        out[#out + 1] = { key = "days", label = "Days you saved",
                          value = M.commas(daysSaved) .. (daysSaved == 1 and " day" or " days") }
        out[#out + 1] = { key = "avg", label = "Average when you save",
                          value = M.commas(stats.averagePerActiveDay) .. " coins" }
    end

    local longest = tonumber(stats.longestStreak) or 0
    if longest > 1 then
        out[#out + 1] = { key = "longest", label = "Longest streak", value = longest .. " days" }
    end

    if stats.recordedFrom then
        out[#out + 1] = { key = "since", label = "Tracking since",
                          value = M.format_day(stats.recordedFrom) }
    end

    return out
end

--- What to say when there is nothing to show. Three different nothings, and
--- telling them apart is the whole value: a player who has never saved needs
--- an invitation, one whose history is still loading needs to be told to wait,
--- and one the server could not answer for needs to know it is not their fault.
function M.empty_reason(stats, pending)
    if pending then return "loading", "Loading your savings history..." end
    if type(stats) ~= "table" then
        return "unavailable", "Savings history is unavailable right now."
    end
    if (tonumber(stats.daysSaved) or 0) == 0 then
        return "never", "You have not saved anything yet. Every coin you add shows up here, by date."
    end
    return nil, nil
end

--- The line that explains a balance bigger than the recorded history.
---
--- Returns nil when there is nothing to explain. When there is, it is because
--- the player was saving before this ledger existed — which is true of every
--- account that predates it, and reads as a bug if the screen shows "all time
--- saved: 10" beside a balance of 8,000 and says nothing.
function M.unrecorded_note(stats)
    stats = type(stats) == "table" and stats or {}
    local n = tonumber(stats.unrecorded) or 0
    if n <= 0 then return nil end
    return M.commas(n) .. " coins were saved before daily tracking began"
end

return M
