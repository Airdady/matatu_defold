local M = {}

-- Round Dot (Checkbox) Configuration
local ROUND_DOT_SPACING_X = 22
local ROUND_DOT_RIM_SIZE  = 20
local ROUND_DOT_FILL_SIZE = 15

-- Localized UI Colors for Scoreboard
local C_CARD_TOP  = vmath.vector4(0.18, 0.18, 0.18, 1.0)
local C_CARD_BOT  = vmath.vector4(0.12, 0.12, 0.12, 1.0)
local C_WHITE     = vmath.vector4(1.0, 1.0, 1.0, 1.0)
local C_FORM_W    = vmath.vector4(0.15, 0.70, 0.25, 1.0)
local C_FORM_L    = vmath.vector4(0.90, 0.25, 0.25, 1.0)
local C_H2H_GOLD  = vmath.vector4(1.00, 0.84, 0.20, 1.0)
local C_H2H_DIM   = vmath.vector4(0.55, 0.58, 0.62, 1.0)
local C_DOT_RIM   = vmath.vector4(0.02, 0.02, 0.02, 0.95)
local C_DOT_EMPTY = vmath.vector4(0.38, 0.40, 0.43, 0.85)
local C_DOT_FILL  = vmath.vector4(1.00, 0.84, 0.20, 1.0)
local C_DOT_FLASH = vmath.vector4(1.00, 1.00, 1.00, 1.0)

-- Local Helpers
local function box(pos, size, color, pivot)
    local n = gui.new_box_node(pos, size)
    gui.set_color(n, color)
    if pivot then gui.set_pivot(n, pivot) end
    return n
end

local function label(pos, text, size, color, align, font_name)
    local n = gui.new_text_node(pos, text)
    gui.set_font(n, font_name or "body")
    local base_size = 24
    if font_name == "subtitle2" or font_name == "title" or font_name == "helvetica_bold" then
        base_size = 36
    end
    gui.set_scale(n, vmath.vector3(size / base_size, size / base_size, 1.0))
    gui.set_color(n, color or C_WHITE)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

-- FLIP CLOCK LOGIC
local function create_flipper(parent, pos)
    local root = box(pos, vmath.vector3(130, 100, 0), vmath.vector4(0.06, 0.06, 0.06, 1.0), gui.PIVOT_CENTER)
    gui.set_parent(root, parent)

    local gear_l = box(vmath.vector3(-65, 0, 0), vmath.vector3(8, 20, 0), vmath.vector4(0.04, 0.04, 0.04, 1.0), gui.PIVOT_CENTER)
    local gear_r = box(vmath.vector3(65, 0, 0), vmath.vector3(8, 20, 0), vmath.vector4(0.04, 0.04, 0.04, 1.0), gui.PIVOT_CENTER)
    gui.set_parent(gear_l, root)
    gui.set_parent(gear_r, root)

    local function make_half(pivot, color)
        local half = box(vmath.vector3(0, 0, 0), vmath.vector3(130, 50, 0), color, pivot)
        gui.set_clipping_mode(half, gui.CLIPPING_MODE_STENCIL)
        gui.set_parent(half, root)

        local lbl = label(vmath.vector3(0, 0, 0), "00", 80, C_WHITE, gui.PIVOT_CENTER, "helvetica_bold")
        -- PIVOT_CENTER centers the font's full ascent+descent metrics box —
        -- but a digit has no descender ink, so its visible glyph sits above
        -- that box's true center, reading as too high relative to `div`,
        -- the seam these two stencil-clipped halves are split at. Nudge the
        -- label down by half the (scaled) descent so the actual visible
        -- ink, not the invisible descender gap, lands on y=0.
        local ok, metrics = pcall(gui.get_text_metrics_from_node, lbl)
        if ok and metrics and metrics.max_descent then
            local s = gui.get_scale(lbl)
            gui.set_position(lbl, vmath.vector3(0, -(metrics.max_descent * s.y) / 2, 0))
        end
        gui.set_shadow(lbl, vmath.vector4(0, 0, 0, 0.6))
        gui.set_parent(lbl, half)

        local shadow = box(vmath.vector3(0, 0, 0), vmath.vector3(130, 50, 0), vmath.vector4(0,0,0,0), pivot)
        gui.set_parent(shadow, half)

        return half, lbl, shadow
    end

    local stat_top, stat_top_lbl, _ = make_half(gui.PIVOT_S, C_CARD_TOP)
    local stat_bot, stat_bot_lbl, stat_bot_shd = make_half(gui.PIVOT_N, C_CARD_BOT)
    local flip_top, flip_top_lbl, flip_top_shd = make_half(gui.PIVOT_S, C_CARD_TOP)
    local flip_bot, flip_bot_lbl, flip_bot_shd = make_half(gui.PIVOT_N, C_CARD_BOT)

    gui.set_enabled(flip_top, false)
    gui.set_enabled(flip_bot, false)

    local div = box(vmath.vector3(0, 0, 0), vmath.vector3(130, 2, 0), vmath.vector4(0,0,0,0.8), gui.PIVOT_CENTER)
    gui.set_parent(div, root)

    return {
        root = root,
        val = "00",
        stat_top = stat_top_lbl,
        stat_bot = stat_bot_lbl,
        stat_bot_shd = stat_bot_shd,
        flip_top_bg = flip_top,
        flip_top_lbl = flip_top_lbl,
        flip_top_shd = flip_top_shd,
        flip_bot_bg = flip_bot,
        flip_bot_lbl = flip_bot_lbl,
        flip_bot_shd = flip_bot_shd,
        is_flipping = false
    }
