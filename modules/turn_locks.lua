-- ONE DRAW PER TURN, AND A LATE CALLBACK NEVER UNDOES A LIVE ONE.
--
-- THE BUG THIS EXISTS FOR
--
-- Reported: "I played a skipping card, went to pick again, accidentally tapped
-- twice very fast, and ended up with two cards in hand instead of one."
--
-- Playing a Skip / Hold On / General Market keeps the turn with the player, and
-- the client re-opened their input TWICE for it, from two different places:
--
--   game_flow.play_card          synchronously, at tap time. Added so a
--                                legitimate rapid second tap (chaining skips)
--                                is not rejected while the first card is still
--                                flying to the pile.
--   game_flow.after_play_settled ~0.42s later, when that flight actually lands.
--
-- The second is stale by construction, and it was unconditional. So:
--
--   t+0.00  skip card played      -> has_drawn = false, locked = false
--   t+0.10  deck tapped           -> has_drawn = true,  locked = true, and a
--                                    card starts its ~0.46s flight to the hand
--   t+0.42  the PLAYED card lands -> after_play_settled re-opens the turn and
--                                    wipes both flags — while the draw it knows
--                                    nothing about is still in the air
--   t+0.45  second tap            -> every guard now reads false. Second card.
--
-- Which is the report exactly, and also why it takes a skip card to produce:
-- no other result re-opens a turn from a delayed callback.
--
-- Nothing downstream caught it. The two cards are genuinely dealt — the client
-- names them correctly because it is reading its own deck in order, and the
-- server accepted a move carrying two DRAW actions and no penalty as readily as
-- one. So neither side saw anything wrong. (be_matatu caps that now as well;
-- this module is the near half, and the half that stops it happening at all.)
--
-- WHY THIS IS ITS OWN FILE
--
-- The same reason reshuffle_queue.lua is: the failure was two pieces of code
-- disagreeing about who was allowed to touch something, and a rule about that
-- should be provable without booting a screen. game_flow needs the Defold
-- engine; these predicates need nothing, so tools/test_turn_locks.lua exercises
-- the real rule rather than a paraphrase of it.

local M = {}

local function on(v) return v and true or false end

--- Is the deck touchable at all right now?
--
-- The shared gate in front of BOTH things a deck tap can mean — settling an
-- owed General Market draw, and an ordinary or penalty draw. Whether the player
-- has already drawn is deliberately NOT part of it: the two branches behind
-- this gate answer that differently, and they say so themselves.
--
-- `s` is the board's own flags, passed as a plain table so this stays testable:
--   my_turn        is_player_turn()
--   waiting        waiting on the server / the opponent
--   locked         is_local_action_locked — a local action already committed
--   suit_selecting the suit picker is open
--   animating      is_animating — a card is in flight to this player's hand
--
-- `animating` is the new one, and it is the belt to the braces. Every other
-- flag here can be cleared by something else while a draw is genuinely mid-air
-- — that is the whole bug above — but a card physically flying into the hand is
-- not a state anything clears by accident. Nor is it a trap: game.script's
-- watchdog clears a stuck is_animating after 3.5s of a player turn with an
-- empty queue.
function M.may_touch_deck(s)
    s = s or {}
    if not s.my_turn then return false end
    if s.waiting or s.locked or s.suit_selecting then return false end
    if s.animating then return false end
    return true
end

