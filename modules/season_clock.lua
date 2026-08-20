-- season_clock.lua — when the season ends, and how long that is in words.
--
-- WHY THIS IS ONE MODULE AND NOT THREE COPIES
--
-- "How long until the season ends" was answered independently in three
-- places: the lobby header (modules/lobby/season.lua), the online screen's
-- own update_season, and now the Season Bonuses title row. All three parsed
-- the same ISO string, all three carried their own copy of the Wednesday
-- midday / Saturday midnight fallback cadence, and all three formatted the
-- remainder themselves.
--
-- Three copies of a schedule is three chances for one of them to disagree
-- with the server about when the money moves. The parsing and the fallback
-- live here now; the formatting comes in two flavours because the two
-- surfaces genuinely want different things (see below).
--
-- Pure: no `gui`, no `ws`, no Defold anything — the caller passes in the
-- season status and the current time. tools/test_season_clock.lua runs it
-- under stock Lua.

local M = {}

-- Africa/Nairobi, UTC+3, no DST. The prize and season cadence is fixed to
-- this timezone regardless of what the handset's clock is set to.
M.EAT_OFFSET = 3 * 3600

-- ---------------------------------------------------------------------------
-- Dates
-- ---------------------------------------------------------------------------

-- Days since the Unix epoch for a civil date (Howard Hinnant's days_from_civil).
-- Used instead of os.time{...} because that reads the DEVICE's timezone, and
-- every date here is either UTC or EAT — never local.
local function days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- A server ISO-8601 UTC timestamp as a unix epoch, or nil if unparseable.
function M.parse_iso_utc(str)
    if type(str) ~= "string" then return nil end
    local y, mo, d, h, mi, s = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

--- The placeholder boundary: Wednesday 12:00 / Saturday 23:59 Africa/Nairobi.
---
--- SEASON_STATUS only reaches an authenticated client, right after IDENTIFY,
--- so guests — and everybody in the window before that round trip lands —
--- would otherwise watch a blank or frozen countdown. Mirrors be_matatu's
--- Prize.DEFAULT_SEASON_SCOPES so it agrees with the real schedule until the
--- live value arrives.
function M.fallback_end_utc(now)
    now = now or os.time()
    local now_eat = now + M.EAT_OFFSET
    local t = os.date("!*t", now_eat)
    local seconds_today = t.hour * 3600 + t.min * 60 + t.sec
    local midnight_today_eat = now_eat - seconds_today
    local is_phase_1 = (t.wday >= 1 and t.wday <= 3) or (t.wday == 4 and seconds_today < 43200)
    local target_eat = is_phase_1
        and (midnight_today_eat + (((4 - t.wday) % 7) * 86400) + 43200)
        or (midnight_today_eat + (((7 - t.wday) % 7) * 86400) + 86399)
    return target_eat - M.EAT_OFFSET
end

--- When the current season ends, preferring the server's word over ours.
function M.end_epoch(status, now)
    local from_server = status and M.parse_iso_utc(status.endDate)
    return from_server or M.fallback_end_utc(now)
end

--- Seconds left, never negative.
function M.remaining(status, now)
    now = now or os.time()
    return math.max(0, M.end_epoch(status, now) - now)
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

--- The full countdown: "4D 05H 12M 07S", or "05H 12M 07S" inside a day.
---
--- For a surface whose whole job is the countdown — the lobby header — where
--- the ticking second is the point and the zero padding stops the string
--- changing width every time a digit drops.
function M.verbose(seconds)
    local d = math.max(0, math.floor(tonumber(seconds) or 0))
    if d >= 86400 then
        return string.format("%dD %02dH %02dM %02dS",
            math.floor(d / 86400), math.floor((d % 86400) / 3600),
            math.floor((d % 3600) / 60), d % 60)
    end
    return string.format("%02dH %02dM %02dS",
        math.floor(d / 3600), math.floor((d % 3600) / 60), d % 60)
end

--- The minimal countdown: TWO UNITS, and only the two that matter right now.
---
---     4D 5H      more than a day out — minutes are noise at this range
---     5H 3M      inside the last day
---     5M 3S      inside the last hour, where seconds start to matter
---     42S        inside the last minute
---     ENDED      the boundary has passed
---
--- This sits inline with the SEASON BONUSES title, where it is a glance and
--- not a clock. "4D 5H 5M" was the version before this one, and the minutes
--- field there is a digit nobody reads on a four-day countdown while still
--- being wide enough to crowd the title.
---
--- UNPADDED, unlike verbose(): the string does change width as it counts
--- down, and that is fine on a right-aligned label — but a leading zero on a
--- number this short reads as a stopwatch, which is the opposite of minimal.
---
--- The unit pair narrows as the deadline approaches, so the row gets more
--- urgent-looking on its own without anything having to decide that it is
--- urgent.
function M.compact(seconds)
    local d = math.max(0, math.floor(tonumber(seconds) or 0))
    if d <= 0 then return "ENDED" end

    local days  = math.floor(d / 86400)
    local hours = math.floor((d % 86400) / 3600)
    local mins  = math.floor((d % 3600) / 60)
    local secs  = d % 60

    if days >= 1 then return string.format("%dD %dH", days, hours) end
    if hours >= 1 then return string.format("%dH %dM", hours, mins) end
    if mins >= 1 then return string.format("%dM %dS", mins, secs) end
    return string.format("%dS", secs)
end

--- How often this string can change, in seconds.
---
--- A caller that repaints the label every frame is repainting an identical
--- string 59 times out of 60 for most of a season. One second is correct at
--- every range — the compact form only shows seconds inside the last hour,
--- but the cost of ticking at 1Hz throughout is one string compare.
M.TICK_SECONDS = 1

return M
