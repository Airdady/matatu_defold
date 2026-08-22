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
    approx("opens on the guess", sr.shown, 10)

    second(sr, 1); approx("one second in", sr.shown, 9, 0.05)
    second(sr, 1); approx("two seconds in", sr.shown, 8, 0.05)

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
    local left, window = SC.target({ max_time = 12, grace_time = 2, t = 0 })
    check("a 12s window with a 2s grace shows 10", left, 10)
    check("and its window is 10", window, 10)

    check("elapsed is subtracted", (SC.target({ max_time = 12, grace_time = 2, t = 4 })), 6)
    check("never negative", (SC.target({ max_time = 12, grace_time = 2, t = 99 })), 0)

    -- A grace as long as the window would leave nothing to draw.
    check("a grace cannot eat the whole window",
        (SC.target({ max_time = 5, grace_time = 99, t = 0 })), 1)

    -- Nothing known yet: the longest window the server uses, so the common
    -- correction is downward — which converges smoothly — rather than upward.
    check("with nothing known it guesses the longest window",
        (SC.target({})), SC.FALLBACK_WINDOW - SC.FALLBACK_GRACE)
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
    check("not while the ring still has time", SC.is_choosing({ shown = 2 }), false)
    check("once it empties", SC.is_choosing({ shown = 0 }), true)
    check("never after an opponent was found", SC.is_choosing({ shown = 0, found = true }), false)
    check("never after a failure", SC.is_choosing({ shown = 0, failed = true }), false)
    check("not before the first frame", SC.is_choosing({}), false)
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
