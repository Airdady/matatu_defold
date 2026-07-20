local M = {}

local C_WHITE     = vmath.vector4(1.0, 1.0, 1.0, 1.0)
local C_T_GREEN   = vmath.vector4(0.13, 0.77, 0.37, 0.8)
local C_T_ORANGE  = vmath.vector4(0.96, 0.62, 0.04, 0.8)
local C_T_RED     = vmath.vector4(0.94, 0.27, 0.27, 0.8)

local T4_TIMER_SQ = 96   
local T4_TIMER_TH = 7    
local T4_CHAMBER_ROW_GAP = 46
local LOGICAL_W, LOGICAL_H = 1280, 720

local function safe_str(val, fallback)
    if val == nil then return fallback or "" end
    return tostring(val)
end

local function safe_upper(val, fallback)
    return string.upper(safe_str(val, fallback))
end

local function label(pos, text, size, color, align, font_name)
    local n = gui.new_text_node(pos, safe_str(text))
    gui.set_font(n, font_name or "body")
    local base_size = (font_name == "subtitle2" or font_name == "subtitle1") and 36 or 24
    gui.set_scale(n, vmath.vector3(size / base_size, size / base_size, 1.0))
    gui.set_color(n, color or C_WHITE)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

local function t4_edge(x, y, w, h, pivot, color)
    local n = gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0))
    gui.set_pivot(n, pivot)
    gui.set_color(n, color)
    gui.set_xanchor(n, gui.ANCHOR_NONE)
    gui.set_yanchor(n, gui.ANCHOR_NONE)
    return n
end

local function build_square_timer(x, y)
    local S, T = T4_TIMER_SQ, T4_TIMER_TH
    local hd = S / 2
    local trk = vmath.vector4(1, 1, 1, 0.10)
    local track = {
        t4_edge(x - hd, y + hd, S, T, gui.PIVOT_W, trk),
        t4_edge(x + hd, y + hd, T, S, gui.PIVOT_N, trk),
        t4_edge(x + hd, y - hd, S, T, gui.PIVOT_E, trk),
        t4_edge(x - hd, y - hd, T, S, gui.PIVOT_S, trk),
    }
    local fills = {
        t4_edge(x - hd, y + hd, S, T, gui.PIVOT_W, C_T_GREEN),
        t4_edge(x + hd, y + hd, T, S, gui.PIVOT_N, C_T_GREEN),
        t4_edge(x + hd, y - hd, S, T, gui.PIVOT_E, C_T_GREEN),
        t4_edge(x - hd, y - hd, T, S, gui.PIVOT_S, C_T_GREEN),
    }
    return { track = track, fills = fills }
end

local function set_square_timer(frame, frac)
    if not frame then return end
    local filled = math.max(0, math.min(1, frac)) * 4
    local f = frame.fills
    gui.set_scale(f[1], vmath.vector3(math.max(0, math.min(1, filled)), 1, 1))
    gui.set_scale(f[2], vmath.vector3(1, math.max(0, math.min(1, filled - 1)), 1))
    gui.set_scale(f[3], vmath.vector3(math.max(0, math.min(1, filled - 2)), 1, 1))
    gui.set_scale(f[4], vmath.vector3(1, math.max(0, math.min(1, filled - 3)), 1))
end

local function set_square_timer_color(frame, col)
    if not frame then return end
    for _, n in ipairs(frame.fills) do gui.set_color(n, col) end
end

local function set_square_timer_enabled(frame, on)
    if not frame then return end
    for _, n in ipairs(frame.fills) do gui.set_enabled(n, on) end
    if frame.track then
        for _, n in ipairs(frame.track) do gui.set_enabled(n, on) end
    end
end

local function delete_square_timer(frame)
    if not frame then return end
    for _, n in ipairs(frame.track or {}) do pcall(gui.delete_node, n) end
    for _, n in ipairs(frame.fills or {}) do pcall(gui.delete_node, n) end
end

function M.clear_graves(self)
    for _, g in ipairs(self.t4_graves or {}) do
        pcall(gui.delete_node, g.disc); pcall(gui.delete_node, g.nm); pcall(gui.delete_node, g.tag)
    end
    self.t4_graves = {}
