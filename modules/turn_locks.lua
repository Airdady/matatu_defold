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

--- The two above, read straight off a board object.
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

return M
