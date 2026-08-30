-- TWO COPIES OF ONE CARD ON THE TABLE.
--
--   Run: lua5.4 tools/test_hand_reconcile.lua
--
-- Reported: a player disconnected, came back, played the 3 of Clubs — and the
-- opponent drew a 3 of Clubs from the deck. One of them was fictional.
--
-- HOW A PHANTOM CARD IS MADE
--
-- A draw is optimistic. The client takes what IT believes is the top of the
-- deck and puts that card in the hand immediately, then tells the server. When
-- its deck has drifted, the server deals a DIFFERENT card and says so, in the
-- state it broadcasts back:
--
--   Draw mismatch at index 0: Expected 8H, Got 7D
--   [DRAW] client deck drifted (deck was 29, 1 requested) — dealing server cards
--
-- finalize_state_sync applies that state to the DECK, the PILE TOP and the
-- OPPONENT'S hand on every sync. The player's own hand was reconciled only on
-- the branch that handles somebody ELSE's move — so the echo of the player's
-- own move, the one case where their hand is most likely to be wrong, was the
-- one case nothing checked. The phantom stayed in hand for the rest of
-- the game while the real card was still in the deck, waiting to be drawn and
-- played by somebody else.
--
-- These read the real source, because what is being asserted is that a call
-- exists on a path — which is a property of the code's shape, not of any value
-- a function returns.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

local f = assert(io.open(here .. "/../modules/online_handler.lua"))
local src = f:read("*a"); f:close()

-- The dispatcher that picks how a synced move is applied.
local dispatch = src:match("(if not is_my_move and has_actions then.-\nend\nend)")
  or src:match("(if not is_my_move and has_actions then.-\n    end\nend)")
assert(dispatch, "move dispatch block not found in online_handler.lua")

print("── every branch reconciles the player's own hand ──")

local calls = 0
for _ in src:gmatch("sync_my_hand%(self, new_state or {}%)") do calls = calls + 1 end
-- The opponent's move, and the echo of our own. There used to be a third —
-- the AI playing our seat for us — until AI takeover was removed; the AI no
-- longer plays a human's seat, so no move of ours ever comes back with
-- actions we did not make.
check("both branches call sync_my_hand", calls, 2)

check("the opponent-move branch does", dispatch:find("process_opponent_actions") ~= nil, true)
check("and nothing replays our own actions for us",
      src:find("process_my_actions") == nil, true)

-- THE ONE THAT WAS MISSING. The `else` is our own move coming back from the
-- server; it used to call finalize_state_sync and nothing more.
local tail = dispatch:match("else(.*)$")
check("and so does the else — our own move's echo", tail ~= nil, true)
check("...which is where the correction actually rides home",
      tail ~= nil and tail:find("sync_my_hand") ~= nil, true)
check("...and it still finalizes the rest of the state first",
      tail ~= nil and tail:find("finalize_state_sync") ~= nil, true)

print("\n── the reconcile itself is non-destructive ──")
local body = src:match("(local function sync_my_hand.-\nend)")
assert(body, "sync_my_hand not found")

-- Reconciles by identity as a multiset, so it only touches cards that really
-- differ — an index-for-index overwrite would relabel a still-held card.
check("matches by value+suit, not by position",
      body:find('tostring%(c%.v%) %.%. "|" %.%. tostring%(c%.s%)') ~= nil, true)
-- Catch-up, not a draw: these cards are already dealt server-side, so they must
-- not consume the local deck or be reported back as a DRAW action.
check("adds missing cards as a SYNC draw", body:find("{ sync = true }") ~= nil, true)
check("...and stamps each one's real identity", body:find("self%.set_face%(c%)") ~= nil, true)
check("returns early when the server sent no hand",
      body:find("if not real then return end") ~= nil, true)

print("\n── what finalize_state_sync already did, and did not ──")
local fin = src:match("(function M%.finalize_state_sync.-\nend)")
assert(fin, "finalize_state_sync not found")
check("it stamps the deck", fin:find("stamp_deck") ~= nil, true)
check("it stamps the pile top", fin:find("stamp_pile_top") ~= nil, true)
check("it stamps the opponent's hand", fin:find("stamp_ai_hand") ~= nil, true)
-- The asymmetry that caused this: our own hand was never its business, so the
-- caller has to ask for it — which is why both branches now do.
check("but never the player's own hand", fin:find("sync_my_hand") == nil, true)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
