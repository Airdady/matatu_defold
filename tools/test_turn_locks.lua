-- TWO TAPS, TWO CARDS.
--
--   Run: lua5.4 tools/test_turn_locks.lua
--
-- Reported: "I played a skipping card and tried picking again, and I
-- accidentally tapped twice randomly very fast — I ended up getting two cards
-- in hand instead of one."
--
-- Playing a Skip / Hold On / General Market keeps the turn, and the client
-- re-opened input for it TWICE: once synchronously in play_card at tap time,
-- and again ~0.42s later in after_play_settled when the played card finishes
-- flying to the pile. The second one was unconditional, so it wiped the guards
-- of a draw that had started in between — and the next tap took another card.
--
-- The sequence, which is what the timeline test below walks:
--
--   t+0.00  skip played       has_drawn=false locked=false   (play_card)
--   t+0.10  deck tapped       has_drawn=true  locked=true    card in flight
--   t+0.42  played card lands has_drawn=FALSE locked=FALSE   <-- the bug
--   t+0.45  deck tapped again every guard reads false        <-- second card
--
-- These drive the real modules/turn_locks.lua, because the whole failure was
-- two pieces of code disagreeing about who was allowed to touch the deck.
package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local TL = require("modules.turn_locks")

local failures = 0
local function check(label, got, want)
    if got == want then return end
    failures = failures + 1
    print(("FAIL  %s: got %s want %s"):format(label, tostring(got), tostring(want)))
end

-- A turn that is otherwise entirely free to act.
local function open(over)
    local s = { my_turn = true, waiting = false, locked = false,
                suit_selecting = false, has_drawn = false, animating = false }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

----------------------------------------------------------------------
-- may_touch_deck: the shared gate in front of every deck tap
----------------------------------------------------------------------
check("an open turn may touch the deck", TL.may_touch_deck(open()), true)
check("not on somebody else's turn", TL.may_touch_deck(open{ my_turn = false }), false)
check("not while waiting on the server", TL.may_touch_deck(open{ waiting = true }), false)
check("not while a local action is committed", TL.may_touch_deck(open{ locked = true }), false)
check("not with the suit picker open", TL.may_touch_deck(open{ suit_selecting = true }), false)

-- THE NEW RULE. Every other flag above can be cleared out from under a draw
-- that is genuinely still in the air; a card physically flying into the hand
-- cannot.
check("NOT while a card is already flying into the hand",
      TL.may_touch_deck(open{ animating = true }), false)
check("...even with every other flag reading clear — which is the bug exactly",
      TL.may_touch_deck({ my_turn = true, waiting = false, locked = false,
                          suit_selecting = false, has_drawn = false, animating = true }), false)

-- has_drawn is deliberately NOT part of this gate: the branches behind it
-- (an owed General Market, an ordinary draw, a penalty draw) answer it
-- differently and each says so itself.
check("having drawn does not close this gate on its own",
      TL.may_touch_deck(open{ has_drawn = true }), true)

check("a missing state table refuses rather than throws", TL.may_touch_deck(nil), false)

----------------------------------------------------------------------
-- may_reopen_kept_turn: the late callback, and what it must not undo
----------------------------------------------------------------------
check("a turn nobody has used yet may be re-opened",
      TL.may_reopen_kept_turn({ has_drawn = false, animating = false }), true)
-- HAVING DRAWN IS NOT A REASON TO REFUSE, and treating it as one broke the
-- most ordinary turn there is: draw a card, it happens to be an 8, play it.
-- The skip keeps the turn, so this gate has to re-arm the player — and
-- has_drawn is true at that moment for the perfectly good reason that they
-- just drew. Refused, the deck stayed locked, the player could not take the
-- card the skip entitles them to, and the action list flushed as
-- [DRAW 8H, PLAY 8H] — a skip with nothing after it, which the server refuses
-- outright and answers with a full RESYNC.
check("a player who just drew an 8 and played it gets their turn back",
      TL.may_reopen_kept_turn({ has_drawn = true, animating = false }), true)
