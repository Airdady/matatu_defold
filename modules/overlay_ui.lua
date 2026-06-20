local M = {}
local akira = require("modules.akira")

local C_WHITE       = vmath.vector4(1.0, 1.0, 1.0, 1.0)
local C_SKIP_TEXT   = vmath.vector4(0.90, 0.91, 0.92, 1.0)
local BTN_BG_COLOR  = vmath.vector4(0, 0, 0, 0.25)
local C_PANEL       = vmath.vector4(0.10, 0.10, 0.10, 0.95)
local C_PANEL_BORDER= vmath.vector4(0.30, 0.30, 0.30, 1.0)
local C_T_RED       = vmath.vector4(0.94, 0.27, 0.27, 0.6)

local AI_C_PANEL  = vmath.vector4(0.086, 0.098, 0.118, 1.0)
local AI_C_ACCENT = vmath.vector4(0.949, 0.702, 0.020, 1.0)
local AI_C_BODY   = vmath.vector4(0.788, 0.812, 0.839, 1.0)
local AI_C_DARK   = vmath.vector4(0.082, 0.094, 0.110, 1.0)

local EXIT_BTN_SIZE, EXIT_BTN_MARGIN_TOP, EXIT_BTN_MARGIN_RIGHT = 80, 10, 10
local EXIT_POPOVER_WIDTH, EXIT_POPOVER_HEIGHT, EXIT_POPOVER_OFFSET_Y = 200, 120, -10

local function box(pos, size, color, pivot)
    local n = gui.new_box_node(pos, size)
    gui.set_color(n, color)
    if pivot then gui.set_pivot(n, pivot) end
    return n
end

local function label(pos, text, size, color, align, font_name)
    local n = gui.new_text_node(pos, text)
    gui.set_font(n, font_name or "body")
    local base_size = (font_name == "subtitle2" or font_name == "title" or font_name == "helvetica_bold") and 36 or 24
    gui.set_scale(n, vmath.vector3(size / base_size, size / base_size, 1.0))
    gui.set_color(n, color or C_WHITE)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

local function poppins(pos, text, px, color, bold, align)
    local n = gui.new_text_node(pos, text)
    gui.set_font(n, bold and "subtitle2" or "body")
    local base = bold and 34 or 28
    gui.set_scale(n, vmath.vector3(px / base, px / base, 1.0))
    gui.set_color(n, color or C_WHITE)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