end

local function t4_add_grave(self, name, avatar)
    pcall(function()
        self.t4_graves = self.t4_graves or {}
        local idx = #self.t4_graves
        local gx = LOGICAL_W - 60
        local gy = LOGICAL_H - 130 - idx * 80
        local disc = gui.new_box_node(vmath.vector3(gx, gy, 0), vmath.vector3(58, 58, 0))
        gui.set_color(disc, vmath.vector4(0.16, 0.06, 0.06, 1))
        gui.set_xanchor(disc, gui.ANCHOR_RIGHT); gui.set_yanchor(disc, gui.ANCHOR_NONE)
        local av = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(50, 50, 0))
        gui.set_parent(av, disc)
        pcall(function() gui.set_texture(av, "avatars"); gui.play_flipbook(av, hash("avatar_" .. tostring(avatar or 1))) end)
        gui.set_color(av, vmath.vector4(0.6, 0.6, 0.6, 1))
        local nm = label(vmath.vector3(gx, gy - 38, 0), safe_upper(name, "PLAYER"), 13, vmath.vector4(0.72, 0.74, 0.78, 1), gui.PIVOT_CENTER, "subtitle2")
        gui.set_xanchor(nm, gui.ANCHOR_RIGHT); gui.set_yanchor(nm, gui.ANCHOR_NONE)
        local tag = label(vmath.vector3(gx + 24, gy + 24, 0), "OUT", 11, vmath.vector4(0.95, 0.40, 0.40, 1), gui.PIVOT_CENTER, "subtitle2")
        gui.set_xanchor(tag, gui.ANCHOR_RIGHT); gui.set_yanchor(tag, gui.ANCHOR_NONE)
        gui.set_scale(disc, vmath.vector3(0.4, 0.4, 1))
        gui.animate(disc, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.4)
        table.insert(self.t4_graves, { disc = disc, nm = nm, tag = tag })
    end)
end

function M.clear(self)
    pcall(function()
        if self.t4_badges then
            for _, b in pairs(self.t4_badges) do
                delete_square_timer(b.timer)
                pcall(gui.delete_node, b.disc); pcall(gui.delete_node, b.nm); pcall(gui.delete_node, b.tot)
            end
        end
        self.t4_badges = {}
        self.t4_active_slot = nil
        if self.t4_tally_root then pcall(gui.delete_node, self.t4_tally_root); self.t4_tally_root = nil end
        M.clear_graves(self)
    end)
end

function M.clear_chamber(self)
    pcall(function()
        if self.t4_chamber and self.t4_chamber.root then pcall(gui.delete_node, self.t4_chamber.root) end
        self.t4_chamber = nil
    end)
end

function M.hide_tally(self)
    if self.t4_tally_root then 
        pcall(gui.delete_node, self.t4_tally_root)
        self.t4_tally_root = nil
        self.t4_tally_rows = nil
    end
end

