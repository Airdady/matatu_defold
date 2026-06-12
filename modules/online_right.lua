-- modules/online_right.lua
-- Right sidebar: Profile card, Standing badge, Form, Payments, Battles, Tournaments, Footer.
-- Called from online.gui_script via M.draw(self, ctx).

local ws = require("modules.websocket_manager")

local M = {}

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
    local badge_h  = 84
    local pay_h    = 44
    local form_h   = 30
    local gap      = 12
    local prof_h   = math.max(av_size, name_h + name_gap + stat_h)
    local cont_h   = margin + prof_h + gap + badge_h + gap + form_h + gap + pay_h + margin
    local ccy      = cy - cont_h / 2
    glass(self, vmath.vector3(cx, ccy, 0), vmath.vector3(pw, cont_h, 0), "container_bg")

    local inner_l = cx - pw/2 + margin
    local inner_r = cx + pw/2 - margin
    local top_y   = cy - margin

    -- Avatar & Rating Progress Ring
    local av_x   = inner_l + av_size/2
    local av_cy  = top_y - prof_h/2
    local rating = (tonumber(u.winRate) or 0) / 10
    local r_col  = rating >= 6 and C.COL_GREEN or (rating >= 4 and C.COL_GOLD or C.COL_RED)
    
    -- Draw Avatar
    track(self, ui.avatar(vmath.vector3(av_x, av_cy, 0), vmath.vector3(av_size, av_size, 0), u.avatar or 1))

    -- Draw Progress Ring Background
    local R = av_size/2 + 6
    local ring_bg = track(self, gui.new_pie_node(vmath.vector3(av_x, av_cy, 0), vmath.vector3(R*2, R*2, 0)))
    gui.set_perimeter_vertices(ring_bg, 64)
    pcall(gui.set_inner_radius, ring_bg, R - 4)
    gui.set_color(ring_bg, vmath.vector4(0, 0, 0, 0.4))

    -- Draw Progress Ring Foreground
    local ring_fg = track(self, gui.new_pie_node(vmath.vector3(av_x, av_cy, 0), vmath.vector3(R*2, R*2, 0)))
    gui.set_perimeter_vertices(ring_fg, 64)
    pcall(gui.set_inner_radius, ring_fg, R - 4)
    gui.set_rotation(ring_fg, vmath.vector3(0, 0, 90))
    gui.set_fill_angle(ring_fg, (rating / 10) * 360)
    gui.set_color(ring_fg, r_col)

    -- Draw Floating Rating Badge (Top Right)
    -- Shifted slightly further out so the wider oval doesn't overlap the avatar's face
    local badge_x = av_x + R * math.cos(math.rad(45)) + 6
    local badge_y = av_cy + R * math.sin(math.rad(45)) + 6
    
    -- Outer dark stroke to separate it from the ring (Oval shaped)
    local badge_bg = track(self, gui.new_pie_node(vmath.vector3(badge_x, badge_y, 0), vmath.vector3(46, 28, 0)))
    gui.set_perimeter_vertices(badge_bg, 32)
    gui.set_color(badge_bg, vmath.vector4(0.08, 0.08, 0.10, 1.0))

    -- Full solid color background (Oval shaped)
    local badge_fill = track(self, gui.new_pie_node(vmath.vector3(badge_x, badge_y, 0), vmath.vector3(40, 22, 0)))
    gui.set_perimeter_vertices(badge_fill, 32)
    gui.set_color(badge_fill, r_col)

    track(self, ui.text(vmath.vector3(badge_x, badge_y, 0), string.format("%.1f", rating), "small", C.COL_WHITE))


    local info_l  = av_x + av_size/2 + 20
    local info_w  = inner_r - info_l
    local info_cx = (info_l + inner_r) / 2

    -- Name pill
    local name_y = top_y - name_h/2
    track(self, ui.box(vmath.vector3(info_cx, name_y, 0), vmath.vector3(info_w, name_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 10, name_y, string.upper(u.username or "PLAYER"), "body", C.COL_BRIGHT)

    mkbtn(self, "nav_account", vmath.vector3(inner_r - 16, name_y, 0), vmath.vector3(28, 28, 0), nil, vmath.vector4(0,0,0,0))
    for li = -1, 1 do
        track(self, ui.box(vmath.vector3(inner_r - 16, name_y + li * 5, 0), vmath.vector3(14, 2, 0), C.COL_MID))
    end

    -- Balance + Points row (Points width expanded)
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

    -- Standing badge
    local pos      = tonumber(u.position) or -1
    local has_rank = pos > 0
    local bw       = pw - margin * 2
    local bcy      = top_y - prof_h - gap - badge_h/2

    track(self, ui.box(vmath.vector3(cx, bcy, 0), vmath.vector3(bw, badge_h, 0), C.COL_STAT_BG))
    
    local accent_col = has_rank and C.COL_GOLD or C.COL_DIM
    track(self, ui.box(vmath.vector3(cx - bw/2 + 2, bcy, 0), vmath.vector3(4, badge_h, 0), accent_col))

    local rank_txt_x = cx - bw/2 + 18
    txtL(self, rank_txt_x, bcy + 22, "SEASON STANDING", "small", C.COL_DIM)
    txtL(self, rank_txt_x, bcy - 2, has_rank and ("#"..pos) or "UNRANKED", "title", accent_col)

    if has_rank then
        local prizes = left_M.build_prizes(commas)
        local val = left_M.prize_for_position(prizes, pos, commas)
        if val ~= "" then
            txtL(self, rank_txt_x, bcy - 28, "Est. Reward: "..val, "small", C.COL_GREEN)
        end
    end

    -- Form row
    local form_y = bcy - badge_h/2 - gap - form_h/2
    track(self, ui.box(vmath.vector3(cx, form_y, 0), vmath.vector3(bw, form_h, 0), C.COL_STAT_BG))
    txtL(self, cx - bw/2 + 8, form_y, "YOUR CURRENT FORM", "small", C.COL_DIM)
    
    local form = type(u.recentForm) == "table" and u.recentForm or {}
    local fsz, fgap = 32, 6 -- Increased size to 32 for much more padding around the win/lose letters
    local fx0 = cx + bw/2 - 8 - fsz/2
    for i = 1, 5 do
        local r  = form[i]
        local bx = fx0 - (i - 1) * (fsz + fgap)
        if r == "W" or r == "L" then
            track(self, ui.box(vmath.vector3(bx, form_y, 0), vmath.vector3(fsz, fsz, 0),
                r == "W" and vmath.vector4(0.15, 0.70, 0.25, 0.92) or vmath.vector4(0.90, 0.25, 0.25, 0.92)))
            -- Changed font to "helvetica_bold"
            track(self, ui.text(vmath.vector3(bx, form_y, 0), r, "helvetica_bold", C.COL_WHITE))
        else
            track(self, ui.box(vmath.vector3(bx, form_y, 0), vmath.vector3(fsz, fsz, 0), vmath.vector4(1, 1, 1, 0.06)))
        end
    end

    -- Make Payments button
    local pay_y = form_y - form_h/2 - gap - pay_h/2
    mkbtn(self, "nav_payments", vmath.vector3(cx, pay_y, 0), vmath.vector3(bw, pay_h, 0), "MAKE PAYMENTS", "primary_btn")

    cy = cy - cont_h - C.BLOCK_GAP

    -- ── Battles panel ─────────────────────────────────────────────────────
    local battle_h = 140
    local scy = cy - battle_h/2
    glass(self, vmath.vector3(cx, scy, 0), vmath.vector3(pw, battle_h, 0), "container_bg")
    
    local mb         = u.myBattle or u.myTournament
    local has_battle = type(mb) == "table" and next(mb) ~= nil
    
    -- Layout for icon and inline text with added top padding
    local icon_x = cx - pw/2 + 40
    local txt_x  = icon_x + 35
    local hdr_y  = cy - 36
    local icon_y = cy - 48

    track(self, ui.image(vmath.vector3(icon_x, icon_y, 0), vmath.vector3(42, 42, 0), "battle_icon"))
    txtL(self, txt_x, hdr_y, "BATTLES", "luckiest_guy_md", C.COL_WHITE)

    if has_battle then
        local amt = tonumber(mb.stakeAmount) or tonumber((mb.stake or {}).amount) or 0
        local fmt = tonumber(mb.matchFormat) or 3
        
        -- Text placed closer to buttons
        txtL(self, txt_x, hdr_y - 24, string.format("BEST OF %d   ~   %s", fmt, commas(amt)), "body", C.COL_GREEN)
        
        -- Buttons moved up to reduce empty gap
        mkbtn(self, "nav_invite",    vmath.vector3(cx - pw/4 + 4, cy - 100, 0), vmath.vector3(pw/2 - 12, 40, 0), "INVITE", "primary_btn")
        mkbtn(self, "update_battle", vmath.vector3(cx + pw/4 - 4, cy - 100, 0), vmath.vector3(pw/2 - 12, 40, 0), "EDIT",   "secondary_btn")
    else
        txtL(self, txt_x, hdr_y - 24, "CREATE A CUSTOM GAME", "body", C.COL_DIM)
        mkbtn(self, "create_battle", vmath.vector3(cx, cy - 100, 0), vmath.vector3(pw - 24, 44, 0), "CREATE BATTLE", "primary_btn")
    end
    cy = cy - battle_h - C.BLOCK_GAP

    -- ── Tournaments panel ─────────────────────────────────────────────────
    local t_h  = 110
    local tcy2 = cy - t_h/2
    track(self, ui.box(vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), C.COL_BG))
    mkbtn(self, "nav_tournaments", vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), nil, "container_bg")
    track(self, ui.image(vmath.vector3(cx, cy - 40, 0), vmath.vector3(50, 50, 0), "tournament_icon"))
    track(self, ui.text(vmath.vector3(cx, cy - 84, 0), "TOURNAMENTS", "luckiest_guy_md", C.COL_WHITE))

    local nx = cx + pw/2 - 30
    local ny = cy - 16
    track(self, ui.box(vmath.vector3(nx, ny, 0), vmath.vector3(44, 18, 0), vmath.vector4(0.15, 0.8, 0.25, 1.0)))
    track(self, ui.box(vmath.vector3(nx, ny + 9, 0), vmath.vector3(44, 1, 0), C.COL_WHITE))
    track(self, ui.text(vmath.vector3(nx, ny, 0), "NEW", "luckiest_guy_sm", C.COL_WHITE))
    cy = cy - t_h - C.BLOCK_GAP

    -- ── Footer links ──────────────────────────────────────────────────────
    local fx1 = cx - pw/4
    local fx2 = cx + pw/4
    mkbtn(self, "nav_support", vmath.vector3(fx1, cy - 22, 0), vmath.vector3(pw/2 - 8, 42, 0), "SUPPORT", "secondary_btn")
    mkbtn(self, "nav_themes",  vmath.vector3(fx2, cy - 22, 0), vmath.vector3(pw/2 - 8, 42, 0), "THEMES",  "secondary_btn")
end

return M