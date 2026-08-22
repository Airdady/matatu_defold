-- THE OPPONENT-SEARCH COUNTDOWN, AND WHY IT KEPT JUMPING.
--
-- The dialog starts counting the moment the player taps INVITE. It cannot know
-- how long the window actually is until the server says so — a ladder settles
-- at twelve seconds, a battle at eight — and that message takes a moment to
-- arrive, because the server builds one invite per opponent and each waits on
-- a head-to-head lookup before any of them go out.
--
-- So the first seconds on screen are a GUESS, and every fix so far has been an
-- attempt to make the guess right:
--
--   12, 11, 10 then 4   the message arrived late AND carried what was left of
--                       the window, and the ring subtracted its own elapsed
--                       time from that remainder a second time
--   12, 11, 10 then 6   the elapsed time was reset on arrival, so the second
--                       error was gone — and the ring still snapped, because
--                       the guess (12, no grace) and the truth (12 minus a 2s
--                       grace, or 8 from an older server) are simply different
--                       numbers
--
-- CORRECTING A GUESS IS A JUMP. That is not a bug in any one number; it is
-- what happens whenever a displayed value is replaced by a better one. The
-- only fix that survives every combination of server version and network
-- delay is to stop replacing it: converge instead.
--
-- THE RULE HERE
--
--   * the ring only ever counts DOWN, one second per second
--   * when the truth turns out to be LOWER than what is on screen, it falls
--     faster until it catches up — never snaps
--   * when the truth turns out to be HIGHER, the ring is not rewound; it keeps
--     descending and the truth catches up to IT
--
-- A player watching this sees a countdown that occasionally runs a little
-- quick. They never see it jump, run backwards, or disagree with the moment
-- the game actually starts.
--
-- Pure: no gui, no ws, no Defold anything. tools/test_search_clock.lua runs it
-- under stock Lua.

local M = {}

--- How much faster than real time the ring may fall while catching up.
--
-- Three is fast enough to close a four-second error in about two seconds — the
-- worst case here, an old server's remainder arriving late — and slow enough
-- to still read as a countdown rather than as a glitch. At 1 it could never
-- catch up at all; at 10 it is a snap with extra steps.
M.CATCHUP_RATE = 3

--- What the ring shows before the server has said anything.
--
-- Twelve is the longest window the server uses, and the grace matches
-- TOURNAMENT_ACCEPT_GRACE_MS. Guessing the LONGEST window is deliberate: it
-- means the common correction is downward, which this module handles smoothly,
-- rather than upward, which it can only handle by letting the ring sit.
M.FALLBACK_WINDOW = 12
M.FALLBACK_GRACE = 2

--- The countdown the server's numbers imply right now.
--
-- THE RING RUNS THE WHOLE WINDOW, INCLUDING THE ASSESSMENT.
--
-- It used to stop at the start of the grace — the tail the server keeps for
-- answers already in flight — so the last seconds were spent looking at an
-- empty ring and the word "assessing". A clock that has stopped reads as a
-- clock that has failed, which is exactly the wrong thing to show at the
-- moment the match is actually being decided.
--
-- It counts to zero now, and zero lands where the server settles. The
-- assessment is a PHASE of the countdown rather than a state after it: the
-- label changes, the number keeps moving.
--
-- Returns the seconds left and the length of the whole window.
function M.target(sr)
    sr = sr or {}
    local max_time = tonumber(sr.max_time) or M.FALLBACK_WINDOW
    if max_time <= 0 then max_time = M.FALLBACK_WINDOW end

    local grace = tonumber(sr.grace_time)
    if grace == nil then grace = M.FALLBACK_GRACE end
    grace = math.max(0, math.min(grace, max_time - 1))

    local elapsed = math.max(0, tonumber(sr.t) or 0)
    -- `grace` is not subtracted from the window any more; it is returned so
    -- callers can ask WHICH PHASE the remaining time is in (see is_choosing).
    return math.max(0, max_time - elapsed), max_time, grace
end

--- Advance the clock by `dt` and return what the ring should draw.
--
-- Writes `sr.t` (the real elapsed time, which the target is computed from) and
-- `sr.shown` (the smoothed value, which is what a player sees). Keeping them
-- separate is the whole trick: the truth is free to be corrected at any moment
-- without the thing on screen ever having to move discontinuously.
function M.tick(sr, dt)
    if type(sr) ~= "table" then return 0 end
    local step = math.max(0, tonumber(dt) or 0)
    sr.t = math.max(0, (tonumber(sr.t) or 0) + step)

    local target = M.target(sr)
    local shown = tonumber(sr.shown)

    if shown == nil then
        -- First frame: there is nothing on screen to contradict, so start at
        -- the truth.
        sr.shown = target
    elseif target < shown then
        -- The window is shorter than we were showing. Fall faster, but land on
        -- the target rather than overshooting past it.
        sr.shown = math.max(target, shown - step * M.CATCHUP_RATE)
    else
        -- The window is longer than we were showing — or exactly right. Either
        -- way the ring keeps descending at one second per second. It is never
        -- rewound: a countdown that goes back up is worse than one that is a
        -- little pessimistic.
        sr.shown = math.max(0, shown - step)
    end

    return sr.shown
end

