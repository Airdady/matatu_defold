-- config.lua
local GameMode = require "modules.game_mode"

local M = {}

-- Detect if we are running in an HTML5 Web Browser
local is_web = sys.get_sys_info().system_name == "HTML5"

-- If in a browser, talk to localhost. If on Android/Mac, use the network IP.
if is_web then
    M.DOMAIN = "api.matatuleague.com"
else
    M.DOMAIN = "api.matatuleague.com"
end

-- Endpoints follow the active game (see modules/game_mode.lua). The backend
-- selects the matching rule engine from this URL path, so GAME_MODE = "WHOT"
-- => /whot => the server validates moves with its Whot rules; "MATATU" =>
-- /matatu; "KADI" => /kadi.
M.BASE_URL = "https://" .. M.DOMAIN .. "/" .. GameMode.PATH
M.WS_URL   = "wss://" .. M.DOMAIN .. "/" .. GameMode.PATH .. "/ws"

M.APP_VERSION = "18.5.9"
M.GAME_STATE_SECRET = "a27a120adfbc9f727c187748fff44547e1ee72f09481c8a965d62ed1c02e6ea3"

M.INITIAL_RECONNECT_DELAY = 1.0
M.MAX_RECONNECT_DELAY = 30.0
M.RECONNECT_BACKOFF = 1.5
M.MAX_RECONNECT_ATTEMPTS = 50
M.KEEP_ALIVE_INTERVAL = 4.0
M.ZOMBIE_TIMEOUT = 13.0
M.TURN_SECONDS = 30

-- The server's own per-turn window: PLAY_TIMEOUT_DURATION in be_matatu's
-- src/matatu/websocket/state.ts, currently 35000ms. Keep the two in step.
M.PLAY_TIMEOUT_SECONDS = 35

-- How long the pie spends on the GRACE round after the turn countdown hits
-- zero, before it raises the red alarm.
--
-- This is a FULL server window, not the 5s by which PLAY_TIMEOUT_DURATION
-- exceeds TURN_SECONDS. When the server's turn timeout fires on a seat that
-- has gone quiet it does not end anything — it hands the seat to the AI (or
-- plays one assisted move) and calls startTimeout again, giving that player
-- another whole PLAY_TIMEOUT_DURATION to come back and take it over. So the
-- window in which a player can still reappear is a turn timer long, and the
-- purple ring should last as long as the thing it is representing.
--
-- Online only: offline the AI is local and there is nobody to wait for.
M.GRACE_SECONDS = M.PLAY_TIMEOUT_SECONDS

-- Stake levels, in each game's own local currency (UGX/NGN/KES). Whot/Kadi
-- are the exact conversion table for this rollout, matching be_matatu's
-- SETTLEMENT_STAKE_LEVELS_BY_GAME (src/common/constants/gameConfig.ts) so a
-- selected stake button here is one the backend actually recognises for
-- that game — Matatu's amounts are unchanged:
--   UGX 200  -> NGN 100 (charge 10) -> KES 10 (charge 1)
--   UGX 500  -> NGN 200 (charge 10) -> KES 20 (charge 1)
--   UGX 1000 -> NGN 500 (charge 20) -> KES 50 (charge 2)
--   UGX 2000 -> NGN 800 (charge 40) -> KES 80 (charge 4)   [new top tier]
-- The 100 tier (UGX 100 / NGN 50 / KES 5) has been retired.
local STAKE_LEVELS_BY_GAME = {
  MATATU = {
    { amount = 0, charge = 0, points = 0, label = "Free" },
    { amount = 200, charge = 20, points = 20, label = "200" },
    { amount = 500, charge = 50, points = 50, label = "500" },
    { amount = 1000, charge = 100, points = 100, label = "1000" },
    -- New top tier replacing the retired 100. ALL_PAY: both players are
    -- charged amount + charge when the game starts, so 2000 costs each of
    -- them 2100 and the winner takes a clean 4000.
    { amount = 2000, charge = 100, points = 100, label = "2000" },
  },
  WHOT = {
    { amount = 0, charge = 0, points = 0, label = "Free" },
    { amount = 50, charge = 10, points = 10, label = "50" },
    { amount = 200, charge = 10, points = 10, label = "200" },
    { amount = 500, charge = 20, points = 20, label = "500" },
    { amount = 800, charge = 40, points = 40, label = "800" },
  },
  KADI = {
    { amount = 0, charge = 0, points = 0, label = "Free" },
    { amount = 5, charge = 1, points = 1, label = "5" },
    { amount = 10, charge = 1, points = 1, label = "10" },
    { amount = 20, charge = 1, points = 1, label = "20" },
    { amount = 50, charge = 2, points = 2, label = "50" },
    { amount = 80, charge = 4, points = 4, label = "80" },
  },
}

M.STAKE_LEVELS = STAKE_LEVELS_BY_GAME[GameMode.GAME] or STAKE_LEVELS_BY_GAME.MATATU

return M
