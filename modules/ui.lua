--- ui.lua
-- Small helpers for building GUI nodes at runtime. Must be called from within a
-- gui_script callback (gui.* is context-bound). Used by lobby + game screens.

local M = {}

-- Palette
M.WHITE = vmath.vector4(1, 1, 1, 1)
M.BLACK = vmath.vector4(0, 0, 0, 1)
M.DARK = vmath.vector4(0.06, 0.07, 0.10, 1)
M.PANEL = vmath.vector4(0.12, 0.14, 0.20, 1)
M.PANEL2 = vmath.vector4(0.17, 0.20, 0.28, 1)
M.GOLD = vmath.vector4(0.95, 0.75, 0.15, 1)
M.GREEN = vmath.vector4(0.20, 0.70, 0.35, 1)
M.RED = vmath.vector4(0.85, 0.25, 0.25, 1)
M.BLUE = vmath.vector4(0.25, 0.55, 0.9, 1)
M.MUTED = vmath.vector4(0.6, 0.65, 0.75, 1)
M.FELT = vmath.vector4(0.08, 0.30, 0.18, 1)
-- Dialog palette (matches the Godot modals).
M.CYAN     = vmath.vector4(0.0, 0.722, 0.831, 1)   -- #00b8d4 titles / timer
M.CYAN_LOW = vmath.vector4(1.0, 0.322, 0.322, 1)   -- #ff5252 timer low
M.DEFEAT   = vmath.vector4(0.718, 0.110, 0.110, 1) -- #b71c1c
M.CHAMPION = vmath.vector4(1.0, 0.843, 0.0, 1)     -- #FFD700
M.SECONDARY= vmath.vector4(0.565, 0.643, 0.682, 1) -- #90a4ae

function M.box(pos, size, color)
	local n = gui.new_box_node(pos, size)
	gui.set_color(n, color or M.PANEL)
	return n
end

function M.text(pos, str, font, color, scale)
	local n = gui.new_text_node(pos, str)
	gui.set_font(n, font or "body")
	gui.set_color(n, color or M.WHITE)
	if scale then
		gui.set_scale(n, vmath.vector3(scale, scale, 1))
	end
	return n
end

-- Textured node from the card atlas (anim e.g. "card_2H", "card_back").
function M.card(pos, size, anim)
	local n = gui.new_box_node(pos, size)
	gui.set_texture(n, "cards")
	pcall(gui.play_flipbook, n, anim)
	return n
end

-- Textured node from the ui atlas (anim e.g. "hearts", "coins").
function M.image(pos, size, anim)
	local n = gui.new_box_node(pos, size)
	gui.set_texture(n, "ui")
	pcall(gui.play_flipbook, n, anim)
	return n
end

-- ── Guaranteed full-screen coverage (reference Defold technique) ─────────────
-- Never rely on exact W×H sizing: an oversized, centered, stretch-adjusted node
-- always overflows the viewport, so there are no black edges on ANY device
-- resolution or aspect ratio.

-- Solid colour base fill. Oversized + centered + ADJUST_STRETCH.
function M.cover(w, h, color)
	local big = math.max(w, h) * 3
	local n = gui.new_box_node(vmath.vector3(w / 2, h / 2, 0), vmath.vector3(big, big, 0))
	gui.set_color(n, color or M.DARK)
	pcall(gui.set_adjust_mode, n, gui.ADJUST_STRETCH)
	return n
end

-- Full-screen textured background. ADJUST_ZOOM = aspect-preserving cover (fills
-- the screen, crops overflow, never distorts and never leaves gaps).
function M.cover_image(w, h, anim)
	local n = gui.new_box_node(vmath.vector3(w / 2, h / 2, 0), vmath.vector3(w, h, 0))
	gui.set_texture(n, "ui")
	pcall(gui.play_flipbook, n, anim)
	pcall(gui.set_adjust_mode, n, gui.ADJUST_ZOOM)
	return n
end

-- Avatar sprite from the avatars atlas. avatar_id 1..60.
function M.avatar(pos, size, avatar_id)
	local id = tonumber(avatar_id) or 1
	if id < 1 or id > 60 then id = 1 end
	local n = gui.new_box_node(pos, size)
	gui.set_texture(n, "avatars")
	pcall(gui.play_flipbook, n, "avatar_" .. id)
	return n
end

-- Full-screen radial gradient backdrop for modal dialogs (Candy-Crush style).
-- Pass the screen size; alpha can be animated by the caller for a fade-in.
function M.grad_backdrop(w, h)
	-- Oversized + zoom so the gradient always covers the whole device screen.
	local big = math.max(w, h) * 2
	local n = gui.new_box_node(vmath.vector3(w / 2, h / 2, 0), vmath.vector3(big, big, 0))
	gui.set_texture(n, "ui")
	pcall(gui.play_flipbook, n, "dialog_grad")
	pcall(gui.set_adjust_mode, n, gui.ADJUST_ZOOM)
	return n
end

-- Slice-9 textured button from the ui atlas (e.g. "primary_btn", "secondary_btn").
-- Returns the bg node; corners stay crisp at any size.
function M.btn9(pos, size, anim)
	local n = gui.new_box_node(pos, size)
	gui.set_texture(n, "ui")
	pcall(gui.play_flipbook, n, anim)
	pcall(gui.set_slice9, n, vmath.vector4(24, 18, 24, 18))
	return n
end

-- Slice-9 textured glass panel (e.g. "container_bg", "container_bg_active").
-- Matches the Godot StyleBoxTexture glass panels (15px texture margins).
function M.panel9(pos, size, anim)
	local n = gui.new_box_node(pos, size)
	gui.set_texture(n, "ui")
	pcall(gui.play_flipbook, n, anim)
	pcall(gui.set_slice9, n, vmath.vector4(15, 15, 15, 15))
	return n
end

-- Pie node (used for the circular "slice" turn timer). Returns the node so the
-- caller can animate its fill angle / colour each frame.
function M.pie(pos, radius, color)
	local n = gui.new_pie_node(pos, vmath.vector3(radius * 2, radius * 2, 0))
	gui.set_perimeter_vertices(n, 40)
	gui.set_fill_angle(n, 360)
	gui.set_color(n, color or M.GREEN)
	return n
end

-- Background image name for a given stake amount (matches the Godot tiers).
function M.stake_bg(amount)
	amount = tonumber(amount) or 0
	if     amount <= 200 then return "bg_1"
	elseif amount <= 500 then return "bg_2"
	else                      return "bg_3" end
end

-- Lighten/darken a colour by factor f (1=unchanged, >1 lighter, <1 darker).
function M.shade(c, f)
	return vmath.vector4(
		math.min(c.x * f, 1),
		math.min(c.y * f, 1),
		math.min(c.z * f, 1),
		c.w)
end

return M
