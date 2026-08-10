-- A WARM RECONNECT REFRESHES BOOKKEEPING ONLY — IT DOES NOT RECONCILE CARDS.
--
--   Run: lua tools/test_reconnect_banner_order.lua
--
-- History, in three reported bugs that were each fixed in turn:
--
--   1. A card played right before a disconnect (or the opponent's, or a
--      partial penalty draw) went missing from BOTH the hand and the played
--      pile after reconnecting — until the NEXT move finally forced a real
--      resync, at which point the missing card reappeared as if freshly
--      drawn from the deck.
--   2. The "OPPONENT DISCONNECTED" banner closed before the board had
--      actually caught up, so the timer/turn indicator visibly jumped a
--      moment later with nothing on screen to explain why.
--   3. The banner sometimes never closed at all: ordinary MOVE messages
--      (an AI takeover playing out the disconnected opponent's turns) kept
--      landing and visibly updating the board while the banner just sat
--      there.
--
-- (1) and (2) were fixed by having ws_player_rc/ws_net_up (main/game.script)
-- call OnlineHandler.full_resync — the same finalize_state_sync + sync_my_hand
-- sequence an ordinary move gets — instead of the narrower OnlineHandler.
-- sync_timers (currentTurn/turnExpiresAt/activePenaltyCount/chosenSuit/
-- pendingMarketDraw only, never the actual card objects). (3) was fixed by
-- moving the banner close OUT of full_resync's completion callback so it can
-- never be starved by a resync that runs long or gets coalesced.
--
-- That full_resync-on-reconnect fix then caused a FOURTH bug: cards from an
-- already-completed combo visibly "drawn back" from the deck, and a spurious
-- reshuffle animation, right after reconnecting. Root cause: full_resync's
-- own reconciliation (sync_my_hand's multiset diff, stamp_deck, the
-- should_reshuffle heuristic) is comparing against whatever the reconnecting
-- client's LOCAL state happens to be — and that comparison itself is what
-- produced the visible artifacts, independent of whether the underlying data
-- was ever actually wrong.
--
-- Fixed by migrating the reference client's approach (matatu-gdt's
-- CardManager.gd, _on_game_start_received): a WARM reconnect — the same game
-- still on screen, cards still in hand, nothing torn down — only refreshes
-- game_state and the turn timer (OnlineHandler.sync_timers) and leaves the
-- hand/deck/pile alone. The game continues naturally from whatever the next
-- real MOVE brings; a move that never reached the server before the drop is
-- covered by retry_unconfirmed_move, not by reconciling the whole board.
-- full_resync itself is untouched and still runs for a genuine COLD load
-- (main/game.script's ws_resync branch, and M.start_game) — this file no
-- longer claims the reconnect branches use it.

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
    print(name .. ": BANNER CLOSES IMMEDIATELY, BOOKKEEPING-ONLY REFRESH")

    local branch = branch_of(game_code, name)
    check(name .. " branch exists", branch ~= nil,
        "a rename would make every assertion below vacuous")
    if not branch then return end

    check("does NOT call OnlineHandler.full_resync",
        branch:find("OnlineHandler%.full_resync") == nil,
        "a warm reconnect must not reconcile the hand/deck/pile — see the file header for why that produced its own bugs")

    local sync_pos = branch:find("OnlineHandler%.sync_timers%(self, self%.game_state or {}%)")
    check("calls OnlineHandler.sync_timers instead", sync_pos ~= nil,
        "the bookkeeping-only refresh (currentTurn/turnExpiresAt/activePenaltyCount/chosenSuit/pendingMarketDraw) is all a warm reconnect needs")

    local close_pos = branch:find('notify_gui%(self%.gui_hud, "conn_overlay", { show = false }%)')
    check("closes the banner somewhere in this branch", close_pos ~= nil)

    local online_gate_pos = branch:find("if self%.online_mode and not self%.game_over then")
    check("gated on online_mode and the game not already being over",
        online_gate_pos ~= nil,
        "resyncing on a message that arrives after the round ended would touch a dead board")

    -- The wording here used to be "UNCONDITIONALLY", which stopped being true
    -- once ws_player_rc's close was put behind `if dismiss then` (see the
    -- section further down — whose reconnect this is gets its own checks
    -- there). What both branches still guarantee is the thing that actually
    -- matters: the close does not sit inside the SAME online_mode/game_over
    -- gate as the bookkeeping refresh below it.
    if close_pos and online_gate_pos then
        check("the close sits BEFORE the online_mode/game_over gate, not inside it",
            close_pos < online_gate_pos,
            "a close that only ran inside the same gate as sync_timers could be left stuck open by exactly the condition that was supposed to make it a no-op")
    end

    if sync_pos then
        local retry_pos = branch:find("OnlineHandler%.retry_unconfirmed_move%(self%)", sync_pos)
        check("retry_unconfirmed_move runs AFTER sync_timers, using its fresh currentTurn",
            retry_pos ~= nil and retry_pos > sync_pos,
            "retry_unconfirmed_move's own guard reads self.game_state.currentTurn, which sync_timers is what refreshes")
    end
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
print("full_resync STILL EXISTS AND STILL RUNS THE SAME SEQUENCE AN ORDINARY MOVE GETS")
print("(used by ws_resync and M.start_game — a genuine cold load/explicit resync,")
print("not the warm-reconnect branches checked above)")

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