end

function M.animate_flipper(flipper, new_val)
    if not flipper or flipper.val == new_val then return end

    if flipper.is_flipping then
        gui.cancel_animation(flipper.flip_top_bg, "euler.x")
        gui.cancel_animation(flipper.flip_bot_bg, "euler.x")
        gui.cancel_animation(flipper.flip_top_shd, "color.w")
        gui.cancel_animation(flipper.flip_bot_shd, "color.w")
        gui.cancel_animation(flipper.stat_bot_shd, "color.w")

        gui.set_enabled(flipper.flip_top_bg, false)
        gui.set_enabled(flipper.flip_bot_bg, false)
        gui.set_text(flipper.stat_top, flipper.val)
        gui.set_text(flipper.stat_bot, flipper.val)
        flipper.is_flipping = false
    end

    flipper.is_flipping = true
    local old_val = flipper.val
    flipper.val = new_val

    gui.set_text(flipper.stat_top, new_val)
    gui.set_text(flipper.stat_bot, old_val)

    gui.set_text(flipper.flip_top_lbl, old_val)
    gui.set_rotation(flipper.flip_top_bg, vmath.vector3(0,0,0))
    local c_t_shd = gui.get_color(flipper.flip_top_shd); c_t_shd.w = 0; gui.set_color(flipper.flip_top_shd, c_t_shd)
    gui.set_enabled(flipper.flip_top_bg, true)

    gui.set_text(flipper.flip_bot_lbl, new_val)
    gui.set_rotation(flipper.flip_bot_bg, vmath.vector3(90,0,0))
    local c_b_shd = gui.get_color(flipper.flip_bot_shd); c_b_shd.w = 0.8; gui.set_color(flipper.flip_bot_shd, c_b_shd)
    gui.set_enabled(flipper.flip_bot_bg, true)

    local c_s_shd = gui.get_color(flipper.stat_bot_shd); c_s_shd.w = 0; gui.set_color(flipper.stat_bot_shd, c_s_shd)

    gui.animate(flipper.flip_top_bg, "euler.x", -90, gui.EASING_INQUAD, 0.15, 0, function()
        gui.set_enabled(flipper.flip_top_bg, false)
        gui.set_text(flipper.stat_bot, new_val)

        gui.animate(flipper.flip_bot_bg, "euler.x", 0, gui.EASING_OUTBOUNCE, 0.40, 0, function()
            gui.set_enabled(flipper.flip_bot_bg, false)
            flipper.is_flipping = false
        end)
        gui.animate(flipper.flip_bot_shd, "color.w", 0.0, gui.EASING_OUTBOUNCE, 0.40)
        gui.animate(flipper.stat_bot_shd, "color.w", 0.0, gui.EASING_OUTBOUNCE, 0.40)
    end)

    gui.animate(flipper.flip_top_shd, "color.w", 0.8, gui.EASING_INQUAD, 0.15)
    gui.animate(flipper.stat_bot_shd, "color.w", 0.6, gui.EASING_INQUAD, 0.15)
end

function M.snap_flipper(flipper, new_val)
    if not flipper then return end
    gui.cancel_animation(flipper.flip_top_bg, "euler.x")
    gui.cancel_animation(flipper.flip_bot_bg, "euler.x")
    gui.set_enabled(flipper.flip_top_bg, false)
    gui.set_enabled(flipper.flip_bot_bg, false)
    flipper.is_flipping = false
    flipper.val = new_val
    gui.set_text(flipper.stat_top, new_val)
    gui.set_text(flipper.stat_bot, new_val)
end

