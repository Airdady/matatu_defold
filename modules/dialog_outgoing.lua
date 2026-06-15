-- modules/dialog_outgoing.lua
-- Handles the outgoing/challenging game request dialog rendering.

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
    local dlg_timer    = ctx.dlg_timer
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

    track(self, ui.text(vmath.vector3(CX, CY + 168, 0), "CHALLENGING", "title", with_a(C.COL_CYAN, a)))

    local col_gap = 165
    local opp_x, me_x = CX - col_gap, CX + col_gap
    local av_y, av_size = CY + 40, 92

    dlg_avatar(self, opp_x, av_y, av_size, d.avatar or 1, a)
    track(self, ui.text(vmath.vector3(opp_x, av_y - av_size/2 - 18, 0), (d.name or "PLAYER"):upper(), "body", with_a(C.COL_WHITE, a)))
    
    local hv = h2h_view(d.h2h)
    if hv and hv.opp_winrate then
        local wr     = math.floor(hv.opp_winrate + 0.5)
        local wr_col = wr >= 60 and C.COL_GREEN or (wr >= 40 and C.COL_GOLD or C.COL_RED)
        track(self, ui.text(vmath.vector3(opp_x, av_y - av_size/2 - 40, 0), "WR "..wr.."%", "small", with_a(wr_col, a)))
    end

    local u = ws.current_user_data or {}
    dlg_avatar(self, me_x, av_y, av_size, u.avatar or 1, a)
    track(self, ui.text(vmath.vector3(me_x, av_y - av_size/2 - 18, 0), "YOU", "body", with_a(ctx.DLG_SEARCH, a)))
    track(self, ui.text(vmath.vector3(me_x, av_y - av_size/2 - 40, 0), "Bal: "..commas(u.balance or 0), "small", with_a(C.COL_GOLD, a)))

    track(self, ui.text(vmath.vector3(CX, av_y + 46, 0), "VS", "title", with_a(ctx.DLG_RED, a)))

    local amt = tonumber((d.stake or {}).amount) or 0
    -- Coin bundle: the pot that forms on accept (the magic starts on the dialog).
    if amt > 0 then
        local bundle = track(self, ui.box(vmath.vector3(CX, av_y + 12, 0), vmath.vector3(54, 54, 0), with_a(vmath.vector4(1, 1, 1, 1), a)))
        pcall(function() gui.set_texture(bundle, "coins"); gui.play_flipbook(bundle, hash("bundle_stack_multi")) end)
    end
    local st_txt = amt == 0 and "Practice Game" or (commas(amt * 2) .. " Coin Pot")
    track(self, ui.text(vmath.vector3(CX, av_y - 24, 0), st_txt, "small", with_a(C.COL_DIM, a)))
    dlg_timer(self, CX, av_y - 46, d.time_left, d.max_time, a)

    track(self, ui.text(vmath.vector3(CX, CY - 80, 0), "Waiting for player to accept...", "small", with_a(C.COL_MID, a)))

    if hv then draw_h2h_row(self, CX, CY - 108, hv, a) end

    mkbtn(self, "cancel_wait", vmath.vector3(CX, CY - 148, 0), vmath.vector3(170, 48, 0), "Cancel", "secondary_btn")
end

return M