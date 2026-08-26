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

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