check("ws_resync (an explicit server-forced resync, not a plain reconnect) still calls full_resync",
    game_code:find("OnlineHandler%.full_resync%(self, fresh%)") ~= nil,
    "a server-forced resync is a different situation from a warm reconnect and still needs the deep catch-up")

-- ---------------------------------------------------------------------------
print("")
print("full_resync NEVER RACES A MOVE THAT IS ALREADY BEING APPLIED")

-- The full function body this time, not just the run() sub-function — up to
-- the next top-level function is the boundary.
local hsm_pos = oh_code:find("function M%.handle_single_move")
local fr_full = (fr_start and hsm_pos) and oh_code:sub(fr_start, hsm_pos - 1) or ""

check("checks self.is_processing_move before running immediately",
    fr_full:find("if not self%.is_processing_move then%s*\n%s*run%(%)") ~= nil,
    "handle_single_move holds this flag for its whole apply (pump_move_queue) — a resync landing mid-apply must not start a second, concurrent finalize_state_sync racing the first over self.ai_hand/self.player_hand")

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
print("full_resync NEVER RACES ITSELF EITHER")

check("a call while one is already running does not start a second, concurrent run",
    fr_full:find("if self%._resyncing then") ~= nil,
    "more than one caller can still reach full_resync in the same window (ws_resync, M.start_game) — nothing upstream serializes them")

check("it is stashed as PENDING, not dropped, so the newer state still lands",
    fr_full:find("self%._pending_resync = { state = state, done = done }") ~= nil,
    "dropping the second call outright would mean a resync that raced could miss catching up on whatever changed between the two")

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

-- ---------------------------------------------------------------------------
-- AND THEN: A BANNER ABOUT THE WRONG PLAYER, RAISED BY THE PLAYER THEMSELVES.
--
-- Reported after the close-immediately fix above: the opponent disconnects,
-- comes back, and the dialog stays up anyway. Two separate causes, one on
-- each side of the socket.
--
-- CLIENT: websocket_manager's PLAYER_RECONNECTED branch read the id out of
-- d._id / d.playerId / d.userId. The backend sends none of those — it sends
-- data.reconnectedPlayer (heartbeatCleanup.ts). So player_id was the empty
-- string on every single reconnect. The DISCONNECTED branch right above it
-- had already been corrected for the matching d.disconnectedPlayer; this one
-- was simply missed, and nothing noticed because game.script did not consult
-- the field.
--
-- Which mattered the moment it did consult it, because both of these messages
-- are broadcast to the WHOLE game, this client included:
--
--   * ws_player_dc firing for our OWN id shows us "OPPONENT DISCONNECTED"
--     about ourselves, and no PLAYER_RECONNECTED will ever contradict it
--   * ws_player_rc firing for our own id, while the opponent is still away,
--     would close a banner that is still true — and nothing raises it again
--
-- So the banner is driven off the game state the message carries. The server
-- builds that with getAccurateGameState, which re-checks every seat against
-- its real socket before sending, making it the authority on who is actually
-- present. The id is the fallback, and dismissing is the fallback to that, so
-- a message carrying neither behaves exactly as it did before.
print("")
print("THE BANNER FOLLOWS THE OPPONENT, NOT WHOEVER THE MESSAGE IS ABOUT")

local rc_branch = branch_of(game_code, "ws_player_rc")
check("ws_player_rc reads the reconnecting player's id", 
    rc_branch ~= nil and rc_branch:find("local rc_who") ~= nil)
