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
    -- The animation clock is NOT the countdown clock. `t` is restarted every
    -- time the server names a window, and anything stamped against it — an
    -- arrival, a flash — would find itself in the future the moment that
    -- happened, replaying or freezing halfway. `anim_t` only ever goes
    -- forward, so a beat that started before the correction finishes after it.
    sr.anim_t = math.max(0, (tonumber(sr.anim_t) or 0) + step)

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

    -- RE-ANCHOR THE RING BEFORE MOVING THE CLOCK OUT FROM UNDER IT.
    --
    -- Where it is now is read first, then re-aimed at zero over the real time
    -- remaining. That is what makes the correction invisible: the ring carries
    -- on from exactly where it was, and absorbs the difference as a small
    -- permanent change of rate instead of a jump or a burst of speed. See the
    -- long note on M.arc.
    local was = M.arc(sr)

    sr.max_time = secs
    sr.grace_time = (tonumber(grace_ms) or 0) / 1000

    sr.arc_from = was
    sr.arc_secs = math.max(0.001, secs)
    sr.arc_t0   = tonumber(sr.anim_t) or 0
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

--- How full the ring should be, 1 at the start down to 0 at the settle.
--
-- THREE THINGS WENT WRONG HERE, EACH ONE ONLY VISIBLE ONCE THE LAST WAS FIXED.
--
-- 1. THE DENOMINATOR. The ring is not the number, it is the number divided by
--    the window — and the window is corrected the moment the server speaks.
--    Dividing the SAME remaining time by a SMALLER denominator makes it a
--    BIGGER fraction, so the ring refilled at exactly the value where the two
--    met. "At 8 it starts afresh."
--
-- 2. THE SPEED. Fixing that left the ring driven off `shown`, the smoothed
--    number — and `shown` does not descend at one second per second. While it
--    converges on a correction it falls at CATCHUP_RATE, three times as fast,
--    then brakes back to one. Digits survive that; three-times speed just skips
--    a number. A ring does not, because angular velocity IS what the eye reads
--    on a ring. "From 12 to 8 junky, from 8 to zero a good flow" is precisely
--    the catch-up phase against the settled phase.
--
-- 3. AND YOU CANNOT SIMPLY USE THE REAL TIME INSTEAD. If the server's message
--    is late — the ring showing 10 while the truth is 8 — then something has
--    to give, and the choice is only ever WHERE:
--
--      into the position   the ring steps back. A visible jump.
--      into the speed      the ring races, then brakes. A visible stutter.
--      into the RATE, once the ring keeps going from exactly where it is and
--                          covers what is left slightly faster, forever.
--
--    The third is the only one with nothing to see, so that is what this does.
--
-- THE ANCHOR
--
-- The ring is a straight line from a remembered fraction to zero over a
-- remembered duration. `adopt` re-anchors it: it reads where the ring is right
-- now, and re-aims THAT at zero over the real time remaining. Position is
-- continuous by construction, the rate is constant between anchors, and there
-- is only ever one anchor — the moment the server speaks.
--
-- When the message arrives promptly, remaining and window agree and the rate
-- does not change at all. When it is four seconds late the ring covers the
-- last two thirds about a quarter faster. Nobody has ever noticed a countdown
-- ring running 25% quick; everybody notices one that jumps or stutters.
--
-- Measured on `anim_t`, the clock that never rewinds — `t` is reset by the very
-- correction being absorbed here.
function M.arc(sr)
    if type(sr) ~= "table" then return 0 end
    local now = tonumber(sr.anim_t) or 0

    if sr.arc_from == nil then
        -- First anchor: full ring, aimed at zero over the whole window. Backs
        -- `t0` off by however much has already elapsed, so a dialog whose first
        -- draw lands a few frames late starts from the right place rather than
        -- from full.
        local left, window = M.target(sr)
        sr.arc_from = 1
        sr.arc_secs = math.max(0.001, window)
        sr.arc_t0   = now - math.max(0, window - left)
    end

    local span = tonumber(sr.arc_secs) or 0
    if span <= 0 then return 0 end
    local p = (now - (tonumber(sr.arc_t0) or 0)) / span
    return math.max(0, math.min(1, (tonumber(sr.arc_from) or 1) * (1 - p)))
