-- HOW MUCH WORK A HAND REFLOW ACTUALLY DOES.
--
--   Run: lua tools/test_hand_layout.lua
--
-- THE COST THIS MEASURES
--
-- layout_hand runs on every play, every draw and every layout change, over
-- BOTH hands. It already skipped the position tween for a card whose slot had
-- not moved — but the rotation write and the opponent-scale write sat OUTSIDE
-- that skip, so every reflow wrote two properties per card regardless of
-- whether anything had changed. Twenty cards on the board meant thirty
-- redundant transform writes per reflow, and each one dirties the object.
--
-- Reported as a hitch while cards fly to the centre, worst when the OPPONENT
-- is playing — which is exactly when a reflow lands on top of an in-flight
-- animation.
--
-- These count the writes rather than describing them, because "this is
-- cheaper now" is not a claim anybody can check by reading.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

-- ── engine stubs ────────────────────────────────────────────────────────────
local writes = { set = 0, animate = 0, set_position = 0 }
local function reset_counts() writes.set, writes.animate, writes.set_position = 0, 0, 0 end

go = {
    set = function() writes.set = writes.set + 1 end,
    animate = function() writes.animate = writes.animate + 1 end,
    set_position = function() writes.set_position = writes.set_position + 1 end,
    PLAYBACK_ONCE_FORWARD = 1,
    EASING_OUTSINE = 1,
}

vmath = {
    vector3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end,
}

local BL = require("modules.board_layout")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- A board with two hands, laid out like the real one.
local function board(n_player, n_ai)
    local self = {
        CENTER = { x = 640, y = 360 },
        PLAYER_HAND_Y = 120,
        AI_HAND_Y = 600,
        -- What calc_spacing needs; update_layout normally computes it from the
        -- window, which this harness has no business faking.
        MAX_HAND_WIDTH = 900,
        player_hand = {},
        ai_hand = {},
    }
    for i = 1, n_player do self.player_hand[i] = { id = "p" .. i, v = i, s = "H" } end
    for i = 1, n_ai do self.ai_hand[i] = { id = "a" .. i, v = i, s = "S" } end
    return self
end

local function total() return writes.set + writes.animate + writes.set_position end

print("A REFLOW THAT CHANGES NOTHING SHOULD DO NOTHING")
local b = board(10, 10)
BL.position_hands(b, true)
local first = total()
print(string.format("      (first reflow: %d writes across 20 cards)", first))
check("the first reflow does real work", first > 0, true)

reset_counts()
BL.position_hands(b, true)
local second = total()
print(string.format("      (identical second reflow: %d writes)", second))
-- The whole point. Every reflow used to write a rotation for all 20 cards and
-- a scale for the opponent's 10, whatever had changed.
check("an identical reflow writes NOTHING", second, 0)

print("")
print("A REFLOW THAT DOES CHANGE SOMETHING STILL WORKS")
-- Removing a card moves every remaining slot, so every card must be re-tweened.
table.remove(b.player_hand, 3)
reset_counts()
BL.position_hands(b, true)
print(string.format("      (after a card left the hand: %d writes)", total()))
check("cards whose slot moved are animated", writes.animate > 0, true)
-- The opponent's hand did not move, so it must stay silent.
check("the untouched hand stays silent", writes.animate <= #b.player_hand, true)

print("")
print("A CARD COMING BACK TO A HAND IS LAID OUT AFRESH")
-- The caches are what make the skip possible, and a stale one is worse than no
-- cache at all: a card that went to the pile and came back would keep the
-- rotation and the SIZE it had in whichever hand it left, because layout_hand
-- would look at the remembered slot and decide there was nothing to do.
local card = b.player_hand[1]
check("it remembers where it was", card._hand_target ~= nil, true)
BL.forget_hand_slot(card)
check("forget clears the slot", card._hand_target, nil)
check("...and the rotation", card._hand_rot, nil)
check("...and the opponent scale", card._scaled_for_opponent, nil)

reset_counts()
BL.position_hands(b, true)
check("a forgotten card is re-animated", writes.animate >= 1, true)

print("")
print("The opponent hand is sized ONCE, not on every reflow")
local b2 = board(0, 8)
BL.position_hands(b2, true)
local scale_writes_first = writes.set
reset_counts()
BL.position_hands(b2, true)
check("first reflow sizes them", scale_writes_first > 0, true)
check("second reflow does not", writes.set, 0)

print("")
print("A card moved from the opponent hand to the player hand is re-sized")
-- The opponent's cards render smaller. Without clearing the flag, a card that
-- changes hands keeps the small size for ever.
local moved = b2.ai_hand[1]
check("it is marked as opponent-sized", moved._scaled_for_opponent, true)
BL.forget_hand_slot(moved)
check("and forgetting clears that too", moved._scaled_for_opponent, nil)

print("")
print("The tween length is SHARED, not written twice")
-- game_flow's draw waits BL.HAND_TWEEN before reporting itself done. It used
-- to wait a separate 0.30 while this tween ran 0.42, so the draw finished
-- 0.12s early and the SKIP prompt appeared over a card still in flight.
check("exported", type(BL.HAND_TWEEN), "number")
check("and it is the real flight time", BL.HAND_TWEEN, 0.42)

local gf = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../modules/game_flow.lua"):read("a")
check("the draw derives its settle from it, not from a second number",
    gf:find("BL.HAND_TWEEN", 1, true) ~= nil, true)
check("and no stale 0.30 settle is left behind",
    gf:find("local SETTLE      = 0.30", 1, true), nil)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
