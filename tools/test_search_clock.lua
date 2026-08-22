-- THE COUNTDOWN THAT KEPT JUMPING.
--
--   Run: lua tools/test_search_clock.lua
--
-- Reported three times, with three different numbers:
--
--   12, 11, 10 then 4   the server's message arrived late AND carried what was
--                       left of the window; the ring then subtracted its own
--                       elapsed time from that remainder a second time
--   12, 11, 10 then 6   the elapsed time was reset on arrival, so the double
--                       subtraction was gone — and it still snapped, because
--                       the guess (12, no grace) and the truth (12 minus a 2s
--                       grace, or 8 from an older server) are different numbers
--
-- CORRECTING A GUESS IS A JUMP. That is not a bug in any one number; it is what
-- happens whenever a displayed value is replaced by a better one. The dialog
-- cannot know the window until the server says so, so the only fix that
-- survives every server version and every network delay is to stop replacing
-- the number and converge to it instead.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end
local function approx(label, got, want, tol)
    checks = checks + 1
    local ok = math.abs(got - want) <= (tol or 0.001)
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %.2f, want %.2f)",
        ok and "PASS" or "FAIL", label, got, want))
end

for name in pairs(package.loaded) do
    if name:match("^modules%.") then package.loaded[name] = nil end
end
package.path = ROOT .. "?.lua;" .. package.path
local SC = require("modules.search_clock")

-- Run a whole second, the way the host does: many small frames.
local function second(sr, n)
    for _ = 1, (n or 1) * 60 do SC.tick(sr, 1 / 60) end
    return sr.shown
end

