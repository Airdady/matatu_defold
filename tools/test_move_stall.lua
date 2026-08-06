-- TAPS THAT GET THROUGH WHILE THE OPPONENT'S CARDS ARE STILL ARRIVING.
--
--   Run: lua tools/test_move_stall.lua
--
-- Reported as: on a slow connection the opponent's cards take a while to come
-- in, and DURING that delay the player can tap their own cards and the taps go
-- out as a move.
--
-- WHAT WAS ACTUALLY HAPPENING
--
-- is_processing_move is the flag that refuses those taps (game.script's
-- on_input returns early on it). update() carried a watchdog that cleared it:
--
--     if #self.move_queue == 0 then
--         if self.is_processing_move then
--             self.stuck_count = self.stuck_count + dt
--             if self.stuck_count > 3.5 then self.is_processing_move = false end
--
-- BOTH of its conditions hold throughout a perfectly healthy move.
-- pump_move_queue takes the item OFF the queue before processing it, so the
-- queue is empty for the entire apply; and the apply genuinely takes seconds —
-- process_opponent_actions waits 0.24s between combo plays and 0.42s to settle,
-- a penalty draws five cards at 0.13s each, and finalize_state_sync can run a
-- 1.3s reshuffle on top of all of it. The watchdog was not detecting a stuck
-- pipeline. It was putting a stopwatch on a slow one and calling time.
--
-- And it does not only open the tap gate. By the time it fires,
-- finalize_state_sync has already assigned self.game_state (so is_player_turn()
-- is true) and cleared is_waiting_for_server_response — so
-- reconcile_input_locks releases `waiting` and is_local_action_locked too. The
-- tap is then judged by evaluate_play against a pile that has not finished
-- being built, and sent.
--
-- A STOPWATCH CANNOT TELL SLOW FROM STUCK. PROGRESS CAN: an apply that is
-- running changes the board every fraction of a second, and one that has died
-- changes nothing at all. These drive the real modules/turn_locks.lua.

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

-- A board whose counts we can move by hand, one frame at a time.
local Board = {}
Board.__index = Board
local function board(over)
    over = over or {}
    return setmetatable({
        player_hand = over.player_hand or 7,
        ai_hand = over.ai_hand or 7,
        played = over.played or 1,
        deck = over.deck or 30,
        anim_locks = over.anim_locks or 0,
        queue = over.queue or 0,
    }, Board)
end
function Board:sig() return TL.board_signature(self) end

--- Run `frames` frames at `dt`, calling `step(i, b)` before each one so a test
--- can move the board. Returns the first stall reason seen, or nil.
local function run(t, b, frames, dt, step, processing)
    if processing == nil then processing = true end
    for i = 1, frames do
        if step then step(i, b) end
        local r = TL.track_processing(t, { is_processing = processing, signature = b:sig() }, dt)
        if r then return r, i end
    end
    return nil
end

print("a move that is being applied is never called stuck")
do
    -- The exact shape of the report: a five-card opponent combo plus a draw
    -- batch, ten seconds of wall clock, with the board changing throughout.
    -- The old watchdog fired at 3.5s of this.
    local t = TL.new_stall_tracker()
    local b = board()
    local r = run(t, b, 600, 1 / 60, function(i)
        -- Something moves roughly every third of a second, which is faster
        -- than any real gap in process_opponent_actions.
        if i % 20 == 0 then
            b.anim_locks = (b.anim_locks + 1) % 3
            b.played = b.played + 1
        end
    end)
    check("ten seconds of visible progress is not a stall", r, nil)
end

print("")
print("the quiet beats inside a healthy apply are survived")
do
    -- process_opponent_actions' longest silence is SETTLE, 0.42s, and
    -- finalize_state_sync's reshuffle holds an animation lock for ~1.3s. Both
    -- are far short of the limit — but only because the limit now measures
    -- SILENCE rather than elapsed time.
    local t = TL.new_stall_tracker()
    local b = board()
    -- 1.3 seconds with nothing changing at all.
    local r = run(t, b, 78, 1 / 60, nil)
    check("a 1.3s reshuffle beat is not a stall", r, nil)
    -- then the reshuffle lands and the board moves again
    b.deck = b.deck + 20
    b.played = 1
    r = run(t, b, 1, 1 / 60, nil)
    check("and the apply continues", r, nil)
    check("the clock went back to zero on the change", t.since_progress, 0)
end

print("")
print("a genuinely dead apply is still caught")
do
    local t = TL.new_stall_tracker()
    local b = board()
    local r, frame = run(t, b, 600, 1 / 60, nil)
    check_truthy("silence eventually reports a stall", r)
    check("and it says how long", r and r:match("no change") ~= nil, true)
    -- 3.5s at 60fps
    check("at about the configured limit", frame ~= nil and frame >= 209 and frame <= 212, true)
