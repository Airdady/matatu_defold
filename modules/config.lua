-- config.lua
local M = {}

-- Detect if we are running in an HTML5 Web Browser
local is_web = sys.get_sys_info().system_name == "HTML5"

-- If in a browser, talk to localhost. If on Android/Mac, use the network IP.
if is_web then
    M.DOMAIN = "192.168.1.128:3000"
else
    M.DOMAIN = "192.168.1.128:3000"
end

M.BASE_URL = "http://" .. M.DOMAIN .. "/matatu"
M.WS_URL = "ws://" .. M.DOMAIN .. "/matatu/ws"

M.APP_VERSION = "18.5.9"
M.GAME_STATE_SECRET = "a27a120adfbc9f727c187748fff44547e1ee72f09481c8a965d62ed1c02e6ea3"

-- OAuth *web* client id (Google Cloud Console → Credentials → OAuth 2.0 client
-- of type "Web application"). Required by the native Google sign-in
-- (gameservices.google_sign_in) for requestIdToken, and must match the backend
-- GOOGLE_WEB_CLIENT_ID env used to verify the token. Replace with your value.
M.GOOGLE_WEB_CLIENT_ID = "YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"

M.INITIAL_RECONNECT_DELAY = 1.0
M.MAX_RECONNECT_DELAY = 30.0
M.RECONNECT_BACKOFF = 1.5
M.MAX_RECONNECT_ATTEMPTS = 50
M.KEEP_ALIVE_INTERVAL = 4.0
M.ZOMBIE_TIMEOUT = 13.0
M.TURN_SECONDS = 30

M.STAKE_LEVELS = {
  { amount = 0, charge = 0, points = 0, label = "Free" },
  { amount = 100, charge = 10, points = 10, label = "100" },
  { amount = 200, charge = 20, points = 20, label = "200" },
  { amount = 500, charge = 50, points = 50, label = "500" },
  { amount = 1000, charge = 100, points = 100, label = "1000" },
}

return M