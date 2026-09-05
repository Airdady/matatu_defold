----------------------------------------------------------------------
-- party_rules.lua
-- WHAT A CARD DOES TO THE TURN ORDER AT A TABLE OF MORE THAN TWO.
--
-- The offline chamber has played three- and four-handed matatu since it
-- shipped, and tournament4.apply_skip is the rule:
--
--     if v == 11 and survivors > 2 -> direction = -direction, "REVERSE!"
--     else                         -> step one extra seat
--
-- So a JACK REVERSES with three or more still in, and only means "skip the
-- next player" heads-up, where reversing would be invisible — the player
-- behind you and the player in front of you are the same person. An EIGHT
-- always skips. And in BOTH cases the seat that played it is DONE: game_flow's
-- SKIP_TURN branch hands straight to apply_skip and returns, without reopening
-- the hand.
--
-- The ONLINE party did none of that. It ran the two-player path — a skip kept
-- the turn and the player was asked to play again — while the server passed
-- the turn on, so the same card behaved one way against bots and another
-- against people.
--
-- This is the client half of be_matatu's common/services/turnEffects.ts, and
-- deliberately the same shape: the two ends have to agree about a rule a
-- player watches happen, and two descriptions that merely sound alike are how
-- they stop agreeing. The SERVER is authoritative — it says whose turn it is
-- and carries the direction on the state — so nothing here decides anything;
-- it decides what this CLIENT does with its own turn, and what to say.
--
-- Pure: no Defold, no requires. tools/test_party_rules.lua runs it under
-- stock Lua.
----------------------------------------------------------------------
local M = {}

--- Jack. Turns the table round at three or more.
M.REVERSE_CARD = 11
--- Eight. Costs the next player their turn, at any size.
M.SKIP_CARD = 8

--- What the card just played does.
--
-- `live` is how many players are STILL IN, not how many chairs the table
-- started with: a four-seat party down to two plays the heads-up rule, exactly
-- as the chamber does when it collapses to a final.
--
-- Returns { steps, reverse, flash } — the same three answers turnEffects.ts
-- returns, so a disagreement between the two is a diff rather than a hunt.
function M.effect(card_value, live)
    local v = tonumber(card_value)
    local n = math.max(0, math.floor(tonumber(live) or 0))

    if v == M.REVERSE_CARD then
        if n > 2 then return { steps = 1, reverse = true, flash = "REVERSE!" } end
        return { steps = 2, reverse = false, flash = "SKIP!" }
    end
    if v == M.SKIP_CARD then return { steps = 2, reverse = false, flash = "SKIP!" } end
    return { steps = 1, reverse = false, flash = nil }
end

--- Does playing this card leave the turn with the player who played it?
--
-- THE ONE QUESTION THE ONLINE PARTY WAS ANSWERING WRONG. Heads-up, yes: "the
-- next player loses their turn" means you play again, which is why the client
-- bundles the follow-on card into the same move and why the server refuses a
-- move that ENDS on a skip. At three or more, no — the turn passes, skipped or
-- reversed, and the hand must not be reopened.
--
-- `live` nil or under two is an ordinary two-player game (or a state that has
-- not arrived yet), and answers true: the shipping duel behaviour, unchanged.
function M.keeps_turn(card_value, live)
    local n = tonumber(live)
    if not n or n <= 2 then return true end
    local v = tonumber(card_value)
    return not (v == M.SKIP_CARD or v == M.REVERSE_CARD)
end

--- How many of a state's seats are still in the hand.
--
-- Reads the same two things the server's isSeatOut does — the eliminated flag
-- and nothing else — because the running score is the server's business and a
-- client second-guessing it would disagree at exactly the wrong moment.
function M.live_count(game_state)
    local st = type(game_state) == "table" and game_state or {}
    local order = type(st.seatOrder) == "table" and st.seatOrder or {}
    if #order == 0 then return nil end   -- not a party at all
    local players = type(st.players) == "table" and st.players or {}
    local n = 0
    for _, id in ipairs(order) do
        local p = players[tostring(id)]
        if p and not p.eliminated then n = n + 1 end
    end
    return n
end

return M