function M.seat(self, message)
    pcall(function()
        self.t4_badges = self.t4_badges or {}
        local slot = message.slot or "top"
        local x, y = message.x or 0, message.y or 0
        local b = self.t4_badges[slot]
        
        if not b then
            local timer_frame = build_square_timer(x, y)
            set_square_timer(timer_frame, 1.0)
            set_square_timer_enabled(timer_frame, false)
            local disc = gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(84, 84, 0))
            gui.set_color(disc, vmath.vector4(0.06, 0.07, 0.10, 1))
            gui.set_xanchor(disc, gui.ANCHOR_NONE); gui.set_yanchor(disc, gui.ANCHOR_NONE)
            local av = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(76, 76, 0))
            gui.set_parent(av, disc)
            gui.set_color(av, vmath.vector4(1, 1, 1, 1))
            pcall(function() gui.set_texture(av, "avatars"); gui.play_flipbook(av, hash("avatar_" .. tostring(message.avatar or 1))) end)
            local nm = label(vmath.vector3(x, y - 62, 0), "", 20, C_WHITE, gui.PIVOT_CENTER, "subtitle2")
            gui.set_xanchor(nm, gui.ANCHOR_NONE); gui.set_yanchor(nm, gui.ANCHOR_NONE)
            local tot = label(vmath.vector3(x, y - 86, 0), "", 18, vmath.vector4(1, 0.84, 0.2, 1), gui.PIVOT_CENTER, "subtitle2")
            gui.set_xanchor(tot, gui.ANCHOR_NONE); gui.set_yanchor(tot, gui.ANCHOR_NONE)
            gui.set_enabled(tot, false)
            b = { disc = disc, av = av, nm = nm, tot = tot, timer = timer_frame }
            self.t4_badges[slot] = b
        end

        b.home_x, b.home_y = x, y
        pcall(function() gui.play_flipbook(b.av, hash("avatar_" .. tostring(message.avatar or 1))) end)

        gui.animate(b.disc, "position", vmath.vector3(x, y, 0), gui.EASING_INOUTSINE, 0.6)
        gui.animate(b.disc, "scale", vmath.vector3(1, 1, 1), gui.EASING_INOUTSINE, 0.6)
        gui.set_pivot(b.nm, gui.PIVOT_CENTER)
        gui.animate(b.nm, "position", vmath.vector3(x, y - 62, 0), gui.EASING_INOUTSINE, 0.6)
        gui.set_pivot(b.tot, gui.PIVOT_CENTER)
        gui.animate(b.tot, "position", vmath.vector3(x, y - 86, 0), gui.EASING_INOUTSINE, 0.6)
        gui.set_scale(b.tot, vmath.vector3(1, 1, 1))

        gui.set_text(b.nm, safe_upper(message.name, "AI"))
        
        local frame_col = message.eliminated and vmath.vector4(0.22, 0.05, 0.05, 1) or (message.active and vmath.vector4(0.10, 0.12, 0.05, 1) or vmath.vector4(0.06, 0.07, 0.10, 1))
        gui.set_color(b.disc, frame_col)
        
        if message.eliminated then
            gui.set_text(b.tot, "OUT"); gui.set_enabled(b.tot, true)
        else
            gui.set_enabled(b.tot, false)
        end
        if not message.active then set_square_timer_enabled(b.timer, false) end
    end)
end

function M.active(self, message)
    pcall(function()
        self.t4_active_slot = message.slot
        self.t4_timer_total = message.duration or 3
        self.t4_timer_left  = self.t4_timer_total
        for s, b in pairs(self.t4_badges or {}) do
            if s == message.slot then
                set_square_timer_enabled(b.timer, true)
                set_square_timer(b.timer, 1.0)
                set_square_timer_color(b.timer, C_T_GREEN)
                gui.set_color(b.disc, vmath.vector4(0.10, 0.12, 0.05, 1))
            else
                set_square_timer_enabled(b.timer, false)
                gui.set_color(b.disc, vmath.vector4(0.06, 0.07, 0.10, 1))
            end
        end
    end)
end

function M.count(self, message)
    pcall(function()
        local b = (self.t4_badges or {})[message.slot]
        if b then
            gui.set_color(b.disc, vmath.vector4(0.16, 0.18, 0.06, 1))
            gui.set_scale(b.disc, vmath.vector3(1.12, 1.12, 1))
            gui.animate(b.disc, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTSINE, 0.5)
        end
    end)
end

local T4_PODIUM_X = LOGICAL_W / 2 - 300
local T4_PODIUM_Y = LOGICAL_H / 2

function M.count_focus(self, message)
    pcall(function()
        local b = (self.t4_badges or {})[message.slot]
        if not b then return end
        set_square_timer_enabled(b.timer, false)
        gui.cancel_animation(b.disc, "euler.z"); gui.set_rotation(b.disc, vmath.vector3(0, 0, 0))
        gui.animate(b.disc, "position", vmath.vector3(T4_PODIUM_X, T4_PODIUM_Y, 0), gui.EASING_INOUTSINE, 0.5)
        gui.animate(b.disc, "scale", vmath.vector3(1.3, 1.3, 1), gui.EASING_OUTBACK, 0.55)
        gui.set_color(b.disc, vmath.vector4(0.16, 0.18, 0.06, 1))
        gui.set_pivot(b.nm, gui.PIVOT_CENTER)
        gui.animate(b.nm, "position", vmath.vector3(T4_PODIUM_X, T4_PODIUM_Y - 66, 0), gui.EASING_INOUTSINE, 0.5)
        gui.set_text(b.tot, "0")
        gui.set_color(b.tot, vmath.vector4(1, 0.84, 0.2, 1))
        gui.set_pivot(b.tot, gui.PIVOT_W)
        gui.set_scale(b.tot, vmath.vector3(2.4, 2.4, 1))
        gui.set_position(b.tot, vmath.vector3(T4_PODIUM_X + 64, T4_PODIUM_Y, 0))
        gui.set_enabled(b.tot, true)
    end)