check("NOT while their card is still in flight",
      TL.may_reopen_kept_turn({ has_drawn = false, animating = true }), false)
check("in flight still refuses, drawn or not",
      TL.may_reopen_kept_turn({ has_drawn = true, animating = true }), false)
check("a missing state table refuses rather than throws",
      TL.may_reopen_kept_turn(nil), true) -- nothing known to undo

----------------------------------------------------------------------
-- the reported sequence, walked in order
----------------------------------------------------------------------
-- A board carrying just the flags these rules read. Each step below is what
-- the real code does at that moment; the checks are what a tap would be told.
local board = {
    is_player_turn = function() return true end,
    waiting = false, is_local_action_locked = false,
    is_suit_selection_active = false, player_has_drawn = false, is_animating = false,
}

-- t+0.00 — the skip card is played. play_card re-opens input synchronously so
-- a legitimate rapid second tap is not rejected mid-flight. Correct, and it
-- stays unconditional.
board.player_has_drawn, board.is_local_action_locked = false, false
check("t+0.00 the deck is tappable after the skip", TL.board_may_touch_deck(board), true)

-- t+0.10 — first tap. The draw commits both flags and a card takes to the air.
board.player_has_drawn, board.is_local_action_locked, board.is_animating = true, true, true
check("t+0.10 a second tap in the same breath is refused",
      TL.board_may_touch_deck(board), false)

-- t+0.42 — the PLAYED card lands and after_play_settled tries to re-open the
-- turn. This is the call that used to wipe the draw's guards.
check("t+0.42 the late re-open is refused while the draw is live",
      TL.board_may_reopen_kept_turn(board), false)

-- t+0.45 — the second tap. Before the fix the flags had been wiped and it took
-- a card; the guards are still standing, so it does not.
check("t+0.45 the second tap still finds the deck closed",
      TL.board_may_touch_deck(board), false)

-- ...and once the draw actually lands, the turn behaves normally again.
-- check_post_draw re-opens input when the drawn card left something playable,
-- and a CARD is playable again.
board.is_animating = false
board.is_local_action_locked = false
check("the draw is still recorded on the board", board.player_has_drawn, true)

-- THE TURN THAT WAS BEING REFUSED. The drawn card was a skip, it has been
-- played, and the player is owed the rest of their turn. Nothing is in flight,
-- so nothing may stand in the way — least of all the record that they drew.
check("and the skip they just played re-opens the turn",
      TL.board_may_reopen_kept_turn(board), true)

-- Staleness is ORDERING, not draw state: after_play_settled drops a
-- superseded callback on its play ticket before this gate is ever consulted.
-- A card genuinely in the air is the one thing left for this to refuse.
board.is_animating = true
check("a card still in the air is the one thing that holds it",
      TL.board_may_reopen_kept_turn(board), false)
board.is_animating = false

----------------------------------------------------------------------
-- what must NOT change: a legitimate rapid chain
----------------------------------------------------------------------
-- Chaining skip cards is the thing the synchronous unlock in play_card exists
-- to allow. Nothing here may close that: after a skip, with no draw taken and
-- nothing in the air, the board is open.
local chaining = {
    is_player_turn = function() return true end,
    waiting = false, is_local_action_locked = false,
    is_suit_selection_active = false, player_has_drawn = false, is_animating = false,
}
check("a second skip card may still be played straight away",
      TL.board_may_touch_deck(chaining), true)
check("and the late re-open on an untouched turn is still allowed",
      TL.board_may_reopen_kept_turn(chaining), true)