end

--- How long the ring has left, in real seconds.
--
-- The duration to hand a native fill_angle animation. It has to come from the
-- same anchor the angle does, or the animation and the next recomputation
-- disagree and the ring visibly jumps every time the dialog redraws.
function M.arc_secs(sr)
    if type(sr) ~= "table" then return 0 end
    M.arc(sr)
    local now  = tonumber(sr.anim_t) or 0
    local span = tonumber(sr.arc_secs) or 0
    return math.max(0, span - (now - (tonumber(sr.arc_t0) or 0)))
end

-- ---------------------------------------------------------------------------
-- THE STORY OF AN ACCEPTANCE
--
-- What used to happen when somebody accepted: a small avatar silently appeared
-- in a row of small avatars. The single most interesting event in these twelve
-- seconds — a real person, somewhere, agreeing to play you for money — had no
-- more presence than a list item, and the empty question-mark slot kept
-- spinning as though nothing had happened.
--
-- It has three beats now, and every one of them is a real thing being said:
--
--   HOLD    they take the opponent slot. Full size, named, their skill badge
--           under them. This is "somebody is here" — the slot answers its own
--           question for a moment.
--   FLY     they travel out of the slot to their seat on the shortlist rail,
--           shrinking as they go. This is "and they are waiting" — the reason
--           the search does not simply stop, drawn rather than explained.
--   REST    they sit on the rail with their name and tier while the slot goes
--           back to hunting. The search visibly continues WITH them held.
--
-- and then, when the window closes:
--
--   RETURN  the chosen one flies back out of the rail into the slot and pulses
--           green. The match is the answer to the search, so it arrives from
--           where the candidates were kept rather than materialising.
--
-- Only ONE player can hold the slot at a time. When two accept close together
-- the newer one takes it and the older snaps to its seat — overlapping
-- entrances would read as a glitch, and the rail is where the older one was
-- going anyway.
--
-- Durations are here, not in the drawing code, so both dialogs play the same
-- beat and so the whole choreography can be reasoned about without a screen.

--- How long a newly arrived player takes to settle to its normal size.
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
-- `arrived_at` is stamped from sr.anim_t — the clock that never restarts —
-- rather than from sr.t, which adopt() rewinds to zero the moment the server
-- names its window. Stamped against the countdown clock, a player who arrived
-- before that correction would be dated in the FUTURE after it, and their whole
-- entrance would replay or freeze halfway through it.
function M.note_arrivals(sr, incoming)
    if type(sr) ~= "table" then return 0 end
    local now = tonumber(sr.anim_t) or 0
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
    local age = (tonumber(sr.anim_t) or 0) - (tonumber(entry.arrived_at) or 0)
    if age < 0 or age >= M.ARRIVE_POP then return 1 end
    local k = 1 - (age / M.ARRIVE_POP)
    -- Cubed so it lands softly rather than arriving at full speed.
    return 1 + 0.6 * k * k * k
end

--- How green a just-arrived avatar still is, 1 at arrival down to 0.
function M.arrival_glow(sr, entry)
    if type(sr) ~= "table" or type(entry) ~= "table" then return 0 end
    local age = (tonumber(sr.anim_t) or 0) - (tonumber(entry.arrived_at) or 0)
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
    local age = (tonumber(sr.anim_t) or 0) - at
    if age < 0 or age >= M.ARRIVE_GLOW then return 0 end
    return 1 - (age / M.ARRIVE_GLOW)
end

--- Centre-stage: how long a new arrival holds the opponent slot.
M.ARRIVE_HOLD = 0.7

--- How long they take to travel from the slot out to their seat on the rail.
M.ARRIVE_FLY = 0.45

--- How long the chosen player takes to fly back into the slot at the end.
M.RETURN_FLY = 0.5

--- The whole entrance, slot to seat.
function M.arrival_span()
    return M.ARRIVE_HOLD + M.ARRIVE_FLY
end