print("\n== the ring never jumps, whatever the server says ==")
do
    -- THE EXACT REPORTED SEQUENCE. Guess of 12 with a 2s grace shows 10, the
    -- player watches 10, 9, 8, and then an OLD server's message lands at t=2
    -- carrying the 8 seconds it has left.
    local sr = {}
    SC.tick(sr, 0)
    approx("opens on the guess", sr.shown, 12)

    second(sr, 1); approx("one second in", sr.shown, 11, 0.05)
    second(sr, 1); approx("two seconds in", sr.shown, 10, 0.05)

    local before = sr.shown
    SC.adopt(sr, 8000, 2000, 5)   -- an old server: 8s left, 2s of it grace
    SC.tick(sr, 0)
    check("adopting does not move the number at all", sr.shown, before)

    -- The truth is 6 and the screen says 8. It closes the gap by falling
    -- faster, and it lands exactly on the target rather than overshooting.
    local seen = {}
    for _ = 1, 90 do seen[#seen + 1] = SC.tick(sr, 1 / 60) end
    local jumped = false
    for i = 2, #seen do
        if seen[i] > seen[i - 1] + 0.0001 then jumped = true end
        if seen[i - 1] - seen[i] > (1 / 60) * SC.CATCHUP_RATE + 0.0001 then jumped = true end
    end
    check("no frame moves up, and none falls faster than the catch-up rate", jumped, false)
end

print("\n== a longer window does not rewind it ==")
do
    -- The opposite correction: the guess was pessimistic. The ring must NOT
    -- jump up — a countdown that goes backwards is worse than one that is a
    -- little pessimistic.
    local sr = { max_time = 6, grace_time = 0 }
    SC.tick(sr, 0)
    approx("starts at the short window", sr.shown, 6)
    second(sr, 2); approx("counts down", sr.shown, 4, 0.05)

    SC.adopt(sr, 12000, 2000)
    local after = SC.tick(sr, 1 / 60)
    check("still below where it was", after < 4.01, true)
    second(sr, 1)
    check("and keeps descending", sr.shown < after, true)
end

print("\n== it lands on zero, and stays there ==")
do
    local sr = { max_time = 3, grace_time = 0 }
    SC.tick(sr, 0)
    second(sr, 5)
    check("bottoms out at zero", sr.shown, 0)
    second(sr, 2)
    check("and does not go negative", sr.shown, 0)
end

print("\n== the target the server's numbers imply ==")
do
    -- The visible ring runs to the START of the grace: once it empties the
    -- dialog is choosing, not waiting for more answers.
    -- THE RING RUNS THE WHOLE WINDOW, assessment included. It used to stop at
    -- the start of the grace, so the last seconds were an empty ring beside
    -- the word "assessing" — and a clock that has stopped reads as a clock
    -- that has failed, at exactly the moment the match is being decided.
    local left, window, grace = SC.target({ max_time = 12, grace_time = 2, t = 0 })
    check("a 12s window counts twelve", left, 12)
    check("and its window is the whole twelve", window, 12)
    check("the grace comes back as the phase boundary", grace, 2)

    check("elapsed is subtracted", (SC.target({ max_time = 12, grace_time = 2, t = 4 })), 8)
    check("never negative", (SC.target({ max_time = 12, grace_time = 2, t = 99 })), 0)

    -- A grace longer than the window would make every second an assessment.
    local _, _, clamped = SC.target({ max_time = 5, grace_time = 99, t = 0 })
    check("a grace cannot eat the whole window", clamped, 4)
    check("and the ring still runs the full window",
        (SC.target({ max_time = 5, grace_time = 99, t = 0 })), 5)

    -- Nothing known yet: the longest window the server uses, so the common
    -- correction is downward — which converges smoothly — rather than upward.
    check("with nothing known it guesses the longest window",
        (SC.target({})), SC.FALLBACK_WINDOW)
end

print("\n== adopting a duration means 'from now' ==")
do
    local sr = { t = 7 }
    check("accepted", SC.adopt(sr, 8000, 2000, 4), true)
    check("the elapsed clock restarts", sr.t, 0)
    check("the window is in seconds", sr.max_time, 8)
    check("so is the grace", sr.grace_time, 2)
    check("and the invited count is carried", sr.invited, 4)

    -- Nonsense must not blank the dialog.
    check("zero is refused", SC.adopt({ }, 0, 0), false)
    check("nil is refused", SC.adopt({ }, nil, nil), false)
    check("a non-table does not throw", SC.adopt(nil, 8000, 2000), false)
end

print("\n== choosing is read off the number on screen ==")
do
    -- Not off the real elapsed time: "choosing" appearing while a number is
    -- still ticking is the same class of glitch as the jump.
    -- Assessing is the LAST `grace` seconds, and the number keeps moving
    -- through them: a phase of the countdown, not a state after it.
    check("not while there is more than the grace left",
        SC.is_choosing({ shown = 5, max_time = 12, grace_time = 2 }), false)
    check("yes once inside the grace, with time still on the clock",
        SC.is_choosing({ shown = 2, max_time = 12, grace_time = 2 }), true)
    check("and still at zero", SC.is_choosing({ shown = 0, max_time = 12, grace_time = 2 }), true)
    check("never after an opponent was found", SC.is_choosing({ shown = 0, found = true }), false)
    check("never after a failure", SC.is_choosing({ shown = 0, failed = true }), false)
    check("not before the first frame", SC.is_choosing({}), false)
end

print("\n== arrivals get a moment of their own ==")
do
    local sr = { anim_t = 0 }
    local one = { { userId = "a", username = "Ada", avatar = 2 } }
    check("the first player is new", SC.note_arrivals(sr, one), 1)
    check("and is on the roster", #sr.roster, 1)
    check("stamped with when they arrived", sr.roster[1].arrived_at, 0)
    check("which also lights the flash", sr.flash_at, 0)

    -- THE SERVER RE-SENDS THE WHOLE ROSTER EVERY PUSH. A handler that counted
    -- the list rather than the difference would re-announce everybody who was
    -- already there, once per push.
    sr.anim_t = 4
    check("the same player again is not new", SC.note_arrivals(sr, one), 0)
    check("and keeps their original arrival time", sr.roster[1].arrived_at, 0)

    local two = { one[1], { userId = "b", username = "Bo", avatar = 3 } }
    check("only the second one counts as new", SC.note_arrivals(sr, two), 1)
    check("stamped at the moment they landed", sr.roster[2].arrived_at, 4)
    check("and the flash relights", sr.flash_at, 4)
end

print("\n== the pop and the glow fade on their own ==")
do
    local sr = { anim_t = 0, roster = {} }
    SC.note_arrivals(sr, { { userId = "a" } })
    local e = sr.roster[1]

    check("arrives oversized", SC.arrival_scale(sr, e) > 1.5, true)
    check("and fully green", SC.arrival_glow(sr, e), 1)

    sr.anim_t = SC.ARRIVE_POP / 2
    local mid = SC.arrival_scale(sr, e)
    check("shrinking", mid < 1.6 and mid > 1.0, true)

    sr.anim_t = SC.ARRIVE_POP
    check("settles to normal size exactly at the end", SC.arrival_scale(sr, e), 1)
    sr.anim_t = 99
    check("and stays there", SC.arrival_scale(sr, e), 1)
    check("with no green left", SC.arrival_glow(sr, e), 0)
    check("and no flash", SC.flash(sr), 0)

    -- One light for the dialog, not one per player: two people accepting half
    -- a second apart should read as the search working, not as two alarms.
    sr.anim_t = 10
    SC.note_arrivals(sr, { { userId = "a" }, { userId = "b" }, { userId = "c" } })
    check("a burst of arrivals is one flash", SC.flash(sr), 1)

    check("nothing throws on rubbish",
        SC.arrival_scale(nil, nil) == 1 and SC.arrival_glow(nil, nil) == 0 and SC.flash(nil) == 0, true)
end

print("\n== the ring never refills ==")
do
    -- THE ONE THAT SURVIVED EVERY FIX TO THE NUMBER, because the ring is not
    -- the number: it is the number divided by the window. The window is
    -- corrected the moment the server speaks, and dividing by a SMALLER
    -- denominator makes the SAME remaining time a BIGGER fraction:
    --
    --   just before   shown 8, window 12  ->  0.67 of the ring
    --   just after    shown 8, window  8  ->  1.00, full again
    --
    -- which is exactly "at 8 it starts afresh". The number was continuous the
    -- whole time; the arc jumped behind it.
    local sr = {}
    SC.tick(sr, 0)
    approx("starts full", SC.arc(sr), 1)

    second(sr, 4)
    local before = SC.arc(sr)
    approx("two thirds through a twelve-second window", before, 8 / 12, 0.05)

    -- The correction that used to refill it.
    SC.adopt(sr, 8000, 2000)
    SC.tick(sr, 0)
    local after = SC.arc(sr)
    check("the arc does not jump back up", after <= before + 0.001, true)
    approx("it stays where it was", after, before, 0.02)

    -- And it keeps falling, monotonically, all the way to empty.
    local prev, rose = after, false
    for _ = 1, 60 * 12 do
        SC.tick(sr, 1 / 60)
        local a = SC.arc(sr)
        if a > prev + 0.0001 then rose = true end
        prev = a
    end
    check("never rises across the whole window", rose, false)
    approx("and lands empty", prev, 0, 0.001)

    check("a non-table does not throw", SC.arc(nil), 0)
end

print("\n== the ring never jumps and never stutters ==")
do
    -- THE ONE THE PREVIOUS TWO FIXES BOTH MISSED, and it only bites when the
    -- guess and the truth genuinely DISAGREE. Four seconds into a twelve-second
    -- guess there are eight left, and a server saying "eight" agrees exactly —
    -- which is why a broken implementation can still look fine there. Two
    -- seconds in, the ring is showing ten and the truth is eight, and that gap
    -- has to go somewhere: into the position (a jump), into the speed (a burst
    -- then a brake), or into the rate, once (nothing to see).
    local DT = 1 / 60
    local function sweep(sr, secs, out)
        local prev = SC.arc(sr)
        for _ = 1, math.floor(secs / DT) do
            SC.tick(sr, DT)
            local v = SC.arc(sr)
            out[#out + 1] = prev - v
            prev = v
        end
        return prev
    end
    local function spread(list)
        local lo, hi = math.huge, -math.huge
        for _, v in ipairs(list) do lo = math.min(lo, v); hi = math.max(hi, v) end
        return hi - lo, hi
    end

    local sr, d = {}, {}
    SC.tick(sr, 0)
    local before = sweep(sr, 2, d)
    approx("two seconds into the guessed window", before, 10 / 12, 0.01)

    -- The correction the player actually sees: a battle's eight-second window
    -- landing while the ring is still drawn against a twelve-second guess.
    SC.adopt(sr, 8000, 2000)
    approx("the ring does not move when it lands", SC.arc(sr), before, 0.0005)

    local d_after = {}
    local last = sweep(sr, 8, d_after)
    approx("and still empties exactly at the settle", last, 0, 0.01)

    local sp1, r1 = spread(d)
    local sp2, r2 = spread(d_after)
    approx("one steady rate before the correction", sp1, 0, 0.0002)
    approx("one steady rate after it", sp2, 0, 0.0002)

    -- Absorbed as a small permanent change of rate. A quarter faster is
    -- invisible; the 3x burst the smoothed number produced was not.
    approx("a quarter faster for the rest of the way", r2 / r1, 1.25, 0.02)
    check("nowhere near the 3x burst that read as junk", r2 / r1 < 1.5, true)

    check("the digits are still free to converge quickly",
        sr.shown <= SC.target(sr) + 0.001, true)
end

print("\n== a correction that agrees costs nothing at all ==")
do
    -- Four seconds into the twelve-second guess with an eight-second window:
    -- both say eight left, so there is no gap and the rate does not budge.
    local DT = 1 / 60
    local sr = {}
    SC.tick(sr, 0)
    local prev, r1 = SC.arc(sr), nil
    for _ = 1, 60 * 4 do
        SC.tick(sr, DT)
        local v = SC.arc(sr); r1 = prev - v; prev = v
    end
    SC.adopt(sr, 8000, 2000)
    approx("the ring does not move", SC.arc(sr), prev, 0.0005)
    SC.tick(sr, DT)
    approx("and neither does its speed", (prev - SC.arc(sr)) / r1, 1, 0.01)
end

print("\n== an entrance survives the window being corrected ==")
do
    -- adopt() rewinds the countdown clock to zero, because the server states a
    -- DURATION and "eight seconds" means eight from now. Anything stamped
    -- against that clock is dated in the FUTURE the instant it happens, so an
    -- arrival mid-entrance would replay it or freeze halfway through. The
    -- animation clock never rewinds, which is the whole reason it exists.
    local sr = {}
    SC.tick(sr, 4)
    SC.note_arrivals(sr, { { userId = "a" } })
    local e = sr.roster[1]
    check("stamped on the animation clock", e.arrived_at, 4)

    SC.tick(sr, 0.2)
    check("mid-entrance", SC.arrival_stage(sr, e), "hold")

    SC.adopt(sr, 8000, 2000)
    check("the countdown clock restarted", sr.t, 0)
    check("the animation clock did not", sr.anim_t > 4, true)

    SC.tick(sr, 0.2)
    local s2, p2 = SC.arrival_stage(sr, e)
    check("the entrance carries straight on", s2, "hold")
    check("and has not rewound", p2 > 0.5, true)
end

print("\n== the acceptance story plays in three beats ==")
do
    local sr = { anim_t = 0, roster = {} }
    SC.note_arrivals(sr, { { userId = "a", username = "Ada" } })
    local a = sr.roster[1]

    local st, p = SC.arrival_stage(sr, a)
    check("they take the slot first", st, "hold")
    approx("at the very start of it", p, 0)
    check("and the slot is theirs", (SC.spotlight(sr) or {}).userId, "a")

    sr.anim_t = SC.ARRIVE_HOLD + SC.ARRIVE_FLY / 2
    st, p = SC.arrival_stage(sr, a)
    check("then they travel out to the rail", st, "fly")
    approx("halfway there", p, 0.5)
    check("still holding the slot while in flight", (SC.spotlight(sr) or {}).userId, "a")

    sr.anim_t = SC.arrival_span() + 0.01
    check("and take their seat", SC.arrival_stage(sr, a), "rest")
    check("freeing the slot to keep hunting", SC.spotlight(sr), nil)

    -- Two people accepting close together: the newer one takes the slot and
    -- the older goes to its seat. Overlapping entrances read as a glitch.
    sr.anim_t = 10
    SC.note_arrivals(sr, { { userId = "a" }, { userId = "b" } })
    check("the newest arrival owns the slot", (SC.spotlight(sr) or {}).userId, "b")

    check("nothing throws on rubbish",
        SC.spotlight(nil) == nil and SC.arrival_stage(nil, nil) == "rest", true)
end

print("\n== the chosen player comes home ==")
do
    local sr = { anim_t = 0, roster = {} }
    SC.note_arrivals(sr, { { userId = "a" }, { userId = "b" } })
    sr.anim_t = 20

    approx("nobody is coming home before a winner is named", SC.return_progress(sr), 0)
    check("and nothing is pulsing", SC.pulse(sr), 0)

    sr.chosen_id = "b"
    approx("the flight starts where they were kept", SC.return_progress(sr), 0)
    check("timed from the announcement, not the next redraw", sr.chosen_at, 20)

    sr.anim_t = 20 + SC.RETURN_FLY / 2
    approx("halfway home", SC.return_progress(sr), 0.5)
    check("not pulsing while still in flight", SC.pulse(sr), 0)

    sr.anim_t = 20 + SC.RETURN_FLY
    approx("home", SC.return_progress(sr), 1)
    sr.anim_t = 200
    approx("and stays home", SC.return_progress(sr), 1)

    local lo, hi = 2, -1
    for i = 0, 200 do
        sr.anim_t = 100 + i * 0.01
        local v = SC.pulse(sr)
        lo = math.min(lo, v); hi = math.max(hi, v)
    end
    check("the pulse breathes across the full range", lo < 0.05 and hi > 0.95, true)
    check("nothing throws on rubbish", SC.return_progress(nil) == 0 and SC.pulse(nil) == 0, true)
end

print("\n== a search with a shortlist has not failed ==")
do
    -- THE BUG THAT SURVIVED THREE FIXES TO THE COUNTDOWN, because it was never
    -- in the countdown. The window closing is not the end of the work: the
    -- server still has to charge the entry, deal a deck and create the game.
    -- The backstop fired in the middle of that and announced that nobody had
    -- accepted — with the people who HAD accepted still drawn on screen
    -- underneath the words.
    check("nobody yet", SC.has_candidates({ roster = {} }), false)
    check("no roster at all", SC.has_candidates({}), false)
    check("somebody accepted", SC.has_candidates({ roster = { { userId = "a" } } }), true)
    check("or one was already chosen", SC.has_candidates({ chosen_id = "a" }), true)
    check("an empty chosen id is not a choice", SC.has_candidates({ chosen_id = "" }), false)
    check("rubbish does not throw", SC.has_candidates(nil), false)

    -- And what it says when it does eventually give up has to be true.
    check("nobody came reads as nobody came",
        SC.give_up_reason({ roster = {} }), "No one accepted your invite")
    check("but never over a populated shortlist",
        SC.give_up_reason({ roster = { { userId = "a" } } }), "Could not start the match")

    check("the extra wait is longer than any deal has taken",
        SC.MATCH_START_GRACE >= 5, true)
end

print("\n== the backstop is measured from now ==")
do
    -- Never minus an elapsed time: that is what made the dialog give up at
    -- eleven seconds while the server settled at twelve, so it closed and THEN
    -- the game opened.
    check("full window plus the caller's grace",
        SC.failsafe_delay({ max_time = 12 }, 3), 15)
    check("uses the fallback when nothing is known",
        SC.failsafe_delay({}, 3), SC.FALLBACK_WINDOW + 3)
    check("a broken window does not shorten it",
        SC.failsafe_delay({ max_time = 0 }, 3), SC.FALLBACK_WINDOW + 3)
end

print("\n== nothing here throws on rubbish ==")
do
    check("tick on a non-table", SC.tick(nil, 1), 0)
    check("tick with no dt", type(SC.tick({}, nil)), "number")
    check("target of nothing", type((SC.target(nil))), "number")
end

print("")
if failures == 0 then
    print(string.format("ALL %d CHECKS PASSED", checks))
else
    print(string.format("%d of %d CHECKS FAILED", failures, checks))
    os.exit(1)
end