--- Adopt the window the server has just named.
--
-- `settle_ms` is a DURATION and means "this long from now", so the elapsed
-- clock restarts here. `shown` is deliberately LEFT ALONE — that is what makes
-- the correction converge rather than snap.
function M.adopt(sr, settle_ms, grace_ms, invited)
    if type(sr) ~= "table" then return false end
    local secs = (tonumber(settle_ms) or 0) / 1000
    if secs <= 0 then return false end

    sr.max_time = secs
    sr.grace_time = (tonumber(grace_ms) or 0) / 1000
    if invited ~= nil then sr.invited = tonumber(invited) or 0 end
    sr.t = 0
    return true
end

--- Is the window past the point where new answers are still accepted?
--
-- True for the last `grace` seconds — the tail the server holds for answers
-- already in flight — and the number keeps counting down throughout. The
-- assessment is a phase of the countdown, not a state after it.
--
-- Asked of the SHOWN value rather than the real one, so the words on screen
-- and the ring beneath them cannot disagree.
function M.is_choosing(sr)
    if type(sr) ~= "table" then return false end
    if sr.found or sr.failed then return false end
    -- The smoothed value when there is one, the raw arithmetic when there is
    -- not. A caller that has set the window but never ticked — a test, or the
    -- frame the dialog opens on — still gets a true answer rather than a flat
    -- "no", which is what reading `shown` alone gave it.
    local left = tonumber(sr.shown)
    local _, _, grace = M.target(sr)
    if left == nil then left = M.target(sr) end
    return left <= grace
end

-- ---------------------------------------------------------------------------
-- ARRIVALS: what a player joining the search looks like
-- ---------------------------------------------------------------------------
--
-- The roster used to appear all at once, silently, as a row of avatars that
-- grew when a redraw happened to land. Somebody accepting a staked invite is
-- the single most interesting thing that happens during those twelve seconds
-- and it went by without a sound or a movement.
--
-- Each arrival now has a moment of its own: it pops in at the slot, the ring
-- flashes green, and it settles into the shortlist beside the ones before it.
-- The timings live here rather than in the drawing code so both dialogs play
-- the same beat, and so they can be reasoned about without a screen.

--- How long a newly arrived player takes to settle into the shortlist.
M.ARRIVE_POP = 0.35

--- How long the green stays on them, and on the ring behind the slot.
M.ARRIVE_GLOW = 0.9

--- Merge a fresh roster into `sr`, remembering when each player first appeared.
--
-- Returns the number of players who are NEW this push — the caller plays one
-- sound per arrival rather than one per message, because the server re-sends
-- the whole roster every time and a naive handler would re-announce everybody
-- who was already there.
--
-- `arrived_at` is stamped from sr.t, the same clock the animation is measured
-- against, so an arrival cannot be timed against one clock and drawn against
-- another.
function M.note_arrivals(sr, incoming)
    if type(sr) ~= "table" then return 0 end
    local now = tonumber(sr.t) or 0
    local seen = {}
    for _, r in ipairs(sr.roster or {}) do
        if r.userId then seen[r.userId] = r.arrived_at or now end
    end

    local merged, fresh = {}, 0
    for _, r in ipairs(incoming or {}) do
        local id = r.userId
        local was = id and seen[id]
        if was == nil then fresh = fresh + 1 end
        merged[#merged + 1] = {
            userId = id, username = r.username, avatar = r.avatar,
            skillTier = r.skillTier,
            arrived_at = was or now,
        }
    end

    sr.roster = merged
    if fresh > 0 then sr.flash_at = now end
    return fresh
end

--- How big a just-arrived avatar should be drawn, as a multiplier.
--
-- Overshoots and settles: 1.6 at the instant of arrival easing back to 1.0.
-- Nothing else on this dialog moves, so a pop is enough to say "that is new"
-- without an animation system.
function M.arrival_scale(sr, entry)
    if type(sr) ~= "table" or type(entry) ~= "table" then return 1 end
    local age = (tonumber(sr.t) or 0) - (tonumber(entry.arrived_at) or 0)
    if age < 0 or age >= M.ARRIVE_POP then return 1 end
    local k = 1 - (age / M.ARRIVE_POP)
    -- Cubed so it lands softly rather than arriving at full speed.
    return 1 + 0.6 * k * k * k
end

--- How green a just-arrived avatar still is, 1 at arrival down to 0.
function M.arrival_glow(sr, entry)
    if type(sr) ~= "table" or type(entry) ~= "table" then return 0 end
    local age = (tonumber(sr.t) or 0) - (tonumber(entry.arrived_at) or 0)
    if age < 0 or age >= M.ARRIVE_GLOW then return 0 end
    return 1 - (age / M.ARRIVE_GLOW)
end

--- The green light behind the slot, 1 the moment somebody joins down to 0.
--
-- One light for the dialog rather than one per player: two people accepting
-- half a second apart should read as the search working, not as two separate
-- alarms.
function M.flash(sr)
    if type(sr) ~= "table" then return 0 end
    local at = tonumber(sr.flash_at)
    if at == nil then return 0 end
    local age = (tonumber(sr.t) or 0) - at
    if age < 0 or age >= M.ARRIVE_GLOW then return 0 end
    return 1 - (age / M.ARRIVE_GLOW)
end

--- How long the caller should arm its own backstop for, in seconds.
--
-- The full window plus the caller's grace, measured from now — never minus an
-- elapsed time, which is what used to make the dialog give up at eleven
-- seconds while the server settled at twelve.
function M.failsafe_delay(sr, extra)
    sr = sr or {}
    local max_time = tonumber(sr.max_time) or M.FALLBACK_WINDOW
    if max_time <= 0 then max_time = M.FALLBACK_WINDOW end
    return max_time + math.max(0, tonumber(extra) or 0)
end

return M
