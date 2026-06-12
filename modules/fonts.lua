-- modules/fonts.lua
-- ONE global place that defines every font role used by the UI. A role maps
-- to a .font resource (registered by name in each .gui) plus its base pixel
-- size, so call sites can ask for exact pixel sizes without sprinkling
-- magic scale numbers around:
--
--   local F = require "modules.fonts"
--   ui.text(pos, "PLAY", F.BUTTON.name, col, F.scale(F.BUTTON, 22))
--
-- Swapping a typeface for the whole app = repointing the .font file (or the
-- role below) in exactly one place.

local M = {}

-- role            .font resource    base px (size in the .font file)
M.TITLE       = { name = "title",         base = 44 } -- big screen titles (ProtestStrike)
M.HEADER      = { name = "poppins_black", base = 34 } -- dialog/section headers
M.BUTTON      = { name = "poppins_bold",  base = 34 } -- buttons / emphasized labels
M.BODY        = { name = "body",          base = 26 } -- standard copy
M.SMALL       = { name = "small",         base = 18 } -- captions, hints, badges
M.MODAL       = { name = "poppins",       base = 28 } -- modal body copy
M.MODAL_BOLD  = { name = "poppins_bold",  base = 34 } -- modal titles/buttons

-- gui.set_scale factor that renders `role` at exactly `px` pixels.
function M.scale(role, px)
	return px / ((role and role.base) or 26)
end

return M
