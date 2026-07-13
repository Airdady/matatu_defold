-- modules/dialog_incoming.lua
-- Handles the incoming game request dialog rendering.

local ws = require("modules.websocket_manager")

local M = {}

function M.draw(self, ctx, d, a)
    local C            = ctx.C
    local track        = ctx.track
    local ui           = ctx.ui
    local mkbtn        = ctx.mkbtn
    local commas       = ctx.commas
    local with_a       = ctx.with_a
    local dlg_avatar   = ctx.dlg_avatar
    local h2h_view     = ctx.h2h_view
    local draw_h2h_row = ctx.draw_h2h_row

    local CX        = ctx.CX
    local CY        = ctx.CY
    local LOGICAL_W = ctx.LOGICAL_W
    local LOGICAL_H = ctx.LOGICAL_H

    local scrim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(LOGICAL_W*2, LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.62 * a)))
    self.buttons[#self.buttons+1] = { node = scrim, id = "dlg_block" }
    local grad = track(self, ui.grad_backdrop(LOGICAL_W, LOGICAL_H))
    gui.set_color(grad, vmath.vector4(1, 1, 1, a))

    track(self, ui.text(vmath.vector3(CX, CY + 168, 0), "INCOMING CHALLENGE", "title", with_a(C.COL_CYAN, a)))

    local col_gap = 165
    local opp_x, me_x = CX - col_gap, CX + col_gap
    local av_y, av_size = CY + 45, 92

    -- Simple static ring/border behind each avatar (NO timer, NO progress, NO animation)
    local function draw_avatar_ring(x, y)
        local ring_dia = av_size + 16
        local ring = track(self, gui.new_pie_node(vmath.vector3(x, y, 0), vmath.vector3(ring_dia, ring_dia, 0)))
        gui.set_color(ring, with_a(vmath.vector4(0, 0, 0, 0.5), a))
        gui.set_fill_angle(ring, 360)
        gui.set_perimeter_vertices(ring, 64)
    end

    -- Draw static rings BEFORE avatars so they sit neatly behind as a border
    draw_avatar_ring(opp_x, av_y)
    draw_avatar_ring(me_x, av_y)

    -- Opponent column
    dlg_avatar(self, opp_x, av_y, av_size, d.avatar or 1, a)
    local hv = h2h_view(d.h2h)
    if hv and hv.opp_winrate then
        local wr     = math.floor(hv.opp_winrate + 0.5)
        local wr_col = wr >= 60 and C.COL_GREEN or (wr >= 40 and C.COL_GOLD or C.COL_RED)
        track(self, ui.text(vmath.vector3(opp_x, av_y - 68, 0), "WR "..wr.."%", "small", with_a(wr_col, a)))
    end
    track(self, ui.text(vmath.vector3(opp_x, av_y - 88, 0), (d.name or "PLAYER"):upper(), "body", with_a(C.COL_WHITE, a)))

    -- Me ("YOU") column - Avatar, Balance, YOU
    local u = ws.current_user_data or {}
    dlg_avatar(self, me_x, av_y, av_size, u.avatar or 1, a)
    track(self, ui.text(vmath.vector3(me_x, av_y - 68, 0), commas(u.balance or 0), "small", with_a(C.COL_GOLD, a)))
    track(self, ui.text(vmath.vector3(me_x, av_y - 88, 0), "YOU", "body", with_a(ctx.DLG_SEARCH, a)))

    -- Central VS & Pot Elements (Re-spaced to prevent overlaps)
    local bundle_y = av_y + 15
    local bundle_h = 96
    track(self, ui.text(vmath.vector3(CX, bundle_y + 55, 0), "VS", "title", with_a(ctx.DLG_RED, a)))

    local amt = tonumber((d.stake or {}).amount) or 0
    local pot_amt = amt * 2

    -- Render Dynamic Coin Bundle
    if amt > 0 then
        local img = "100"
        if pot_amt >= 2000 then img = "2000"
        elseif pot_amt >= 1000 then img = "1000"
        elseif pot_amt >= 500 then img = "500"
        elseif pot_amt >= 200 then img = "200"
        end

        local bundle = track(self, gui.new_box_node(vmath.vector3(CX, bundle_y, 0), vmath.vector3(96, bundle_h, 0)))
        gui.set_color(bundle, with_a(vmath.vector4(1, 1, 1, 1), a))
        pcall(function() gui.set_texture(bundle, "coins"); gui.play_flipbook(bundle, hash(img)) end)
    end

    -- Simple text countdown timer strictly below the bundle
    local secs      = math.max(0, math.ceil(d.time_left or 0))
    local timer_col = ((d.time_left or 0) <= 3) and C.COL_RED or C.COL_GOLD
    local timer_pos = vmath.vector3(CX, bundle_y - bundle_h/2 - 12, 0)
    track(self, ui.text(timer_pos, secs .. "s", "body", with_a(timer_col, a)))

    -- Plain gold text below the timer — no boxed/bordered container, same
    -- icon-then-amount style the in-game coin pot HUD already uses
    -- (coins.gui_script's ensure_pot), instead of a separate bordered chip.
    local st_txt = amt == 0 and "PRACTICE" or (commas(pot_amt) .. " POT")
    local stake_pos = vmath.vector3(CX, timer_pos.y - 30, 0)

    local stake_node = track(self, ui.text(stake_pos, st_txt, "helvetica_black", with_a(C.COL_GOLD, a)))
    gui.set_scale(stake_node, vmath.vector3(0.85, 0.85, 0.85))

    -- Additional Status Info cleanly separated
    track(self, ui.text(vmath.vector3(CX, CY - 95, 0), "Wants to play!", "small", with_a(C.COL_MID, a)))

    if hv then draw_h2h_row(self, CX, CY - 118, hv, a) end

    mkbtn(self, "decline", vmath.vector3(CX - 95, CY - 162, 0), vmath.vector3(150, 48, 0), "DECLINE", "primary_btn")
    mkbtn(self, "accept",  vmath.vector3(CX + 95, CY - 162, 0), vmath.vector3(150, 48, 0), "ACCEPT",  "secondary_btn")
end

return M