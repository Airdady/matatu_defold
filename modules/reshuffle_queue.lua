-- ONE reshuffle at a time, and nobody waits forever.
--
-- THE BUG THIS EXISTS FOR
--
-- Recycling the discard pile back into the deck takes about 1.3 seconds of
-- animation, but it EMPTIES played_cards on its very first line — synchronously,
-- long before the cards actually arrive back in the deck. For that second and a
-- bit the board is in a state that looks, to anything that inspects it, exactly
-- like "there is nothing left to recycle": deck empty, pile down to one card.
--
-- draw_to_hand guarded against that with a flag LOCAL to each call. That covers
-- one batch of draws against itself and nothing else. Two draw batches overlap
-- constantly — a penalty stack resolving while the opponent draws, a General
-- Market, any Whot pick-2 chain — and the second batch has its own flag, sees
-- the drained pile, and concludes the deck is exhausted.
--
-- Worse, a card played DURING the animation pushes the pile back above one. The
-- second batch then starts its OWN reshuffle, and both assign self.deck when
-- they finish. Whichever lands last wins and the other one's cards are gone from
-- the deck, gone from the pile, and referenced by nothing: they cease to exist.
-- The deck ends up at nothing with a one-card pile, which is precisely the state
-- in which no further reshuffle is possible. The game is stuck for good, and the
-- symptom is "the cards drained away and the deck never came back".
--
-- So: exactly one reshuffle runs at a time, everybody else waits on THAT one,
-- and every waiter is answered even when the reshuffle is abandoned — a waiter
-- that is never called back is a draw that never finishes and a turn that never
-- ends.
--
-- Pure and separate from game_flow because game_flow needs the Defold engine to
-- load, and a rule about who is allowed to touch the deck should be provable
-- rather than read.
local M = {}

--- May the caller start a reshuffle right now?
--
-- Returns true exactly once per reshuffle. Every later caller gets false and
-- must wait() instead of doing anything itself.
function M.begin(state)
    if state._reshuffling then return false end
    state._reshuffling = true
    state._reshuffle_waiters = state._reshuffle_waiters or {}
    return true
end

function M.is_running(state)
    return state._reshuffling == true
end

--- Be called back when the reshuffle in progress finishes.
--
-- Callbacks are held rather than invoked, because the point of waiting is that
-- the deck is not ready yet. Calling one early would hand the caller the same
-- empty deck it is waiting to stop seeing.
function M.wait(state, fn)
    if not fn then return end
    if not state._reshuffling then
        -- Nothing to wait for. Answer immediately rather than queue a callback
        -- that nothing will ever drain.
        fn()
        return
    end
    state._reshuffle_waiters = state._reshuffle_waiters or {}
    state._reshuffle_waiters[#state._reshuffle_waiters + 1] = fn
end

--- The reshuffle is over — completed, or abandoned.
--
-- Called on EVERY exit, including the abandoned ones. A reshuffle that is
-- dropped without this leaves the flag set for the life of the board: every
-- future draw then waits on a reshuffle that is not running and never will be,
-- which is a different way to reach the same frozen game.
--
-- Waiters are snapshotted and the list cleared BEFORE any of them run, because a
-- waiter may well start the next draw, find the deck empty again and queue
-- itself onto a fresh list. Iterating the live list would run it in the same
-- pass and recurse.
function M.finish(state)
    state._reshuffling = false
    local waiters = state._reshuffle_waiters or {}
    state._reshuffle_waiters = {}
    for _, fn in ipairs(waiters) do
        -- One waiter erroring must not strand the rest. They are separate draws
        -- belonging to separate turns.
        pcall(fn)
    end
end

--- Fold recycled cards into the deck instead of replacing it.
--
-- Assignment was the second half of the vanishing act: `self.deck = final_deck`
-- discards whatever the deck holds at that instant. Serialising reshuffles means
-- nothing should be there — but "should" is what the original code assumed too,
-- and the cost of being wrong is cards that exist in no collection at all.
--
-- Appends rather than prepends: the deck is drawn from the END (table.remove
-- with no index), so newly recycled cards are drawn before any stragglers, which
-- is also what a player watching the animation expects.
function M.merge_deck(current, incoming)
    local out = {}
    for _, c in ipairs(current or {}) do out[#out + 1] = c end
    for _, c in ipairs(incoming or {}) do out[#out + 1] = c end
    return out
end

--- Is there anything a reshuffle could actually recycle?
--
-- The top card stays on the pile — it is the card in play — so a pile of one is
-- nothing to recycle. Deliberately does NOT consider whether a reshuffle is
-- already running; callers must check that FIRST, because during one this
-- returns false for a pile that is about to be full again.
function M.can_recycle(played_cards)
    return #(played_cards or {}) > 1
end

--- Everything the deck could still yield: what is in it, plus what the pile
--- could give back. The question "can this player draw at all" has to count both
--- or a draw is refused at the exact moment a reshuffle would have supplied it.
function M.available(deck, played_cards)
    local pile = #(played_cards or {})
    return #(deck or {}) + math.max(0, pile - 1)
end

return M