----------------------------------------------------------------------
-- may_clear_stale_draw: ONE PICK PER TURN, AND THE WATCHDOG KNOWS WHICH TURN
----------------------------------------------------------------------
-- Reported: "the turn is not locked locally when one person picks a card
-- normally". player_has_drawn is the only thing enforcing one pick per turn,
-- and game.script's update() watchdog was clearing it every frame on the
-- reasoning that a draw not in flight must be a previous turn's. An ordinary
-- pick is not in flight either the moment it lands — check_post_draw clears
-- is_local_action_locked so the player can play what they drew — so the guard
-- was wiped one frame later, and the deck stayed open for the rest of the turn.
local function drew(over)
    -- A turn where the player has picked and the card has landed.
    local s = { has_drawn = true, animating = false, locked = false,
                staged = 1, drew_on = "me#1000", turn_now = "me#1000" }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

check("THE BUG: a pick taken this turn is not a previous turn's leftover",
      TL.may_clear_stale_draw(drew()), false)
check("nothing to clear when the player has not drawn",
      TL.may_clear_stale_draw(drew{ has_drawn = false }), false)
check("a draw still in the air is never stale",
      TL.may_clear_stale_draw(drew{ animating = true, staged = 0, drew_on = "me#900" }), false)
check("nor is one whose local action is still committed",
      TL.may_clear_stale_draw(drew{ locked = true, staged = 0, drew_on = "me#900" }), false)

-- THE CASE THE WATCHDOG EXISTS FOR, which must keep working. Two state updates
-- landing in one frame hide the "not my turn" in between, so the now_my_turn
-- edge never fires and the flag survives. By then end_turn has emptied the
-- staged list and the opponent's move has moved the server's turn token, so
-- both discriminators agree the draw belongs to a turn that is over.
check("a genuine previous turn's flag is still cleared",
      TL.may_clear_stale_draw(drew{ staged = 0, drew_on = "me#1000", turn_now = "me#2000" }), true)

-- The token is the authority, and it has to OUTRANK the staged list: a turn
-- that ended without end_turn (a server-side timeout) leaves its DRAW staged
-- forever. Refusing on `staged` there would pin the flag on and leave the
-- player unable to draw — the stuck-with-a-penalty-pending failure this
-- watchdog exists to prevent in the first place.
check("a turn that ended without emptying the staged list still clears",
      TL.may_clear_stale_draw(drew{ staged = 2, drew_on = "me#1000", turn_now = "me#2000" }), true)
check("and the token equally outranks it the other way",
      TL.may_clear_stale_draw(drew{ staged = 0, drew_on = "me#1000", turn_now = "me#1000" }), false)
-- Spelled out rather than built with drew{}: these turn on a token being
-- ABSENT, and a nil override cannot survive a pairs() copy.
-- `staged` is the fallback for when there is no token at all.
check("staged alone carries it when there is no token to compare",
      TL.may_clear_stale_draw({ has_drawn = true, animating = false, locked = false,
                                staged = 0 }), true)
check("an unknown token must read as unknown, never as 'same turn'",
      TL.may_clear_stale_draw({ has_drawn = true, animating = false, locked = false,
                                staged = 0, drew_on = "me#1000" }), true)
check("...and the same the other way round",
      TL.may_clear_stale_draw({ has_drawn = true, animating = false, locked = false,
                                staged = 0, turn_now = "me#1000" }), true)
check("a missing state table refuses rather than throws",
      TL.may_clear_stale_draw(nil), false)

----------------------------------------------------------------------
-- turn_token: server-derived, and nil when it knows nothing
----------------------------------------------------------------------
check("no state, no token", TL.turn_token({}), nil)
check("no turnExpiresAt, no token",
      TL.turn_token({ game_state = { currentTurn = "me" } }), nil)
check("a zero expiry is 'not known yet', not a turn",
      TL.turn_token({ game_state = { currentTurn = "me", turnExpiresAt = 0 } }), nil)
check("a real turn names itself",
      TL.turn_token({ game_state = { currentTurn = "me", turnExpiresAt = 1000 } }), "me#1000")
-- handleMove reassigns turnExpiresAt on EVERY move, so consecutive turns of
-- the same player never share a token — which is the whole point of using it.
check("the same seat on a later turn is a different turn",
      TL.turn_token({ game_state = { currentTurn = "me", turnExpiresAt = 2000 } }) ~=
      TL.turn_token({ game_state = { currentTurn = "me", turnExpiresAt = 1000 } }), true)

