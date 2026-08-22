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
--                max_time   countdown length, seconds (default 12 — the
--                           server states it on GAME_SEARCH_STARTED)
--                grace_time the tail of max_time that is the server's grace for
--                           answers already in flight. The ring counts down to
--                           the START of it and then says CHOOSING, so the
--                           number on screen is only ever time somebody can
--                           still be joining in.
--                invited    how many players the invite went out to
--                roster     { {userId, username, avatar, skillTier}, … } — the
--                           players who have ACCEPTED so far, pushed by the
--                           server as each one lands (GAME_REQUEST_ROSTER)
--                chosen_id  set on the last roster push only: the opponent the
--                           window actually awarded the match to
--                subtitle   searching subtitle (default battle-invite wording)
--                cancel_id  when set, a Cancel button with this id is drawn
--                modal      when true the scrim swallows taps (blocks behind UI)
--   reel_key : key on self under which the reel avatar node is stored so the host
--              update loop can spin it (default "search_reel_node").
local ws = require("modules.websocket_manager")
local search_clock = require("modules.search_clock")

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
    -- Twelve, not ten. The server's window is twelve seconds for a
    -- championship ladder and eight for a battle, and it says which on
    -- GAME_SEARCH_STARTED — this is only what is drawn in the moment before
    -- that lands, so it is the longest of them rather than the shortest.
    -- THE NUMBER ON SCREEN IS THE SMOOTHED ONE, not the raw arithmetic.
    --
    -- The dialog opens before the server has said how long the window is, so
    -- the first seconds are a guess — and replacing a guess with the truth is
    -- a jump. modules/search_clock keeps the two apart: `t` is the real
    -- elapsed time and may be corrected at any moment, `shown` is what a
    -- player watches and only ever descends. See the long note there.
    local target = search_clock.target(sr)
    local time_shown = tonumber(sr.shown) or target
    local choosing   = search_clock.is_choosing(sr)

    -- Scrim + soft gradient backdrop.
    local scrim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W * 2, ctx.LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.78)))
    if sr.modal then self.buttons[#self.buttons + 1] = { node = scrim, id = "dlg_block" } end
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    -- Title + status line.
    -- WHO HAS TURNED UP, AND WHETHER ONE OF THEM IS YOURS YET.
    --
    -- An arrival is not a match. Somebody accepting means the search is
    -- working; the opponent is chosen when the window closes, and titling the
    -- first arrival "OPPONENT FOUND" would be the first-to-tap rule again,
    -- drawn rather than enforced.
    local roster    = (type(sr.roster) == "table") and sr.roster or {}
    local joined    = #roster
    local title = sr.found and "OPPONENT FOUND!"
        or (sr.failed and "NO OPPONENT FOUND"
        or (choosing and "ASSESSING THE BEST CANDIDATE"
        or (joined > 0 and "OPPONENTS FOUND" or "SEARCHING FOR OPPONENT")))
    local t_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1) or (sr.failed and C.COL_GOLD or C.COL_WHITE)
    track(self, ui.text(vmath.vector3(CX, CY + 130, 0), title, "title", t_col))

    if sr.failed then
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), sr.fail_msg or "No one accepted your invite", "small", C.COL_DIM))
    elseif not sr.found then
        local dots = string.rep(".", 1 + (math.floor((sr.t or 0) * 2) % 3))
        -- WHAT ZERO ON THE RING MEANS.
        --
        -- It used to mean the search had failed — the dialog announced "no
        -- opponent" the instant the countdown emptied, which on a ladder was
        -- two seconds before the server had finished picking between the
        -- players who accepted. Zero is the shortlist closing, not the search
        -- giving up, and the line says so.
        local plural = function(n, word)
            return tostring(n) .. " " .. word .. ((n == 1) and "" or "s")
        end
        local line
        if choosing then
            line = joined > 0
                and ("assessing " .. plural(joined, "candidate"))
                or "picking the best match"
        elseif joined > 0 then
            -- The reassurance the old spinner never gave: somebody IS there,
            -- and the search keeps running because a better match may still
            -- answer inside the window.
            line = plural(joined, "player") .. " joined, still searching"
        else
            line = sr.subtitle or "inviting a player to your battle"
        end
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), line .. dots, "small", C.COL_DIM))
    else
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), "get ready…", "small", C.COL_DIM))
    end

    local u = ws.current_user_data or {}
    local ax, bx, ay = CX - 190, CX + 190, CY - 10

    -- YOU (left column).
    track(self, ui.box(vmath.vector3(ax, ay, 0), vmath.vector3(124, 124, 0), vmath.vector4(0.10, 0.10, 0.13, 0.9)))
    track(self, ui.avatar(vmath.vector3(ax, ay, 0), vmath.vector3(108, 108, 0), u.avatar or 1))
    track(self, ui.text(vmath.vector3(ax, ay - 86, 0), "YOU", "body", C.COL_GOLD))

    -- Centre column: the coin pot when a stake is in play, otherwise "VS".
    -- Never both — the pot between the two avatars already carries the
    -- meaning, and the word stacked above it was just repeating it.
    if show_coins then
        local pot = amt * 2
        local img = "100"
        if pot >= 2000 then img = "2000"
        elseif pot >= 1000 then img = "1000"
        elseif pot >= 500 then img = "500"
        elseif pot >= 200 then img = "200"
        end
        -- Centred ON the avatars' own centre line (both columns sit at ay), so
        -- the pot reads as sitting BETWEEN the two players. It used to be
        -- pushed down to make room for the VS above it; with that gone it can
        -- take the middle.
        local bundle = track(self, gui.new_box_node(vmath.vector3(CX, ay, 0), vmath.vector3(88, 88, 0)))
        gui.set_color(bundle, vmath.vector4(1, 1, 1, 1))
        pcall(function() gui.set_texture(bundle, "coins"); gui.play_flipbook(bundle, hash(img)) end)
        track(self, ui.text(vmath.vector3(CX, ay - 58, 0), ctx.commas(pot), "helvetica_black", C.COL_GOLD))
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
    -- WHO THE SLOT IS SHOWING.
    --
    -- Once somebody has accepted, the reel stops being an unknown: it shows
    -- the latest player to join, and the chosen one the moment the window
    -- names them. It only reads "? ? ?" while nobody has answered at all,
    -- which is the one time that is actually true.
    local chosen
    if sr.chosen_id then
        for _, r in ipairs(roster) do
            if r.userId == sr.chosen_id then chosen = r end
        end
    end
    local latest = roster[#roster]
    if not sr.found and not sr.failed and (chosen or latest) then
        local show = chosen or latest
        self[reel_key] = nil -- stop the host cycling it; this is a real player
        pcall(gui.play_flipbook, reel, "avatar_" .. tostring(show.avatar or 1))
    end

    -- THE GREEN LIGHT. One pulse for the dialog each time somebody joins —
    -- not one per player, because two acceptances half a second apart should
    -- read as the search working rather than as two separate alarms.
    local flash = search_clock.flash(sr)
    if flash > 0 and not sr.found and not sr.failed then
        local n = track(self, ui.box(vmath.vector3(bx, ay, 0),
            vmath.vector3(150 + 40 * flash, 150 + 40 * flash, 0),
            vmath.vector4(0.15, 0.85, 0.35, 0.35 * flash)))
        pcall(gui.set_texture, n, "ui")
        pcall(gui.play_flipbook, n, hash("circle"))
    end

    local who = sr.found and (sr.opp_name or "PLAYER")
        or (sr.failed and "—"
        or (chosen and string.upper(chosen.username or "PLAYER")
        or (latest and string.upper(latest.username or "PLAYER") or "? ? ?")))
    local who_col = (sr.found or chosen) and C.COL_WHITE or C.COL_DIM
    track(self, ui.text(vmath.vector3(bx, ay - 86, 0), who, "body", who_col))

    -- THE SHORTLIST, UNDER THE SLOT.
    --
    -- Every player who has accepted, in the order they arrived, so the
    -- requester can see the search working rather than trusting a spinner. The
    -- chosen one is marked once the window has closed on them.
    if joined > 0 and not sr.failed then
        local SZ, GAP = 34, 8
        local row_w = joined * SZ + (joined - 1) * GAP
        local x0 = CX - row_w / 2 + SZ / 2
        local ry = ay - 132
        track(self, ui.text(vmath.vector3(CX, ry + 30, 0),
            chosen and "MATCHED" or "JOINED", "small", C.COL_DIM))
        for i, r in ipairs(roster) do
            local rx = x0 + (i - 1) * (SZ + GAP)
            local is_won = chosen and (r.userId == chosen.userId)

            -- ARRIVING. A player who has just accepted pops in oversized and
            -- green, and settles into the row over a third of a second. It is
            -- the most interesting thing that happens in these twelve seconds
            -- and it used to appear silently, whenever a redraw happened to
            -- land. Timings come from search_clock so both dialogs play the
            -- same beat.
            local pop  = search_clock.arrival_scale(sr, r)
            local glow = search_clock.arrival_glow(sr, r)

            -- The green of a fresh arrival fades into the neutral border; the
            -- chosen player keeps it for good.
            local border
            if is_won then
                border = vmath.vector4(0.15, 0.85, 0.35, 1)
            else
                border = vmath.vector4(
                    0.25 + (0.15 - 0.25) * glow,
                    0.25 + (0.85 - 0.25) * glow,
                    0.30 + (0.35 - 0.30) * glow, 1)
            end

            local bs = (SZ + 4) * pop
            track(self, ui.box(vmath.vector3(rx, ry, 0), vmath.vector3(bs, bs, 0), border))
            track(self, ui.avatar(vmath.vector3(rx, ry, 0),
                vmath.vector3(SZ * pop, SZ * pop, 0), r.avatar or 1))
        end
    end

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
        -- Native, fully smooth countdown ring (animates independent of redraw
        -- cycle), running the whole window — the assessment included, so the
        -- clock is still moving at the moment the match is being decided.
        --
        -- The fraction comes from search_clock, NOT from time_left / window.
        -- The window is corrected the moment the server speaks, and dividing
        -- by a smaller denominator makes the same remaining time a bigger
        -- fraction — which refilled the ring mid-count. See M.arc.
        local time_left = time_shown
        local frac = search_clock.arc(sr)
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
