-- THE DECK THAT DRAINS AND NEVER COMES BACK.
--
--   Run: lua tools/test_reshuffle.lua
--
-- Reported as: in offline play, and most often in Whot, the cards run out
-- completely, the reshuffle never happens again, and the deck stays empty for
-- the rest of the game.
--
-- WHAT WAS ACTUALLY HAPPENING
--
-- Recycling the discard pile takes ~1.3 seconds of animation, but it empties
-- played_cards on its FIRST line — synchronously, long before the cards arrive
-- back in the deck. For that second and a bit the board looks, to anything
-- inspecting it, exactly like a genuinely exhausted game: deck at zero, pile
-- down to the single card in play.
--
-- draw_to_hand guarded that window with a flag local to each call, which covers
-- one batch of draws against itself and nothing else. Overlapping draws are the
-- normal case, not an edge one — a penalty stack resolving while the opponent
-- draws, a General Market, any Whot pick-2 chain — and Whot has more of them
-- than Matatu, which is why Whot showed it most.
--
-- Two failures follow, and the second is the one that is permanent:
--
--   1. the second batch sees the drained pile, calls the deck exhausted, and
--      finishes having dealt fewer cards than the rules require
--   2. a card played DURING the animation pushes the pile back above one, so
--      the second batch starts its OWN reshuffle. Both end by ASSIGNING
--      self.deck. Whichever lands last wins, and the other's cards are
--      referenced by nothing at all — not the deck, not the pile, not a hand.
--      They cease to exist.
--
-- The board is then at zero deck and a one-card pile, which is exactly the
-- state in which no further reshuffle is possible. Stuck for good.
--
-- These drive the REAL modules/reshuffle_queue.lua, because the whole failure
-- was two pieces of code disagreeing about who was allowed to touch the deck.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local RQ = require("modules.reshuffle_queue")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local function board() return {} end

print("only one reshuffle may run at a time")
do
    local b = board()
    check("the first caller may go", RQ.begin(b), true)
    -- THE BUG. The second caller used to be a different draw batch with its own
    -- local flag, so it went ahead too — and both ended by assigning the deck.
    check("the second caller may NOT", RQ.begin(b), false)
    check("nor the third", RQ.begin(b), false)
    check("it reports itself as running", RQ.is_running(b), true)
    RQ.finish(b)
    check("and not once finished", RQ.is_running(b), false)
    check("after which a new one may start", RQ.begin(b), true)
end

print("")
print("everybody who waits is answered")
do
    local b = board()
    RQ.begin(b)
    local woke = 0
    RQ.wait(b, function() woke = woke + 1 end)
    RQ.wait(b, function() woke = woke + 1 end)
    RQ.wait(b, function() woke = woke + 1 end)
    -- Held, not called: the point of waiting is that the deck is not ready. An
    -- early callback hands the waiter the same empty deck it is waiting to stop
    -- seeing, which is the "finished short" failure all over again.
    check("nobody is woken early", woke, 0)
    RQ.finish(b)
    check("all three are woken at the end", woke, 3)
end

do
    local b = board()
    -- Nothing running: answer at once rather than queue onto a list that
    -- nothing will ever drain. A waiter never called back is a draw that never
    -- finishes and a turn that never ends.
    local woke = false
    RQ.wait(b, function() woke = true end)
    check("waiting with nothing running answers immediately", woke, true)
end

