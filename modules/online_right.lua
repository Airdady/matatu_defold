-- Right sidebar: Profile card, Standing badge, Form, Payments, Battles, Tournaments.
-- Also manages the Battle Creation/Update modal and the Invite Search overlay.

local ws = require("modules.websocket_manager")

local M = {}

-- Battle stakes cap out at 2000 (the 5000 / 10000 tiers were removed).
M.BATTLE_TIERS = {
    { amount = 500,   formats = { { games = 3, charge = 75,  points = 9 } } },
    { amount = 1000,  formats = { { games = 3, charge = 75,  points = 9 }, { games = 5, charge = 125, points = 15 } } },
    { amount = 2000,  formats = { { games = 3, charge = 75,  points = 9 }, { games = 5, charge = 125, points = 15 },
                                  { games = 7, charge = 175, points = 21 }, { games = 9, charge = 225, points = 27 } } },
}

local INVITE_AVATAR_MAX = 60
local BM_TAN = vmath.vector4(0.702, 0.604, 0.467, 1)

-- ── Battle Modal Drawing ──────────────────────────────────────────────────────
local function draw_battle_modal(self, ctx)
    local bm = self.battle_modal
    if not bm then return end

    local track = ctx.track
    local ui    = ctx.ui
    local mkbtn = ctx.mkbtn
    local txtL  = ctx.txtL
    local commas = ctx.commas
    local CX, CY = ctx.CX, ctx.CY

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.8)))
    self.buttons[#self.buttons+1] = { node = dim, id = "bm_block" }

    -- Further reduced the height to perfectly close the empty space gap
    local pw, ph = 500, 330
    track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(pw, ph, 0), ctx.C.COL_BG))
    track(self, ui.btn9(vmath.vector3(CX, CY, 0), vmath.vector3(pw, ph, 0), "container_bg"))

    local l   = CX - pw/2 + 30
    local r   = CX + pw/2 - 30
    local top = CY + ph/2 - 30

    txtL(self, l, top - 8, bm.editing and "UPDATE BATTLE" or "CREATE BATTLE", "body", ctx.C.COL_WHITE)
    mkbtn(self, "bm_close", vmath.vector3(r - 10, top - 8, 0), vmath.vector3(30, 30, 0), nil, vmath.vector4(0,0,0,0.001))
    track(self, ui.text(vmath.vector3(r - 10, top - 8, 0), "X", "luckiest_guy_sm", ctx.C.COL_MID))

    local tier         = M.BATTLE_TIERS[bm.stake_i] or M.BATTLE_TIERS[1]
    local fmts         = tier.formats
    if bm.fmt_i > #fmts then bm.fmt_i = #fmts end
    local fmt          = fmts[bm.fmt_i] or fmts[1]
    local winner_takes = tier.amount * 2 - fmt.charge

    local fee_y = top - 64
    txtL(self, l, fee_y + 28, "ENTRY FEE", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
    mkbtn(self, "bm_fee_minus", vmath.vector3(l + 20, fee_y - 8, 0), vmath.vector3(40, 40, 0), "-", "secondary_btn")
    track(self, ui.box(vmath.vector3(CX, fee_y - 8, 0), vmath.vector3(pw - 200, 40, 0), ctx.C.COL_NAMEID_BG))
    track(self, ui.text(vmath.vector3(CX, fee_y - 8, 0), commas(tier.amount) .. " COINS", "body", vmath.vector4(1, 0.8, 0.4, 1)))
    mkbtn(self, "bm_fee_plus", vmath.vector3(r - 20, fee_y - 8, 0), vmath.vector3(40, 40, 0), "+", "secondary_btn")
    track(self, ui.text(vmath.vector3(CX, fee_y - 44, 0),
        string.format("Winner Takes: %s + %d Pts", commas(winner_takes), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))

    local fmt_y = top - 156
    txtL(self, l, fmt_y + 28, "GAME FORMAT", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
    mkbtn(self, "bm_fmt_minus", vmath.vector3(l + 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "-", "secondary_btn")
    track(self, ui.box(vmath.vector3(CX, fmt_y - 8, 0), vmath.vector3(pw - 200, 40, 0), ctx.C.COL_NAMEID_BG))
    track(self, ui.text(vmath.vector3(CX, fmt_y - 8, 0), "BEST OF " .. fmt.games, "body", ctx.C.COL_WHITE))
    mkbtn(self, "bm_fmt_plus", vmath.vector3(r - 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "+", "secondary_btn")
    track(self, ui.text(vmath.vector3(CX, fmt_y - 44, 0),
        string.format("Charge: %s  ·  %d Pts to the winner", commas(fmt.charge), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))

    if bm.msg then
        track(self, ui.text(vmath.vector3(CX, CY - ph/2 + 102, 0), bm.msg, "small",
            bm.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    local sub_label = bm.submitting and "SUBMITTING..." or (bm.editing and "UPDATE BATTLE" or "CREATE BATTLE")
    mkbtn(self, "bm_submit", vmath.vector3(CX, CY - ph/2 + 46, 0), vmath.vector3(pw - 60, 60, 0), sub_label, "secondary_btn", nil, "luckiest_guy_md", BM_TAN)
end

-- ── Invite Modal Drawing ──────────────────────────────────────────────────────
local function draw_invite_search(self, ctx)
    local sr = self.invite_search
    if not sr then return end

    local track = ctx.track
    local ui    = ctx.ui
    local CX, CY = ctx.CX, ctx.CY

    track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W * 2, ctx.LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.78)))
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    local title = sr.found and "OPPONENT FOUND!" or "SEARCHING FOR OPPONENT"
    local t_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1) or ctx.C.COL_WHITE
    track(self, ui.text(vmath.vector3(CX, CY + 130, 0), title, "title", t_col))
    
    if not sr.found then
        local dots = string.rep(".", 1 + (math.floor((sr.t or 0) * 2) % 3))
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), "inviting a player to your battle" .. dots, "small", ctx.C.COL_DIM))
    else
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), "get ready…", "small", ctx.C.COL_DIM))
    end

    local u = ws.current_user_data or {}
    local ax, bx, ay = CX - 190, CX + 190, CY - 10

    track(self, ui.box(vmath.vector3(ax, ay, 0), vmath.vector3(124, 124, 0), vmath.vector4(0.10, 0.10, 0.13, 0.9)))
    track(self, ui.avatar(vmath.vector3(ax, ay, 0), vmath.vector3(108, 108, 0), u.avatar or 1))
    track(self, ui.text(vmath.vector3(ax, ay - 86, 0), "YOU", "body", ctx.C.COL_GOLD))
    track(self, ui.text(vmath.vector3(CX, ay, 0), "VS", "title", vmath.vector4(1, 0.4, 0.4, 1)))

    local frame_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1) or vmath.vector4(0.25, 0.25, 0.30, 1)
    local frame = track(self, ui.box(vmath.vector3(bx, ay, 0), vmath.vector3(124, 124, 0), frame_col))
    local reel  = track(self, ui.avatar(vmath.vector3(bx, ay, 0), vmath.vector3(108, 108, 0), sr.reel_ix or 1))
    self.invite_reel_node = reel
    local who = sr.found and (sr.opp_name or "PLAYER") or "? ? ?"
    track(self, ui.text(vmath.vector3(bx, ay - 86, 0), who, "body", sr.found and ctx.C.COL_WHITE or ctx.C.COL_DIM))

    if sr.found then
        gui.set_scale(frame, vmath.vector3(0.9, 0.9, 1))
        gui.animate(frame, "scale", vmath.vector3(1.12, 1.12, 1), gui.EASING_OUTBACK, 0.35, 0, function()
            pcall(gui.animate, frame, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTSINE, 0.18)
        end)
    else
        -- Native, fully smooth animated timer
        local time_left = math.max(0, 10 - (sr.t or 0))
        local frac = time_left / 10
        local R = 34
        
        local bg = track(self, gui.new_pie_node(vmath.vector3(CX, CY - 140, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(bg, 48)
        pcall(gui.set_inner_radius, bg, R * 0.80)
        gui.set_color(bg, vmath.vector4(0.25, 0.25, 0.25, 0.45))

        local col = time_left <= 3 and ctx.C.COL_RED or ctx.C.COL_CYAN
        local fg = track(self, gui.new_pie_node(vmath.vector3(CX, CY - 140, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(fg, 48)
        pcall(gui.set_inner_radius, fg, R * 0.80)
        gui.set_rotation(fg, vmath.vector3(0, 0, 90))
        gui.set_fill_angle(fg, frac * 360)
        gui.set_color(fg, col)
        
        -- Native engine tween over properties guarantees 60fps independent of redraw cycle
        if time_left > 0 then
            pcall(gui.animate, fg, "fill_angle", 0, gui.EASING_LINEAR, time_left)
        end
        
        track(self, ui.text(vmath.vector3(CX, CY - 140, 0), tostring(math.ceil(time_left)), "title", col))
    end
end


-- ── Main Right Panel Drawing ──────────────────────────────────────────────────
function M.draw(self, ctx, left_M)
    local C          = ctx.C
    local track      = ctx.track
    local txtL       = ctx.txtL
    local txtR       = ctx.txtR
    local mkbtn      = ctx.mkbtn
    local glass      = ctx.glass
    local commas     = ctx.commas
    local get_layout = ctx.get_layout
    local ui         = ctx.ui

    local u = ws.current_user_data or {}
    local _, right_w, _, div_rx = get_layout()
    local pw  = (ctx.EDGE_R - div_rx) - (C.SIDE_MARGIN * 2)
    local cx  = (div_rx + ctx.EDGE_R) / 2
    local cy  = ctx.EDGE_T - 16

    -- ── User info container ───────────────────────────────────────────────
    local margin   = 15
    local av_size  = 96
    local name_h   = 30
    local stat_h   = 32
    local name_gap = 8
    local list_h   = 160 -- Expanded to fit 4 rows
    local pay_h    = 44
    local gap      = 12
    local prof_h   = math.max(av_size, name_h + name_gap + stat_h)
    local cont_h   = margin + prof_h + gap + list_h + gap + pay_h + margin
    local ccy      = cy - cont_h / 2
    glass(self, vmath.vector3(cx, ccy, 0), vmath.vector3(pw, cont_h, 0), "container_bg")

    local inner_l = cx - pw/2 + margin
    local inner_r = cx + pw/2 - margin
    local top_y   = cy - margin

    -- Avatar Only (Removed floating badge and rings)
    local av_x   = inner_l + av_size/2
    local av_cy  = top_y - prof_h/2
    local rating = (tonumber(u.winRate) or 0) / 10
    local r_col  = rating >= 6 and C.COL_GREEN or (rating >= 4 and C.COL_GOLD or C.COL_RED)
    
    track(self, ui.avatar(vmath.vector3(av_x, av_cy, 0), vmath.vector3(av_size, av_size, 0), u.avatar or 1))

    local info_l  = av_x + av_size/2 + 20
    local info_w  = inner_r - info_l
    local info_cx = (info_l + inner_r) / 2

    -- Name pill
    local name_y = top_y - name_h/2
    track(self, ui.box(vmath.vector3(info_cx, name_y, 0), vmath.vector3(info_w, name_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 10, name_y, string.upper(u.username or "PLAYER"), "body", C.COL_BRIGHT)

    -- Pencil icon → opens the profile screen to edit username/avatar.
    mkbtn(self, "nav_account", vmath.vector3(inner_r - 16, name_y, 0), vmath.vector3(30, 30, 0), nil, vmath.vector4(0,0,0,0))
    local COL_PENCIL = vmath.vector4(1.0, 0.78, 0.18, 1.0)
    -- diagonal pencil body
    local body = track(self, ui.box(vmath.vector3(inner_r - 16, name_y + 1, 0), vmath.vector3(16, 5, 0), COL_PENCIL))
    gui.set_rotation(body, vmath.vector3(0, 0, 45))
    -- pencil tip (dark nib at the lower-left end)
    local tip = track(self, ui.box(vmath.vector3(inner_r - 21, name_y - 4, 0), vmath.vector3(5, 5, 0), C.COL_DIM))
    gui.set_rotation(tip, vmath.vector3(0, 0, 45))

    -- Balance + Points
    local stat_y  = name_y - name_h/2 - name_gap - stat_h/2
    local pts_w   = 115
    local bal_w   = info_w - pts_w - 8
    local bal_cx  = info_l + bal_w/2
    local pts_cx  = inner_r - pts_w/2
    local COL_ORANGE = vmath.vector4(1.0, 0.6, 0.0, 1.0)
    
    track(self, ui.box(vmath.vector3(bal_cx, stat_y, 0), vmath.vector3(bal_w, stat_h, 0), C.COL_STAT_BG))
    txtL(self, info_l + 8, stat_y, "BAL.", "small", COL_ORANGE)
    txtR(self, info_l + bal_w - 6, stat_y, commas(u.balance or 0), "body", COL_ORANGE)
    
    track(self, ui.box(vmath.vector3(pts_cx, stat_y, 0), vmath.vector3(pts_w, stat_h, 0), C.COL_STAT_BG))
    txtL(self, pts_cx - pts_w/2 + 8, stat_y, "PTS.", "small", C.COL_DIM)
    txtR(self, pts_cx + pts_w/2 - 8, stat_y, commas(u.points or 0), "body", C.COL_CYAN)

    -- Combined Stats List (Rating, Position, Reward, Form)
    local pos      = tonumber(u.position) or -1
    local has_rank = pos > 0
    local bw       = pw - margin * 2
    local lcy      = top_y - prof_h - gap - list_h/2

    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw, list_h, 0), C.COL_STAT_BG))
    
    local accent_col = has_rank and C.COL_GOLD or C.COL_DIM
    local row_h = list_h / 4

    -- Dividers
    track(self, ui.box(vmath.vector3(cx, lcy + list_h/4, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
    track(self, ui.box(vmath.vector3(cx, lcy - list_h/4, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))

    -- Row 1: Your Rating
    local r1_y = lcy + list_h/2 - row_h/2
    txtL(self, cx - bw/2 + 12, r1_y, "YOUR RATING", "small", C.COL_DIM)
    txtR(self, cx + bw/2 - 12, r1_y, string.format("%.1f", rating), "body", r_col)

    -- Row 2: Your Position
    local r2_y = lcy + list_h/2 - row_h*1.5
    txtL(self, cx - bw/2 + 12, r2_y, "YOUR POSITION", "small", C.COL_DIM)
    txtR(self, cx + bw/2 - 12, r2_y, has_rank and ("#"..pos) or "UNRANKED", "body", accent_col)

    -- Row 3: Estimated Reward
    local r3_y = lcy + list_h/2 - row_h*2.5
    txtL(self, cx - bw/2 + 12, r3_y, "ESTIMATED REWARD", "small", C.COL_DIM)
    local val = "-"
    if has_rank then
        local prizes = left_M.build_prizes(commas)
        local prize_val = left_M.prize_for_position(prizes, pos, commas)
        if prize_val ~= "" then val = prize_val end
    end
    txtR(self, cx + bw/2 - 12, r3_y, val, "body", C.COL_GREEN)

    -- Row 4: Your Current Form
    local r4_y = lcy + list_h/2 - row_h*3.5
    txtL(self, cx - bw/2 + 12, r4_y, "YOUR CURRENT FORM", "small", C.COL_DIM)

    local form = type(u.recentForm) == "table" and u.recentForm or {}
    local fsz, fgap = 26, 6 
    local fx0 = cx + bw/2 - 12 - fsz/2
    for i = 1, 5 do
        local r  = form[i]
        local bx = fx0 - (i - 1) * (fsz + fgap)
        if r == "W" or r == "L" then
            track(self, ui.box(vmath.vector3(bx, r4_y, 0), vmath.vector3(fsz, fsz, 0),
                r == "W" and vmath.vector4(0.15, 0.70, 0.25, 0.92) or vmath.vector4(0.90, 0.25, 0.25, 0.92)))
            track(self, ui.text(vmath.vector3(bx, r4_y, 0), r, "helvetica_bold", C.COL_WHITE))
        else
            track(self, ui.box(vmath.vector3(bx, r4_y, 0), vmath.vector3(fsz, fsz, 0), vmath.vector4(1, 1, 1, 0.06)))
        end
    end

    -- Make Payments button
    local pay_y = lcy - list_h/2 - gap - pay_h/2
    mkbtn(self, "nav_payments", vmath.vector3(cx, pay_y, 0), vmath.vector3(bw, pay_h, 0), "MAKE PAYMENTS", "primary_btn")

    cy = cy - cont_h - C.BLOCK_GAP

    -- ── Battles panel ─────────────────────────────────────────────────────
    local battle_h = 140
    local scy = cy - battle_h/2
    glass(self, vmath.vector3(cx, scy, 0), vmath.vector3(pw, battle_h, 0), "container_bg")
    
    local mb         = u.myBattle or u.myTournament
    local has_battle = type(mb) == "table" and next(mb) ~= nil
    
    local icon_x = cx - pw/2 + 40
    local txt_x  = icon_x + 35
    local hdr_y  = cy - 36
    local icon_y = cy - 48

    track(self, ui.image(vmath.vector3(icon_x, icon_y, 0), vmath.vector3(42, 42, 0), "battle_icon"))
    txtL(self, txt_x, hdr_y, "BATTLES", "luckiest_guy_md", C.COL_WHITE)

    -- Adjusted padding and spacing for the buttons
    local btn_pad = 24
    local btn_gap = 14
    local btn_w   = (pw - (btn_pad * 2) - btn_gap) / 2
    local left_bx = cx - btn_gap/2 - btn_w/2
    local rght_bx = cx + btn_gap/2 + btn_w/2

    if has_battle then
        local amt = tonumber(mb.stakeAmount) or tonumber((mb.stake or {}).amount) or 0
        local fmt = tonumber(mb.matchFormat) or 3
        txtL(self, txt_x, hdr_y - 24, string.format("BEST OF %d   ~   %s", fmt, commas(amt)), "body", C.COL_GREEN)
        
        mkbtn(self, "nav_invite",    vmath.vector3(left_bx, cy - 100, 0), vmath.vector3(btn_w, 40, 0), "INVITE", "primary_btn")
        mkbtn(self, "update_battle", vmath.vector3(rght_bx, cy - 100, 0), vmath.vector3(btn_w, 40, 0), "EDIT",   "secondary_btn")
    else
        txtL(self, txt_x, hdr_y - 24, "CREATE A CUSTOM GAME", "body", C.COL_DIM)
        mkbtn(self, "create_battle", vmath.vector3(cx, cy - 100, 0), vmath.vector3(pw - (btn_pad * 2), 44, 0), "CREATE BATTLE", "primary_btn")
    end
    cy = cy - battle_h - C.BLOCK_GAP

    -- ── Tournaments panel ─────────────────────────────────────────────────
    local t_h  = 64
    local tcy2 = cy - t_h/2
    track(self, ui.box(vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), C.COL_BG))
    mkbtn(self, "nav_tournaments", vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), nil, "container_bg")
    
    local icon_x = cx - 74
    track(self, ui.image(vmath.vector3(icon_x, tcy2, 0), vmath.vector3(28, 28, 0), "tournament_icon"))
    txtL(self, icon_x + 22, tcy2, "TOURNAMENTS", "luckiest_guy_md", C.COL_WHITE)

    local nx = cx + pw/2 - 36
    local ny = tcy2
    track(self, ui.box(vmath.vector3(nx, ny, 0), vmath.vector3(44, 18, 0), vmath.vector4(0.15, 0.8, 0.25, 1.0)))
    track(self, ui.box(vmath.vector3(nx, ny + 9, 0), vmath.vector3(44, 1, 0), C.COL_WHITE))
    track(self, ui.text(vmath.vector3(nx, ny, 0), "NEW", "luckiest_guy_sm", C.COL_WHITE))
    cy = cy - t_h - C.BLOCK_GAP

    -- ── Footer links ──────────────────────────────────────────────────────
    local fx1 = cx - pw/4
    local fx2 = cx + pw/4
    -- Support moved to the main lobby; Themes spans the footer here.
    mkbtn(self, "nav_themes", vmath.vector3(cx, cy - 22, 0), vmath.vector3(pw - 16, 42, 0), "THEMES", "secondary_btn")

    -- ── Draw Extracted Modals on Top ──────────────────────────────────────
    draw_battle_modal(self, ctx)
    draw_invite_search(self, ctx)
end

-- ── Input Action Exports for Main Script ─────────────────────────────────────
function M.bm_submit(self, rebuild_cb)
    local bm = self.battle_modal
    if not bm or bm.submitting then return end
    
    local tier = M.BATTLE_TIERS[bm.stake_i] or M.BATTLE_TIERS[1]
    local fmt  = tier.formats[math.min(bm.fmt_i, #tier.formats)]
    local uid  = ws.get_current_user_id()
    if uid == "" then
        bm.msg, bm.msg_ok = "User ID missing. Please log in.", false
        rebuild_cb(); return
    end

    bm.submitting = true; bm.msg, bm.msg_ok = nil, nil; rebuild_cb()

    local payload = { userId = uid, amount = tier.amount, matchFormat = fmt.games, rules = "JOKERS" }

    local function on_result(result)
        local cur = self.battle_modal
        if not cur then return end
        cur.submitting = false
        if result.success then
            local data   = result.data or {}
            local battle = data.tournament or data.data or data
            local u      = ws.current_user_data or {}
            u.myBattle   = battle; ws.current_user_data = u
            cur.msg, cur.msg_ok = bm.editing and "Battle updated successfully!" or "Battle created successfully!", true
            if self._active then rebuild_cb() end
            timer.delay(1.0, false, function()
                if self.battle_modal == cur then
                    self.battle_modal = nil
                    if self._active then rebuild_cb() end
                end
            end)
        else
            cur.msg, cur.msg_ok = result.message or "Request failed", false
            if self._active then rebuild_cb() end
        end
    end

    local api = require("modules.api_service")
    if bm.editing and bm.id and bm.id ~= "" then
        api.update_tournament(bm.id, payload, on_result)
    else
        api.create_tournament(payload, on_result)
    end
end

function M.start_invite_search(self, app_state, rebuild_cb)
    local u  = ws.current_user_data or {}
    local mb = u.myBattle or u.myTournament
    if type(mb) ~= "table" or next(mb) == nil then return end

    local stake = (type(mb.stake) == "table") and mb.stake or { amount = tonumber(mb.stakeAmount) or 0, charge = 0 }

    self.invite_search = { active = true, t = 0, reel_ix = math.random(INVITE_AVATAR_MAX), spin_t = 0 }
    app_state.searching_invite = true

    ws.send_game_request({}, stake, {
        gameType     = "TOURNAMENT",
        tournamentId = tostring(mb._id or mb.id or ""),
        rules        = "JOKERS",
    })

    -- Add a 10-second auto-timeout
    self.invite_search.timer_handle = timer.delay(10, false, function()
        if self.invite_search and not self.invite_search.found then
            M.stop_invite_search(self, app_state, rebuild_cb)
        end
    end)

    rebuild_cb()
end

function M.stop_invite_search(self, app_state, rebuild_cb)
    -- Clean up timer if cancelled early
    if self.invite_search and self.invite_search.timer_handle then
        pcall(timer.cancel, self.invite_search.timer_handle)
    end
    
    self.invite_search = nil
    self.invite_reel_node = nil
    app_state.searching_invite = false
    rebuild_cb()
end

return M