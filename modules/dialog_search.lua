-- modules/dialog_search.lua
-- Shared "searching for a random opponent" reel dialog.
--
-- This is the single source of truth for the random-opponent request overlay.
-- It is used by BOTH the online battle/knockout quick-invite (modules/online_right)
-- AND the online tournament map (main/tournaments). Sharing it guarantees the
-- tournament's "request a random player" dialog looks and behaves exactly like
-- the one battles and knockouts already use.
--
-- The host screen owns the live search record and drives the reel + countdown in
-- its own update loop; this module only renders a frame of that state.
--
--   self     : host gui_script state (needs self.nodes / self.buttons via ctx)
--   ctx      : shared draw context { track, ui, C, commas, CX, CY, LOGICAL_W, LOGICAL_H }
--   sr       : the live search record. Recognised fields:
--                t          elapsed seconds (host increments each frame)
--                reel_ix    current reel avatar index (host spins it)
--                found      an opponent was matched
--                failed     the search failed / timed out
--                opp_name   matched opponent name (when found)
--                fail_msg   failure reason (when failed)
--                stake      { amount = n } -> when amount > 0 a coin pot is shown
--                max_time   countdown length, seconds (default 10)
--                subtitle   searching subtitle (default battle-invite wording)
--                cancel_id  when set, a Cancel button with this id is drawn
--                modal      when true the scrim swallows taps (blocks behind UI)
--   reel_key : key on self under which the reel avatar node is stored so the host
--              update loop can spin it (default "search_reel_node").
local ws = require("modules.websocket_manager")

local M = {}

