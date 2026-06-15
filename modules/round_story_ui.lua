local M = {}

local C_WHITE     = vmath.vector4(1.0, 1.0, 1.0, 1.0)
local C_FORM_W    = vmath.vector4(0.15, 0.70, 0.25, 1.0)
local C_FORM_L    = vmath.vector4(0.90, 0.25, 0.25, 1.0)
local C_H2H_GOLD  = vmath.vector4(1.00, 0.84, 0.20, 1.0)
local C_H2H_DIM   = vmath.vector4(0.55, 0.58, 0.62, 1.0)
local C_STORY_CYAN= vmath.vector4(0.0, 0.722, 0.831, 1.0)

local function box(pos, size, color, pivot)
    local n = gui.new_box_node(pos, size)
    gui.set_color(n, color)
    if pivot then gui.set_pivot(n, pivot) end
    return n
end

local function label(pos, text, size, color, align, font_name)
    local n = gui.new_text_node(pos, text)
    gui.set_font(n, font_name or "body")
    local base_size = (font_name == "title") and 36 or 24
    gui.set_scale(n, vmath.vector3(size / base_size, size / base_size, 1.0))
    gui.set_color(n, color or C_WHITE)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

function M.build(self, logical_w, logical_h)
    self.story_scrim = box(vmath.vector3(logical_w/2, logical_h/2, 0), vmath.vector3(5000, 5000, 0), vmath.vector4(0, 0, 0, 0.88), gui.PIVOT_CENTER)
    gui.set_adjust_mode(self.story_scrim, gui.ADJUST_STRETCH)

    self.story_wrap = box(vmath.vector3(logical_w/2, logical_h/2 + 14, 0), vmath.vector3(1, 1, 0), vmath.vector4(0, 0, 0, 0), gui.PIVOT_CENTER)
    self.story_title = label(vmath.vector3(0, 24, 0), "", 54, C_WHITE, gui.PIVOT_CENTER, "title")
    pcall(function() gui.set_shadow(self.story_title, vmath.vector4(0, 0, 0, 0.7)) end)
    gui.set_parent(self.story_title, self.story_wrap)
    self.story_sub = label(vmath.vector3(0, -32, 0), "", 20, C_H2H_DIM, gui.PIVOT_CENTER, "body")
    gui.set_parent(self.story_sub, self.story_wrap)

    gui.set_enabled(self.story_scrim, false)
    gui.set_enabled(self.story_wrap, false)
    self.story_seq = 0
end

local function story_finish(self, seq)
    if seq ~= self.story_seq then return end
    gui.set_enabled(self.story_scrim, false)
    gui.set_enabled(self.story_wrap, false)
    self.story_active = false
    msg.post("/controller#game_logic", "round_story_done")
end

local function story_phase(self, seq, title, sub, color, hold, next_fn)
    if seq ~= self.story_seq then return end
    gui.set_text(self.story_title, title)
    gui.set_color(self.story_title, color)
    gui.set_text(self.story_sub, sub or "")
    gui.set_enabled(self.story_wrap, true)

    gui.cancel_animation(self.story_wrap, "scale")
    gui.cancel_animation(self.story_wrap, "color.w")
    gui.set_scale(self.story_wrap, vmath.vector3(0.45, 0.45, 1))
    local c = gui.get_color(self.story_wrap); c.w = 0; gui.set_color(self.story_wrap, c)
    gui.animate(self.story_wrap, "color.w", 1.0, gui.EASING_OUTSINE, 0.22)
    gui.animate(self.story_wrap, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.42, 0, function()
        if seq ~= self.story_seq then return end
        timer.delay(hold, false, function()
            if seq ~= self.story_seq then return end
            gui.animate(self.story_wrap, "color.w", 0.0, gui.EASING_INSINE, 0.30)
            gui.animate(self.story_wrap, "scale", vmath.vector3(1.18, 1.18, 1), gui.EASING_INSINE, 0.30, 0, function()
                if seq ~= self.story_seq then return end
                next_fn()
            end)
        end)
    end)
end

function M.show(self, m, opp_display_name)
    self.story_seq = (self.story_seq or 0) + 1
    local seq = self.story_seq
    self.story_active = true

    gui.set_enabled(self.story_scrim, true)
    local sc = gui.get_color(self.story_scrim); sc.w = 0; gui.set_color(self.story_scrim, sc)
    gui.animate(self.story_scrim, "color.w", 0.88, gui.EASING_OUTSINE, 0.25)

    local p, o = tonumber(m.p_score) or 0, tonumber(m.o_score) or 0
    local won = m.won and true or false
    local opp = tostring(m.opp_name or opp_display_name or "OPPONENT")

    local t1 = won and "ROUND WON!" or "ROUND LOST"
    local c1 = won and C_FORM_W or C_FORM_L
    local s1
    if p > o then s1 = string.format("You lead %d - %d", p, o)
    elseif o > p then s1 = string.format("%s leads %d - %d", opp, o, p)
    else s1 = string.format("All square at %d - %d", p, o) end

    local t2, c2, s2
    if m.last_round then
        t2, c2 = "FINAL ROUND", C_H2H_GOLD
        s2 = "Next win takes the match!"
    else
        t2, c2 = "ROUND " .. tostring(m.next_round or (p + o + 1)), C_STORY_CYAN
        s2 = won and "Keep the streak alive!" or "Time to bounce back!"
    end

    story_phase(self, seq, t1, s1, c1, 1.35, function()
        story_phase(self, seq, t2, s2, c2, 1.15, function()
            gui.animate(self.story_scrim, "color.w", 0.0, gui.EASING_INSINE, 0.28, 0, function()
                story_finish(self, seq)
            end)
        end)
    end)
end

function M.hide(self)
    self.story_seq = (self.story_seq or 0) + 1
    self.story_active = false
    if self.story_scrim then gui.set_enabled(self.story_scrim, false) end
    if self.story_wrap then gui.set_enabled(self.story_wrap, false) end
end

return M