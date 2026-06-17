--- config.lua
-- Central configuration, ported from the Godot ApiService / WebSocketManager.

local M = {}

M.DOMAIN = "10.142.23.113:3000"
M.BASE_URL = "http://" .. M.DOMAIN .. "/matatu"
M.WS_URL = "ws://" .. M.DOMAIN .. "/matatu/ws"

M.APP_VERSION = "18.5.9"

-- AES-256 key (hex) used to decrypt the server's game-state payloads.
-- (Matches the SECRET in the original Godot `Utils.gd`.)
M.GAME_STATE_SECRET = "a27a120adfbc9f727c187748fff44547e1ee72f09481c8a965d62ed1c02e6ea3"

-- Reconnect/backoff tuning (seconds).
M.INITIAL_RECONNECT_DELAY = 1.0
M.MAX_RECONNECT_DELAY = 30.0
M.RECONNECT_BACKOFF = 1.5
M.MAX_RECONNECT_ATTEMPTS = 50
M.KEEP_ALIVE_INTERVAL = 4.0

-- Zombie-connection watchdog: if the socket reports "connected" but no message
-- (not even a PONG/PING/keep-alive ack) has arrived in this many seconds, the
-- TCP link is dead-but-open. The client force-closes it and reconnects instead
-- of silently hanging forever. ~3x the keep-alive interval avoids false trips.
M.ZOMBIE_TIMEOUT = 13.0

-- Turn length (seconds) used by the local game timer display.
M.TURN_SECONDS = 30

-- Stake tiers for the lobby (amount = coins wagered, charge = fee, points won).
-- 50-coin stake retired: lowest paid stake is now 100.
M.STAKE_LEVELS = {
	{ amount = 0, charge = 0, points = 0, label = "Free" },
	{ amount = 100, charge = 10, points = 10, label = "100" },
	{ amount = 200, charge = 20, points = 20, label = "200" },
	{ amount = 500, charge = 50, points = 50, label = "500" },
	{ amount = 1000, charge = 100, points = 100, label = "1000" },
}

return M
