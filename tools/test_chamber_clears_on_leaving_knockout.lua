-- THE SCORE-CAP CHAMBER MUST NOT SURVIVE INTO AN UNRELATED GAME.
--
--   Run: lua tools/test_chamber_clears_on_leaving_knockout.lua
--
-- Reported: finish an ONLINE knockout match, then start a Battle (a
-- different match type, with its own different scoreboard layout) — the
-- knockout's score-cap chamber board was still showing over the Battle's
-- board underneath it.
--
-- main/game.gui_script's reset_hud handler already had the right shape for
-- this: `if not (keep_scoreboard and self.t4_chamber) then t4.clear_chamber
-- end` — every reset tears the chamber down UNLESS keep_scoreboard is true
-- (a knockout's own next round, which legitimately wants to keep it). The
-- bug was upstream, in game_flow.lua's M.start_game, which is what decides
-- keep_scoreboard: it was computed ONLY from self.t4 (the OFFLINE
-- elimination-chamber flag), never from whether the game just being left
-- was an ONLINE knockout. For the online path keep_scoreboard was
-- unconditionally true, so the only thing that ever tore an online
-- chamber down was the NEXT online knockout's own chamber re-init
-- overwriting it — never an unrelated game that doesn't touch the chamber
-- at all, like the reported Battle.
--
-- Fixed by computing an online equivalent of leaving_offline_t4:
-- self._is_knockout (online_handler.lua) still holds the JUST-ENDED game's
-- knockout status at this point in M.start_game — OnlineHandler.start_game,
-- a few lines below, is what overwrites it for the INCOMING game, and it
-- has not run yet. Compared against the incoming game's own matchType
-- (read the same way online_handler.lua's is_knockout_state does), the
-- chamber is now kept only when the next game is genuinely another
-- knockout round.

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

local gf_src = slurp("modules/game_flow.lua")
local gf_code = gf_src:gsub("%-%-[^\n]*", "")

local fn_start = gf_code:find("function M%.start_game%(self%)")
check("M.start_game exists", fn_start ~= nil)
local fn_end = fn_start and gf_code:find("\nfunction M%.", fn_start + 10)
local fn_body = fn_start and gf_code:sub(fn_start, fn_end)

print("")
print("LEAVING AN ONLINE KNOCKOUT IS DETECTED THE SAME WAY LEAVING OFFLINE T4 IS")

check("reads self._is_knockout as the JUST-ENDED game's status",
    fn_body ~= nil and fn_body:find("local was_online_knockout = self%._is_knockout == true") ~= nil,
    "this must be read BEFORE OnlineHandler.start_game overwrites it for the incoming game")

check("captures the incoming game's state before deciding keep_scoreboard",
    fn_body ~= nil and fn_body:find("local incoming_state = %(app%.mode == \"online\"%) and ws%.get_active_game%(%)") ~= nil)

check("checks the incoming state's matchType, not just whether SOME online game is next",
    fn_body ~= nil and fn_body:find('incoming_match_type == "KNOCKOUT" or incoming_match_type == "ELIMINATION"') ~= nil,
    "mirrors online_handler.lua's is_knockout_state — a battle or tournament match must not count as a knockout")

check("leaving_online_knockout requires BOTH: was a knockout, and the next game is not",
    fn_body ~= nil and fn_body:find("local leaving_online_knockout = was_online_knockout and not incoming_is_knockout") ~= nil,
    "a knockout's own next round (also a knockout) must NOT trip this")

print("")
print("keep_scoreboard NOW ACCOUNTS FOR BOTH THE OFFLINE AND ONLINE CASES")

local reset_hud_pos = fn_body and fn_body:find('notify_gui%(self%.gui_hud, "reset_hud"')
check("the reset_hud call exists", reset_hud_pos ~= nil)
check("keep_scoreboard is false if EITHER the offline or the online chamber is being left",
    fn_body ~= nil and fn_body:find("keep_scoreboard = not leaving_offline_t4 and not leaving_online_knockout") ~= nil,
    "it used to be `not leaving_offline_t4` alone — the online case was never in the expression at all")

if reset_hud_pos and fn_body then
    local was_pos = fn_body:find("local was_online_knockout")
    check("was_online_knockout is computed BEFORE the reset_hud call, not after",
        was_pos ~= nil and was_pos < reset_hud_pos,
        "computing it after would read this decision one game too late")
end

print("")
print("THE INCOMING STATE FETCHED ONCE IS REUSED, NOT RE-FETCHED")

check("the online-game branch below reuses incoming_state instead of calling ws.get_active_game() again",
    fn_body ~= nil and fn_body:find("local state = incoming_state") ~= nil,
    "ws.get_active_game() is cheap (a plain getter) but re-fetching invites the two reads drifting apart")

print("")
print("game.gui_script's reset_hud HANDLER ITSELF IS UNCHANGED — THE BUG WAS UPSTREAM")

local hud_src = slurp("main/game.gui_script")
local hud_code = hud_src:gsub("%-%-[^\n]*", "")
check("still tears the chamber down unless keep_scoreboard says otherwise",
    hud_code:find("if not %(keep and self%.t4_chamber%) then") ~= nil
        and hud_code:find("t4%.clear_chamber%(self%)") ~= nil)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
