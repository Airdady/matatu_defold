-- A "GARBAGE" CARD THAT OUTLIVES THE GAME IT APPEARED IN.
--
--   Run: lua tools/test_own_move_hand_sync.lua
--
-- Reported: a `[DRAW] client deck is stale (index 0: server has 13C, client
-- asked for 6S)` warning in the backend logs correlated with a visibly wrong
-- card in the player's own hand — one that never got cleaned up even once
-- the game ended.
--
-- Root cause, in two halves:
--
--   * be_matatu's drawCards (matatu/websocket/handlers/moves/reshuffle.ts)
--     already self-heals a stale draw request (same count, wrong card
--     named) by handing back the server's REAL top card. But the caller
--     only ever told the mover about a correction when enforceDrawBounds
--     had to clamp the DRAW COUNT — a same-count, different-identity
--     mismatch got nothing but a bare TIMER_UPDATE (no gameState at all).
--   * Even where the backend NOW sends the mover a quiet full-state MOVE for
--     exactly this case (see moves/index.ts's `drawMismatched` branch),
--     handle_single_move's own "this is my move, nothing to replay" branch
--     called ONLY finalize_state_sync — which reconciles the deck pile and
--     the opponent's hand, but never touches self.player_hand at all. The
--     mover's local hand kept showing whatever card it had guessed, forever.
--
-- The fix reconciles the mover's own hand the same way an opponent's action
-- or an AI-covered move already does: sync_my_hand after finalize_state_sync,
-- unconditionally. It is a no-op multiset diff when the two hands already
-- agree (the common case), so this costs nothing when there was nothing to
-- fix.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

local src = slurp("modules/online_handler.lua")
local code = src:gsub("%-%-[^\n]*", "")

print("")
print("handle_single_move: OUR OWN ordinary move also reconciles player_hand")

local fn_start = code:find("function M%.handle_single_move%(self, move_data, new_state, done%)")
check("handle_single_move exists", fn_start ~= nil)

local fn_end = fn_start and code:find("\nfunction M%.pump_move_queue", fn_start)
local fn_body = fn_start and code:sub(fn_start, fn_end and (fn_end - 1) or nil)

if fn_body then
    -- The final `else` branch (neither "opponent's move" nor "AI covered our
    -- turn") is what a plain self-originated MOVE with no actions to replay
    -- falls into — exactly the shape of the quiet drawMismatched correction.
    local else_pos = fn_body:find("\n    else\n")
    check("the final else branch exists", else_pos ~= nil)

    local else_body = else_pos and fn_body:sub(else_pos)

    check("it still calls finalize_state_sync first",
        else_body and else_body:find("M%.finalize_state_sync%(self, new_state, function%(%)") ~= nil,
        "deck pile size and opponent-hand-count still have to catch up before anything else")

    check("and now also calls sync_my_hand, not just done()",
        else_body and else_body:find("sync_my_hand%(self, self%.game_state or new_state or {}, done%)") ~= nil,
        "without this, a same-count draw-identity mismatch (see reshuffle.ts's describeDrawMismatch) never gets corrected on the client at all — the mover's local hand just stays wrong")

    -- self.game_state, not the closure-captured new_state — same reasoning
    -- as the opponent-move and ai_for_me branches right above it use, and
    -- for the identical race: finalize_state_sync's own do_sync can be
    -- deferred behind a reshuffle, and a newer state can land and overwrite
    -- self.game_state while that's still in flight.
    check("reconciles against self.game_state, not the stale closure-captured new_state",
        else_body and else_body:find("sync_my_hand%(self, self%.game_state or new_state") ~= nil,
        "reconciling against a stale new_state can re-add a card the player has since played")
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
