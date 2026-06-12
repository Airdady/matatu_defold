-- modules/online_center.lua
-- Center panel: deadline banner, header bar, tabs, stakes selector, user list.
-- Called from online.gui_script via M.draw(self, ctx).

local ws     = require("modules.websocket_manager")
local config = require("modules.config")

local TAB_QUICK   = 1
local TAB_BATTLES = 2

local M = {}

function M.draw(self, ctx)
    local C          = ctx.C
    local track      = ctx.track
    local txtL       = ctx.txtL
    local txtR       = ctx.txtR
    local commas     = ctx.commas
    local get_layout = ctx.get_layout
    local ui         = ctx.ui

    local _, _, div_lx, div_rx = get_layout()
    local center_cx = (div_lx + div_rx) / 2
    local content_l = div_lx + C.CENTER_PAD
    local content_r = div_rx - C.CENTER_PAD
    local list_w    = content_r - content_l
    local cx        = center_cx

    local top = ctx.EDGE_T

    -- ── Final-day reminder banner ─────────────────────────────────────────
    if self.deadline and self.deadline ~= "" then
        local bh  = 46
        local bcy = top - bh/2
        local urgent = (self.deadline_urgency == "FINAL HOUR!" or self.deadline_urgency == "Time running out!")
        track(self, ui.box(vmath.vector3(center_cx, bcy, 0), vmath.vector3(list_w, bh, 0),
            urgent and vmath.vector4(0.42, 0.07, 0.07, 0.98) or vmath.vector4(0.16, 0.12, 0.02, 0.98)))
        track(self, ui.box(vmath.vector3(center_cx, bcy - bh/2 + 1.5, 0), vmath.vector3(list_w, 3, 0), C.COL_GOLD))
        track(self, ui.box(vmath.vector3(content_l + 12, bcy, 0), vmath.vector3(10, 10, 0), urgent and C.COL_RED or C.COL_GOLD))
        txtL(self, content_l + 26, bcy + 9, "FINAL DAY · " .. self.deadline, "small", C.COL_GOLD)
        txtL(self, content_l + 26, bcy - 9, "Prizes paid today — climb the standings!", "small", C.COL_BRIGHT)
        txtR(self, content_r - 8, bcy + 9, self.deadline_clock or "", "body", urgent and C.COL_RED or C.COL_WHITE)
        txtR(self, content_r - 8, bcy - 9, self.deadline_urgency or "", "small", urgent and C.COL_RED or C.COL_MID)
        top = top - bh - 4
    end

    -- ── Header bar ────────────────────────────────────────────────────────
    local hdr_h = 72
    local hcy   = top - hdr_h/2
    track(self, ui.box(vmath.vector3(center_cx, hcy, 0), vmath.vector3(list_w, hdr_h, 0), C.COL_HEADER_BG))
    track(self, ui.box(vmath.vector3(center_cx, hcy - hdr_h/2 + 1, 0), vmath.vector3(list_w, 1, 0), C.COL_BORDER))
    txtL(self, content_l + 6, hcy + 12,  "AVAILABLE PLAYERS", "body", C.COL_BRIGHT)
    local helper = txtL(self, content_l + 6, hcy - 14, "Tap a player to request a game. If they decline, try another!", "small", C.COL_MID)
    gui.set_scale(helper, vmath.vector3(0.8, 0.8, 1))

    -- Removed the extra gap below the header
    local cy = top - hdr_h

    -- ── Tabs ──────────────────────────────────────────────────────────────
    local tabw  = (list_w / 2) - 4
    local tab_qx = cx - tabw/2 - 2
    local tab_bx = cx + tabw/2 + 2
    local tab_h  = 44

    local q_col = self.tab == TAB_QUICK   and C.COL_WHITE or C.COL_DIM
    local b_col = self.tab == TAB_BATTLES and C.COL_GOLD  or C.COL_DIM

    local btn_q = track(self, ui.box(vmath.vector3(tab_qx, cy - tab_h/2, 0), vmath.vector3(tabw, tab_h, 0),
        self.tab == TAB_QUICK   and vmath.vector4(0.2,0.2,0.2,1) or vmath.vector4(0.1,0.1,0.1,0.5)))
    local btn_b = track(self, ui.box(vmath.vector3(tab_bx, cy - tab_h/2, 0), vmath.vector3(tabw, tab_h, 0),
        self.tab == TAB_BATTLES and vmath.vector4(0.2,0.2,0.2,1) or vmath.vector4(0.1,0.1,0.1,0.5)))
    self.buttons[#self.buttons+1] = { node = btn_q, id = "tab_quick" }
    self.buttons[#self.buttons+1] = { node = btn_b, id = "tab_battles" }

    -- Text shifted down by 3 pixels so it sits more centrally in the tab button
    track(self, ui.text(vmath.vector3(tab_qx, cy - tab_h/2 - 3, 0), "QUICK PLAY",     "luckiest_guy_md", q_col))
    track(self, ui.text(vmath.vector3(tab_bx, cy - tab_h/2 - 3, 0), "BATTLE GROUNDS", "luckiest_guy_md", b_col))

    if self.tab == TAB_QUICK then
        track(self, ui.box(vmath.vector3(tab_qx, cy - tab_h, 0), vmath.vector3(tabw, 2, 0), C.COL_WHITE))
    else
        track(self, ui.box(vmath.vector3(tab_bx, cy - tab_h, 0), vmath.vector3(tabw, 2, 0), C.COL_GOLD))
    end
    
    -- Added gap between the tabs and the stakes container below
    cy = cy - tab_h - 12

    -- ── Stakes selector (Quick Play only) ────────────────────────────────
    local list_top = cy
    if self.tab == TAB_QUICK then
        local stakes_gap   = 10
        local stake_card_h = 62
        local st_w         = (list_w - (3 * stakes_gap)) / 4
        
        local my_balance  = tonumber((ws.current_user_data or {}).balance) or 0
        local stakes      = { 50, 200, 500, 1000 }

        for i, st in ipairs(stakes) do
            local sx       = content_l + (i - 0.5) * st_w + (i - 1) * stakes_gap
            local is_active = (config.STAKE_LEVELS[self.stake_index] and config.STAKE_LEVELS[self.stake_index].amount == st)
            local affordable = (my_balance >= st)

            -- Keep only the base styling and the active class container background
            track(self, ui.btn9(vmath.vector3(sx, cy - stake_card_h/2, 0), vmath.vector3(st_w, stake_card_h, 0),
                is_active and "container_bg_active" or "container_bg"))

            local btn = track(self, ui.box(vmath.vector3(sx, cy - stake_card_h/2, 0), vmath.vector3(st_w, stake_card_h, 0),
                vmath.vector4(0, 0, 0, 0)))
            self.buttons[#self.buttons+1] = { node = btn, id = "stake_"..i, data = i + 1 }

            local amt_col = is_active and C.COL_RED or (affordable and C.COL_WHITE or C.COL_DIM)
            track(self, ui.text(vmath.vector3(sx, cy - stake_card_h/2 - 6, 0), tostring(st), "body", amt_col))
            track(self, ui.text(vmath.vector3(sx, cy - stake_card_h/2 + 16, 0), "COINS", "small", C.COL_DIM))
        end
        
        -- Gap below the stakes container before the user list
        cy = cy - stake_card_h - 12
        list_top = cy
    end

    -- ── User list ─────────────────────────────────────────────────────────
    local list_bottom = ctx.EDGE_B + 20
    local region_h    = list_top - list_bottom
    local row_h       = C.ROW_H_LIST
    -- Completely removed the gap (row_gap) between rows for a perfect stripe format
    local step        = row_h

    local users = ws.get_online_users() or {}
    local my_id = ws.get_current_user_id()

    local rows = {}
    for _, pu in ipairs(users) do
        if pu._id ~= my_id then rows[#rows+1] = pu end
    end

    local content_h  = #rows * step
    local max_scroll = math.max(0, content_h - region_h)
    self.list_scroll = math.max(0, math.min(self.list_scroll or 0, max_scroll))

    if #rows == 0 then
        local msg = ws.socket_connected and "No opponents online right now" or "Connecting..."
        track(self, ui.text(vmath.vector3(cx, list_top - region_h/2, 0), msg, "body", C.COL_DIM))
        self.list_region = nil
        return
    end

    self.list_region = { top = list_top, bottom = list_bottom, left = content_l, right = content_r, x = cx }

    local y = list_top - row_h/2 - (self.list_scroll or 0)
    for i, pu in ipairs(rows) do
        local row_cy = y - (i-1) * step
        if row_cy + row_h/2 >= list_bottom and row_cy - row_h/2 <= list_top then
            local playing = pu.gameId and pu.gameId ~= ""
            local is_ai   = pu.isAI or tostring(pu._id or ""):find("^ai_bot")

            local rowcol = (i % 2 == 0)
                and vmath.vector4(0.10, 0.08, 0.06, 0.9)
                or  vmath.vector4(0.10, 0.08, 0.06, 0.35)
            local frame = track(self, ui.box(vmath.vector3(cx, row_cy, 0), vmath.vector3(list_w, row_h, 0), rowcol))

            local name_x   = content_l + C.INNER_PAD
            local name_col = playing and vmath.vector4(0.5,0.5,0.5,1) or C.COL_WHITE
            txtL(self, name_x, row_cy, string.upper(pu.username or "PLAYER"), "helvetica_bold", name_col)

            local badge_x = content_l + 200
            if is_ai then
                txtL(self, badge_x, row_cy, "AI", "body", vmath.vector4(0.3, 1.0, 0.5, 1.0))
                badge_x = badge_x + 36
            end
            if playing then
                track(self, ui.box(vmath.vector3(badge_x + 6, row_cy, 0), vmath.vector3(6, 6, 0), C.COL_RED))
                txtL(self, badge_x + 16, row_cy, "PLAYING", "small", vmath.vector4(1.0, 0.5, 0.5, 1.0))
            end

            local info_x = content_r - C.INNER_PAD
            if self.tab == TAB_BATTLES and pu.myBattle then
                local mb  = pu.myBattle
                local amt = tonumber((mb.stake or {}).amount) or tonumber(mb.stakeAmount) or 0
                local fmt = tonumber(mb.matchFormat) or 3
                local rules = mb.rules
                local is_classic = false
                if type(rules) == "string" then is_classic = rules:upper() == "CLASSIC"
                elseif type(rules) == "table" then
                    for _, r in ipairs(rules) do if tostring(r):upper() == "CLASSIC" then is_classic = true end end
                end
                if is_classic then
                    local jx = info_x - 140
                    track(self, ui.box(vmath.vector3(jx, row_cy, 0), vmath.vector3(70, 18, 0), vmath.vector4(0.3, 0.1, 0.1, 0.8)))
                    track(self, ui.text(vmath.vector3(jx, row_cy, 0), "NO JOKERS", "small", C.COL_RED))
                end
                txtR(self, info_x, row_cy, string.format("BEST OF %d ~ %s", fmt, commas(amt)), "small", C.COL_GOLD)
            else
                local s_amt = tonumber((pu.stake or {}).amount) or 0
                txtR(self, info_x, row_cy, s_amt == 0 and "FREE" or commas(s_amt), "body", C.COL_BRIGHT)
            end

            if not playing then
                self.buttons[#self.buttons+1] = { node = frame, id = "challenge", data = pu, row = true }
            end
        end
    end
end

return M