end

function M.count_tick(self, message)
    pcall(function()
        local b = (self.t4_badges or {})[message.slot]
        if not b then return end
        local added_val = tonumber(message.added_val) or 0
        if added_val > 0 then
            local ftxt = label(vmath.vector3(message.cx or 0, message.cy or 0, 0), "+" .. tostring(added_val), 40, vmath.vector4(1, 0.55, 0.2, 1), gui.PIVOT_CENTER, "btn_md")
            gui.set_shadow(ftxt, vmath.vector4(0, 0, 0, 1))
            gui.animate(ftxt, "position", vmath.vector3(T4_PODIUM_X + 90, T4_PODIUM_Y, 0), gui.EASING_INSINE, 0.42, 0, function()
                pcall(gui.delete_node, ftxt)
                gui.cancel_animation(b.tot, "scale")
                gui.set_text(b.tot, tostring(message.total or 0))
                gui.set_scale(b.tot, vmath.vector3(3.0, 3.0, 1))
                gui.animate(b.tot, "scale", vmath.vector3(2.4, 2.4, 1), gui.EASING_OUTBOUNCE, 0.3)
            end)
        else
            gui.set_text(b.tot, tostring(message.total or 0))
        end
    end)
end

function M.count_unfocus(self, message)
    pcall(function()
        local b = (self.t4_badges or {})[message.slot]
        if not b then return end
        local hx, hy = b.home_x or T4_PODIUM_X, b.home_y or T4_PODIUM_Y
        gui.animate(b.disc, "position", vmath.vector3(hx, hy, 0), gui.EASING_INOUTSINE, 0.5)
        gui.animate(b.disc, "scale", vmath.vector3(1, 1, 1), gui.EASING_INOUTSINE, 0.5)
        gui.set_color(b.disc, vmath.vector4(0.06, 0.07, 0.10, 1))
        gui.set_pivot(b.nm, gui.PIVOT_CENTER)
        gui.animate(b.nm, "position", vmath.vector3(hx, hy - 62, 0), gui.EASING_INOUTSINE, 0.5)
        gui.set_pivot(b.tot, gui.PIVOT_CENTER)
        gui.animate(b.tot, "scale", vmath.vector3(0.9, 0.9, 1), gui.EASING_INOUTSINE, 0.5)
        gui.animate(b.tot, "position", vmath.vector3(hx, hy - 86, 0), gui.EASING_INOUTSINE, 0.5)
    end)
end