----------------------------------------------------------------------
-- the reported sequence, walked in order: ONE normal pick, then no more
----------------------------------------------------------------------
local picked = {
    is_player_turn = function() return true end,
    waiting = false, is_local_action_locked = false,
    is_suit_selection_active = false, player_has_drawn = false, is_animating = false,
    current_turn_actions = {},
    game_state = { currentTurn = "me", turnExpiresAt = 5000 },
}

-- t+0.00 — the turn opens. The deck is the player's to tap, once.
check("t+0.00 the deck is open at the start of the turn",
      TL.board_may_touch_deck(picked), true)

-- t+0.01 — they tap it. The draw commits, stamped with the turn it belongs to,
-- and its DRAW action is staged for the move that will end the turn.
picked.player_has_drawn      = true
picked._drew_on_turn         = TL.turn_token(picked)
picked.is_local_action_locked = true
picked.is_animating          = true
table.insert(picked.current_turn_actions, { type = "DRAW", v = 5, s = "H" })
check("t+0.01 a second tap mid-flight is refused",
      TL.board_may_touch_deck(picked), false)

-- t+0.47 — the card lands. draw_to_hand clears is_animating, then
-- check_post_draw finds the drawn card left something playable and clears
-- is_local_action_locked so it can be played. Pick-and-play, working.
picked.is_animating           = false
picked.is_local_action_locked = false

-- t+0.48 — the watchdog frame. THIS is where the pick used to be forgotten.
check("t+0.48 the watchdog does NOT mistake this turn's pick for a stale one",
      TL.board_may_clear_stale_draw(picked), false)

-- t+0.50 — and because it was not forgotten, the deck stays shut. The player
-- may play a card; they may not take a second one.
check("t+0.50 a normal pick is once per turn",
      picked.player_has_drawn, true)

-- The turn ends: end_turn sends the move and empties the staged list, and the
-- opponent's move moves the server's token on. NOW the flag is genuinely a
-- leftover, and the watchdog is free to clear it — which is the missed-edge
-- case it was written for.
picked.current_turn_actions = {}
picked.game_state.turnExpiresAt = 9000
check("once the turn has really moved on, the flag is cleared",
      TL.board_may_clear_stale_draw(picked), true)

----------------------------------------------------------------------
-- a SKIP card is the one thing that earns a second pick
----------------------------------------------------------------------
-- play_card re-opens input for SKIP_TURN synchronously and clears both the
-- flag and its stamp, so the deck is genuinely open again — this is the one
-- route back to the deck within a turn, and it must stay open.
local after_skip = {
    is_player_turn = function() return true end,
    waiting = false, is_local_action_locked = false,
    is_suit_selection_active = false, is_animating = false,
    game_state = { currentTurn = "me", turnExpiresAt = 5000 },
    -- the pick, the 8 that came out of it, and then the skip's re-open
    current_turn_actions = { { type = "DRAW", v = 8, s = "H" }, { type = "PLAY", v = 8, s = "H" } },
    player_has_drawn = false, _drew_on_turn = nil,
}
check("after a skip the deck is open for the pick it entitles them to",
      TL.board_may_touch_deck(after_skip), true)
check("and there is no flag left for the watchdog to argue about",
      TL.board_may_clear_stale_draw(after_skip), false)

-- That second pick commits exactly like the first, and is just as final.
after_skip.player_has_drawn      = true
after_skip._drew_on_turn         = TL.turn_token(after_skip)
after_skip.is_local_action_locked = false
table.insert(after_skip.current_turn_actions, { type = "DRAW", v = 5, s = "C" })
check("the skip's pick is itself once-only",
      TL.board_may_clear_stale_draw(after_skip), false)

----------------------------------------------------------------------
print(failures == 0 and "\nall checks passed" or ("\n%d FAILED"):format(failures))
os.exit(failures == 0 and 0 or 1)
