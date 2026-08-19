-- modules/dialog_outgoing.lua
-- Handles the outgoing/challenging game request dialog rendering.

local ws   = require("modules.websocket_manager")
local rank = require("modules.rank_badge")

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

    track(self, ui.text(vmath.vector3(CX, CY + 168, 0), "CHALLENGING", "title", with_a(C.COL_CYAN, a)))

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

    -- Draw static rings BEFORE avatars so they act as a border
    draw_avatar_ring(opp_x, av_y)
    draw_avatar_ring(me_x, av_y)

    -- Opponent column
    dlg_avatar(self, opp_x, av_y, av_size, d.avatar or 1, a)
    -- THE OPPONENT'S STANDING, AS A TIER RATHER THAN A PERCENTAGE.
    --
    -- This slot used to read "WR 48%" in one of three colours. The number is
    -- the wrong shape for the glance it gets: the player has ten seconds and
    -- one decision, and working out whether 48 is good takes context nobody
    -- holds at that moment. The tier says it in a word — AMATEUR, PRO, MASTER,
    -- GRANDMASTER — from the same win rate, in the same place.
    --
    -- Nothing is drawn when the server sent no rating: an unrated stranger has
    -- not been shown to be bad, and badging them as the bottom tier would
    -- invent a fact about them. See modules/rank_badge.lua.
    local hv = h2h_view(d.h2h)
    if hv then
        rank.draw({ track = function(n) return track(self, n) end, ui = ui },
            hv.opp_winrate, opp_x, av_y - 68, 22, a)
    end
    -- The name sits lower than it used to, by the difference between a 22px
    -- pill and the line of text it replaced. Both columns move, not just the
    -- badged one, so the two names stay on one line.
    track(self, ui.text(vmath.vector3(opp_x, av_y - 96, 0), (d.name or "PLAYER"):upper(), "body", with_a(C.COL_WHITE, a)))

    -- Me ("YOU") column - Avatar, Balance, YOU
    local u = ws.current_user_data or {}
    dlg_avatar(self, me_x, av_y, av_size, u.avatar or 1, a)
    track(self, ui.text(vmath.vector3(me_x, av_y - 68, 0), commas(u.balance or 0), "small", with_a(C.COL_GOLD, a)))
    track(self, ui.text(vmath.vector3(me_x, av_y - 96, 0), "YOU", "body", with_a(ctx.DLG_SEARCH, a)))

    -- Central Pot Element. Centred ON the avatars' own centre line (both sit
    -- at av_y), so the pot reads as sitting BETWEEN the two players rather
    -- than floating above them — it used to be offset 15px up, which with the
    -- VS gone from over it left it visibly high.
    local bundle_y = av_y
    local bundle_h = 96

    local amt = tonumber((d.stake or {}).amount) or 0
    local pot_amt = amt * 2

    -- "VS" only when there is nothing else in the middle. With a stake the
    -- coin pot sits between the two avatars and already says "these two are
    -- playing each other for this" — the word on top of it was a second,
    -- weaker way of saying the same thing.
    if amt <= 0 then
        track(self, ui.text(vmath.vector3(CX, bundle_y + 55, 0), "VS", "title", with_a(ctx.DLG_RED, a)))
    end

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

    -- Order: coin bundle image, then the bold amount label pulled in 10px
    -- closer to the image, then the countdown seconds below that.
    local st_txt = amt == 0 and "PRACTICE" or commas(pot_amt)
    local stake_pos = vmath.vector3(CX, bundle_y - bundle_h/2 - 2, 0)

    local stake_node = track(self, ui.text(stake_pos, st_txt, "helvetica_black", with_a(C.COL_GOLD, a)))
    gui.set_scale(stake_node, vmath.vector3(0.85, 0.85, 0.85))
    pcall(function() gui.set_outline(stake_node, with_a(vmath.vector4(0, 0, 0, 1), a)) end)

    local secs      = math.max(0, math.ceil(d.time_left or 0))
    local timer_col = ((d.time_left or 0) <= 3) and C.COL_RED or C.COL_GOLD
    local timer_pos = vmath.vector3(CX, stake_pos.y - 30, 0)
    track(self, ui.text(timer_pos, secs .. "s", "body", with_a(timer_col, a)))

    -- Additional Status Info cleanly separated
    track(self, ui.text(vmath.vector3(CX, CY - 95, 0), "Waiting for player to accept...", "small", with_a(C.COL_MID, a)))

    if hv then draw_h2h_row(self, CX, CY - 118, hv, a) end
end

return M