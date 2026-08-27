-- SWIPING THE PLAYER LIST MUST NOT CHALLENGE SOMEBODY.
--
--   Run: lua tools/test_list_gesture.lua
--
-- Reported: scrolling the lobby's list of players sends a game request to
-- whoever was under the thumb.
--
-- The cause was structural, not a missing threshold. online.gui_script
-- dispatched its rows inside `if action_id == hash("touch") and
-- action.pressed`, so a row acted the instant a finger LANDED on it. A drag
-- check existed, but it ran on the NEXT frame's move event — by which time
-- the request had already gone out. There is no threshold that fixes that,
-- because at the moment of the press a tap and a scroll are identical.
--
-- So the press decides nothing and the release decides everything.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path
local G = require("modules.list_gesture")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

local BIG = G.SLOP + 20     -- unambiguously a scroll
local WOBBLE = G.SLOP - 4   -- unambiguously a tap

----------------------------------------------------------------------
print("A PRESS DECIDES NOTHING")
----------------------------------------------------------------------
do
    local g = {}
    check("pressing only starts a gesture", G.press(g, 300), "held")
    check("and the gesture is live", G.active(g), true)
end

----------------------------------------------------------------------
print("A SWIPE IS A SCROLL, AND NEVER A TAP")
----------------------------------------------------------------------
do
    local g = {}
    G.press(g, 300)
    G.move(g, 300 - BIG)
    check("the release is a scroll", G.release(g), "scroll")
    check("and the gesture is finished", G.active(g), false)
end

do
    -- The real report: a long drag that happens to END on a row. Where the
    -- finger comes up is irrelevant once the gesture is a scroll.
    local g = {}
    G.press(g, 300)
    for y = 299, 300 - BIG, -1 do G.move(g, y) end
    for y = 300 - BIG, 300 do G.move(g, y) end   -- and back to where it began
    check("a drag that returns to its start is still a scroll", G.release(g), "scroll")
end

----------------------------------------------------------------------
print("A TAP SURVIVES AN ORDINARY WOBBLE")
----------------------------------------------------------------------
do
    local g = {}
    G.press(g, 300)
    G.move(g, 300 + WOBBLE)
    G.move(g, 300 - WOBBLE + 2)
    check("still a tap", G.release(g), "tap")
end

do
    local g = {}
    G.press(g, 300)
    check("a press with no movement at all is a tap", G.release(g), "tap")
end

----------------------------------------------------------------------
print("THE LIST HOLDS STILL UNTIL THE GESTURE IS A SCROLL")
----------------------------------------------------------------------
-- It used to follow every pixel of jitter, so the list crept under a finger
-- that was only tapping and the row drifted out from under it. That is what
-- makes the release point trustworthy.
do
    local g = {}
    G.press(g, 300)
    check("a sub-slop move scrolls nothing", G.move(g, 300 + WOBBLE), 0)
    check("and neither does the one after it", G.move(g, 300 + WOBBLE - 1), 0)
end

do
    local g = {}
    G.press(g, 300)
    local d = G.move(g, 300 - BIG)
    check("crossing the slop scrolls", d ~= 0, true)
    check("and follows the finger's direction", d < 0, true)
end

do
    -- Once dragging, every subsequent move is a delta from the LAST position,
    -- not from the start — or the list would accelerate away.
    local g = {}
    G.press(g, 300)
    G.move(g, 300 - BIG)
    check("the second drag frame moves by its own step", G.move(g, 300 - BIG - 5), -5)
end

----------------------------------------------------------------------
print("A GESTURE CAN BE ABANDONED")
----------------------------------------------------------------------
-- A dialog opens, a banner arrives, the tab changes: the list is gone from
-- under the finger. The release must not then be read as a tap on whatever
-- now occupies that point.
do
    local g = {}
    G.press(g, 300)
    G.cancel(g)
    check("nothing is live", G.active(g), false)
    check("and the release reports nothing at all", G.release(g), nil)
    check("a move on a cancelled gesture scrolls nothing", G.move(g, 100), 0)
end

do
    local g = {}
    check("a release with no press is nil, not a tap", G.release(g), nil)
