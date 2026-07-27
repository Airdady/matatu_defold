-- modules/lobby/draw.lua — node bookkeeping and the small drawing primitives
-- every lobby component builds on.
--
-- `self` is the gui_script's own state table: it owns `nodes` (everything to
-- delete on the next rebuild) and `buttons` (the tappable list on_input
-- sweeps). Passing it through keeps these functions stateless, so the same
-- helpers work for the main screen and for every overlay.

local ui = require("modules.ui")
local T  = require("modules.lobby.theme")

local M = {}

function M.track(self, n)
    self.nodes[#self.nodes + 1] = n
    return n
end

function M.clear(self)
    for _, n in ipairs(self.nodes or {}) do pcall(gui.delete_node, n) end
    self.nodes, self.buttons = {}, {}
end

function M.set_pivot(node, pivot)
    pcall(gui.set_pivot, node, pivot)
    return node
end

function M.box(self, x, y, w, h, color)
    return M.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0), color))
end

function M.text(self, x, y, str, font, color)
    return M.track(self, ui.text(vmath.vector3(x, y, 0), str, font, color))
end

-- Left-aligned text in one call — the pivot dance was repeated at nearly
-- every call site.
function M.text_w(self, x, y, str, font, color)
    return M.set_pivot(M.text(self, x, y, str, font, color), gui.PIVOT_W)
end

function M.text_e(self, x, y, str, font, color)
    return M.set_pivot(M.text(self, x, y, str, font, color), gui.PIVOT_E)
end

-- Drop-shadowed text: a dark copy offset behind the real one.
function M.text_sh(self, pos, str, font, color, ox, oy)
    ox = ox or 1; oy = oy or -2
    M.track(self, ui.text(vmath.vector3(pos.x + ox, pos.y + oy, 0), str, font,
        vmath.vector4(0, 0, 0, 0.8)))
    return M.track(self, ui.text(pos, str, font, color))
end

-- The textured slice-9 panel used for every container in the lobby (mode
-- tiles, utility buttons, cup cards) — the same artwork the stake tiles use.
function M.panel(self, x, y, w, h, anim)
    return M.track(self, ui.panel9(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0),
        anim or "container_bg"))
end

-- Textured slice-9 button + optional label, registered as a tappable button
-- in one call — same shape as online.gui_script's local mkbtn helper.
function M.btn(self, id, pos, size, label, style, data)
    local bg = M.track(self, ui.btn9(pos, size, style or "secondary_btn"))
    if label then
        M.track(self, ui.text(vmath.vector3(pos.x, pos.y - 3, pos.z), label,
            size.y >= 44 and "btn_md" or "btn_sm", T.CREAM))
    end
    self.buttons[#self.buttons + 1] = { node = bg, id = id, data = data }
    return bg
end

-- An invisible hit area over already-drawn artwork.
function M.hit(self, x, y, w, h, id, data)
    local n = M.box(self, x, y, w, h, T.TRANSP)
    self.buttons[#self.buttons + 1] = { node = n, id = id, data = data }
    return n
end

-- Full-screen scrim that also swallows taps, so a dialog's backdrop can't
-- leak input to the lobby beneath it.
function M.scrim(self, alpha, id)
    local n = M.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H,
        vmath.vector4(0, 0, 0, alpha or 0.85)))
    self.buttons[#self.buttons + 1] = { node = n, id = id or "dialog_block" }
    return n
end

function M.commas(n)
    return (tostring(math.floor(tonumber(n) or 0))
        :reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

return M