function M.build(self, logical_w, logical_h)
    -- Skip Button
    local width, height = 700.0, logical_h - 360.0
    self.skip_btn = box(vmath.vector3(logical_w/2, logical_h/2, 0), vmath.vector3(width, height, 0), BTN_BG_COLOR, gui.PIVOT_CENTER)
    gui.set_xanchor(self.skip_btn, gui.ANCHOR_NONE); gui.set_yanchor(self.skip_btn, gui.ANCHOR_NONE)
    local inner_border = box(vmath.vector3(0,0,0), vmath.vector3(width - 8, height - 8, 0), vmath.vector4(0,0,0,0), gui.PIVOT_CENTER)
    gui.set_parent(inner_border, self.skip_btn)
    local lbl = label(vmath.vector3(width/2 - 15, -height/2 + 10, 0), "TAP TO SKIP >>", 14, C_SKIP_TEXT, gui.PIVOT_SE, "btn_sm")
    gui.set_shadow(lbl, vmath.vector4(0, 0, 0, 0.8))
    gui.set_parent(lbl, self.skip_btn)
    gui.set_enabled(self.skip_btn, false)

    -- (The stake is now shown entirely by the live coin bundle/pot overlay
    --  in #coins — the old static stake chip has been removed.)

    -- Standings
    local st_y, st_x = logical_h - EXIT_BTN_MARGIN_TOP - EXIT_BTN_SIZE - 20, logical_w - EXIT_BTN_MARGIN_RIGHT
    self.standings_root = box(vmath.vector3(st_x, st_y, 0), vmath.vector3(220, 180, 0), vmath.vector4(0,0,0,0), gui.PIVOT_NE)
    gui.set_xanchor(self.standings_root, gui.ANCHOR_RIGHT); gui.set_yanchor(self.standings_root, gui.ANCHOR_TOP)
    self.standings_title = label(vmath.vector3(-220, 0, 0), "STANDINGS", 13, vmath.vector4(0.65, 0.68, 0.72, 1.0), gui.PIVOT_NW, "small")
    gui.set_parent(self.standings_title, self.standings_root)
    gui.set_enabled(self.standings_title, false)
    self.standings_rows = {}
    for i=1, 3 do
        local row = box(vmath.vector3(-220, -24 - (i-1)*28, 0), vmath.vector3(220, 24, 0), vmath.vector4(0,0,0,0), gui.PIVOT_NW)
        gui.set_parent(row, self.standings_root)
        local pos_lbl = label(vmath.vector3(0, -12, 0), "", 16, C_WHITE, gui.PIVOT_W, "small")
        local name_lbl = label(vmath.vector3(35, -12, 0), "", 16, C_WHITE, gui.PIVOT_W, "small")
        local pts_lbl = label(vmath.vector3(220, -12, 0), "", 16, C_WHITE, gui.PIVOT_E, "small")
        gui.set_parent(pos_lbl, row); gui.set_parent(name_lbl, row); gui.set_parent(pts_lbl, row)
        table.insert(self.standings_rows, { bg=row, pos=pos_lbl, name=name_lbl, pts=pts_lbl })
    end

    -- Exit Setup
    self.exit_btn = box(vmath.vector3(logical_w - EXIT_BTN_MARGIN_RIGHT, logical_h - EXIT_BTN_MARGIN_TOP, 0), vmath.vector3(EXIT_BTN_SIZE, EXIT_BTN_SIZE, 0), C_WHITE, gui.PIVOT_NE)
    gui.set_xanchor(self.exit_btn, gui.ANCHOR_RIGHT); gui.set_yanchor(self.exit_btn, gui.ANCHOR_TOP)
    if not pcall(function() gui.set_texture(self.exit_btn, "ui"); gui.play_flipbook(self.exit_btn, hash("exit_game")) end) then
        gui.set_color(self.exit_btn, vmath.vector4(0.8, 0.2, 0.2, 1.0))
        local l = label(vmath.vector3(-EXIT_BTN_SIZE/2, -EXIT_BTN_SIZE/2, 0), "X", 20, C_WHITE, gui.PIVOT_CENTER, "btn_md")
        gui.set_parent(l, self.exit_btn)
    end

    self.exit_popover = box(vmath.vector3(logical_w - EXIT_BTN_MARGIN_RIGHT, logical_h - EXIT_BTN_MARGIN_TOP - EXIT_BTN_SIZE + EXIT_POPOVER_OFFSET_Y, 0), vmath.vector3(EXIT_POPOVER_WIDTH, EXIT_POPOVER_HEIGHT, 0), C_PANEL, gui.PIVOT_NE)
    gui.set_xanchor(self.exit_popover, gui.ANCHOR_RIGHT); gui.set_yanchor(self.exit_popover, gui.ANCHOR_TOP)
    local ext_title = label(vmath.vector3(-EXIT_POPOVER_WIDTH/2, -30, 0), "Exit Game?", 16, C_WHITE, gui.PIVOT_CENTER, "subtitle2")
    gui.set_parent(ext_title, self.exit_popover)
    
    self.btn_yes = box(vmath.vector3(-EXIT_POPOVER_WIDTH/2 - 45, -80, 0), vmath.vector3(80, 40, 0), C_PANEL_BORDER, gui.PIVOT_CENTER)
    local ly = label(vmath.vector3(0,0,0), "Yes", 16, C_WHITE, gui.PIVOT_CENTER, "btn_sm"); gui.set_parent(ly, self.btn_yes)
    gui.set_parent(self.btn_yes, self.exit_popover)

    self.btn_no = box(vmath.vector3(-EXIT_POPOVER_WIDTH/2 + 45, -80, 0), vmath.vector3(80, 40, 0), C_PANEL_BORDER, gui.PIVOT_CENTER)
    local ln = label(vmath.vector3(0,0,0), "No", 16, C_WHITE, gui.PIVOT_CENTER, "btn_sm"); gui.set_parent(ln, self.btn_no)
    gui.set_parent(self.btn_no, self.exit_popover)
    gui.set_enabled(self.exit_popover, false)

    -- Conn Overlay
    self.conn_scrim = box(vmath.vector3(logical_w/2, logical_h/2, 0), vmath.vector3(5000, 5000, 0), vmath.vector4(0, 0, 0, 0.6), gui.PIVOT_CENTER)
    gui.set_adjust_mode(self.conn_scrim, gui.ADJUST_STRETCH)
    self.conn_panel = box(vmath.vector3(0, 0, 0), vmath.vector3(460, 190, 0), vmath.vector4(0.07, 0.08, 0.11, 0.98), gui.PIVOT_CENTER)
    gui.set_parent(self.conn_panel, self.conn_scrim)
    self.conn_title = label(vmath.vector3(0, 48, 0), "RECONNECTING", 24, vmath.vector4(0.0, 0.722, 0.831, 1.0), gui.PIVOT_CENTER, "subtitle2")
    gui.set_parent(self.conn_title, self.conn_panel)
    self.conn_sub = label(vmath.vector3(0, 8, 0), "", 16, vmath.vector4(0.70, 0.74, 0.80, 1.0), gui.PIVOT_CENTER, "body")
    gui.set_parent(self.conn_sub, self.conn_panel)
    self.conn_count = label(vmath.vector3(0, -44, 0), "", 34, C_WHITE, gui.PIVOT_CENTER, "helvetica_bold")
    gui.set_parent(self.conn_count, self.conn_panel)
    gui.set_enabled(self.conn_scrim, false)

    -- AI Modals
    self.ai_scrim = box(vmath.vector3(logical_w/2, logical_h/2, 0), vmath.vector3(5000, 5000, 0), vmath.vector4(0, 0, 0, 0.78), gui.PIVOT_CENTER)
    gui.set_adjust_mode(self.ai_scrim, gui.ADJUST_STRETCH)
    local pw, ph = 560, 280
    self.ai_panel = box(vmath.vector3(0, 0, 0), vmath.vector3(pw, ph, 0), AI_C_PANEL, gui.PIVOT_CENTER)
    gui.set_parent(self.ai_panel, self.ai_scrim)
    local strip = box(vmath.vector3(0, ph/2 - 3, 0), vmath.vector3(pw, 6, 0), AI_C_ACCENT, gui.PIVOT_CENTER)
    gui.set_parent(strip, self.ai_panel)
    local av_frame = box(vmath.vector3(-pw/2 + 64, 64, 0), vmath.vector3(76, 76, 0), AI_C_ACCENT, gui.PIVOT_CENTER)
    gui.set_parent(av_frame, self.ai_panel)
    local av_well = box(vmath.vector3(0, 0, 0), vmath.vector3(72, 72, 0), AI_C_DARK, gui.PIVOT_CENTER)
    gui.set_parent(av_well, av_frame)
    local av = box(vmath.vector3(0, 0, 0), vmath.vector3(66, 66, 0), C_WHITE, gui.PIVOT_CENTER)
    gui.set_parent(av, av_frame)
    pcall(function() gui.set_texture(av, "avatars"); gui.play_flipbook(av, hash("avatar_" .. akira.avatar())) end)

    local title = poppins(vmath.vector3(38, 84, 0), "AKIRA HAD YOUR BACK", 28, C_WHITE, true)
    local body1 = poppins(vmath.vector3(38, 46, 0), "Akira AI has been playing for you", 21, AI_C_BODY, false)
    local body2 = poppins(vmath.vector3(38, 18, 0), "to avoid losing your token.", 21, AI_C_BODY, false)
    local body3 = poppins(vmath.vector3(0, -32, 0), "You are back in control.", 18, vmath.vector4(0.55, 0.59, 0.64, 1), false)
    gui.set_parent(title, self.ai_panel); gui.set_parent(body1, self.ai_panel); gui.set_parent(body2, self.ai_panel); gui.set_parent(body3, self.ai_panel)

    self.ai_ok_btn = box(vmath.vector3(0, -92, 0), vmath.vector3(200, 56, 0), AI_C_ACCENT, gui.PIVOT_CENTER)
    gui.set_parent(self.ai_ok_btn, self.ai_panel)
    local ok_lbl = label(vmath.vector3(0, -2, 0), "GOT IT", 22, AI_C_DARK, gui.PIVOT_CENTER, "btn_md")
    gui.set_parent(ok_lbl, self.ai_ok_btn)
    gui.set_enabled(self.ai_scrim, false)

    -- AI Banner
    local bw, bh = 660, 56
    self.ai_banner = box(vmath.vector3(logical_w/2, logical_h - 52, 0), vmath.vector3(bw, bh, 0), AI_C_PANEL, gui.PIVOT_CENTER)
    gui.set_yanchor(self.ai_banner, gui.ANCHOR_TOP)
    local bstrip = box(vmath.vector3(-bw/2 + 3, 0, 0), vmath.vector3(6, bh, 0), AI_C_ACCENT, gui.PIVOT_CENTER)
    gui.set_parent(bstrip, self.ai_banner)
    self.ai_banner_lbl = poppins(vmath.vector3(0, -1, 0), "Time ran out — Akira played this move to protect your token.", 19, C_WHITE, false)
    gui.set_parent(self.ai_banner_lbl, self.ai_banner)
    gui.set_enabled(self.ai_banner, false)
end

function M.set_skip_visible(self, visible)
    if not self.skip_btn then return end
    if visible and not gui.is_enabled(self.skip_btn) then
        gui.set_enabled(self.skip_btn, true)
        gui.set_scale(self.skip_btn, vmath.vector3(0.9, 0.9, 1))
        local c = gui.get_color(self.skip_btn); c.w = 0; gui.set_color(self.skip_btn, c)

        gui.animate(self.skip_btn, "scale", vmath.vector3(1.0, 1.0, 1), gui.EASING_OUTBACK, 0.2)
        gui.animate(self.skip_btn, "color.w", 0.25, gui.EASING_OUTSINE, 0.2, 0, function()
            gui.animate(self.skip_btn, "scale", vmath.vector3(1.03, 1.03, 1), gui.EASING_INOUTSINE, 0.4, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
        end)
    elseif not visible and gui.is_enabled(self.skip_btn) then
        gui.cancel_animation(self.skip_btn, "scale")
        gui.cancel_animation(self.skip_btn, "color.w")
        gui.set_enabled(self.skip_btn, false)
    end
end

function M.update_standings(self, ranks)
    table.sort(ranks, function(a, b) return (tonumber(a.position) or 9999) < (tonumber(b.position) or 9999) end)
    if self.standings_title then gui.set_enabled(self.standings_title, #ranks > 0) end
    for i=1, 3 do
        local row = self.standings_rows[i]
        if not row then break end
        if ranks[i] then
            gui.set_enabled(row.bg, true)
            gui.set_text(row.pos, "#" .. tostring(ranks[i].position or 0))
            
            local raw_active = ranks[i].active
            local is_active = (type(raw_active) == "boolean" and raw_active) or (string.lower(tostring(raw_active)) == "true")
            
            local nm = tostring(ranks[i].username or "Player")
            if is_active then nm = "YOU" elseif #nm > 7 then nm = string.sub(nm, 1, 7) .. "…" end
            
            gui.set_text(row.name, string.upper(nm))
            gui.set_text(row.pts, tostring(ranks[i].points or 0))

            local pos_c = is_active and vmath.vector4(1, 0.84, 0, 1) or vmath.vector4(0.6, 0.6, 0.6, 1)
            local nm_c  = is_active and vmath.vector4(1, 1, 1, 1) or vmath.vector4(0.8, 0.8, 0.8, 0.8)
            local pts_c = is_active and vmath.vector4(1, 1, 1, 1) or vmath.vector4(0.7, 0.7, 0.7, 0.8)
            local s_size = is_active and 20 or 16
            
            gui.set_color(row.pos, pos_c); gui.set_color(row.name, nm_c); gui.set_color(row.pts, pts_c)
            gui.set_scale(row.pos, vmath.vector3(s_size/24, s_size/24, 1))
            gui.set_scale(row.name, vmath.vector3(s_size/24, s_size/24, 1))
            gui.set_scale(row.pts, vmath.vector3(s_size/24, s_size/24, 1))
        else
            gui.set_enabled(row.bg, false)
        end
    end
end


function M.set_conn_overlay(self, opts)
    if not self.conn_scrim then return end
    if opts and opts.show then
        gui.set_enabled(self.conn_scrim, true)
        gui.set_text(self.conn_title, opts.title or "RECONNECTING")
        gui.set_color(self.conn_title, opts.danger and C_T_RED or vmath.vector4(0.0, 0.722, 0.831, 1.0))
        gui.set_text(self.conn_sub, opts.subtitle or "")
        local grace = tonumber(opts.grace) or 0
        if grace > 0 then
            self.conn_deadline = socket.gettime() + grace
            self.conn_count_active = true
            gui.set_enabled(self.conn_count, true)
            gui.set_text(self.conn_count, string.format("%ds", math.ceil(grace)))
        else
            self.conn_count_active = false
            gui.set_enabled(self.conn_count, false)
            gui.set_text(self.conn_count, "")
        end
    else
        gui.set_enabled(self.conn_scrim, false)
        self.conn_count_active = false
    end
end

function M.show_ai_notice(self, opts)
    opts = opts or {}
    if opts.mode == "TAKEOVER" then
        if self.ai_scrim then gui.set_enabled(self.ai_scrim, true) end
    else
        if not self.ai_banner then return end
        local used = tonumber(opts.moves) or 0
        local max = tonumber(opts.max) or 3
        if self.ai_banner_lbl then
            if used > 0 then
                local txt = string.format("Time ran out — Akira played for you (%d of %d).", used, max)
                if used >= max then txt = string.format("Akira played for you (%d of %d) — next timeout forfeits!", used, max) end
                gui.set_text(self.ai_banner_lbl, txt)
            else
                gui.set_text(self.ai_banner_lbl, "Time ran out — Akira played this move to protect your token.")
            end
        end
        gui.set_enabled(self.ai_banner, true)
        self._ai_banner_seq = (self._ai_banner_seq or 0) + 1
        local seq = self._ai_banner_seq
        timer.delay(4.0, false, function()
            if seq == self._ai_banner_seq and self.ai_banner then
                gui.set_enabled(self.ai_banner, false)
            end
        end)
    end
end

function M.hide_ai_notices(self)
    if self.ai_scrim then gui.set_enabled(self.ai_scrim, false) end
    if self.ai_banner then gui.set_enabled(self.ai_banner, false) end
    self._ai_banner_seq = (self._ai_banner_seq or 0) + 1
end

function M.reset(self)
    M.set_skip_visible(self, false)
    M.set_conn_overlay(self, { show = false })
    M.hide_ai_notices(self)
    if self.exit_popover then gui.set_enabled(self.exit_popover, false) end
    if self.standings_title then gui.set_enabled(self.standings_title, false) end
    for _, row in ipairs(self.standings_rows or {}) do gui.set_enabled(row.bg, false) end
end

function M.update(self, dt)
    if self.conn_count_active then
        local left = (self.conn_deadline or 0) - socket.gettime()
        if left < 0 then left = 0 end
        gui.set_text(self.conn_count, string.format("%ds", math.ceil(left)))
        if left <= 0 then self.conn_count_active = false end
    end
end

local function hit(node, action)
    if not node then return false end
    return gui.is_enabled(node) and gui.pick_node(node, action.x, action.y)
end

function M.on_input(self, action)
    if self.ai_scrim and gui.is_enabled(self.ai_scrim) then
        if hit(self.ai_ok_btn, action) then
            gui.set_enabled(self.ai_scrim, false)
            msg.post("/controller#game_logic", "ai_notice_ack")
        end
        return true
    end

    if self.exit_popover and gui.is_enabled(self.exit_popover) then
        if hit(self.btn_yes, action) then
            gui.set_enabled(self.exit_popover, false)
            msg.post("/controller#game_logic", "exit_to_lobby")
        elseif hit(self.btn_no, action) then
            gui.set_enabled(self.exit_popover, false)
        elseif not gui.pick_node(self.exit_popover, action.x, action.y) then
            -- Tapping anywhere outside the popover dismisses it (same as "No").
            gui.set_enabled(self.exit_popover, false)
        end
        return true
    end

    if self.exit_btn and hit(self.exit_btn, action) then
        if self.exit_popover then gui.set_enabled(self.exit_popover, true) end
        return true
    end

    if self.skip_btn and gui.is_enabled(self.skip_btn) and hit(self.skip_btn, action) then
        msg.post("/controller#game_logic", "skip_pressed")
        return true
    end

    return false
end

return M