local function build_round_dots(flipper, is_top)
    flipper.dots = {}
    flipper.dots_filled = 0
    flipper.is_top = is_top

    flipper.skirting = box(vmath.vector3(0, 0, 0), vmath.vector3(140, 36, 0), vmath.vector4(0.08, 0.08, 0.08, 1), gui.PIVOT_CENTER)
    gui.set_parent(flipper.skirting, flipper.root)
    gui.set_enabled(flipper.skirting, false)

    for i = 1, 5 do
        local rim = box(vmath.vector3(0, 0, 0), vmath.vector3(ROUND_DOT_RIM_SIZE, ROUND_DOT_RIM_SIZE, 0), C_DOT_RIM, gui.PIVOT_CENTER)
        gui.set_parent(rim, flipper.root)
        
        local fill = box(vmath.vector3(0, 0, 0), vmath.vector3(ROUND_DOT_FILL_SIZE, ROUND_DOT_FILL_SIZE, 0), C_DOT_EMPTY, gui.PIVOT_CENTER)
        gui.set_parent(fill, rim)
        gui.set_enabled(rim, false)
        flipper.dots[i] = { rim = rim, fill = fill }
    end
end

function M.hide_round_dots(flipper)
    if not (flipper and flipper.dots) then return end
    for i = 1, 5 do gui.set_enabled(flipper.dots[i].rim, false) end
    if flipper.skirting then gui.set_enabled(flipper.skirting, false) end
    flipper.dots_filled = 0
end

function M.set_round_dots(flipper, needed, won, animate)
    if not (flipper and flipper.dots) then return end
    needed = math.max(1, math.min(5, tonumber(needed) or 1))
    won = math.max(0, math.min(tonumber(won) or 0, needed))

    local spacing_x = ROUND_DOT_SPACING_X 
    local dir_y = flipper.is_top and 1 or -1
    local card_edge_y = flipper.is_top and 50 or -50

    local skirting_h = 36
    local skirting_w = math.max(130, needed * spacing_x + 12)
    
    if flipper.skirting then
        gui.set_size(flipper.skirting, vmath.vector3(skirting_w, skirting_h, 0))
        local sy = card_edge_y + dir_y * (skirting_h / 2)
        gui.set_position(flipper.skirting, vmath.vector3(0, sy, 0))
        gui.set_enabled(flipper.skirting, true)
    end

    local base_y = card_edge_y + dir_y * 18
    local x0 = -((needed - 1) * spacing_x) / 2

    for i = 1, 5 do
        local d = flipper.dots[i]
        gui.set_enabled(d.rim, i <= needed)
        if i <= needed then
            local x = x0 + (i - 1) * spacing_x
            local y = base_y
            
            gui.set_position(d.rim, vmath.vector3(x, y, 0))
            
            gui.cancel_animation(d.fill, "scale")
            gui.set_scale(d.fill, vmath.vector3(1, 1, 1))
            gui.set_color(d.fill, (i <= won) and C_DOT_FILL or C_DOT_EMPTY)
        end
    end

    local prev = flipper.dots_filled or 0
    if animate and won > prev and flipper.dots[won] then
        pcall(msg.post, "/controller#snd_ping", "play_sound")
        local d = flipper.dots[won]
        gui.set_color(d.fill, C_DOT_FLASH)
        gui.set_scale(d.fill, vmath.vector3(0.1, 0.1, 1))
        gui.animate(d.fill, "scale", vmath.vector3(1.6, 1.6, 1), gui.EASING_OUTBACK, 0.38, 0.05, function()
            gui.animate(d.fill, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTSINE, 0.20)
            gui.set_color(d.fill, C_DOT_FILL)
        end)
    end
    flipper.dots_filled = won
end

-- Tear down every node + cached field this module created so the NEXT build
-- yields a brand-new scoreboard instance. Deleting a flipper root recursively
-- removes its halves, gears, dividers, round dots and skirting; deleting the
-- H2H container removes its form label and badges. This guarantees no flipper
-- values, round dots, layout, opponent name or head-to-head data leak across a
-- game-mode / player-count / board change.
function M.destroy(self)
    local function del(n) if n then pcall(gui.delete_node, n) end end

    if self.o_flipper then del(self.o_flipper.root) end
    if self.p_flipper then del(self.p_flipper.root) end
    del(self.sb_div1)
    del(self.sb_div2)
    del(self.sb_title)
    del(self.h2h_alltime_lbl)
    del(self.h2h_container)

    self.o_flipper        = nil
    self.p_flipper        = nil
    self.sb_div1          = nil
    self.sb_div2          = nil
    self.sb_title         = nil
    self.sb_root          = nil
    self.h2h_alltime_lbl  = nil
    self.h2h_container    = nil
    self.h2h_form_lbl     = nil
    self.h2h_badges       = nil
    self.opp_display_name = nil
end