end

----------------------------------------------------------------------
print("THE SCREEN ACTUALLY USES IT")
----------------------------------------------------------------------
do
    local src = io.open(ROOT .. "main/online.gui_script"):read("a")
    local code = src:gsub("%-%-[^\n]*", "")

    check("the list no longer dispatches rows on the press",
        code:find("action_id == hash(\"touch\") and action.pressed then", 1, true), nil)
    check("the button loop runs off a resolved tap point",
        code:find("if tap_x then", 1, true) ~= nil, true)
    check("a press inside the list is swallowed",
        code:find("list_gesture.press", 1, true) ~= nil, true)
    check("and a stranded gesture is cancelled, not left live",
        code:find("list_gesture.cancel", 1, true) ~= nil, true)
end

----------------------------------------------------------------------
print("A GESTURE WHOSE TOUCH NEVER ENDED CANNOT EAT THE NEXT PRESS")
----------------------------------------------------------------------
-- THE REPORTED BUG. A release is not guaranteed to arrive: a touch
-- interrupted by a system gesture, a notification shade, a second finger or
-- the app being backgrounded can end without one.
--
-- The drag branch reads "not action.released", and a PRESS is also not a
-- release — so with a gesture left live, the next press anywhere on screen
-- was consumed as a drag and swallowed, and every button on the lobby stopped
-- responding. Nothing usually cleared it: the cancel at the top of on_input
-- only fires when there is no list_region, which is when the list is EMPTY.
-- A quiet lobby healed itself; a busy one stayed stuck.
do
    local g = {}
    G.press(g, 300, 0)
    -- ...and no release ever comes.
    check("it is still live", G.active(g), true)
    check("and after four seconds it is judged expired", G.expired(g, 5), true)
    G.cancel(g)
    check("cancelling frees it", G.active(g), false)
end

do
    local g = {}
    G.press(g, 300, 0)
    check("a live gesture inside its window is NOT expired", G.expired(g, 1), false)
    check("nor is one exactly at the limit", G.expired(g, G.MAX_AGE), false)
end

do
    -- Nothing in flight cannot expire, and a caller with no clock simply never
    -- expires one — which is what happened before the age existed.
    check("an idle gesture is never expired", G.expired({}, 999), false)
    check("nor is one with no clock behind it", G.expired({ last = 1, y0 = 1 }, 999), false)
    check("and junk does not throw", G.expired(nil, 1), false)
end

do
    -- The window is long enough for a real drag and short enough that a player
    -- does not sit wondering why the screen has stopped responding.
    check("the window is measured in seconds, not frames", G.MAX_AGE >= 2, true)
    check("and is not so long that it is no help", G.MAX_AGE <= 10, true)
end

----------------------------------------------------------------------
print("AND THE SCREEN TESTS THE PRESS FIRST")
----------------------------------------------------------------------
do
    local src = io.open(ROOT .. "main/online.gui_script"):read("a")
    local code = src:gsub("%-%-[^\n]*", "")

    -- The ordering IS the fix: a press is the start of something new, so it
    -- is tested before the drag branch can claim it.
    local at_press = code:find("if action.pressed then", 1, true)
    local at_drag  = code:find("elseif list_gesture.active(self._gesture) and not action.released", 1, true)
    check("the press branch comes first", at_press ~= nil and at_drag ~= nil and at_press < at_drag, true)

    -- Out of region: drop the gesture and fall through to the button loop
    -- rather than eating the tap.
    check("an out-of-region press cancels whatever was in flight",
        code:find("if self._gesture then list_gesture.cancel(self._gesture) end", 1, true) ~= nil, true)
    check("and does NOT return true, so the button loop still sees it",
        code:find("list_gesture.cancel(self._gesture) end\n                return true", 1, true), nil)

    -- Belt and braces.
    check("update abandons a gesture that outlived its touch",
        code:find("list_gesture.expired(self._gesture, self.ui_clock)", 1, true) ~= nil, true)
    check("and drops any tap it was about to deliver",
        code:find("self._tap_at = nil", 1, true) ~= nil, true)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
