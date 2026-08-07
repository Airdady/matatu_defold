-- THE "OPPONENT DISCONNECTED" BANNER MUST OUTLIVE THE RESYNC IT IS WAITING ON.
--
--   Run: lua tools/test_reconnect_banner_order.lua
--
-- Reported: closing the banner and catching the board up on what happened
-- while the opponent was gone were in the wrong order. ws_player_rc (main/
-- game.script) used to close the "OPPONENT DISCONNECTED / Waiting for them
-- to reconnect…" overlay FIRST and only THEN apply the fresh state
-- (self.game_state = fresh; OnlineHandler.sync_timers(...)) — so there was a
-- beat where the banner was gone but the board still showed the stale
-- pre-disconnect turn/timer, which then visibly jumped a moment later with
-- nothing on screen to explain why. The fix is purely an ordering one:
-- sync_timers is synchronous (plain field assignment plus a couple of
-- msg.post("turn", ...) calls, no animation or deferred step), so applying
-- the resync BEFORE closing the banner removes the gap entirely rather than
-- just narrowing it.

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

local src = slurp("main/game.script")
local code = src:gsub("%-%-[^\n]*", "") -- comments stripped, same convention as the other wiring tests

-- Isolate the ws_player_rc branch: from its own `elseif` to the next one.
local branch_start = code:find('elseif message_id == hash%("ws_player_rc"%) then')
check("the ws_player_rc branch exists", branch_start ~= nil,
    "a rename would make every assertion below vacuous")

if branch_start then
    local branch_end = code:find("elseif message_id ==", branch_start + 1)
    local branch = code:sub(branch_start, branch_end and (branch_end - 1) or nil)

    print("")
    print("THE RESYNC IS APPLIED BEFORE THE BANNER CLOSES")

    local sync_pos = branch:find("OnlineHandler%.sync_timers%(self, self%.game_state or {}%)")
    local close_pos = branch:find('notify_gui%(self%.gui_hud, "conn_overlay", { show = false }%)')

    check("sync_timers is called in this branch", sync_pos ~= nil)
    check("the banner is closed in this branch", close_pos ~= nil)
    if sync_pos and close_pos then
        check("sync_timers runs BEFORE the banner closes, not after",
            sync_pos < close_pos,
            string.format("sync at %d, close at %d — the player sees the banner vanish before the board catches up", sync_pos, close_pos))
    end

    -- The fresh-state assignment itself (self.game_state = fresh) must also
    -- land before the close — sync_timers reads self.game_state, so getting
    -- the CALL order right but the ASSIGNMENT order wrong would still resync
    -- against stale data before the banner disappears.
    local assign_pos = branch:find("self%.game_state = fresh")
    check("the fresh state is assigned before sync_timers uses it",
        assign_pos ~= nil and sync_pos ~= nil and assign_pos < sync_pos)

    print("")
    print("AND ONLY WHEN THERE IS SOMETHING TO RESYNC")
    check("gated on online_mode and the game not already being over",
        branch:find("if self%.online_mode and not self%.game_over then") ~= nil,
        "resyncing/closing on a message that arrives after the round ended would touch a dead board")
end

-- The mirror image, for contrast: the OPEN call (ws_player_dc, the opponent
-- going offline) is unconditional on there being a fresh state to apply —
-- it is the CLOSE that had to wait, not the open.
print("")
print("OPENING THE BANNER IS NOT PART OF WHAT THIS FIX TOUCHES")
local dc_start = code:find('elseif message_id == hash%("ws_player_dc"%) then')
check("ws_player_dc still opens it with show = true", dc_start ~= nil and (function()
    local dc_end = code:find("elseif message_id ==", dc_start + 1)
    local dc_branch = code:sub(dc_start, dc_end and (dc_end - 1) or nil)
    return dc_branch:find('notify_gui%(self%.gui_hud, "conn_overlay", {%s*show = true') ~= nil
end)())

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
