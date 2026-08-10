local M = {}
local app_state = require("modules.app_state")

local C_WHITE       = vmath.vector4(1.0, 1.0, 1.0, 1.0)
local C_SKIP_TEXT   = vmath.vector4(0.90, 0.91, 0.92, 1.0)
local BTN_BG_COLOR  = vmath.vector4(0, 0, 0, 0.25)
local C_PANEL       = vmath.vector4(0.10, 0.10, 0.10, 0.95)
local C_PANEL_BORDER= vmath.vector4(0.30, 0.30, 0.30, 1.0)
local C_T_RED       = vmath.vector4(0.94, 0.27, 0.27, 0.6)

local AI_C_PANEL  = vmath.vector4(0.086, 0.098, 0.118, 1.0)
local AI_C_ACCENT = vmath.vector4(0.949, 0.702, 0.020, 1.0)

local EXIT_BTN_SIZE, EXIT_BTN_MARGIN_TOP, EXIT_BTN_MARGIN_RIGHT = 140, 20, 20
local EXIT_POPOVER_WIDTH, EXIT_POPOVER_HEIGHT, EXIT_POPOVER_OFFSET_Y = 200, 120, 0

-- Reconnect countdown ring: same gui.new_pie_node/set_fill_angle mechanism
-- hud_ui.lua's turn timer already uses, so this reuses a proven-working
-- pattern rather than a new one.
local CONN_RING_RADIUS = 88
local CONN_RING_TRACK  = vmath.vector4(1, 1, 1, 0.12)
local C_T_TEAL         = vmath.vector4(0.0, 0.722, 0.831, 1.0)
local C_T_TEAL_RING    = vmath.vector4(0.0, 0.722, 0.831, 0.85)
local C_T_RED_RING     = vmath.vector4(0.94, 0.27, 0.27, 0.90)

local function box(pos, size, color, pivot)
    local n = gui.new_box_node(pos, size)
    gui.set_color(n, color)
    if pivot then gui.set_pivot(n, pivot) end
    return n
end