do
    local b = board()
    RQ.begin(b)
    local order = {}
    -- A waiter typically starts the next draw, finds the deck empty again and
    -- queues itself onto a FRESH list. Iterating the live list would run it in
    -- the same pass and recurse until the stack gave out.
    RQ.wait(b, function()
        order[#order + 1] = "first"
        RQ.begin(b)
        RQ.wait(b, function() order[#order + 1] = "requeued" end)
    end)
    RQ.wait(b, function() order[#order + 1] = "second" end)
    RQ.finish(b)
    check("a waiter that re-queues does not recurse", #order, 2)
    check("and the requeue is not run in the same pass", order[2], "second")
end

do
    local b = board()
    RQ.begin(b)
    local reached = false
    RQ.wait(b, function() error("this waiter is broken") end)
    RQ.wait(b, function() reached = true end)
    RQ.finish(b)
    -- Separate draws belonging to separate turns. One erroring must not strand
    -- the rest mid-hand.
    check("one broken waiter does not strand the others", reached, true)
end

print("")
print("an abandoned reshuffle still releases")
do
    local b = board()
    RQ.begin(b)
    RQ.finish(b)
    -- The seq-abort paths bail out mid-animation when a round is torn down. If
    -- one returns without releasing, the flag stays set for the life of the
    -- board and every future draw waits on a reshuffle that will never run —
    -- the same frozen game by a different route.
    check("a new reshuffle can start afterwards", RQ.begin(b), true)
end

print("")
print("recycling is judged on the pile, and the top card is not part of it")
do
    check("an empty pile has nothing to recycle", RQ.can_recycle({}), false)
    -- One card is the card IN PLAY. Recycling it would take the game's own
    -- reference point away.
    check("a pile of one has nothing to recycle", RQ.can_recycle({ 1 }), false)
    check("a pile of two does", RQ.can_recycle({ 1, 2 }), true)
    check("nil is not a crash", RQ.can_recycle(nil), false)
end

print("")
print("how much the deck can still yield")
do
    check("deck only", RQ.available({ 1, 2, 3 }, {}), 3)
    -- The pile counts, minus the card in play — a draw refused here is a draw
    -- refused at the exact moment a reshuffle would have supplied it, and in
    -- offline_handler two of those in a row ended the match as a stalemate.
    check("deck plus the recyclable pile", RQ.available({ 1 }, { 1, 2, 3 }), 3)
    check("a one-card pile adds nothing", RQ.available({ 1 }, { 1 }), 1)
    check("genuinely exhausted is zero", RQ.available({}, { 1 }), 0)
    check("never negative", RQ.available({}, {}), 0)
    check("nils are not a crash", RQ.available(nil, nil), 0)
end

print("")
print("NO CARD IS EVER LOST")
do
    -- The second half of the vanishing act: `self.deck = final_deck` discards
    -- whatever the deck holds at that instant.
    local existing = { "a", "b" }
    local incoming = { "c", "d", "e" }
    local merged = RQ.merge_deck(existing, incoming)
    check("every card survives a merge", #merged, 5)
    check("what was already there is kept", merged[1], "a")
    -- Appended, not prepended: the deck is drawn from the END, so recycled
    -- cards come out before any stragglers — which is also what a player
    -- watching the animation expects.
    check("recycled cards go on top of the draw order", merged[5], "e")
    check("merging into an empty deck works", #RQ.merge_deck({}, incoming), 3)
    check("merging nothing in is harmless", #RQ.merge_deck(existing, {}), 2)
    check("nils are not a crash", #RQ.merge_deck(nil, nil), 0)
end

print("")
print("THE REPORTED FAILURE, replayed")
do
    -- Two draw batches overlapping across one reshuffle, which is the shape
    -- every report of this had in common.
    local b = board()
    local deck, pile = {}, { "top", "x", "y", "z" }
    local delivered = 0

    -- Batch one finds the deck empty and starts the reshuffle. The pile is
    -- drained NOW; the cards arrive later.
    check("batch one may reshuffle", RQ.begin(b), true)
    local recycled = { "x", "y", "z" }
    pile = { "top" }

    -- Batch two arrives mid-animation. Before the fix it had its own flag, saw
    -- deck 0 and pile 1, and either finished short or started a second
    -- reshuffle whose completion clobbered the first.
    check("batch two is refused its own reshuffle", RQ.begin(b), false)
    check("and it does NOT read the board as exhausted", RQ.is_running(b), true)
    RQ.wait(b, function() delivered = delivered + 1 end)

    -- A card played during the animation pushes the pile back above one — the
    -- condition that used to let batch two start a rival reshuffle.
    pile[#pile + 1] = "played-mid-animation"
    check("a rival reshuffle is still refused", RQ.begin(b), false)

    -- The reshuffle lands.
    deck = RQ.merge_deck(deck, recycled)
    RQ.finish(b)

    check("batch two was woken rather than abandoned", delivered, 1)
    check("the deck came back", #deck, 3)
    check("with the mid-animation card still on the pile", #pile, 2)
    -- Nothing may have gone missing: three recycled plus two on the pile is the
    -- five that existed before.
    check("no card vanished", #deck + #pile, 5)
    check("and the board is free to reshuffle again", RQ.begin(b), true)
end

print("")
print("AFTER A RESHUFFLE: SURVIVORS ON TOP, RECYCLED BELOW")
-- The server's rule, from reshufflePlayedCards in handlers/moves/reshuffle.ts:
--   newDeck = [...shuffledPlayedCards, ...currentDeck]
-- Top of deck is the END of the array, so the cards already in the deck stay on
-- top and the recycled pile goes underneath. The card a player is about to draw
-- is therefore UNCHANGED by a reshuffle — which is the only reason the server
-- can validate a DRAW that was chosen before it reshuffled.
do
    local deck     = { "A", "B", "C" }        -- survivors; C is the top
    local recycled = { "x", "y", "z", "w" }   -- pile coming back

    -- game_flow builds final_deck as recycled-then-survivors. It ALREADY
    -- contains everything in deck.
    local final_deck = {}
    for _, c in ipairs(recycled) do final_deck[#final_deck + 1] = c end
    for _, c in ipairs(deck)     do final_deck[#final_deck + 1] = c end

    local merged = RQ.merge_deck(final_deck, deck)

    check("no card is listed twice", #merged, #deck + #recycled)
    check("the top card is untouched by the reshuffle", merged[#merged], "C")
    check("survivors sit on top", table.concat(merged, " "), "x y z w A B C")

    local seen, dupes = {}, 0
    for _, c in ipairs(merged) do
        if seen[c] then dupes = dupes + 1 end
        seen[c] = true
    end
    -- A card object at two indices is the real damage: stamp_deck assigns
    -- identities BY INDEX, so the later write wins for both and the earlier
    -- position reports a card that is really elsewhere in the deck.
    check("and no card object sits at two indices", dupes, 0)

    -- Merging the other way round was the bug, twice over: it duplicated the
    -- survivors AND put the recycled cards on top, so the very next draw named
    -- a card the server did not have on top.
    local wrong = RQ.merge_deck(deck, final_deck)
    check("the reverse order would put recycled on top", wrong[#wrong], "w")

    -- A card that genuinely arrived mid-animation is still not lost.
    local straggler = { "S" }
    for _, c in ipairs(deck) do straggler[#straggler + 1] = c end
    local kept = RQ.merge_deck(final_deck, straggler)
    check("a straggler is appended, not dropped", kept[#kept], "S")
    check("and it does not duplicate anything", #kept, #deck + #recycled + 1)
end

print("")
print("WHO MAY TAKE A CARD OUT OF THE DECK")
-- The second "Draw mismatch" bug. A sync draw delivers cards the SERVER has
-- already dealt, so the server's deck already excludes them and ours has just
-- been sized to match. Consuming from the deck on top of that pushes it below
-- the server's and shifts its top.
check("a real player draw consumes the deck", RQ.consumes_deck(false, true), true)
check("a sync draw online does NOT", RQ.consumes_deck(true, true), false)
check("offline there are no sync draws to exempt", RQ.consumes_deck(true, false), true)
check("and an ordinary offline draw consumes", RQ.consumes_deck(false, false), true)

print("")
print("THE OFFSET, replayed")
do
    -- The server dealt 2 cards to our hand and its deck is now 20. do_sync
    -- sizes ours to 20 and stamps identities index-for-index, so deck[20] is
    -- the card the server will expect us to draw next.
    local SERVER_DECK = 20
    local deck = {}
    for i = 1, SERVER_DECK do deck[i] = "card" .. i end

    -- sync_my_hand then catches the hand up by 2. Those 2 are already dealt.
    local catch_up = 2
    for _ = 1, catch_up do
        if RQ.consumes_deck(true, true) then table.remove(deck) end
    end

    check("the deck still matches the server's", #deck, SERVER_DECK)
    -- The whole point: the next real draw must report the server's top.
    check("and its top is still what the server expects", deck[#deck], "card20")

    -- What the bug did instead, for contrast: consume anyway, and the top the
    -- next draw reports is two positions down from the one the server holds.
    local broken = {}
    for i = 1, SERVER_DECK do broken[i] = "card" .. i end
    for _ = 1, catch_up do table.remove(broken) end
    check("consuming would have reported the wrong card", broken[#broken], "card18")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
