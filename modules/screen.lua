-- screen.lua - True physical screen-edge metrics for full-bleed layouts.
--
-- The GUI logical resolution stays 1280x720, but on devices with a different
-- aspect ratio the *visible* area extends past the logical box (the engine
-- keeps the logical height/width and overscans the other axis). These helpers
-- compute the real visible edges so content can anchor to the actual screen
-- corners — no black bars, no exposed background gaps, on any device.
--
-- Centre of the physical screen is always logical (640,360). On a wider screen
-- EDGE_L is < 0 and EDGE_R is > 1280; on a taller screen EDGE_B < 0, EDGE_T > 720.

local M = {}

M.LOGICAL_W, M.LOGICAL_H = 1280, 720

-- Returns a metrics table:
--   VW, VH  visible width / height (>= logical)
--   CX, CY  centre (always 640, 360)
--   L, R    visible left / right edges (design space)
--   B, T    visible bottom / top edges (design space)
function M.metrics()
	local ok, ww, wh = pcall(window.get_size)
	if not ok or not ww or ww == 0 then ww = M.LOGICAL_W end
	if not wh or wh == 0 then wh = M.LOGICAL_H end

	local sa = ww / wh
	local la = M.LOGICAL_W / M.LOGICAL_H
	local vw, vh
	if sa > la then
		vw, vh = M.LOGICAL_H * sa, M.LOGICAL_H
	else
		vw, vh = M.LOGICAL_W, M.LOGICAL_W / sa
	end

	local cx, cy = M.LOGICAL_W / 2, M.LOGICAL_H / 2
	return {
		VW = vw, VH = vh,
		CX = cx, CY = cy,
		L  = cx - vw / 2, R = cx + vw / 2,
		B  = cy - vh / 2, T = cy + vh / 2,
	}
end

return M