-- Radial gradient backdrop (the same "dialog_grad" the online challenge / search
-- dialogs use) so the in-game modals share one consistent look. Parented to the
-- modal's scrim and created BEFORE the panel so it sits behind the content.
local function grad_bg(parent)
    local n = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(1440, 1440, 0))
    local ok = pcall(function() gui.set_texture(n, "ui"); gui.play_flipbook(n, hash("dialog_grad")) end)
    if ok then
        pcall(function() gui.set_adjust_mode(n, gui.ADJUST_ZOOM) end)
    else
        -- Atlas/flipbook missing: keep the node fully transparent so it never
        -- renders as a stray white square behind the modal.
        gui.set_color(n, vmath.vector4(0, 0, 0, 0))
    end
    if parent then gui.set_parent(n, parent) end
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
    grad_bg(self.conn_scrim)
    self.conn_panel = box(vmath.vector3(0, 0, 0), vmath.vector3(480, 400, 0), vmath.vector4(0.07, 0.08, 0.11, 0.98), gui.PIVOT_CENTER)
    gui.set_parent(self.conn_panel, self.conn_scrim)
    -- A thin accent strip along the top, same device the AI banner and other
    -- in-game panels use, so this reads as part of the same UI family.
    local conn_strip = box(vmath.vector3(0, 196, 0), vmath.vector3(480, 4, 0), C_T_TEAL, gui.PIVOT_CENTER)
    gui.set_parent(conn_strip, self.conn_panel)
    self.conn_strip = conn_strip

    self.conn_title = label(vmath.vector3(0, 152, 0), "RECONNECTING", 26, C_T_TEAL, gui.PIVOT_CENTER, "subtitle2")
    gui.set_parent(self.conn_title, self.conn_panel)

    -- The ring: a dim static track (the full circle, always visible) with a
    -- live fill pie on top that shrinks from a full circle to nothing as the
    -- grace period runs out — same gui.new_pie_node/set_fill_angle mechanism
    -- as hud_ui.lua's own turn timer, rotated the same way so both start
    -- draining from 12 o'clock.
    local ring_y = 8
    self.conn_ring_track = gui.new_pie_node(vmath.vector3(0, ring_y, 0), vmath.vector3(CONN_RING_RADIUS * 2, CONN_RING_RADIUS * 2, 0))
    gui.set_rotation(self.conn_ring_track, vmath.vector3(0, 0, 90))
    gui.set_color(self.conn_ring_track, CONN_RING_TRACK)
    gui.set_parent(self.conn_ring_track, self.conn_panel)

    self.conn_ring_fill = gui.new_pie_node(vmath.vector3(0, ring_y, 0), vmath.vector3(CONN_RING_RADIUS * 2, CONN_RING_RADIUS * 2, 0))
    gui.set_rotation(self.conn_ring_fill, vmath.vector3(0, 0, 90))
    gui.set_color(self.conn_ring_fill, C_T_TEAL_RING)
    gui.set_parent(self.conn_ring_fill, self.conn_panel)

    -- The countdown itself, big enough to read at a glance, sitting inside
    -- the ring.
    self.conn_count = label(vmath.vector3(0, ring_y, 0), "", 72, C_WHITE, gui.PIVOT_CENTER, "helvetica_bold")
    gui.set_parent(self.conn_count, self.conn_panel)

    self.conn_sub = label(vmath.vector3(0, -152, 0), "", 16, vmath.vector4(0.70, 0.74, 0.80, 1.0), gui.PIVOT_CENTER, "body")
    gui.set_parent(self.conn_sub, self.conn_panel)
    gui.set_enabled(self.conn_scrim, false)

    -- AI Banner: the ONLY AI notice left. Persistent AI takeover of a
    -- disconnected player's seat has been removed (a player who doesn't
    -- reconnect within the grace period is forfeited instead), so the
    -- "AKIRA HAD YOUR BACK... you are back in control" full-screen modal
    -- that used to announce a takeover ending has nothing left to announce
    -- — the backend never sends mode="TAKEOVER" any more, only the one-shot
    -- SINGLE_MOVE assist this banner covers.
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
        gui.set_color(self.conn_title, opts.danger and C_T_RED or C_T_TEAL)
        if self.conn_strip then gui.set_color(self.conn_strip, opts.danger and C_T_RED or C_T_TEAL) end
        gui.set_text(self.conn_sub, opts.subtitle or "")
        local grace = tonumber(opts.grace) or 0
        if grace > 0 then
            self.conn_deadline = socket.gettime() + grace
            self.conn_grace_total = grace
            self.conn_count_active = true
            gui.set_enabled(self.conn_count, true)
            gui.set_text(self.conn_count, string.format("%ds", math.ceil(grace)))
            -- Countdown itself carries the urgency, not just the title: teal
            -- until the last 10s, then red — same treatment as matatu-gdt's
            -- PlayerDisconnectedModal, which reads clearly as "running out"
            -- rather than a plain number nobody's watching. The ring mirrors
            -- it exactly, full circle draining to nothing as time runs out —
            -- same gui.set_fill_angle mechanism as hud_ui.lua's turn timer.
            local urgent = grace <= 10
            gui.set_color(self.conn_count, urgent and C_T_RED or C_WHITE)
            if self.conn_ring_track then gui.set_enabled(self.conn_ring_track, true) end
            if self.conn_ring_fill then
                gui.set_enabled(self.conn_ring_fill, true)
                gui.set_fill_angle(self.conn_ring_fill, 360)
                gui.set_color(self.conn_ring_fill, urgent and C_T_RED_RING or C_T_TEAL_RING)
            end
        else
            self.conn_count_active = false
            gui.set_enabled(self.conn_count, false)
            gui.set_text(self.conn_count, "")
            if self.conn_ring_track then gui.set_enabled(self.conn_ring_track, false) end
            if self.conn_ring_fill then gui.set_enabled(self.conn_ring_fill, false) end
        end
        -- Claim the "network" modal slot so app.input_blocked() (checked first
        -- thing in game.script's on_input) swallows board taps for us — the
        -- same mechanism game over/incoming-request dialogs use. Without this
        -- the scrim was purely visual: a player could still touch cards while
        -- the opponent (or they themselves) showed as disconnected.
        --
        -- NOT when it's this player's OWN turn, though (opts.block_input ==
        -- false — see game.script's ws_player_dc): the OPPONENT disconnecting
        -- has no bearing on whether this player can legally act right now,
        -- and the server processes their move exactly the same either way.
        -- Reported: the opponent drops mid-game while it's my turn, and my
        -- own cards go dead until they either reconnect or the grace period
        -- times out — my own valid turn held hostage by their connection.
        --
        -- Skipping the claim, not force-closing it: "network" is a single
        -- shared slot (see app_state.lua's M.modals) main/network.gui_script
        -- also claims for THIS device's own connectivity — an unrelated,
        -- more serious concern that must never get silently unblocked just
        -- because the opponent's connection happened to also be in flux.
        if opts.block_input ~= false then
            app_state.modal_open("network")
        end
    else
        gui.set_enabled(self.conn_scrim, false)
        self.conn_count_active = false
        app_state.modal_close("network")
    end
end

-- The one-shot notice for a turn-timeout assist: the player was online the
-- whole time, just AFK for this one turn. Persistent takeover of a
-- disconnected player's seat is gone — see the "AI Banner" comment above.
function M.show_ai_notice(self, opts)
    opts = opts or {}
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

function M.hide_ai_notices(self)
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
        local secs = math.ceil(left)
        gui.set_text(self.conn_count, string.format("%ds", secs))
        -- Flip to red once the countdown itself is inside the last 10s, not
        -- just at the moment it was first shown — set_conn_overlay's own
        -- coloring only ever ran once, at the start, so a grace period that
        -- began above 10s stayed white the whole way down to zero. The ring
        -- gets the same treatment, and drains in step with the number —
        -- both read off the same `left`/total, so they can never disagree.
        local urgent = secs <= 10
        gui.set_color(self.conn_count, urgent and C_T_RED or C_WHITE)
        local total = self.conn_grace_total or 0
        if self.conn_ring_fill and total > 0 then
            gui.set_fill_angle(self.conn_ring_fill, math.max(0, left / total) * 360)
            gui.set_color(self.conn_ring_fill, urgent and C_T_RED_RING or C_T_TEAL_RING)
        end
        if left <= 0 then self.conn_count_active = false end
    end
end

local function hit(node, action)
    if not node then return false end
    return gui.is_enabled(node) and gui.pick_node(node, action.x, action.y)
end

function M.on_input(self, action)
    -- RECONNECTING/OFFLINE overlay: no buttons on it, just swallow every tap
    -- while it's up. This was previously missing entirely — M.set_conn_overlay
    -- enables self.conn_scrim, but nothing here ever checked it, so a tap
    -- during a "RECONNECTING…"/"OFFLINE" state fell straight through the
    -- checks below to the unconditional `return false` at the bottom, all
    -- the way to game.script's own card-play input underneath.
    if self.conn_scrim and gui.is_enabled(self.conn_scrim) then
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