function M.elimination_sequence(self, message)
    pcall(function()
        local worst_name, worst_slot, worst_avatar = message.worst_name, message.worst_slot, message.worst_avatar
        local drama = label(vmath.vector3(LOGICAL_W / 2, LOGICAL_H / 2 + 210, 0), safe_upper(worst_name, "PLAYER") .. " IS WIPED OUT!", 46, vmath.vector4(1, 0.25, 0.25, 1), gui.PIVOT_CENTER, "subtitle1")
        gui.set_scale(drama, vmath.vector3(0.2, 0.2, 1))
        gui.animate(drama, "scale", vmath.vector3(1.0, 1.0, 1), gui.EASING_OUTBACK, 0.45)
        gui.animate(drama, "color.w", 0, gui.EASING_INSINE, 0.6, 2.2, function() pcall(gui.delete_node, drama) end)

        local b = (self.t4_badges or {})[worst_slot]
        if not b then
            t4_add_grave(self, worst_name, worst_avatar)
            return
        end

        gui.set_color(b.disc, vmath.vector4(0.8, 0.1, 0.1, 1))
        gui.set_scale(b.disc, vmath.vector3(1, 1, 1))
        gui.animate(b.disc, "scale", vmath.vector3(1.14, 1.14, 1), gui.EASING_INOUTSINE, 0.22, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)

        local idx = #(self.t4_graves or {})
        local gx = LOGICAL_W - 60
        local gy = LOGICAL_H - 130 - idx * 80

        timer.delay(1.3, false, function()
            gui.cancel_animation(b.disc, "scale")
            gui.animate(b.disc, "position", vmath.vector3(gx, gy, 0), gui.EASING_INBACK, 0.6)
            gui.animate(b.disc, "scale", vmath.vector3(0.62, 0.62, 1), gui.EASING_INBACK, 0.6)
            gui.animate(b.disc, "euler.z", 30, gui.EASING_LINEAR, 0.6)
            gui.animate(b.nm, "position", vmath.vector3(gx, gy - 36, 0), gui.EASING_INBACK, 0.6)
            gui.animate(b.tot, "color.w", 0, gui.EASING_INSINE, 0.3)

            timer.delay(0.62, false, function()
                t4_add_grave(self, worst_name, worst_avatar)
                pcall(gui.delete_node, b.disc); pcall(gui.delete_node, b.nm); pcall(gui.delete_node, b.tot)
                if self.t4_badges then self.t4_badges[worst_slot] = nil end
            end)
        end)
    end)
end

-- ============================================================================
-- MINIMAL OVERVIEW & EXPANDABLE ROUND HISTORY LIST
-- ============================================================================

local function t4_chamber_row_y(i) return -58 - i * T4_CHAMBER_ROW_GAP end

