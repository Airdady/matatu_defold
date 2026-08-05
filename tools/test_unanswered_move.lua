-- THE BOARD THAT FREEZES UNTIL YOU RESTART THE APP.
--
--   Run: lua tools/test_unanswered_move.lua
--
-- Reported as: the opponent played 8 of clubs and 3 of clubs, and after that no
-- card could be picked at all — until the app was restarted.
--
-- THE CHAIN, IN ORDER
--
--   1. 8C is a skip and 3C is a penalty, so the combo hands the player a
--      THREE-CARD PENALTY. Drawing it is the only legal move there is.
--   2. The player draws three, and online_handler.end_turn sends the move and
--      sets is_waiting_for_server_response.
--   3. The server cannot satisfy the draw and answers with a bare ERROR:
--
--        if (!drawResult.success) {
--          if (ws) ws.send({ ERROR: 'Sync Error: Deck mismatch' });
--          return;      // no state, no broadcast, no turn change
--        }
--
--   4. Nothing in the client subscribed to that `error` event, so it was
--      emitted into nothing.
--   5. is_waiting_for_server_response is cleared in exactly ONE place —
--      finalize_state_sync, i.e. when a state arrives. None ever does.
--
-- AND THAT ONE FLAG IS A TERM IN EVERY OTHER WATCHDOG THE BOARD HAS:
--
--   reconcile_input_locks .... counts it as server_busy and returns early
--   the `waiting` watchdog ... gated on `not is_waiting_for_server_response`
--   stale_draw_flag .......... lives inside that same gated block
--   the lock watchdog ........ gated on it too
--
-- So one stuck flag disables all four at once. The `now_my_turn` edge cannot
-- save it either: the server never moved the turn, so is_player_turn() never
-- went false and there is no false->true edge to observe. Nothing was left but
-- restarting the app — which is exactly what was reported.
--
-- Note what this is NOT: the earlier fix (tools/test_move_stall.lua) was for
-- taps getting through TOO EARLY. This is the opposite failure and shares no
-- code with it.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local TL = require("modules.turn_locks")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end
local function check_truthy(label, got)
    local ok = got and true or false
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s)", ok and "PASS" or "FAIL", label, tostring(got)))
end

local function run(t, frames, dt, awaiting)
    for i = 1, frames do
        local r = TL.track_server_answer(t, { awaiting = awaiting }, dt)
        if r then return r, i end
    end
    return nil
end

print("a normal round trip is never disturbed")
do
    -- A slow mobile round trip is well under two seconds. The board must not
    -- start second-guessing the server inside a normal wait.
    local t = TL.new_answer_tracker()
    local r = run(t, 120, 1 / 60, true)          -- 2s
    check("two seconds of waiting is fine", r, nil)
    -- the answer arrives
    TL.track_server_answer(t, { awaiting = false }, 1 / 60)
    check("and the clock resets when it does", t.waited, 0)
end

print("")
print("but a move that is never answered stops holding the board")
do
    local t = TL.new_answer_tracker()
    local r, frame = run(t, 1200, 1 / 60, true)
    check_truthy("the wait is eventually declared overdue", r)
    check("and it says how long we waited", r and r:match("no answer") ~= nil, true)
    check("at about the configured deadline", frame ~= nil and frame >= 599 and frame <= 602, true)
end

print("")
print("and it recovers ONCE, not every frame")
do
    -- Recovery re-applies the server's state and resets the turn locks. Doing
    -- that sixty times a second because the answer is still missing would be
    -- its own kind of frozen board.
    local t = TL.new_answer_tracker()
    run(t, 601, 1 / 60, true)                    -- fires here
    local again = run(t, 1200, 1 / 60, true)     -- twenty more seconds
    check("it does not fire a second time", again, nil)
end

print("")
print("and the next move gets a clean deadline")
do
    local t = TL.new_answer_tracker()
    run(t, 601, 1 / 60, true)                    -- fired
    TL.track_server_answer(t, { awaiting = false }, 1 / 60)
    check("clearing the flag resets the clock", t.waited, 0)
    check("and re-arms it", t.fired, false)
    local r = run(t, 120, 1 / 60, true)
    check("so the next move is not judged by the last one's wait", r, nil)
end

print("")
print("nothing is measured when no move is outstanding")
do
    local t = TL.new_answer_tracker()
    local r = run(t, 3000, 1 / 60, false)
    check("an idle board never fires", r, nil)
    check("and the clock stays at zero", t.waited, 0)
end

print("")
print("the board is actually wired to it, and the locks are released")
do
    local here = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
    local function read(rel)
        local f = assert(io.open(here .. "../" .. rel, "r"))
        local s = f:read("*a"); f:close()
        -- Comments stripped: this change is explained at length in both files
        -- and those explanations QUOTE the code being asserted absent.
        return (s:gsub("%-%-[^\n]*", ""))
    end
    local game = read("main/game.script")
    local online = read("modules/online_handler.lua")

    check("the flag now has a watchdog of its own",
        game:match("TL%.track_server_answer") ~= nil, true)

    -- Releasing is_waiting_for_server_response alone is not enough: the three
    -- watchdogs it was blocking each need another 3.5s to notice, and
    -- reconcile_input_locks only runs on a tap. Cleared together.
    local blk = game:match("if overdue then.-\n        end")
    check_truthy("the overdue branch exists", blk)
    for _, flag in ipairs({
        "is_waiting_for_server_response", "player_has_drawn",
        "is_local_action_locked", "waiting",
    }) do
        check("it releases " .. flag, blk and blk:match(flag .. " = false") ~= nil, true)
    end

    -- A move the server may never have accepted must not be re-sent: end_turn
    -- builds its payload from current_turn_actions, so a stale list replays
    -- cards that are already on the pile.
    check("and drops the unsent action list",
        blk and blk:match("current_turn_actions = {}") ~= nil, true)
    check("then rebuilds from the server's own state",
        blk and blk:match("rebuild_from_server") ~= nil, true)

    -- Ten seconds is the backstop. An ERROR frame IS the answer, and it
    -- arrives in milliseconds.
    check("the client now subscribes to the server's ERROR frames",
        online:match('ws%.on%("error"') ~= nil, true)
    check("and the board handles it",
        game:match('hash%("ws_server_error"%)') ~= nil, true)
    local err = game:match('hash%("ws_server_error"%).-\n        end')
    check_truthy("the handler exists", err)
    check("which only acts when a move is actually outstanding",
        err and err:match("if self%.is_waiting_for_server_response then") ~= nil, true)
    check("and recovers the same way",
        err and err:match("rebuild_from_server") ~= nil, true)
end

print("")
if failures == 0 then
    print("ALL PASSED")
else
    print(failures .. " FAILED")
    os.exit(1)
end
