-- WHAT HAPPENS BETWEEN ONE GAME AND THE NEXT.
--
--   Run: luajit tools/test_round_handover.lua
--
-- Four reports, one seam. Everything here is about the handover from a game
-- that has just ended to whatever comes after it, and all four failed inside
-- that window:
--
--   1. the old scoreboard is still showing when the next game deals, and a
--      KNOCKOUT's score-cap table is still up during a TOURNAMENT started
--      after it — with the tournament's own scoreboard never appearing at all.
--
--   2. round transitions take "very very long", when the next round is
--      supposed to be set up the instant the round is decided and merely
--      QUEUED by the phone until the ending animations are done.
--
--   3. a game accepted while the last one was still counting initialises, but
--      the game-over dialog for the game that just ended never appears.
--
--   4. on a cutting card the revealed opponent hand is not the hand they had.
--
-- These drive the real modules. Nothing here is a restatement of the code: each
-- check is the reported symptom expressed as a condition on state.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

----------------------------------------------------------------------
-- The shared headless Defold runtime. Used for its websocket seam in
-- particular: parse_message is a module local, so the only honest way to
-- deliver a GAME_OVER is the one the real socket uses — SIM.server_send
-- driving the registered connection callback.
----------------------------------------------------------------------
local SIM = dofile("tools/defold_sim.lua")
local ws = require("modules.websocket_manager")
local OnlineHandler = require("modules.online_handler")

----------------------------------------------------------------------
print("")
print("1. THE BOARD FURNITURE OF THE GAME THAT JUST ENDED")
-- game_flow's start_game asks one question before it tears the HUD down: does
-- the state it is about to build CONTINUE what is already on screen? The
-- answer decides whether the scoreboard is rebuilt from scratch and whether
-- the knockout chamber survives.
--
-- It never actually asked. The flag it passed was computed from self.t4, which
-- GS.destroy_all had already set to nil a dozen lines earlier, so the answer
-- was unconditionally "yes, continue" — for every game, in every mode. The
-- previous match's scoreboard and the previous knockout's table were inherited
-- by whatever came next.
----------------------------------------------------------------------
local function state(t)
    return {
        id = t.id or "g1",
        tournamentId = t.tid,
        matchType = t.match_type,
        matchFormat = t.fmt,
        players = { ["me"] = { id = "me" }, [t.opp or "opp1"] = { id = t.opp or "opp1" } },
    }
end

local self_ = { my_player_id = "me" }

local ko_round1 = state({ id = "k1", tid = "T-KO", match_type = "KNOCKOUT", fmt = 3 })
local ko_round2 = state({ id = "k2", tid = "T-KO", match_type = "KNOCKOUT", fmt = 3 })
local tourney   = state({ id = "t1", tid = "T-CUP", fmt = 3 })

-- Nothing on screen yet: the first game of anything is never a continuation.
check("first knockout round is not a continuation",
    OnlineHandler.continues_series(self_, ko_round1), false)

self_._sb_series_key = OnlineHandler.series_key(self_, ko_round1)

-- The case that must keep working: round 2 of the same knockout keeps its
-- chamber and its running totals.
check("round 2 of the SAME knockout continues it",
    OnlineHandler.continues_series(self_, ko_round2), true)

-- THE REPORTED CASE. A tournament started while the knockout's table is still
-- on screen. Different match entirely — the table has to go, and with it the
-- `if self.t4_chamber` guard in update_scoreboard that was suppressing the
-- tournament's own scoreboard for as long as the table stayed up.
check("a TOURNAMENT after a knockout does NOT continue it",
    OnlineHandler.continues_series(self_, tourney), false)

-- Same tournament id, different opponent: a level replayed against someone new
-- is a new pairing, not a continuation, or the previous opponent's score is
-- still on the board.
self_._sb_series_key = OnlineHandler.series_key(self_, tourney)
local tourney_new_opp = state({ id = "t2", tid = "T-CUP", fmt = 3, opp = "opp2" })
check("same tournament, NEW opponent is not a continuation",
    OnlineHandler.continues_series(self_, tourney_new_opp), false)
check("same tournament, same opponent is",
    OnlineHandler.continues_series(self_, state({ id = "t2", tid = "T-CUP", fmt = 3 })), true)

-- A plain unformatted match has no series to continue, so it can never be
-- mistaken for one — including by the game after it.
check("a one-off match has no series identity",
    OnlineHandler.series_key(self_, state({ id = "n1" })), "")
self_._sb_series_key = ""
check("and an empty key never matches an empty key",
    OnlineHandler.continues_series(self_, state({ id = "n2" })), false)