local function t4_chamber_reflow(self)
    if not (self.t4_chamber and self.t4_chamber.list) then return end
    local list = self.t4_chamber.list
    local order = {}
    for _, e in ipairs(list) do order[#order + 1] = e end
    table.sort(order, function(a, b)
        local ae = a.eliminated and 1 or 0
        local be = b.eliminated and 1 or 0
        if ae ~= be then return ae < be end
        if a.total ~= b.total then return a.total < b.total end
        return a.idx < b.idx
    end)
    for slot, e in ipairs(order) do
        local base_y = t4_chamber_row_y(slot - 1)
        gui.set_text(e.rk, tostring(slot))
        for _, nd in ipairs(e.nodes) do
            gui.cancel_animation(nd.node, "position.y")
            gui.animate(nd.node, "position.y", base_y + nd.dy, gui.EASING_INOUTSINE, 0.4)
        end
    end
end

function M.chamber_init(self, message)
    pcall(function()
        if self.t4_chamber and self.t4_chamber.root then pcall(gui.delete_node, self.t4_chamber.root) end
        
        local threshold = message.threshold or 100
        local rows = message.rows or {}
        local n = #rows
        local HELPER_H = 26
        local height = 66 + n * T4_CHAMBER_ROW_GAP + HELPER_H
        
        local gap_left = 40
        local width = 235
        local rx = gap_left
        local ry = LOGICAL_H - 14
        
        if message.placement == "left_center" or message.placement == "right_center" then
            rx = gap_left
            ry = math.floor(LOGICAL_H / 2 + height / 2)
        end
        
        local root = gui.new_box_node(vmath.vector3(rx, ry, 0), vmath.vector3(width, height, 0))
        gui.set_pivot(root, gui.PIVOT_NW)
        gui.set_color(root, vmath.vector4(0.08, 0.1, 0.14, 0.95))
        gui.set_xanchor(root, gui.ANCHOR_LEFT); gui.set_yanchor(root, gui.ANCHOR_NONE)
        
        local title = label(vmath.vector3(width/2, -26, 0), "SCORE CAP  " .. tostring(threshold), 30, vmath.vector4(1, 0.84, 0.2, 1), gui.PIVOT_CENTER, "subtitle1")
        gui.set_parent(title, root)
        
        self.t4_chamber = { root = root, title = title, threshold = threshold, rows = {}, list = {}, base_width = width, base_height = height }
        
        for i, r in ipairs(rows) do
            local ry_offset = t4_chamber_row_y(i - 1)
            local total = r.total or 0
            
            local bg = gui.new_box_node(vmath.vector3(width/2, ry_offset - 4, 0), vmath.vector3(width - 16, 42, 0))
            gui.set_color(bg, vmath.vector4(0.14, 0.16, 0.22, 0.8))
            gui.set_parent(bg, root)
            
            local rk = label(vmath.vector3(18, ry_offset, 0), tostring(i), 15, vmath.vector4(1, 0.84, 0.2, 1), gui.PIVOT_W, "subtitle2")
            gui.set_parent(rk, root)
            
            local nm = label(vmath.vector3(44, ry_offset, 0), safe_upper(r.name, ""), 18, C_WHITE, gui.PIVOT_W, "subtitle2")
            gui.set_parent(nm, root)
            
            local val = label(vmath.vector3(width - 16, ry_offset, 0), tostring(total), 34, C_WHITE, gui.PIVOT_E, "subtitle1")
            gui.set_parent(val, root)
            
            local trk = gui.new_box_node(vmath.vector3(44, ry_offset - 17, 0), vmath.vector3(width - 64, 5, 0))
            gui.set_pivot(trk, gui.PIVOT_W); gui.set_color(trk, vmath.vector4(1, 1, 1, 0.12)); gui.set_parent(trk, root)
            
            local fill = gui.new_box_node(vmath.vector3(44, ry_offset - 17, 0), vmath.vector3(width - 64, 5, 0))
            gui.set_pivot(fill, gui.PIVOT_W); gui.set_color(fill, C_T_GREEN); gui.set_parent(fill, root)
            local frac = math.min(1, total / math.max(1, threshold))
            gui.set_scale(fill, vmath.vector3(frac, 1, 1))
            
            local entry = {
                idx = i, total = total, eliminated = false, rk = rk, nm = nm, val = val, fill = fill, trk = trk, bg = bg,
                nodes = { {node=bg, dy=-4}, {node=rk, dy=0}, {node=nm, dy=0}, {node=val, dy=0}, {node=trk, dy=-17}, {node=fill, dy=-17} },
                key = safe_upper(r.name, "")
            }
            self.t4_chamber.rows[entry.key] = entry
            self.t4_chamber.list[i] = entry
        end

        -- Explain the rule at a glance — it's the opposite of most scoring
        -- displays (lower is safer here), so spell it out under the rows,
        -- naming the actual cap so it's clear WHAT triggers elimination.
        local helper_y = -58 - n * T4_CHAMBER_ROW_GAP + 4
        local helper_text = "Hit " .. tostring(threshold) .. " = eliminated"
        local helper = label(vmath.vector3(width/2, helper_y, 0), helper_text, 12, vmath.vector4(0.65, 0.68, 0.72, 1), gui.PIVOT_CENTER, "body")
        gui.set_parent(helper, root)
        self.t4_chamber.helper = helper
    end)
end

-- Re-sort the standings board (lowest total on top). Called explicitly, once
-- per round transition — NOT from every chamber_update — so the board only
-- ever reorders when a new round is actually being initialized, instead of
-- shuffling positions mid-round on every incidental score-sync tick.
function M.chamber_reflow(self)
    t4_chamber_reflow(self)
end

function M.chamber_update(self, message)
    pcall(function()
        if not (self.t4_chamber and self.t4_chamber.rows) then return end
        local row = self.t4_chamber.rows[safe_upper(message.name or "", "")]
        if not row then return end
        
        local thr = message.threshold or self.t4_chamber.threshold or 100
        row.total = message.total or 0
        if message.eliminated then row.eliminated = true end
        
        local frac = math.min(1, row.total / math.max(1, thr))
        gui.animate(row.fill, "scale.x", frac, gui.EASING_OUTCUBIC, 0.5)
        local col = C_T_GREEN
        if frac >= 1 then col = C_T_RED elseif frac >= 0.66 then col = C_T_ORANGE end
        gui.set_color(row.fill, col)
        
        local added = tonumber(message.added) or 0
        if added > 0 and message.cx and message.cy then
            pcall(msg.post, "/controller#snd_ping", "play_sound")
            
            local ftxt = label(vmath.vector3(message.cx, message.cy, 0), "+" .. tostring(added), 18, vmath.vector4(1, 0.55, 0.2, 1), gui.PIVOT_CENTER, "subtitle1")
            gui.set_shadow(ftxt, vmath.vector4(0, 0, 0, 1))
            
            local rx = gui.get_position(self.t4_chamber.root).x
            local ry = gui.get_position(self.t4_chamber.root).y
            local val_pos = gui.get_position(row.val)
            
            local target_x = (rx + val_pos.x) - 90
            local target_y = ry + val_pos.y
            
            gui.animate(ftxt, "position", vmath.vector3(target_x, target_y, 0), gui.EASING_INSINE, 0.42, 0, function()
                pcall(gui.delete_node, ftxt)
                gui.cancel_animation(row.val, "scale")
                gui.set_text(row.val, tostring(row.total))
                gui.set_scale(row.val, vmath.vector3(1.4, 1.4, 1))
                gui.animate(row.val, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBOUNCE, 0.4)
            end)
        else
            gui.set_text(row.val, tostring(row.total))
        end
        
        if message.eliminated then
            gui.set_color(row.nm, vmath.vector4(0.5, 0.5, 0.55, 1))
            gui.set_color(row.val, vmath.vector4(0.95, 0.32, 0.32, 1))
        end
    end)
end

function M.chamber_expand(self, message)
    pcall(function()
        if not self.t4_chamber then return end
        
        local history = message.history or {}
        local players = message.players or {}
        local my_id = message.my_id or ""
        
        local ordered_keys = {}
        for i, e in ipairs(self.t4_chamber.list) do
            table.insert(ordered_keys, e.key)
        end
        local n_players = #ordered_keys
        if n_players == 0 then return end
        
        local new_width = math.max(self.t4_chamber.base_width, 240 + n_players * 80)
        local new_height = self.t4_chamber.base_height + 40 + (#history * 32) + 10
        
        gui.animate(self.t4_chamber.root, "size", vmath.vector3(new_width, new_height, 0), gui.EASING_INOUTSINE, 0.4)
        gui.animate(self.t4_chamber.title, "position.x", new_width / 2, gui.EASING_INOUTSINE, 0.4)
        
        for _, e in ipairs(self.t4_chamber.list) do
            gui.animate(e.bg, "size.x", new_width - 16, gui.EASING_INOUTSINE, 0.4)
            gui.animate(e.bg, "position.x", new_width / 2, gui.EASING_INOUTSINE, 0.4)
            gui.animate(e.val, "position.x", new_width - 16, gui.EASING_INOUTSINE, 0.4)
            gui.animate(e.trk, "color.w", 0, gui.EASING_OUTSINE, 0.2)
            gui.animate(e.fill, "color.w", 0, gui.EASING_OUTSINE, 0.2)
        end
        
        local hist_node = gui.new_box_node(vmath.vector3(0, -self.t4_chamber.base_height, 0), vmath.vector3(new_width, new_height - self.t4_chamber.base_height, 0))
        gui.set_pivot(hist_node, gui.PIVOT_NW)
        gui.set_color(hist_node, vmath.vector4(0,0,0,0))
        gui.set_parent(hist_node, self.t4_chamber.root)
        self.t4_chamber.hist_node = hist_node
        self.t4_chamber.hist_rows = {}
        
        local header_y = -20
        local c_w = (new_width - 120) / n_players
        
        for i, row in ipairs(history) do
            local ry = header_y - (i * 32)
            local r_bg = gui.new_box_node(vmath.vector3(new_width/2, ry, 0), vmath.vector3(new_width - 20, 28, 0))
            gui.set_color(r_bg, i % 2 == 0 and vmath.vector4(1,1,1, 0.05) or vmath.vector4(0,0,0,0))
            gui.set_parent(r_bg, hist_node)
            table.insert(self.t4_chamber.hist_rows, r_bg)
            
            local l_game = label(vmath.vector3(10 - new_width/2, 0, 0), "R" .. tostring(i), 16, vmath.vector4(0.7,0.7,0.7,1), gui.PIVOT_W, "body")
            gui.set_parent(l_game, r_bg)
            
            for col_idx, key in ipairs(ordered_keys) do
                local val = 0
                if type(row) == "table" then
                    for h_k, h_v in pairs(row) do
                        local mapped_name = h_k
                        if players and players[h_k] then 
                            mapped_name = string.upper(players[h_k].username or players[h_k].name or h_k) 
                        end
                        if mapped_name == key or (key == "YOU" and tostring(h_k) == tostring(my_id)) then
                            val = tonumber(h_v) or 0
                            break
                        end
                    end
                end
                
                local cx = (100 - new_width/2) + (col_idx - 0.5) * c_w
                local col_color = (key == "YOU") and C_T_GREEN or C_WHITE
                local l_val = label(vmath.vector3(cx, 0, 0), tostring(val), 16, col_color, gui.PIVOT_CENTER, "body")
                gui.set_parent(l_val, r_bg)
            end
        end
        
        local c = gui.get_color(hist_node); c.w = 0; gui.set_color(hist_node, c)
        gui.animate(hist_node, "color.w", 1, gui.EASING_INSINE, 0.4)
    end)
end

function M.chamber_collapse(self)
    pcall(function()
        if not self.t4_chamber or not self.t4_chamber.hist_node then return end
        
        gui.animate(self.t4_chamber.hist_node, "color.w", 0, gui.EASING_OUTSINE, 0.3, 0, function()
            pcall(gui.delete_node, self.t4_chamber.hist_node)
            self.t4_chamber.hist_node = nil
            self.t4_chamber.hist_rows = nil
        end)
        
        gui.animate(self.t4_chamber.root, "size", vmath.vector3(self.t4_chamber.base_width, self.t4_chamber.base_height, 0), gui.EASING_INOUTSINE, 0.4)
        gui.animate(self.t4_chamber.title, "position.x", self.t4_chamber.base_width / 2, gui.EASING_INOUTSINE, 0.4)
        
        for _, e in ipairs(self.t4_chamber.list) do
            gui.animate(e.bg, "size.x", self.t4_chamber.base_width - 16, gui.EASING_INOUTSINE, 0.4)
            gui.animate(e.bg, "position.x", self.t4_chamber.base_width / 2, gui.EASING_INOUTSINE, 0.4)
            gui.animate(e.val, "position.x", self.t4_chamber.base_width - 16, gui.EASING_INOUTSINE, 0.4)
            gui.animate(e.trk, "color.w", 0.12, gui.EASING_INSINE, 0.4)
            gui.animate(e.fill, "color.w", 1.0, gui.EASING_INSINE, 0.4)
        end
    end)
end

function M.flash(self, message)
    pcall(function()
        local fl = label(vmath.vector3(LOGICAL_W/2, LOGICAL_H/2 + 80, 0), tostring(message.text or ""), 40, vmath.vector4(1, 0.84, 0.2, 1), gui.PIVOT_CENTER, "subtitle1")
        gui.set_scale(fl, vmath.vector3(0.5, 0.5, 1))
        gui.animate(fl, "scale", vmath.vector3(1.1, 1.1, 1), gui.EASING_OUTBACK, 0.3)
        gui.animate(fl, "color.w", 0, gui.EASING_INSINE, 0.5, 1.5, function() pcall(gui.delete_node, fl) end)
    end)
end

function M.update(self, dt)
    pcall(function()
        if self.t4_active_slot and self.t4_badges and self.t4_badges[self.t4_active_slot] then
            self.t4_timer_left = math.max(0, (self.t4_timer_left or 0) - dt)
            local frac = (self.t4_timer_total and self.t4_timer_total > 0) and (self.t4_timer_left / self.t4_timer_total) or 0
            local frame = self.t4_badges[self.t4_active_slot].timer
            if frame then
                set_square_timer(frame, frac)
                local col = C_T_GREEN
                if frac < 0.33 then col = C_T_RED elseif frac < 0.66 then col = C_T_ORANGE end
                set_square_timer_color(frame, col)
            end
        end
    end)
end

return M