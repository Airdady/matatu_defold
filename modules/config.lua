-- config.lua
local GameMode = require "modules.game_mode"

local M = {}

-- Detect if we are running in an HTML5 Web Browser
local is_web = sys.get_sys_info().system_name == "HTML5"

-- If in a browser, talk to localhost. If on Android/Mac, use the network IP.
if is_web then
    M.DOMAIN = "champion.matatuleague.com"
else
    M.DOMAIN = "champion.matatuleague.com"
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

-- Stake levels, in each game's own local currency (UGX/NGN/KES). Whot/Kadi
-- are the exact conversion table for this rollout, matching be_matatu's
-- SETTLEMENT_STAKE_LEVELS_BY_GAME (src/common/constants/gameConfig.ts) so a
-- selected stake button here is one the backend actually recognises for
-- that game — Matatu's amounts are unchanged:
--   UGX 100  -> NGN 50  (charge 10) -> KES 5  (charge 1)
--   UGX 200  -> NGN 100 (charge 10) -> KES 10 (charge 1)
--   UGX 500  -> NGN 200 (charge 10) -> KES 20 (charge 1)
--   UGX 1000 -> NGN 500 (charge 20) -> KES 50 (charge 2)
local STAKE_LEVELS_BY_GAME = {
  MATATU = {
    { amount = 0, charge = 0, points = 0, label = "Free" },
    { amount = 100, charge = 10, points = 10, label = "100" },
    { amount = 200, charge = 20, points = 20, label = "200" },
    { amount = 500, charge = 50, points = 50, label = "500" },
    { amount = 1000, charge = 100, points = 100, label = "1000" },
  },
  WHOT = {
    { amount = 0, charge = 0, points = 0, label = "Free" },
    { amount = 50, charge = 10, points = 10, label = "50" },
    { amount = 100, charge = 10, points = 10, label = "100" },
    { amount = 200, charge = 10, points = 10, label = "200" },
    { amount = 500, charge = 20, points = 20, label = "500" },
  },
  KADI = {
    { amount = 0, charge = 0, points = 0, label = "Free" },
    { amount = 5, charge = 1, points = 1, label = "5" },
    { amount = 10, charge = 1, points = 1, label = "10" },
    { amount = 20, charge = 1, points = 1, label = "20" },
    { amount = 50, charge = 2, points = 2, label = "50" },
  },
}

M.STAKE_LEVELS = STAKE_LEVELS_BY_GAME[GameMode.GAME] or STAKE_LEVELS_BY_GAME.MATATU

return M
