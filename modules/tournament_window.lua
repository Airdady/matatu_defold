-- IS THE TOURNAMENT OPEN RIGHT NOW?
--
-- Two screens ask this and they must not disagree. tournaments.gui_script has
-- always worked it out — as `is_dormant`, inline, mixed in with the countdown
-- strings it drives — and the online screen's badge said "NEW" regardless,
-- which is not a state at all: it said the same thing on a tournament that had
-- been running for months and on one that closed an hour ago.
--
-- So the rule moves here, as arithmetic with no screen attached.
--
-- THE TWO GATES, IN ORDER
--
--   launchDate   the tournament has not started existing yet. Set on
--                tournaments announced ahead of time; the backend does NOT
--                enforce it (it is informational there), so this is the only
--                thing keeping a player out. Missing or unparseable means
--                "already live", which is every tournament that has no
--                launchDate at all.
--
--   activeTime   the DAILY window. Tournaments run between a start and an end
--                hour, and outside that they are closed until tomorrow. The
--                defaults are the ones tournaments.gui_script has always used;
--                a tournament may override either end.
local M = {}

--- Default daily window: 08:00 to 23:59.
M.DEFAULT_START_HOUR   = 8
M.DEFAULT_START_MINUTE = 0
M.DEFAULT_END_HOUR     = 23
M.DEFAULT_END_MINUTE   = 59

--- Seconds since the epoch for a UTC ISO-8601 string, or nil.
---
-- Kept here beside the only rule that reads it. `!*t` is the UTC form of
-- os.date, and the offset it produces is what turns a local-time os.time into
-- a comparable one — without it a player east of UTC sees a tournament unlock
-- hours early and one to the west sees it late.
function M.parse_iso_utc_epoch(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    local t = {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec),
        isdst = false,
    }
    local as_local = os.time(t)
    if not as_local then return nil end
    -- os.time treated the fields as LOCAL. Measure that error and undo it.
    local utc = os.date("!*t", as_local)
    utc.isdst = false
    return as_local + (as_local - os.time(utc))
end

--- The daily window, in minutes past midnight, honouring any override.
function M.window_minutes(tournament)
    local sh, sm = M.DEFAULT_START_HOUR, M.DEFAULT_START_MINUTE
    local eh, em = M.DEFAULT_END_HOUR, M.DEFAULT_END_MINUTE

    local at = type(tournament) == "table" and tournament.activeTime or nil
    if type(at) == "table" then
        if type(at.start) == "string" then
            local h, m = at.start:match("(%d+):(%d+)")
            sh = tonumber(h) or sh
            sm = tonumber(m) or sm
        end
        if type(at["end"]) == "string" then
            local h, m = at["end"]:match("(%d+):(%d+)")
            eh = tonumber(h) or eh
            em = tonumber(m) or em
        end
    end

    return sh * 60 + sm, eh * 60 + em
end

--- "open" | "closed" | "soon"
---
--- `now` and `now_parts` are injected so this can be tested without waiting for
--- a particular hour of the day. Both default to the real clock.
function M.state(tournament, now, now_parts)
    if type(tournament) ~= "table" then return "closed" end

    now = now or os.time()
    local parts = now_parts or os.date("*t", now)

    -- Announced but not yet launched.
    local launch = M.parse_iso_utc_epoch(tournament.launchDate)
    if launch and now < launch then return "soon" end

    -- A tournament the server has finished with is closed whatever the clock
    -- says. Checked after launchDate because an unlaunched one has no
    -- meaningful status yet.
    local status = tournament.status
    if status ~= nil and status ~= "active" and status ~= "upcoming" then
        return "closed"
    end

    local start_mins, end_mins = M.window_minutes(tournament)
    local cur = (parts.hour or 0) * 60 + (parts.min or 0)

    if cur < start_mins then return "closed" end
    if cur >= end_mins then return "closed" end
    return "open"
end

--- WHICH tournament the badge is about.
---
--- The same order tournaments.gui_script picks in, so the badge describes the
--- tournament the tap actually opens. Getting this wrong would be worse than
--- the "NEW" it replaces: a badge that says OPEN about a tournament other than
--- the one the player then lands on.
---
---   1. a GLOBAL one that is active
---   2. any active one
---   3. the first there is, so a closed tournament still gets a badge saying so
function M.headline(tournaments)
    if type(tournaments) ~= "table" then return nil end

    local function is_global(t)
        return t.scope == "GLOBAL" or t.name == "Global Championship" or t.type == "public"
    end

    for _, t in ipairs(tournaments) do
        if type(t) == "table" and is_global(t) and t.status == "active" then return t end
    end
    for _, t in ipairs(tournaments) do
        if type(t) == "table" and t.status == "active" then return t end
    end
    for _, t in ipairs(tournaments) do
        if type(t) == "table" then return t end
    end
    return nil
end

--- What the badge should say for a state.
M.BADGE_LABEL = { open = "OPEN", closed = "CLOSED", soon = "SOON" }

function M.badge_label(tournament, now, now_parts)
    return M.BADGE_LABEL[M.state(tournament, now, now_parts)] or "CLOSED"
end

return M