function M.build(self, parent_node, logical_w, logical_h)
    -- Always start from a clean slate so a rebuild (one per fresh game) never
    -- stacks nodes or inherits cached state from the previous match.
    M.destroy(self)

    self.o_flipper = create_flipper(parent_node, vmath.vector3(0, 100, 0))
    self.p_flipper = create_flipper(parent_node, vmath.vector3(0, -100, 0))
    
    build_round_dots(self.o_flipper, true)
    build_round_dots(self.p_flipper, false)

    self.sb_div1 = box(vmath.vector3(0, 22, 0), vmath.vector3(120, 2, 0), vmath.vector4(0.2,0.2,0.2,1), gui.PIVOT_CENTER)
    self.sb_div2 = box(vmath.vector3(0, -22, 0), vmath.vector3(120, 2, 0), vmath.vector4(0.2,0.2,0.2,1), gui.PIVOT_CENTER)
    gui.set_parent(self.sb_div1, parent_node)
    gui.set_parent(self.sb_div2, parent_node)

    self.sb_title = label(vmath.vector3(0, 0, 0), "BEST OF 3", 15, C_WHITE, gui.PIVOT_CENTER, "subtitle2")
    gui.set_parent(self.sb_title, parent_node)

    self.h2h_alltime_lbl = label(vmath.vector3(-110, 0, 0), "ALL TIME 0-0", 16, C_H2H_GOLD, gui.PIVOT_CENTER, "subtitle2")
    gui.set_rotation(self.h2h_alltime_lbl, vmath.vector3(0, 0, -90))
    gui.set_parent(self.h2h_alltime_lbl, parent_node)
    gui.set_enabled(self.h2h_alltime_lbl, false)

    self.h2h_container = box(vmath.vector3(logical_w - 140, logical_h/2 - 180, 0), vmath.vector3(260, 80, 0), vmath.vector4(0.08, 0.08, 0.08, 0.85), gui.PIVOT_CENTER)
    gui.set_xanchor(self.h2h_container, gui.ANCHOR_RIGHT)
    gui.set_yanchor(self.h2h_container, gui.ANCHOR_NONE)
    gui.set_enabled(self.h2h_container, false)

    self.h2h_form_lbl = label(vmath.vector3(0, 22, 0), "YOUR LAST 5 GAMES WITH OPPONENT", 11, C_H2H_DIM, gui.PIVOT_CENTER, "subtitle2")
    gui.set_parent(self.h2h_form_lbl, self.h2h_container)

    self.h2h_badges = {}
    for i = 1, 5 do
        local x_pos = (i - 3) * 42 
        local bg = box(vmath.vector3(x_pos, -10, 0), vmath.vector3(34, 34, 0), vmath.vector4(0.2, 0.2, 0.2, 0.5), gui.PIVOT_CENTER)
        gui.set_parent(bg, self.h2h_container)
        local lbl = label(vmath.vector3(0, 0, 0), "", 18, C_WHITE, gui.PIVOT_CENTER, "subtitle2")
        gui.set_parent(lbl, bg)
        gui.set_enabled(bg, false)
        self.h2h_badges[i] = { bg = bg, lbl = lbl }
    end

    self.sb_root = parent_node
end

function M.set_active(self, active)
    if self.o_flipper then gui.set_enabled(self.o_flipper.root, active) end
    if self.p_flipper then gui.set_enabled(self.p_flipper.root, active) end
    if self.sb_div1 then gui.set_enabled(self.sb_div1, active) end
    if self.sb_div2 then gui.set_enabled(self.sb_div2, active) end
    if self.sb_title then gui.set_enabled(self.sb_title, active) end
end

function M.set_h2h_strip(self, h2h, is_series)
    local has = type(h2h) == "table"
    local form = has and type(h2h.form) == "table" and h2h.form or {}
    local has_form = has and #form > 0
    local show_alltime = has and is_series
    
    if self.h2h_container then 
        gui.set_enabled(self.h2h_container, has_form) 
        if has_form then
            local opp_name = self.opp_display_name or "OPPONENT"
            gui.set_text(self.h2h_form_lbl, "YOUR LAST 5 GAMES WITH " .. string.upper(opp_name))
        end
    end
    
    for i = 1, 5 do
        local badge = self.h2h_badges and self.h2h_badges[i]
        if badge then
            local r = form[i]
            if has and (r == "W" or r == "L") then
                gui.set_text(badge.lbl, r)
                gui.set_color(badge.bg, r == "W" and C_FORM_W or C_FORM_L)
                gui.set_enabled(badge.bg, true)
            else
                gui.set_enabled(badge.bg, false)
            end
        end
    end
    
    if self.h2h_alltime_lbl then
        if show_alltime then
            gui.set_text(self.h2h_alltime_lbl, "ALL TIME " .. tostring(h2h.p or 0) .. "-" .. tostring(h2h.o or 0))
            gui.set_enabled(self.h2h_alltime_lbl, true)
        else
            gui.set_enabled(self.h2h_alltime_lbl, false)
        end
    end
end

return M