function M.draw(self, ctx, sr, reel_key)
    if not sr then return end
    reel_key = reel_key or "search_reel_node"

    local track = ctx.track
    local ui    = ctx.ui
    local C     = ctx.C
    local CX, CY = ctx.CX, ctx.CY

    local amt        = tonumber((sr.stake or {}).amount) or 0
    local show_coins = amt > 0
    local max_time   = sr.max_time or 10

    -- Scrim + soft gradient backdrop.
    local scrim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W * 2, ctx.LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.78)))
    if sr.modal then self.buttons[#self.buttons + 1] = { node = scrim, id = "dlg_block" } end
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    -- Title + status line.
    local title = sr.found and "OPPONENT FOUND!" or (sr.failed and "NO OPPONENT FOUND" or "SEARCHING FOR OPPONENT")
    local t_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1) or (sr.failed and C.COL_GOLD or C.COL_WHITE)
    track(self, ui.text(vmath.vector3(CX, CY + 130, 0), title, "title", t_col))

    if sr.failed then
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), sr.fail_msg or "No one accepted your invite", "small", C.COL_DIM))
    elseif not sr.found then
        local dots = string.rep(".", 1 + (math.floor((sr.t or 0) * 2) % 3))
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), (sr.subtitle or "inviting a player to your battle") .. dots, "small", C.COL_DIM))
    else
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), "get ready…", "small", C.COL_DIM))
    end

    local u = ws.current_user_data or {}
    local ax, bx, ay = CX - 190, CX + 190, CY - 10

    -- YOU (left column).
    track(self, ui.box(vmath.vector3(ax, ay, 0), vmath.vector3(124, 124, 0), vmath.vector4(0.10, 0.10, 0.13, 0.9)))
    track(self, ui.avatar(vmath.vector3(ax, ay, 0), vmath.vector3(108, 108, 0), u.avatar or 1))
    track(self, ui.text(vmath.vector3(ax, ay - 86, 0), "YOU", "body", C.COL_GOLD))

    -- Centre column: VS, plus an optional coin pot when a stake is in play.
    if show_coins then
        track(self, ui.text(vmath.vector3(CX, ay + 50, 0), "VS", "title", vmath.vector4(1, 0.4, 0.4, 1)))
        local pot = amt * 2
        local img = "100"
        if pot >= 2000 then img = "2000"
        elseif pot >= 1000 then img = "1000"
        elseif pot >= 500 then img = "500"
        elseif pot >= 200 then img = "200"
        end
        local bundle = track(self, gui.new_box_node(vmath.vector3(CX, ay - 18, 0), vmath.vector3(88, 88, 0)))
        gui.set_color(bundle, vmath.vector4(1, 1, 1, 1))
        pcall(function() gui.set_texture(bundle, "coins"); gui.play_flipbook(bundle, hash(img)) end)
        track(self, ui.text(vmath.vector3(CX, ay - 74, 0), ctx.commas(pot), "helvetica_black", C.COL_GOLD))
    else
        track(self, ui.text(vmath.vector3(CX, ay, 0), "VS", "title", vmath.vector4(1, 0.4, 0.4, 1)))
    end

    -- Opponent reel (right column).
    local frame_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1)
        or (sr.failed and vmath.vector4(0.85, 0.25, 0.25, 1) or vmath.vector4(0.25, 0.25, 0.30, 1))
    local frame = track(self, ui.box(vmath.vector3(bx, ay, 0), vmath.vector3(124, 124, 0), frame_col))
    local reel  = track(self, ui.avatar(vmath.vector3(bx, ay, 0), vmath.vector3(108, 108, 0), sr.reel_ix or 1))
    self[reel_key] = reel
    if sr.failed then
        -- Freeze + dim the slot and drop the reel handle so the host stops cycling it.
        gui.set_color(reel, vmath.vector4(0.55, 0.55, 0.55, 1))
        self[reel_key] = nil
    end
    local who = sr.found and (sr.opp_name or "PLAYER") or (sr.failed and "—" or "? ? ?")
    track(self, ui.text(vmath.vector3(bx, ay - 86, 0), who, "body", sr.found and C.COL_WHITE or C.COL_DIM))

    if sr.found then
        gui.set_scale(frame, vmath.vector3(0.9, 0.9, 1))
        gui.animate(frame, "scale", vmath.vector3(1.12, 1.12, 1), gui.EASING_OUTBACK, 0.35, 0, function()
            pcall(gui.animate, frame, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTSINE, 0.18)
        end)
    elseif sr.failed then
        -- "no opponent" miss transition: shake the empty slot once, then fade.
        if not sr.failed_anim then
            sr.failed_anim = true
            gui.animate(frame, "position.x", bx + 10, gui.EASING_OUTSINE, 0.06, 0, function()
                pcall(gui.animate, frame, "position.x", bx - 8, gui.EASING_INOUTSINE, 0.08, 0, function()
                    pcall(gui.animate, frame, "position.x", bx, gui.EASING_OUTSINE, 0.06)
                end)
            end, gui.PLAYBACK_ONCE_FORWARD)
        end
        gui.set_color(frame, vmath.vector4(0.85, 0.25, 0.25, 0.6))
    else
        -- Native, fully smooth countdown ring (animates independent of redraw cycle).
        local time_left = math.max(0, max_time - (sr.t or 0))
        local frac = time_left / max_time
        local R = 34

        local bg = track(self, gui.new_pie_node(vmath.vector3(CX, CY - 140, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(bg, 48)
        pcall(gui.set_inner_radius, bg, R * 0.80)
        gui.set_color(bg, vmath.vector4(0.25, 0.25, 0.25, 0.45))

        local col = time_left <= 3 and C.COL_RED or C.COL_CYAN
        local fg = track(self, gui.new_pie_node(vmath.vector3(CX, CY - 140, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(fg, 48)
        pcall(gui.set_inner_radius, fg, R * 0.80)
        gui.set_rotation(fg, vmath.vector3(0, 0, 90))
        gui.set_fill_angle(fg, frac * 360)
        gui.set_color(fg, col)
        if time_left > 0 then
            pcall(gui.animate, fg, "fill_angle", 0, gui.EASING_LINEAR, time_left)
        end

        track(self, ui.text(vmath.vector3(CX, CY - 140, 0), tostring(math.ceil(time_left)), "title", col))
    end

    -- Optional cancel button (host owns the matching button id).
    if sr.cancel_id and not sr.found and not sr.failed then
        local cb = track(self, ui.btn9(vmath.vector3(CX, CY - 210, 0), vmath.vector3(170, 48, 0), "secondary_btn"))
        track(self, ui.text(vmath.vector3(CX, CY - 210, 0), "Cancel", "btn_md", vmath.vector4(1, 1, 1, 1)))
        self.buttons[#self.buttons + 1] = { node = cb, id = sr.cancel_id }
    end
end

return M
