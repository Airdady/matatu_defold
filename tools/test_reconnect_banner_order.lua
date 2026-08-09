-- A RECONNECT DESERVES THE SAME RESYNC AN ORDINARY MOVE GETS.
--
--   Run: lua tools/test_reconnect_banner_order.lua
--
-- Reported, in two parts that turned out to be one bug:
--
--   1. A card played right before a disconnect (or the opponent's, or a
--      partial penalty draw) went missing from BOTH the hand and the played
--      pile after reconnecting — until the NEXT move finally forced a real
--      resync, at which point the missing card reappeared as if freshly
--      drawn from the deck.
--   2. The "OPPONENT DISCONNECTED" banner closed before the board had
--      actually caught up, so the timer/turn indicator visibly jumped a
--      moment later with nothing on screen to explain why.
--
-- Root cause for both: ws_player_rc and ws_net_up (main/game.script) — the
-- two live in-app reconnect paths (the opponent coming back, and THIS
-- client's own socket coming back) — only ever called OnlineHandler.
-- sync_timers, which touches nothing but currentTurn/turnExpiresAt/
-- activePenaltyCount/chosenSuit/pendingMarketDraw on self.game_state. It
-- never touched the actual card objects in self.player_hand,
-- self.played_cards or self.deck. Only handle_single_move (run for an
-- ORDINARY move) ever called the real thing: finalize_state_sync followed
-- by sync_my_hand. A reconnect has exactly as much to catch up on as a move
-- does — a play that settled server-side with the confirmation lost to the
-- drop, several opponent moves, a reshuffle, a penalty draw that was only
-- ever sent as one bundled move once complete (never mid-way) — so it needs
-- the same machinery, not a smaller one.
--
-- Fixed by exposing that same sequence as OnlineHandler.full_resync and
-- having both reconnect paths call it instead of sync_timers directly, with
-- the banner closing only in ITS completion callback — not synchronously
-- assumed-instant, since a reshuffle or a hand catch-up inside it can take
-- over a second.

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

local game_src = slurp("main/game.script")
local game_code = game_src:gsub("%-%-[^\n]*", "")

local function branch_of(code, name, start_from)
    local s = code:find('elseif message_id == hash%("' .. name .. '"%) then', start_from)
    if not s then return nil end
    local e = code:find("elseif message_id ==", s + 1)
    return code:sub(s, e and (e - 1) or nil), s
end

local function check_reconnect_branch(name)
    print("")
    print(name .. ": FULL RESYNC, BANNER CLOSES ONLY WHEN IT COMPLETES")

    local branch = branch_of(game_code, name)
    check(name .. " branch exists", branch ~= nil,
        "a rename would make every assertion below vacuous")
    if not branch then return end

    local resync_pos = branch:find("OnlineHandler%.full_resync%(self, self%.game_state or {}, function%(%)")
    check("calls OnlineHandler.full_resync, not just sync_timers", resync_pos ~= nil,
        "sync_timers alone never touches self.player_hand/self.played_cards/self.deck")
    check("does NOT also call the narrower sync_timers directly",
        branch:find("OnlineHandler%.sync_timers%(self, self%.game_state or {}%)") == nil,
        "would mean the narrow sync still races ahead of the full one")

    local close_pos = branch:find('notify_gui%(self%.gui_hud, "conn_overlay", { show = false }%)')
    check("closes the banner somewhere in this branch", close_pos ~= nil)

    if resync_pos and close_pos then
        check("the close sits INSIDE full_resync's completion callback, not before the call",
            close_pos > resync_pos,
            string.format("resync call at %d, close at %d", resync_pos, close_pos))
    end

    check("gated on online_mode and the game not already being over",
        branch:find("if self%.online_mode and not self%.game_over then") ~= nil,
        "resyncing on a message that arrives after the round ended would touch a dead board")
    check("still closes the banner on the ELSE path (offline mode / game already over)",
        branch:match("else%s*\n%s*notify_gui%(self%.gui_hud, \"conn_overlay\", { show = false }%)") ~= nil,
        "a banner that only closes through full_resync's callback would never close at all outside online play")
end

check_reconnect_branch("ws_player_rc")
check_reconnect_branch("ws_net_up")

-- The mirror image, for contrast: the OPEN call (ws_player_dc, the opponent
-- going offline) is unconditional on there being anything to resync — it is
-- the CLOSE that had to wait, not the open.
print("")
print("OPENING THE BANNER IS NOT PART OF WHAT THIS FIX TOUCHES")
local dc_branch = branch_of(game_code, "ws_player_dc")
check("ws_player_dc still opens it with show = true",
    dc_branch ~= nil and dc_branch:find('notify_gui%(self%.gui_hud, "conn_overlay", {%s*show = true') ~= nil)

-- ---------------------------------------------------------------------------
print("")
print("full_resync ITSELF RUNS THE SAME SEQUENCE AN ORDINARY MOVE GETS")

local oh_src = slurp("modules/online_handler.lua")
local oh_code = oh_src:gsub("%-%-[^\n]*", "")

local fr_start = oh_code:find("function M%.full_resync%(self, state, done%)")
check("M.full_resync is exported", fr_start ~= nil,
    "sync_my_hand is a local function in this module — game.script cannot reach it directly without an export")

if fr_start then
    local fr_end = oh_code:find("\nend\n", fr_start)
    local fr_body = oh_code:sub(fr_start, fr_end)

    check("calls finalize_state_sync (deck + opponent hand + timers)",
        fr_body:find("M%.finalize_state_sync%(self, state, function%(%)") ~= nil)
    check("and THEN sync_my_hand (our own hand), inside its completion callback",
        fr_body:find("sync_my_hand%(self, self%.game_state or state or {}, finish%)") ~= nil,
        "finish (not the raw `done` argument) is what lets full_resync clear its own re-entrancy flag and run a coalesced follow-up before the caller's done() fires")

    -- Ordering within the body text itself, not just presence — a version
    -- that called sync_my_hand first (before finalize_state_sync even ran)
    -- would still contain both calls.
    local finalize_pos = fr_body:find("M%.finalize_state_sync")
    local sync_hand_pos = fr_body:find("sync_my_hand%(self,")
    check("finalize_state_sync runs before sync_my_hand, not after",
        finalize_pos ~= nil and sync_hand_pos ~= nil and finalize_pos < sync_hand_pos)
end

check("handle_single_move still exists and full_resync sits right before it",
    (function()
        local hsm_pos = oh_code:find("function M%.handle_single_move")
        return fr_start ~= nil and hsm_pos ~= nil and fr_start < hsm_pos
    end)())

-- ---------------------------------------------------------------------------
print("")
print("full_resync NEVER RACES A MOVE THAT IS ALREADY BEING APPLIED")

-- The full function body this time, not just the run() sub-function — up to
-- the next top-level function is the boundary.
local hsm_pos = oh_code:find("function M%.handle_single_move")
local fr_full = (fr_start and hsm_pos) and oh_code:sub(fr_start, hsm_pos - 1) or ""

check("checks self.is_processing_move before running immediately",
    fr_full:find("if not self%.is_processing_move then%s*\n%s*run%(%)") ~= nil,
    "handle_single_move holds this flag for its whole apply (pump_move_queue) — a reconnect landing mid-apply must not start a second, concurrent finalize_state_sync racing the first over self.ai_hand/self.player_hand")

check("defers via timer.delay when a move IS in flight, rather than running anyway",
    fr_full:find("timer%.delay%(RESYNC_WAIT_POLL_S, false, poll%)") ~= nil)

check("the poll re-checks is_processing_move each time, not just once",
    fr_full:find("if self%.game_over or not self%.is_processing_move or waited >= RESYNC_WAIT_CAP_S then") ~= nil)

check("also gives up and runs anyway once self.game_over — a dead board is not worth waiting on",
    fr_full:find("self%.game_over or not self%.is_processing_move") ~= nil)

check("the wait is CAPPED, not indefinite",
    fr_full:find("waited >= RESYNC_WAIT_CAP_S") ~= nil and fr_full:find("waited = waited %+ RESYNC_WAIT_POLL_S") ~= nil,
    "the flag WILL eventually clear on its own (the move finishes, or the stall watchdog forces it), but a coordinated wait must still not be able to poll forever if the game object is torn down while pending")

-- ---------------------------------------------------------------------------
print("")
print("full_resync NEVER RACES ITSELF EITHER — ws_net_up and ws_player_rc both")
print("fire for the SAME reconnect episode, moments apart")

check("a call while one is already running does not start a second, concurrent run",
    fr_full:find("if self%._resyncing then") ~= nil,
    "ws_net_up (this client's own socket reconnecting) and ws_player_rc (PLAYER_RECONNECTED, sent to the reconnecting client about itself — see heartbeatCleanup.ts) both call full_resync for one reconnect; nothing upstream serializes them")

check("it is stashed as PENDING, not dropped, so the newer state still lands",
    fr_full:find("self%._pending_resync = { state = state, done = done }") ~= nil,
    "dropping the second call outright would mean a reconnect that raced could miss catching up on whatever changed between the two")

check("the guard is set to true before the wait/run path, not after",
    (function()
        local guard_pos = fr_full:find("self%._resyncing = true")
        local run_call_pos = fr_full:find("run%(%)")
        return guard_pos ~= nil and run_call_pos ~= nil and guard_pos < run_call_pos
    end)(),
    "setting the flag after run() could already start means a second call arriving during the is_processing_move wait would race in anyway")

check("finish() clears the flag and replays exactly the LATEST pending state, not the one it just ran",
    fr_full:find("M%.full_resync%(self, pending%.state, pending%.done%)") ~= nil,
    "coalesced to latest rather than queued — a second call mid-run means the first run's target is already stale")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
