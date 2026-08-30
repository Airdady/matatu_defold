-- A DRAW THAT ALREADY LANDED MUST NOT BE SENT AGAIN.
--
--   Run: lua tools/test_draw_resend_evidence.lua
--
-- Reported: the deck empties into one hand, no penalty involved, mostly at the
-- START of a game — and, decisively, "under a stable connection everything
-- works fine". That last part is the clue this file is about.
--
-- WHY A GLITCH, SPECIFICALLY.
--
-- Every move is held until the server's own state can settle whether it
-- arrived (resend_pending_move_if_lost). For a move with PLAY cards the test
-- is real evidence: if the cards we played are still in the server's copy of
-- our hand, it never landed.
--
-- A DRAW names no card of ours, so it has no fingerprint of that kind, and the
-- judgement fell through to this:
--
--     if #held.plays == 0 or still == #held.plays then   -- RESEND
--
-- `#held.plays == 0` — a draw-only move was resent UNCONDITIONALLY, on nothing
-- but "it is still our turn". That is not weak evidence, it is no evidence at
-- all, because a draw that LANDS and leaves something playable KEEPS the turn:
-- game_flow's check_post_draw only ends the turn when nothing in hand can be
-- played. So "still my turn" is exactly as true of a draw that arrived as of
-- one that vanished.
--
-- On a stable connection nothing is ever held long enough to be adjudicated
-- and the path never runs. On a flaky one every reconnect resent the draw and
-- the server dealt another card — which is the deck draining, and why it
-- tracks connection quality rather than anything about the cards.
--
-- Worst at the start of a game for the same reason the sibling bug is: a full
-- seven-card hand nearly always leaves something playable, so the turn stays
-- open and the move stays eligible for resending.
--
-- THE FINGERPRINT A DRAW DOES LEAVE is that our hand GREW. hand_after records
-- the size the server's copy should be once the move lands, and the judgement
-- now reads it.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

local function read(p)
    local f = assert(io.open(ROOT .. p)); local s = f:read("*a"); f:close(); return s
end

----------------------------------------------------------------------
-- The judgement, transcribed from resend_pending_move_if_lost.
----------------------------------------------------------------------
local function should_resend(held, server_hand)
    local in_hand = function(pc)
        for _, hc in ipairs(server_hand) do
            if hc.v == pc.v and hc.s == pc.s then return true end
        end
        return false
    end
    if #held.plays > 0 then
        local still = 0
        for _, pc in ipairs(held.plays) do
            if in_hand(pc) then still = still + 1 end
        end
        return still == #held.plays
    elseif (held.draws or 0) > 0 then
        return (held.hand_after ~= nil) and (#server_hand < held.hand_after)
    end
    return false
end

local function hand_of(n)
    local h = {}
    for i = 1, n do h[i] = { v = i + 1, s = "H" } end
    return h
end

----------------------------------------------------------------------
print("-- a draw-only move, still our turn (a landed draw keeps the turn) --")

-- Held 7 cards, drew one, so the server should show 8 if it landed.
local drew = { plays = {}, draws = 1, hand_after = 8 }

check("it LANDED: server already shows 8 -> do not resend",
    should_resend(drew, hand_of(8)), false)
check("it was LOST: server still shows 7 -> resend",
    should_resend(drew, hand_of(7)), true)

print("\n-- the repeat that drained the deck --")
-- Four reconnects on a flaky connection, the draw having landed the first time.
local sent = 0
for _ = 1, 4 do
    if should_resend(drew, hand_of(8)) then sent = sent + 1 end
end
check("four reconnects resend it zero times", sent, 0)

print("\n-- with no figure to compare, refuse rather than risk it --")
-- The two mistakes are not equal: a duplicated draw takes a card off the deck
-- every time, a lost one costs the player a tap.
local nofigure = { plays = {}, draws = 1, hand_after = nil }
check("an unjudgeable draw is not resent", should_resend(nofigure, hand_of(7)), false)

print("\n-- and the PLAY half is untouched --")
local K = { v = 13, s = "S" }
local played = { plays = { K }, draws = 0, hand_after = 6 }
check("card still in the server's hand -> never landed -> resend",
    should_resend(played, { K, { v = 4, s = "D" } }), true)
check("card gone from the server's hand -> landed -> drop",
    should_resend(played, { { v = 4, s = "D" } }), false)

print("\n-- a move with both plays and draws is judged on the plays --")
-- The plays are a true fingerprint; they decide, exactly as before.
local both = { plays = { K }, draws = 1, hand_after = 7 }
check("play still held -> resend", should_resend(both, { K }), true)
check("play gone -> drop", should_resend(both, { { v = 4, s = "D" } }), false)

----------------------------------------------------------------------
print("\n-- the model matches the code it stands in for --")

local ws = read("modules/websocket_manager.lua")
local oh = read("modules/online_handler.lua")

check("the unconditional draw-only resend is gone",
    ws:find("#held%.plays == 0 or still == #held%.plays") == nil, true)
check("a draw-only move is judged on hand size",
    ws:find("server_n < held%.hand_after") ~= nil, true)
check("send_move records how many draws the move carried",
    ws:find("draws = %(function%(%)") ~= nil, true)
check("and the hand size the move should produce",
    ws:find("hand_after = tonumber%(hand_after%)") ~= nil, true)
check("end_turn supplies it",
    oh:find("self%.chosen_suit, self%.active_penalty, #self%.player_hand") ~= nil, true)
check("the plays fingerprint is still what decides a move that has one",
    ws:find("resend = %(still == #held%.plays%)") ~= nil, true)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