--- Where one player is in their entrance right now.
--
-- Returns a stage and a progress within it:
--
--   "hold", p   p running 0 -> 1 across their moment in the slot
--   "fly",  p   p running 0 (at the slot) -> 1 (at their seat)
--   "rest", 1   seated
--
-- Progress is eased by the caller if it wants easing; this stays linear so the
-- tests can state positions exactly.
function M.arrival_stage(sr, entry)
    if type(sr) ~= "table" or type(entry) ~= "table" then return "rest", 1 end
    local age = (tonumber(sr.anim_t) or 0) - (tonumber(entry.arrived_at) or 0)
    if age < 0 then return "rest", 1 end
    if age < M.ARRIVE_HOLD then
        return "hold", (M.ARRIVE_HOLD > 0) and (age / M.ARRIVE_HOLD) or 1
    end
    local f = age - M.ARRIVE_HOLD
    if f < M.ARRIVE_FLY then
        return "fly", (M.ARRIVE_FLY > 0) and (f / M.ARRIVE_FLY) or 1
    end
    return "rest", 1
end

--- Which player owns the opponent slot right now, if any.
--
-- The most recent arrival still inside its entrance. Nil means the slot is
-- free to go back to hunting, which is the normal state between acceptances —
-- the search does not stop just because somebody turned up.
function M.spotlight(sr)
    if type(sr) ~= "table" then return nil end
    local roster = (type(sr.roster) == "table") and sr.roster or {}
    local best, best_at
    for _, r in ipairs(roster) do
        local stage = M.arrival_stage(sr, r)
        if stage ~= "rest" then
            local at = tonumber(r.arrived_at) or 0
            if best_at == nil or at >= best_at then best, best_at = r, at end
        end
    end
    return best
end

--- The chosen player's flight back into the slot, 0 at the rail to 1 home.
--
-- Stamped the first time a winner is named so the flight is measured from the
-- announcement rather than from whenever the dialog next happened to redraw.
function M.return_progress(sr)
    if type(sr) ~= "table" then return 0 end
    if not sr.chosen_id or tostring(sr.chosen_id) == "" then return 0 end
    local now = tonumber(sr.anim_t) or 0
    if sr.chosen_at == nil then sr.chosen_at = now end
    if M.RETURN_FLY <= 0 then return 1 end
    return math.max(0, math.min(1, (now - sr.chosen_at) / M.RETURN_FLY))
end

--- A slow breathing pulse, 0 to 1 and back, for the matched player.
--
-- Only once they are home. A card that pulses while it is still flying reads
-- as two animations fighting rather than as one arrival.
function M.pulse(sr, period)
    if type(sr) ~= "table" then return 0 end
    if M.return_progress(sr) < 1 then return 0 end
    local p = tonumber(period) or 1.1
    if p <= 0 then return 0 end
    local now = tonumber(sr.anim_t) or 0
    return 0.5 - 0.5 * math.cos((now / p) * 2 * math.pi)
end

--- Has anybody actually accepted?
--
-- The one question the failure path never asked. A search with players on the
-- shortlist has NOT failed for want of an opponent, whatever a timer thinks —
-- the server has somebody and is in the middle of seating them.
function M.has_candidates(sr)
    if type(sr) ~= "table" then return false end
    if sr.chosen_id and tostring(sr.chosen_id) ~= "" then return true end
    return #((type(sr.roster) == "table") and sr.roster or {}) > 0
end

--- How long to keep waiting AFTER the window, once somebody has accepted.
--
-- The window closing is not the end of the work: the server still has to
-- charge the entry, deal a deck, create the game and send it. That takes real
-- time, and the dialog used to give up in the middle of it and announce that
-- nobody had accepted — with the people who HAD accepted still drawn on
-- screen underneath the message.
--
-- Eight seconds is far longer than the deal has ever taken and still short
-- enough that a genuinely stuck match does not hold the screen forever.
M.MATCH_START_GRACE = 8

--- What a search that ran out of time should actually say.
--
-- "No one accepted your invite" is only true when nobody did. Said over a
-- populated shortlist it is not a wording problem, it is the dialog reporting
-- the opposite of what it is showing.
function M.give_up_reason(sr)
    if M.has_candidates(sr) then
        return "Could not start the match"
    end
    return "No one accepted your invite"
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
