-- SEASON_COMPLETE HAS TO REACH current_user_data, NOT JUST THE RESULTS DIALOG.
--
--   Run: lua tools/test_season_complete_syncs_hud.lua
--
-- be_matatu resets points and credits coinsEarned/savingCoinsEarned into the
-- player's account atomically the moment a season closes (completeSeason's
-- own bulkWrite). SEASON_COMPLETE carries those same figures to the client —
-- the results dialog (season_results.gui_script) already reads them straight
-- off the message and shows the right thing.
--
-- Nothing updated ws.current_user_data, though, which is what every OTHER
-- screen reads (the BAL/PTS/SAVINGS panel in online_right.lua, in
-- particular). So the server-side reset was correct and this repo's own
-- backend tests proved it — but a player watching their own HUD across a
-- season boundary kept seeing their old points total until the next full
-- reconnect, which is exactly what "points never actually clear" looks like
-- from the seat that matters.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

for name in pairs(package.loaded) do
    if name:match("^modules%.") then package.loaded[name] = nil end
end
package.path = ROOT .. "?.lua;" .. package.path

local SIM = dofile(ROOT .. "tools/defold_sim.lua")
SIM.install_gui_stub()
_G.window.set_listener = function() end
_G.sys.get_config_string = function() return "" end
_G.sys.get_config = function() return "" end
_G.http = { request = function() end }

local ws = require("modules.websocket_manager")
ws.connect()
SIM.pump(0.5)

----------------------------------------------------------------------
print("A SEASON CLOSE WITH NOTHING EXTRA EARNED")
----------------------------------------------------------------------
ws.current_user_data = { _id = "u1", username = "Ada", balance = 500, points = 980, savingCoins = 20 }

SIM.server_send({ type = "SEASON_COMPLETE", data = {
    seasonId = "s1", seasonNumber = 7,
    startDate = "2026-08-01T00:00:00.000Z", endDate = "2026-08-19T00:00:00.000Z",
    playerRank = 2, playerPointsEarned = 980, coinsEarned = 2000,
    savingCoinsEarned = 0, rewardPointsEarned = 0,
    badgesEarned = {}, missionsCompleted = {},
    finalLeaderboard = {}, topWinners = {}, winnersAreGlobal = true,
} })
SIM.pump(0.2)

check("points are reset to the server's new total, not left at the pre-close score",
      ws.current_user_data.points, 0)
check("the weekly/season coins earned are added to the cached balance",
      ws.current_user_data.balance, 2500)
check("an unchanged savings figure leaves the cached balance unchanged",
      ws.current_user_data.savingCoins, 20)

----------------------------------------------------------------------
print("")
print("A CLOSE THAT ALSO PAYS SAVINGS AND REWARD POINTS")
----------------------------------------------------------------------
ws.current_user_data = { _id = "u1", username = "Ada", balance = 100, points = 4500, savingCoins = 50 }

SIM.server_send({ type = "SEASON_COMPLETE", data = {
    seasonId = "s2", seasonNumber = 8,
    startDate = "2026-08-19T00:00:00.000Z", endDate = "2026-08-22T23:59:00.000Z",
    playerRank = 4, playerPointsEarned = 4500, coinsEarned = 1000,
    savingCoinsEarned = 150, rewardPointsEarned = 20,
    badgesEarned = {}, missionsCompleted = {},
    finalLeaderboard = {}, topWinners = {}, winnersAreGlobal = true,
} })
SIM.pump(0.2)

check("points are SET to rewardPointsEarned, not summed with the old score",
      ws.current_user_data.points, 20)
check("balance adds the coins earned", ws.current_user_data.balance, 1100)
check("savings adds the savings earned", ws.current_user_data.savingCoins, 200)

----------------------------------------------------------------------
print("")
print("NO CACHED USER YET — MUST NOT ERROR")
----------------------------------------------------------------------
ws.current_user_data = nil
local sent_ok = pcall(function()
    SIM.server_send({ type = "SEASON_COMPLETE", data = {
        seasonId = "s3", seasonNumber = 9, playerRank = 1, playerPointsEarned = 10,
        coinsEarned = 10, savingCoinsEarned = 0, rewardPointsEarned = 0,
        badgesEarned = {}, missionsCompleted = {}, finalLeaderboard = {}, topWinners = {},
        winnersAreGlobal = false,
    } })
    SIM.pump(0.2)
end)
check("a SEASON_COMPLETE with no cached user yet does not throw", sent_ok, true)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
