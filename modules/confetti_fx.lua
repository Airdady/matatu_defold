-- confetti_fx.lua — shared "confetti cannon" particle burst (port of the
-- Godot ConfettiCannon), factored out of main/gameover.gui_script so any
-- .gui_script can trigger the same celebratory effect without duplicating
-- the particle sim.
--
-- Usage from any .gui_script:
--   local confetti_fx = require("modules.confetti_fx")
--   function init(self)        confetti_fx.build(self) end
--   function update(self, dt)  confetti_fx.update(self, dt) end
--   -- to trigger: confetti_fx.explode(self)
--   -- to hide:    confetti_fx.clear(self)
--
-- Stores its state under self.confetti / self.confetti_running — don't
-- reuse those field names for anything else in the same script. Nodes are
-- created unparented (top level of the calling script's own .gui scene), so
-- they render at whatever render_order that scene is set to.

local M = {}

local LOGICAL_W, LOGICAL_H = 1280, 720
local CX = LOGICAL_W / 2

local CONFETTI_N = 150
local function chex(h)
    return vmath.vector4(tonumber(h:sub(1,2),16)/255, tonumber(h:sub(3,4),16)/255, tonumber(h:sub(5,6),16)/255, 1)
end
local CONFETTI_COLORS = {
    chex("e67e22"), chex("2ecc71"), chex("3498db"), chex("84AAC2"), chex("E6D68D"),
    chex("F67933"), chex("42A858"), chex("4F50A2"), chex("A86BB7"), chex("e74c3c"), chex("1abc9c"),
}
local function rr(a, b) return a + math.random() * (b - a) end
local function remap(v, a0, b0, a1, b1)
    if b0 == a0 then return a1 end
    return a1 + (b1 - a1) * ((v - a0) / (b0 - a0))
end

function M.build(self)
    self.confetti = {}
    for i = 1, CONFETTI_N do
        local n = gui.new_box_node(vmath.vector3(-100, -100, 0), vmath.vector3(10, 7, 0))
        gui.set_pivot(n, gui.PIVOT_CENTER)
        gui.set_xanchor(n, gui.ANCHOR_NONE)
        gui.set_yanchor(n, gui.ANCHOR_NONE)
        gui.set_enabled(n, false)
        self.confetti[i] = { node = n, active = false }
    end
end

local function confetti_phys(p, val)
    local settled = val > (1.0 + p.top_delta)
    local y
    if val <= 1.0 then
        y = p.origin_y + (p.peak_y - p.origin_y) * val
    elseif not settled then
        local t = math.max(0, math.min(1, (val - 1.0) / p.top_delta))
        y = p.peak_y + (p.floor_y - p.peak_y) * t
    else
        y = p.floor_y
    end
    local x = (val <= 1.0) and (p.origin_x + (p.target_x - p.origin_x) * val) or p.target_x
    local swing, sway = p.swing_delta * 30.0, 0
    if not settled then
        if val <= 0.4 then sway = remap(val, 0, 0.4, 0, -swing)
        elseif val <= 1.2 then sway = remap(val, 0.4, 1.2, -swing, swing)
        else sway = remap(val, 1.2, 2.0, swing, 0) end
    end
    local rot_val = settled and (1.0 + p.top_delta) or val
    gui.set_position(p.node, vmath.vector3(x + sway, y, 0))
    gui.set_rotation(p.node, vmath.vector3(0, 0, rot_val * p.spz * 360))
    gui.set_scale(p.node, vmath.vector3(1, math.cos(math.rad(rot_val * p.spx * 360)), 1))
end

function M.explode(self)
    if not self.confetti then return end
    self.confetti_running = true
    local ox, oy = CX, 0  -- bottom-centre (Defold GUI y is up)
    for _, p in ipairs(self.confetti) do
        local col = CONFETTI_COLORS[math.random(#CONFETTI_COLORS)]
        gui.set_color(p.node, col)
        gui.set_size(p.node, vmath.vector3(rr(6, 12), rr(4, 10), 0))
        p.origin_x, p.origin_y = ox, oy
        local left_delta = rr(0, 1)
        p.top_delta   = rr(0.40, 0.95)
        p.swing_delta = rr(0.2, 1.0)
        p.spx, p.spz  = math.random() * 10, math.random() * 2
        p.target_x = (left_delta - 0.5) * (LOGICAL_W * 0.9) + ox
        p.peak_y   = p.top_delta * LOGICAL_H
        p.floor_y  = rr(6, 36)
        p.exp_time  = 0.55 * rr(0.8, 1.2)
        p.fall_time = 3.5 * rr(0.7, 1.3)
        p.delay = (math.random() ^ 3) * 0.4
        p.t, p.phase, p.active = 0, 1, true
        gui.set_enabled(p.node, true)
        confetti_phys(p, 0)
    end
end

function M.clear(self)
    self.confetti_running = false
    for _, p in ipairs(self.confetti or {}) do
        p.active = false
        gui.set_enabled(p.node, false)
    end
end

function M.update(self, dt)
    if not self.confetti_running then return end
    local any = false
    for _, p in ipairs(self.confetti) do
        if p.active then
            any = true
            if p.delay > 0 then
                p.delay = p.delay - dt
            elseif p.phase == 1 then
                p.t = p.t + dt
                local x = math.min(1, p.t / p.exp_time)
                confetti_phys(p, 1 - (1 - x) * (1 - x))   -- ease-out-quad 0..1
                if x >= 1 then p.phase, p.t = 2, 0 end
            else
                p.t = p.t + dt
                local x = math.min(1, p.t / p.fall_time)
                confetti_phys(p, 1 + x * x)               -- ease-in-quad 1..2
                if x >= 1 then p.active = false end        -- settle + freeze (pile up)
            end
        end
    end
    if not any then self.confetti_running = false end
end

return M
