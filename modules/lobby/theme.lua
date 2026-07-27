-- modules/lobby/theme.lua — palette, layout constants and screen states for
-- the lobby and its extracted components.
--
-- Split out of lobby.gui_script so the pieces below it (draw, tiles, season,
-- overlays, cups) can share one definition of the look instead of each
-- carrying its own copy of the colours.

local M = {}

-- ---------------------------------------------------------------------------
-- Palette
-- ---------------------------------------------------------------------------
M.CREAM    = vmath.vector4(1.000, 0.980, 0.950, 1.00)
M.RED      = vmath.vector4(0.929, 0.110, 0.141, 1.00)
M.DARKRED  = vmath.vector4(0.600, 0.100, 0.100, 1.00)
M.GOLD     = vmath.vector4(0.784, 0.580, 0.235, 1.00)
M.BORDER   = vmath.vector4(0.350, 0.290, 0.200, 1.00) -- thin gold border
M.TILE     = vmath.vector4(0.060, 0.050, 0.040, 0.95) -- almost black tile fill
M.DARK     = vmath.vector4(0.050, 0.040, 0.030, 0.95)
M.TRANSP   = vmath.vector4(0, 0, 0, 0)
M.MUTED    = vmath.vector4(0.600, 0.600, 0.600, 1.00)
M.TEAM     = vmath.vector4(0.596, 0.298, 0.796, 1.00)
M.DISABLED = vmath.vector4(0.380, 0.380, 0.380, 1.00)
M.SUCCESS  = vmath.vector4(0.300, 0.900, 0.400, 1.00)
M.ERROR    = vmath.vector4(1.000, 0.350, 0.350, 1.00)

-- Akira / consent palette
M.CONSENT_PANEL   = vmath.vector4(0.110, 0.071, 0.051, 1.0)
M.CONSENT_ACCENT  = vmath.vector4(0.949, 0.702, 0.180, 1.0)
M.CONSENT_BODY    = vmath.vector4(0.850, 0.800, 0.750, 1.0)
M.CONSENT_DARK    = vmath.vector4(0.082, 0.055, 0.040, 1.0)
M.CONSENT_NEUTRAL = vmath.vector4(0.180, 0.140, 0.110, 1.0)
M.CONSENT_DONE    = vmath.vector4(0.612, 0.482, 0.325, 1.0)

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
M.LOGICAL_W, M.LOGICAL_H = 1280, 720
M.GUTTER   = 10
M.PADDING  = 32
M.HEADER_H = 65

-- ---------------------------------------------------------------------------
-- Screen states
-- ---------------------------------------------------------------------------
M.STATE_LOBBY     = "lobby"
M.STATE_AI_SELECT = "ai_select"
M.STATE_TOURNEY   = "tournament"
M.STATE_TEAM_JOIN = "team_join"
M.STATE_TEAM_MENU = "team_menu"

-- Canvas, refreshed from screen.metrics() before every rebuild. Kept here so
-- every component reads the same numbers rather than being handed four edges
-- through every call.
M.VW, M.VH = 1280, 720
M.EDGE_L, M.EDGE_R, M.EDGE_B, M.EDGE_T = 0, 1280, 0, 720
M.CX, M.CY = 640, 360

function M.refresh(metrics)
    M.VW, M.VH = metrics.VW, metrics.VH
    M.EDGE_L, M.EDGE_R = metrics.L, metrics.R
    M.EDGE_B, M.EDGE_T = metrics.B, metrics.T
    M.CX, M.CY = metrics.CX, metrics.CY
end

return M
