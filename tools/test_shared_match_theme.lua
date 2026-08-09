-- THE MATCH'S THEME IS SHARED, NOT EACH PLAYER'S OWN LOCAL PICK.
--
--   Run: lua tools/test_shared_match_theme.lua
--
-- The server resolves which of the two players' active themes is worth
-- showing off (cardUtils.ts's selectWinningTheme — higher price wins) and
-- puts the plain id on GameState.theme (see the be_matatu companion commit).
-- This checks the client actually applies it, restores the player's OWN
-- theme on leaving the game, and that a theme switch mid-session is
-- reflected in the cached user object a restore reads from — without which
-- the restore silently reverts to whatever was active BEFORE the switch.

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

print("APPLYING THE MATCH THEME (modules/online_handler.lua)")

local oh_src = slurp("modules/online_handler.lua")
local oh_code = oh_src:gsub("%-%-[^\n]*", "")

check("requires app_state", oh_code:find('require "modules%.app_state"') ~= nil)

local sg_start = oh_code:find("function M%.start_game%(self, state%)")
check("M.start_game exists", sg_start ~= nil, "a rename would make every assertion below vacuous")

if sg_start then
    local sg_end = oh_code:find("\nfunction M%.", sg_start + 1)
    local sg_body = oh_code:sub(sg_start, sg_end and (sg_end - 1) or nil)

    check("reads state.theme", sg_body:find("local match_theme = state and state%.theme") ~= nil)
    check("applies it to the SHARED app_state.theme, not a per-instance copy",
        sg_body:find('app_state%.theme = %(type%(match_theme%) == "string" and match_theme ~= ""%) and match_theme or "default"') ~= nil,
        "a missing/blank theme from an older or offline path must still resolve to a real theme id, not nil/empty")
    check("sits alongside the other unconditional per-call resets, not behind a first-round-only guard",
        sg_body:find("self%.game_state = state") ~= nil and sg_body:find("local match_theme") ~= nil,
        "start_game runs on every round of a series, and the backend re-resolves state.theme every round too (see themePayload.test.ts) — gating this behind a guard would freeze the match at round 1's theme")
end

-- ---------------------------------------------------------------------------
print("")
print("RESTORING THE PLAYER'S OWN THEME ON LEAVING THE GAME (main/game.script)")

local game_src = slurp("main/game.script")
local game_code = game_src:gsub("%-%-[^\n]*", "")

local dis_start = game_code:find('elseif message_id == hash%("disable"%) then')
check("the disable branch exists", dis_start ~= nil)

if dis_start then
    local dis_end = game_code:find("elseif message_id ==", dis_start + 1)
    local dis_branch = game_code:sub(dis_start, dis_end and (dis_end - 1) or nil)

    local destroy_pos = dis_branch:find("GS%.destroy_all%(self%)")
    local restore_pos = dis_branch:find("app%.sync_theme_from_user%(ws%.current_user_data%)")
    check("re-derives the player's own theme on the way out", restore_pos ~= nil)
    check("after the board itself is torn down, not before",
        destroy_pos ~= nil and restore_pos ~= nil and destroy_pos < restore_pos,
        "ordering doesn't affect correctness here, but keeps teardown grouped before the account-derived resets that follow it")
end

-- ---------------------------------------------------------------------------
print("")
print("A SWITCH MID-SESSION UPDATES THE CACHED USER OBJECT (main/controller.script)")

local ctrl_src = slurp("main/controller.script")
local ctrl_code = ctrl_src:gsub("%-%-[^\n]*", "")

local ts_start = ctrl_code:find('elseif message_id == hash%("theme_switch"%) then')
check("the theme_switch branch exists", ts_start ~= nil)

if ts_start then
    local ts_end = ctrl_code:find("elseif message_id ==", ts_start + 1)
    local ts_branch = ctrl_code:sub(ts_start, ts_end and (ts_end - 1) or nil)

    check("still sets the live app_state.theme on success",
        ts_branch:find("app_state%.theme = message%.theme_id") ~= nil)
    check("also updates ws.current_user_data.themes[].active",
        ts_branch:find("t%.active = %(t%.id == message%.theme_id%)") ~= nil,
        "without this, leaving an online match restores whichever theme was active BEFORE this switch — see game.script's disable handler, which reads exactly this cached object")
    check("guarded against themes not being a table yet",
        ts_branch:find("if type%(themes%) == \"table\" then") ~= nil,
        "a fresh account or a payload that predates the themes field must not error out of the whole switch")

    local api_pos = ts_branch:find("api%.switch_theme%(")
    local update_pos = ts_branch:find("t%.active = ")
    check("the cache update happens INSIDE the success callback, not assumed before the server answers",
        api_pos ~= nil and update_pos ~= nil and api_pos < update_pos)
end

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