check("and prefers the opponent's status from the state the message carried",
    rc_branch ~= nil and rc_branch:find('opp_status ~= ""') ~= nil
        and rc_branch:find('dismiss = %(opp_status ~= "DISCONNECTED"%)') ~= nil,
    "getAccurateGameState re-verifies every seat server-side, so it beats guessing from the id")
check("falling back to the id when the state carries no seat for the opponent",
    rc_branch ~= nil and rc_branch:find("dismiss = %(rc_who ~= tostring%(self%.my_player_id%)%)") ~= nil)
check("and falling back to dismissing when it has neither",
    rc_branch ~= nil and rc_branch:find("else%s*\n%s*dismiss = true") ~= nil,
    "a message with no id and no state must not become a NEW way for the banner to stick")
check("the close is gated on that decision",
    rc_branch ~= nil and rc_branch:find("if dismiss then") ~= nil
        and rc_branch:find("if dismiss then") < rc_branch:find('notify_gui%(self%.gui_hud, "conn_overlay", { show = false }%)'))
check("and _opp_dc_grace_active is cleared with it, not separately",
    rc_branch ~= nil and (function()
        local gate = rc_branch:find("if dismiss then")
        local flag = rc_branch:find("self%._opp_dc_grace_active = false")
        return gate ~= nil and flag ~= nil and flag > gate
    end)(),
    "leaving the flag set while the overlay is gone re-locks input from update()'s watchdog")

check("ws_player_dc does NOT raise the banner for this client's own id",
    dc_branch ~= nil and dc_branch:find("dc_is_me") ~= nil
        and dc_branch:find("not dc_is_me") ~= nil,
    "PLAYER_DISCONNECTED is broadcast to the whole game — including the player it names")
check("and an empty id still raises it, as before",
    dc_branch ~= nil and dc_branch:find('dc_who ~= "" and dc_who == tostring%(self%.my_player_id%)') ~= nil,
    "is_me must require a NON-empty id, or a message without one suppresses the banner entirely")

-- ---------------------------------------------------------------------------
print("")
print("THE FIELD THE BACKEND ACTUALLY SENDS")

local wsm_src = slurp("modules/websocket_manager.lua")
local wsm_code = wsm_src:gsub("%-%-[^\n]*", "")

local rc_msg = wsm_code:match('elseif t == "PLAYER_RECONNECTED" then(.-)elseif t ==')
check("PLAYER_RECONNECTED reads d.reconnectedPlayer", 
    rc_msg ~= nil and rc_msg:find("d%.reconnectedPlayer") ~= nil,
    "this is the field heartbeatCleanup.ts sends; without it player_id is always the empty string")
check("and reads it FIRST, ahead of the names that are not on this message",
    rc_msg ~= nil and (function()
        local a = rc_msg:find("d%.reconnectedPlayer")
        local b = rc_msg:find("d%._id")
        return a ~= nil and (b == nil or a < b)
    end)())

local dc_msg = wsm_code:match('elseif t == "PLAYER_DISCONNECTED" then(.-)elseif t ==')
check("PLAYER_DISCONNECTED still reads d.disconnectedPlayer first",
    dc_msg ~= nil and dc_msg:find("d%.disconnectedPlayer") ~= nil)

-- ---------------------------------------------------------------------------
-- The logs are the point of the exercise, not decoration: the whole reason
-- this took two rounds to find is that nothing said which of these messages
-- arrived, for whom, or what was decided about the banner.
print("")
print("AND IT SAYS WHAT IT DECIDED, SO THE NEXT REPORT IS ONE LOG AWAY")

check("PLAYER_RECONNECTED logs the id it resolved",
    rc_msg ~= nil and rc_msg:find("%[RECONNECT%]") ~= nil)
check("PLAYER_DISCONNECTED logs the id it resolved",
    dc_msg ~= nil and dc_msg:find("%[RECONNECT%]") ~= nil)
check("ws_player_rc logs whose reconnect it was and what it did with the banner",
    rc_branch ~= nil and rc_branch:find("%[RECONNECT%]") ~= nil
        and rc_branch:find("DISMISS banner") ~= nil and rc_branch:find("keep banner") ~= nil)
check("ws_player_dc logs whose disconnect it was",
    dc_branch ~= nil and dc_branch:find("%[RECONNECT%]") ~= nil)

print("")
if failures == 0 then print("ALL PASS") else print(failures .. " FAILURE(S)") end
os.exit(failures == 0 and 0 or 1)