end

print("")
print("and one that spins forever is caught by the ceiling")
do
    -- The freeze the original watchdog was written for is real: a pipeline can
    -- wedge while still ticking an animation counter, so "the board changed"
    -- alone must not be a licence to run indefinitely.
    local t = TL.new_stall_tracker()
    local b = board()
    local r, frame = run(t, b, 2000, 1 / 60, function(i)
        b.anim_locks = (b.anim_locks + 1) % 4   -- always moving, never finishing
    end)
    check_truthy("a permanently busy apply is still abandoned", r)
    check("by the ceiling, not the silence rule", r and r:match("still applying") ~= nil, true)
    check("at about the ceiling", frame ~= nil and frame >= 899 and frame <= 902, true)
end

print("")
print("nothing is measured when no move is being applied")
do
    local t = TL.new_stall_tracker()
    local b = board()
    local r = run(t, b, 3000, 1 / 60, nil, false)
    check("an idle board never stalls", r, nil)
    check("and the clock stays at zero", t.since_start, 0)
end

print("")
print("the tracker resets between moves")
do
    local t = TL.new_stall_tracker()
    local b = board()
    -- Most of the way to a stall...
    run(t, b, 180, 1 / 60, nil)
    check_truthy("time has accumulated", t.since_progress > 2.9)
    -- ...the move finishes...
    TL.track_processing(t, { is_processing = false, signature = b:sig() }, 1 / 60)
    check("finishing clears the silence clock", t.since_progress, 0)
    check("and the elapsed clock", t.since_start, 0)
    -- ...and the next one gets a full budget rather than the leftovers.
    local r = run(t, b, 180, 1 / 60, nil)
    check("so the next move is not stalled by the last one's time", r, nil)
end

print("")
print("the signature notices every kind of progress")
do
    local base = board():sig()
    for _, field in ipairs({ "player_hand", "ai_hand", "played", "deck", "anim_locks", "queue" }) do
        local b = board()
        b[field] = b[field] + 1
        check("a change in " .. field .. " is visible", b:sig() ~= base, true)
    end
    -- Identical boards must compare equal, or every frame looks like progress
    -- and nothing is ever caught.
    check("and two identical boards agree", board():sig(), base)
end

print("")
print("and the board is actually wired to it")
do
    local here = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
    local function read(rel)
        local f = assert(io.open(here .. "../" .. rel, "r"))
        local s = f:read("*a"); f:close()
        -- Comments stripped: this change is explained at length in both files,
        -- and those explanations QUOTE the code being asserted absent.
        return (s:gsub("%-%-[^\n]*", ""))
    end
    local game = read("main/game.script")
    local online = read("modules/online_handler.lua")

    check("the stopwatch watchdog is gone",
        game:match("stuck_count") ~= nil, false)
    check("and the progress tracker replaces it",
        game:match("TL%.track_processing") ~= nil, true)
    check("fed the board's own counts",
        game:match("TL%.board_signature") ~= nil, true)
    check("including the animation locks, which move fastest of all",
        game:match("anim_locks = self%._gs_anim_locks") ~= nil, true)

    -- An apply that DIED left the board part-built. Reopening input onto a
    -- half-drawn hand and half-built pile is the same bug wearing a hat.
    check("a real stall resyncs the board before input reopens",
        game:match("OnlineHandler%.finalize_state_sync%(self, latest") ~= nil, true)
    check("and says why, with the number",
        game:match("Incoming move abandoned") ~= nil, true)

    -- sync_my_hand LAUNCHES draw_to_hand and returns; releasing the lock on
    -- the next line let taps through while the player's own new cards were
    -- still flying in.
    --
    -- Reconciles against self.game_state now, not the closure-captured
    -- new_state — the same staleness fix settle() already had (a newer move
    -- can overwrite self.game_state while this chain is still unwinding
    -- behind process_opponent_actions' animations and finalize_state_sync's
    -- own possible reshuffle wait; reconciling against a stale new_state
    -- meant a card the player had since played could get added right back).
    -- new_state stays as the fallback for the one real gap: no
    -- self.game_state has ever been set.
    check("the apply ends when the player's hand has finished arriving",
        online:match("sync_my_hand%(self, self%.game_state or new_state or {}, done%)") ~= nil, true)
    check("and never one line early",
        online:match("sync_my_hand%(self, self%.game_state or new_state or {}%)%s*\n%s*done%(%)") ~= nil, false)
end

print("")
if failures == 0 then
    print("ALL PASSED")
else
    print(failures .. " FAILED")
    os.exit(1)
end