----------------------------------------------------------------------
print("")
print("2. THE HAND THE OPPONENT ACTUALLY HELD")
-- The opponent's cards are face-down all game, spawned as placeholder 10s of
-- hearts, so the reveal has to overwrite every one of them with the real card.
-- Its source used to be, in the last resort, the cached ACTIVE GAME — and the
-- server now pushes the next round before it broadcasts GAME_OVER, so by the
-- time the reveal runs that cache routinely describes a round nobody has
-- played yet. GAME_OVER carries the true final hands; they were being thrown
-- away with the rest of the final state.
----------------------------------------------------------------------
ws.connect()
SIM.pump(0.3)   -- lets the simulated socket finish opening

-- Exactly the shape endGame.ts sends: data.gameState is the whole final state,
-- with gameOverState nested inside it.
SIM.server_send({
    type = "GAME_OVER",
    data = { gameState = {
        gameOverState = { winner = "me", reason = "CUTTING_CARD", gameType = "TOURNAMENT" },
        players = {
            me   = { id = "me",   hand = { { v = 5, s = "S" } } },
            opp1 = { id = "opp1", hand = { { v = 7, s = "H" }, { v = 12, s = "D" }, { v = 3, s = "C" } } },
        },
    } },
})

local opp = (ws.last_game_over_hands or {})["opp1"] or {}
check("GAME_OVER's own hands are kept", #opp, 3)
check("...with the real values", tostring(opp[1] and opp[1].v) .. tostring(opp[1] and opp[1].s), "7H")
check("...and not the placeholder 10 of hearts",
    (opp[2] and opp[2].v == 10 and opp[2].s == "H") and true or false, false)

-- The next round arriving replaces the cached active game — this is the exact
-- substitution that was showing the opponent a hand from a round nobody had
-- played yet. The kept hands must not move with it.
ws.active_game_state = {
    id = "next", players = { opp1 = { id = "opp1", hand = { { v = 1, s = "S" }, { v = 2, s = "S" } } } },
}
local still = (ws.last_game_over_hands or {})["opp1"] or {}
check("a next-round state does not overwrite them", #still, 3)
check("...still the ended round's first card",
    tostring(still[1].v) .. tostring(still[1].s), "7H")

-- And the reveal must not fall back to that cache when its id disagrees with
-- the game that ended — the guard game_flow now applies.
local ended_id, cached_id = "k1", tostring(ws.active_game_state.id)
check("the cached state is recognisably NOT the ended game", cached_id == ended_id, false)

----------------------------------------------------------------------
print("")
print("3. MATCHING THE COUNT, NOT JUST THE VALUES")
-- The reveal overwrote pairwise and stopped at the shorter of the two hands.
-- A cutting card played EARLY ends the round on full hands, which is exactly
-- when the local board and the server are most likely to disagree about how
-- many cards the opponent is holding — so the surplus local cards flipped
-- face-up still showing their placeholder, or real cards were never shown.
--
-- This is the resize rule on its own, in the same shape game_flow applies it.
----------------------------------------------------------------------
local function reveal(local_count, real_hand)
    local hand = {}
    for i = 1, local_count do hand[i] = { v = 10, s = "H", id = "c" .. i } end
    for i = #hand, #real_hand + 1, -1 do table.remove(hand, i) end
    while #hand < #real_hand do hand[#hand + 1] = { v = 10, s = "H", id = "new" } end
    for i, c in ipairs(hand) do
        local r = real_hand[i]
        if r then c.v, c.s = r.v, r.s end
    end
    return hand
end

local real = { { v = 7, s = "H" }, { v = 12, s = "D" }, { v = 3, s = "C" } }

local shown = reveal(5, real)   -- board thinks they hold MORE than they do
check("surplus local cards are dropped", #shown, 3)
local any_placeholder = false
for _, c in ipairs(shown) do if c.v == 10 and c.s == "H" then any_placeholder = true end end
check("no placeholder survives the reveal", any_placeholder, false)

shown = reveal(2, real)         -- board thinks they hold FEWER
check("missing cards are created", #shown, 3)
check("and the last real card is shown", tostring(shown[3].v) .. shown[3].s, "3C")

shown = reveal(3, real)         -- the ordinary agreeing case
check("an agreeing count is untouched", #shown, 3)
check("values still replaced", tostring(shown[1].v) .. shown[1].s, "7H")

----------------------------------------------------------------------
print("")
print("4. THE NEXT-ROUND HOLD IS RELEASED BY EVERY ENDING, NOT JUST ONE")
-- game.script takes the hold the instant GAME_OVER lands, before anyone knows
-- whether a round follows. It was released by exactly one route — the round
-- banner reporting itself finished — which only runs for a CONTINUATION. Every
-- FINAL game over therefore left it set for as long as the player stayed on
-- the screen, and the next game they started was parked instead of built: no
-- GF.start_game, so the game-over dialog was never told to close, the
-- scoreboard never switched mode, and the board appeared only when the 12s
-- backstop fired.
--
-- Driven against the REAL game.script below; the model here states the rule
-- the driven part then has to satisfy.
----------------------------------------------------------------------
local function new_client()
    return { round_transition_busy = false, round_story_active = false,
             _pending_next_state = nil, _pending_next_deadline = nil, built = nil }
end

local function on_game_over(c) c.round_transition_busy = true end
local function next_round_arrives(c, id)
    if c.round_transition_busy or c.round_story_active then
        c._pending_next_state = id
        c._pending_next_deadline = 12.0
    else
        c.built = id
    end
end
local function release(c)
    c.round_transition_busy, c.round_story_active = false, false
    c._pending_next_deadline = nil
    local p = c._pending_next_state
    c._pending_next_state = nil
    if p then c.built = p end
end

-- Continuation: unchanged behaviour, and the one that already worked.
local c = new_client()
on_game_over(c)
next_round_arrives(c, "round2")
check("a next round arriving mid-ending is parked, not built", c.built, nil)
release(c)                                       -- banner finished
check("and built once the ending is done", c.built, "round2")
check("with the hold clear", c.round_transition_busy, false)

-- THE REPORTED CASE: a final game over, then a game started afterwards.
c = new_client()
on_game_over(c)
release(c)                                       -- result shown -> hold released
check("a final game over also releases the hold", c.round_transition_busy, false)
next_round_arrives(c, "rematch")
check("so the next game is built immediately", c.built, "rematch")
check("and nothing is left parked", c._pending_next_state, nil)

-- And without the release, the exact reported symptom: parked, no build, and a
-- 12-second backstop as the only way out.
c = new_client()
on_game_over(c)
next_round_arrives(c, "rematch")
check("unreleased, the next game is parked instead", c.built, nil)
check("waiting on the 12s backstop", c._pending_next_deadline, 12.0)

----------------------------------------------------------------------
print("")
print("5. THE WATCHDOGS THAT WERE SUPPOSED TO GUARANTEE ALL OF THAT")
-- Holding a next round back is only ever safe because something is guaranteed
-- to let it go, and update()'s two watchdogs are the last of those guarantees.
--
-- Neither could run. update() is compiled ABOVE start_new_online_game's `local
-- function`, so its calls to it resolved as GLOBALS — and there is no such
-- global. Every firing was `attempt to call a nil value`, and because the
-- error aborts the rest of update(), the ONLINE GAME-OVER watchdog that runs
-- later in the same function stopped being reached too: once a parked round
-- went past its deadline, that screen never processed another game over.
--
-- Driven against the real file. The parked state is an empty table on purpose:
-- truthy, so the release path calls through in full, and rejected by
-- start_new_online_game's own invalid-state guard, so nothing tries to build a
-- board in a headless harness.
----------------------------------------------------------------------
SIM.load_script_component("game_logic_probe", "main/game.script")
SIM.init_component("game_logic_probe")
local probe = SIM.components["game_logic_probe"]

-- SIM.with_ctx returns whether the frame completed without a Lua error, which
-- is the whole assertion: an erroring update() is a screen that has stopped
-- watching for anything, game overs included.
local function run_frame(st)
    return SIM.with_ctx("game_logic_probe", probe.update, st, 0.05)
end

local st = probe.self
st.online_mode = false             -- skip the online-only half of update()
st._gs_anim_locks = 0

-- A parked round, past its deadline: the parked-round watchdog's exact case.
st.round_story_active = false
st._pending_next_state = {}
st._pending_next_deadline = socket.gettime() - 1
st.round_transition_busy = true

check("update() survives the parked-round watchdog firing", run_frame(st), true)
check("...the hold is cleared", st.round_transition_busy, false)
check("...the state is unparked", st._pending_next_state, nil)
check("...and the deadline goes with it", st._pending_next_deadline, nil)

-- The round-story watchdog, the other one that errored, on the same file.
st.round_story_active = true
st.round_story_deadline = socket.gettime() - 1
st._pending_next_state = {}
st._pending_next_deadline = socket.gettime() + 12
st.round_transition_busy = true

check("update() survives the round-story watchdog firing", run_frame(st), true)
check("...and it releases BOTH flags, not just its own",
    (st.round_story_active == false and st.round_transition_busy == false), true)
check("...so what it unparks cannot be re-parked", st._pending_next_state, nil)

-- And an ordinary frame with nothing parked stays quiet.
check("an idle frame is still fine", run_frame(st), true)

----------------------------------------------------------------------
print("")
print(string.format("──── %d checks, %d failed ────", checks, failures))
os.exit(failures == 0 and 0 or 1)