--- May a callback that fires AFTER the played card lands re-open the turn?
--
-- This is what re-arms the player when they play a SKIP card (an 8 or a Jack):
-- the skip keeps the turn, so the deck and the hand have to come back.
--
-- has_drawn IS NOT A REASON TO REFUSE, AND TREATING IT AS ONE BROKE THE GAME.
--
-- It was in this gate. The reasoning was that a re-open arriving while a draw
-- was under way must be a stale callback from a superseded play. It is not —
-- it is the most ordinary turn there is:
--
--   draw a card, it happens to be an 8, play it
--
-- has_drawn is true at that moment for the perfectly good reason that the
-- player just drew. Refusing here left the turn un-armed and the deck locked,
-- so the player could not take the second card the skip entitles them to. The
-- action list then flushed as [DRAW 8H, PLAY 8H] — a skip card with nothing
-- after it, which the server refuses outright (validateActionCardList: "Skip
-- card cannot be the final card. It must be followed by a DRAW card or be your
-- last card"). Refusal means ERROR + RESYNC, so a legal turn produced a full
-- board rebuild. Reported as: "when I do pick and play more than once I am
-- stopped from continuing, and the backend keeps resyncing."
--
-- STALENESS IS ORDERING, NOT DRAW STATE, and after_play_settled already
-- answers it properly with its play ticket (`ticket < self._play_ticket`
-- drops a superseded call before this is ever asked). That is the correct
-- mechanism; this one was a proxy for it that happened to be true in the case
-- it was meant to allow.
--
-- `animating` stays. A card physically in flight is a real reason to wait, and
-- unlike has_drawn it is not true during the ordinary case above by the time
-- the play has settled.
--
-- `locked` is deliberately not consulted: it is the flag being cleared.
function M.may_reopen_kept_turn(s)
    s = s or {}
    if s.animating then return false end
    return true
end

--- May the watchdog treat player_has_drawn as a PREVIOUS turn's leftover?
--
-- THE BUG THIS EXISTS FOR
--
-- Reported: "the turn is not locked locally when one person picks a card
-- normally". Picking is meant to be once per turn — only a SKIP card earns a
-- second trip to the deck — and it had stopped being once per turn at all.
--
-- player_has_drawn is the ONLY thing enforcing that rule. game.script's deck
-- tap ends in `elseif not self.player_has_drawn then`, so whatever clears that
-- flag mid-turn hands out another card. game.script's update() watchdog was
-- clearing it every frame, on this reasoning:
--
--   it is my turn, nothing is processing, the queue is empty, nothing is
--   awaited from the server, and neither is_animating nor is_local_action_locked
--   is set -- so a draw in flight is ruled out, so this flag must be a
--   previous turn's
--
-- The last step does not follow. An ordinary pick lands in exactly that state
-- and it is THIS turn's:
--
--   t+0.00  deck tapped        player_has_drawn = true, locked = true
--   t+0.46  the card lands     draw_to_hand's finish() clears is_animating,
--                              THEN calls check_post_draw
--   t+0.46  check_post_draw    the drawn card left something playable, so it
--                              clears is_local_action_locked and raises the
--                              "tap to skip" prompt -- pick-and-play, correct
--   t+0.47  next frame         watchdog reads has_drawn=true, animating=false,
--                              locked=false -> "stale" -> clears it
--   t+0.50  deck tapped again  the one guard there was is gone. Second card.
--
-- And a third, and a fourth: the watchdog re-clears the flag every frame, so
-- the deck stayed open for the whole turn. The server does not catch it either
-- -- be_matatu's validation.ts carries a long note on why it deliberately has
-- no per-move draw cap ("the double-tap is prevented where it actually
-- originates -- matatu_defold's modules/turn_locks.lua"). This IS that guard,
-- so nothing else was ever going to.
--
-- WHY THE WATCHDOG STILL HAS TO EXIST
--
-- It is not removable. player_has_drawn's ordinary reset is the false->true
-- edge of now_my_turn in update(), an edge sampled once a frame, and two state
-- updates -- the opponent's play (which can trigger a ~1.3s reshuffle settle)
-- and the turn coming back -- can land in the SAME frame. The intermediate
-- "not my turn" is then never observed, the edge never fires, and the flag
-- really does survive into the next turn. With a penalty pending, drawing is
-- the only legal move, so a stale flag refuses every tap and the whole hand
-- reads as disabled.
--
-- So the watchdog needs what it never had: a way to tell THIS turn's draw from
-- a previous turn's. It asks the draw which turn it was taken on.
--
--   drew_on / turn_now
--             the turn the draw was stamped with (game.script stamps it at the
--             moment it sets player_has_drawn) against the turn in progress --
--             see M.turn_token. This is the authority when both are known, and
--             it is server-derived, so unlike the now_my_turn edge it cannot be
--             missed by a frame: handleMove reassigns turnExpiresAt on every
--             single move. Same token means the draw is THIS turn's and the
--             one-pick-per-turn rule is simply doing its job; a different token
--             means the turn it belonged to is over and the flag is a leftover.
--
--   staged    #current_turn_actions -- the fallback for when there is no token
--             to compare (offline, or before any turnExpiresAt has arrived).
--             A real online pick appends its DRAW here (draw_to_hand) and
--             online_handler.end_turn empties the list when the turn's move is
--             sent, so non-empty means "this turn is still mid-composition" --
--             which is also exactly the signal reconcile_input_locks already
--             trusts for the same question.
--
-- The token is consulted FIRST rather than AND-ed with `staged`, and that
-- ordering matters in one direction: a turn that ended WITHOUT end_turn (a
-- server-side timeout, say) leaves its DRAW staged forever, so an AND would
-- refuse to clear a flag that really is stale and leave the player unable to
-- draw -- the exact stuck-with-a-penalty-pending failure this watchdog exists
-- to prevent. The token answers that case correctly, so let it answer.
--
-- animating / locked stay as they were: a draw physically in flight is never a
-- leftover, whatever the rest says.
function M.may_clear_stale_draw(s)
    s = s or {}
    if not s.has_drawn then return false end
    if s.animating or s.locked then return false end
    if s.drew_on ~= nil and s.turn_now ~= nil then
        return s.drew_on ~= s.turn_now
    end
    return (s.staged or 0) == 0
end

--- The identity of the turn currently in progress, or nil if not known.
--
-- turnExpiresAt is reassigned by be_matatu's handleMove on EVERY move
-- (`gameState.turnExpiresAt = Date.now() + PLAY_TIMEOUT_DURATION`), and by
-- startTimeout whenever it arms a FRESH turn -- which covers the turn a
-- server-side timeout hands on. It reaches this client through
-- online_handler.sync_timers, which copies the server's value verbatim: the
-- local recomputation further down sync_timers only drives the HUD clock and
-- is never written back. So it changes once per turn, from the authority, and
-- pairs with currentTurn to name a turn.
--
-- What deliberately does NOT move it is a disconnect grace re-arm
-- (startTimeout's freshTurn = false), which is right for this too: a grace
-- period is not a new turn, and a draw taken before it is still this turn's.
--
-- nil rather than a placeholder when there is nothing to go on (offline, or no
-- state yet). A caller must read that as "unknown", never as "same turn" --
-- may_clear_stale_draw does, and falls back to `staged` alone.
function M.turn_token(self)
    local gs = self and self.game_state
    if type(gs) ~= "table" then return nil end
    local expires = gs.turnExpiresAt
    if expires == nil or expires == 0 then return nil end
    return tostring(gs.currentTurn) .. "#" .. tostring(expires)
end

--- The rules above, read straight off a board object.
--
-- The call sites hold `self`; these save them spelling the same fields out
-- again and getting one of them wrong, which is how the two unlocks came to
-- disagree in the first place.
function M.board_may_touch_deck(self)
    return M.may_touch_deck({
        my_turn        = on(self.is_player_turn and self.is_player_turn()),
        waiting        = on(self.waiting),
        locked         = on(self.is_local_action_locked),
        suit_selecting = on(self.is_suit_selection_active),
        animating      = on(self.is_animating),
    })
end

function M.board_may_reopen_kept_turn(self)
    return M.may_reopen_kept_turn({
        has_drawn = on(self.player_has_drawn),
        animating = on(self.is_animating),
    })
end

function M.board_may_clear_stale_draw(self)
    local staged = self.current_turn_actions
    return M.may_clear_stale_draw({
        has_drawn = on(self.player_has_drawn),
        animating = on(self.is_animating),
        locked    = on(self.is_local_action_locked),
        staged    = (type(staged) == "table") and #staged or 0,
        drew_on   = self._drew_on_turn,
        turn_now  = M.turn_token(self),
    })
end

return M
