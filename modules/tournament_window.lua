-- IS THE GLOBAL TOURNAMENT OPEN RIGHT NOW?
--
-- One question, asked from two places that must not disagree.
--
-- The tournament screen has always known the answer: check_timer_states works
-- out a daily active window and sets `is_dormant`, which greys the PLAY button
-- and swaps the countdown between "ENDS IN" and "NEW TOURNAMENT STARTS IN".
-- That knowledge never left the screen, so the lobby's way IN could only ever
-- say something static — a "NEW" badge that had been there since the feature
-- shipped and meant nothing by the second day.
--
-- A badge that says OPEN or CLOSED has to compute the same window, and a
-- second copy of a schedule is a promise that the two will drift: one of them
-- gets the overnight case fixed, or a new override honoured, and the other
-- keeps sending players to a door that is shut.
--
-- So the window lives here, both callers read it, and it is testable without a
-- screen — same shape as season_clock and takeover_rules.
--
-- Pure: no gui, no ws, no Defold anything. Callers pass the tournaments list
-- they already hold (ws.current_user_data.tournaments) and the current
-- minute-of-day. tools/test_tournament_window.lua runs it under stock Lua.

local M = {}

--- The default daily window, when a tournament names none of its own.
--
-- These are the numbers main/tournaments.gui_script has always used. They are
-- the DEFAULT, not the rule: a tournament carrying activeTime overrides them,
-- which is how a one-off schedule is set without a client release.
M.START_HOUR   = 8
M.START_MINUTE = 0
M.END_HOUR     = 23
M.END_MINUTE   = 59

--- Is this the global championship rather than a private or team cup?
--
-- Three ways of saying it, because three generations of the backend have said
-- it differently and old tournaments are still live: an explicit scope, the
-- name, or the public type. Any of them counts.
function M.is_global(t)
    if type(t) ~= "table" then return false end
    return t.scope == "GLOBAL"
        or t.name == "Global Championship"
        or t.type == "public"
end

--- The global tournament out of a list, preferring an active one.
--
-- An active global beats a dormant one; a dormant global is still returned
-- when that is all there is, because "the championship exists and is shut" is
-- a different thing to say than nothing at all.
function M.global_of(list)
    if type(list) ~= "table" then return nil end
    local fallback
    for _, t in ipairs(list) do
        if M.is_global(t) then
            if tostring(t.status or ""):lower() == "active" then return t end
            fallback = fallback or t
        end
    end
    return fallback
end

--- The window this tournament runs to, as minutes of the day.
--
-- activeTime is "HH:MM" strings on the tournament document. A half-set or
-- unparseable override falls back per FIELD rather than wholesale, so a
-- tournament that names only its start keeps the default end.
function M.bounds(t)
    local sh, sm = M.START_HOUR, M.START_MINUTE
    local eh, em = M.END_HOUR, M.END_MINUTE

    local at = (type(t) == "table") and t.activeTime or nil
    if type(at) == "table" then
        if type(at.start) == "string" then
            local h, m = at.start:match("^(%d+):(%d+)")
            sh, sm = tonumber(h) or sh, tonumber(m) or sm
        end
        if type(at["end"]) == "string" then
            local h, m = at["end"]:match("^(%d+):(%d+)")
            eh, em = tonumber(h) or eh, tonumber(m) or em
        end
    end
    return sh * 60 + sm, eh * 60 + em
end

--- Minutes of the day, from an os.date("*t") table.
function M.minute_of_day(dt)
    if type(dt) ~= "table" then return 0 end
    return (tonumber(dt.hour) or 0) * 60 + (tonumber(dt.min) or 0)
end

--- Is the window open at this minute of the day?
--
-- Handles a window that WRAPS midnight — an end earlier than its start, say
-- 20:00 to 02:00. The screen's own version could not: it compared against both
-- bounds as though they were always in order, so an overnight schedule read as
-- closed for the whole of its actual run. Nothing sets one today, which is
-- exactly why it would have been found the hard way.
function M.is_open_at(t, cur_mins)
    local s, e = M.bounds(t)
    cur_mins = tonumber(cur_mins) or 0
    if s == e then return false end          -- a zero-length window is shut
    if e > s then return cur_mins >= s and cur_mins < e end
    return cur_mins >= s or cur_mins < e     -- wraps midnight
end

--- Is the global championship open, given the whole tournaments list?
--
-- A tournament the server has not marked active is shut whatever the clock
-- says: the schedule describes when an ACTIVE championship runs, not whether
-- there is one.
function M.is_open(list, cur_mins)
    local t = M.global_of(list)
    if not t then return false end
    if tostring(t.status or ""):lower() ~= "active" then return false end
    return M.is_open_at(t, cur_mins)
end

--- The badge word. Nil when there is no global championship to describe.
--
-- Nil rather than "CLOSED", because they are different facts and the caller
-- draws nothing for the first. A badge reading CLOSED says the door is shut;
-- one drawn over a list that has not loaded yet says it about a door nobody
-- has looked at.
function M.status_label(list, cur_mins)
    if M.global_of(list) == nil then return nil end
    return M.is_open(list, cur_mins) and "OPEN" or "CLOSED"
end

return M
