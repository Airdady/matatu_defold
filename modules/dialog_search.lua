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
--                t          elapsed seconds against the CURRENT window. Reset
--                           to zero whenever the server names a window, since
--                           it names a duration ("eight seconds from now").
--                anim_t     elapsed seconds that never reset. Every animation
--                           is measured against this one, so a beat that
--                           started before a correction finishes after it.
--                           Both are advanced by search_clock.tick.
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
--                           server as each one lands (GAME_REQUEST_ROSTER).
--                           Each carries an arrived_at stamp, which is what
--                           drives the entrance choreography below.
--                chosen_id  set on the last roster push only: the opponent the
--                           window actually awarded the match to
--                subtitle   searching subtitle (default battle-invite wording)
--                cancel_id  when set, a Cancel button with this id is drawn
--                modal      when true the scrim swallows taps (blocks behind UI)
--   reel_key : key on self under which the reel avatar node is stored so the host
--              update loop can spin it (default "search_reel_node").
local ws = require("modules.websocket_manager")
local search_clock = require("modules.search_clock")
local rank_badge   = require("modules.rank_badge")

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

    -- =====================================================================
    -- THE OPPONENT SLOT, AND THE STORY OF WHO PASSES THROUGH IT
    --
    -- The slot used to be a spinning reel that stayed a spinning reel, while
    -- everybody who accepted appeared as a small silent avatar in a row
    -- underneath. The single most interesting event in these twelve seconds —
    -- a real person agreeing to play you for money — had exactly the presence
    -- of a list item, and the slot went on asking a question that had already
    -- been answered.
    --
    -- It now tells the search as a story, in beats (timings in search_clock):
    --
    --   HOLD    the new arrival TAKES the slot. Full size, named, their tier
    --           under them. "Somebody is here."
    --   FLY     they travel out of the slot to a seat on the rail below,
    --           shrinking as they go. "And they are being kept." The reason
    --           the search does not simply stop, shown rather than explained.
    --   REST    they sit on the rail with name and tier while the slot goes
    --           back to hunting. The search visibly continues WITH them held.
    --   RETURN  when the window closes the chosen one flies back out of the
    --           rail into the slot and pulses green. The match arrives from
    --           where the candidates were kept, so it reads as the ANSWER to
    --           the search rather than as something that just appeared.
    -- =====================================================================
    local GREEN = vmath.vector4(0.15, 0.85, 0.35, 1)
    local SLOT  = 108           -- avatar size in the opponent slot
    local SEAT  = 44            -- avatar size on the shortlist rail
    local ry    = ay - 155      -- the rail's line

    local chosen
    if sr.chosen_id then
        for _, r in ipairs(roster) do
            if r.userId == sr.chosen_id then chosen = r end
        end
    end

    -- Where each candidate's seat on the rail is. Seats are laid out for the
    -- whole roster at once, so a player who is still flying is heading for the
    -- place they will actually land rather than for wherever the row happened
    -- to end when they left.
    local CARD_W, CARD_GAP = 86, 8
    local function seat_x(i)
        local row_w = joined * CARD_W + math.max(0, joined - 1) * CARD_GAP
        return CX - row_w / 2 + CARD_W / 2 + (i - 1) * (CARD_W + CARD_GAP)
    end

    local function tier_colors(entry)
        local key = string.lower(tostring((entry or {}).skillTier or ""))
        local c = rank_badge.COLORS[key]
        if not c then return nil end
        return vmath.vector4(c.bg[1], c.bg[2], c.bg[3], c.bg[4]),
               vmath.vector4(c.tx[1], c.tx[2], c.tx[3], c.tx[4])
    end

    -- One candidate, drawn anywhere between the slot and their seat. `k` is 0
    -- at the seat and 1 at the slot, so the entrance (1 -> 0) and the winner's
    -- return (0 -> 1) are the same drawing code run in opposite directions.
    local function draw_candidate(entry, i, k, border, dim, pop)
        local sx, sy = seat_x(i), ry
        local x = sx + (bx - sx) * k
        local y = sy + (ay - sy) * k
        local size = (SEAT + (SLOT - SEAT) * k) * (pop or 1)
        local pad  = 8 + 8 * k

        track(self, ui.box(vmath.vector3(x, y, 0),
            vmath.vector3(size + pad, size + pad, 0), border))
        track(self, ui.avatar(vmath.vector3(x, y, 0),
            vmath.vector3(size, size, 0), entry.avatar or 1))

        -- Name and tier ride along, fading in as they reach the slot so the
        -- rail stays legible when four of them are sitting side by side.
        local name_font = (k > 0.5) and "body" or "small"
        local name_col  = dim and C.COL_DIM or C.COL_WHITE
        track(self, ui.text(vmath.vector3(x, y - size / 2 - 16, 0),
            string.upper(entry.username or "PLAYER"), name_font, name_col))

        local tbg, ttx = tier_colors(entry)
        if tbg then
            local ty = y - size / 2 - 34
            local tw = 62 + 20 * k
            track(self, ui.box(vmath.vector3(x, ty, 0), vmath.vector3(tw, 15 + 4 * k, 0), tbg))
            track(self, ui.text(vmath.vector3(x, ty, 0),
                string.upper(tostring(entry.skillTier)), "small", ttx))
        end
    end

    -- --- the slot itself --------------------------------------------------
    local frame_col = sr.found and GREEN
        or (sr.failed and vmath.vector4(0.85, 0.25, 0.25, 1) or vmath.vector4(0.25, 0.25, 0.30, 1))
    local frame = track(self, ui.box(vmath.vector3(bx, ay, 0), vmath.vector3(124, 124, 0), frame_col))

    local spot = (not sr.found and not sr.failed) and search_clock.spotlight(sr) or nil
    local ret  = chosen and search_clock.return_progress(sr) or 0
    local slot_taken = (spot ~= nil) or (chosen ~= nil)

    -- The reel keeps hunting whenever nobody is standing in the slot. That is
    -- the point of the whole rearrangement: an acceptance no longer stops the
    -- search, it steps through the slot and moves aside, and the hunt visibly
    -- carries on behind it.
    local reel = track(self, ui.avatar(vmath.vector3(bx, ay, 0), vmath.vector3(SLOT, SLOT, 0), sr.reel_ix or 1))
    self[reel_key] = reel
    if slot_taken then
        gui.set_color(reel, vmath.vector4(1, 1, 1, 0))   -- hidden, not deleted
        self[reel_key] = nil
    elseif sr.failed then
        gui.set_color(reel, vmath.vector4(0.55, 0.55, 0.55, 1))
        self[reel_key] = nil
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

    -- --- the shortlist rail, and everybody on their way to it -------------
    if joined > 0 and not sr.failed then
        track(self, ui.text(vmath.vector3(CX, ry + SEAT / 2 + 22, 0),
            chosen and "MATCHED" or "HELD FOR YOU", "small",
            chosen and GREEN or C.COL_DIM))

        for i, r in ipairs(roster) do
            local is_won  = chosen and (r.userId == chosen.userId)
            local stage, p = search_clock.arrival_stage(sr, r)

            -- Where they are: 1 is the slot, 0 is their seat.
            local k
            if is_won then
                -- Coming home. Eased so it arrives softly rather than at speed.
                local e = 1 - (1 - ret) * (1 - ret)
                k = e
            elseif chosen then
                k = 0                       -- everybody else stays seated
            elseif spot and r.userId ~= spot.userId then
                -- ONLY ONE PLAYER CAN HOLD THE SLOT. When two accept close
                -- together the newer one takes it and the older goes straight
                -- to its seat — two entrances overlapping in the same 108px
                -- box reads as a glitch, and the seat is where the older one
                -- was heading anyway.
                k = 0
            elseif stage == "hold" then
                k = 1
            elseif stage == "fly" then
                k = 1 - p                   -- linear: they are travelling
            else
                k = 0
            end

            -- The green of a fresh arrival fades into the neutral border; the
            -- chosen player keeps it, and breathes once they are home.
            local border
            if is_won then
                local pulse = search_clock.pulse(sr)
                border = vmath.vector4(0.15, 0.85 - 0.15 * pulse, 0.35, 1)
            else
                local glow = search_clock.arrival_glow(sr, r)
                border = vmath.vector4(
                    0.25 + (0.15 - 0.25) * glow,
                    0.25 + (0.85 - 0.25) * glow,
                    0.30 + (0.35 - 0.30) * glow, 1)
            end

            -- The overshoot on the way in. It settles halfway through the
            -- hold, so the punch is over before they start travelling.
            local pop = (stage == "hold" and not chosen)
                and search_clock.arrival_scale(sr, r) or 1

            draw_candidate(r, i, k, border, chosen and not is_won, pop)
        end
    end

    -- The name under the slot is only drawn when NOBODY is standing in it —
    -- a candidate carries their own name, and a second one underneath would
    -- be the same fact twice.
    if not slot_taken then
        local who = sr.found and (sr.opp_name or "PLAYER") or (sr.failed and "\226\128\148" or "? ? ?")
        track(self, ui.text(vmath.vector3(bx, ay - 86, 0), who, "body",
            sr.found and C.COL_WHITE or C.COL_DIM))
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
        local sweep = search_clock.arc_secs(sr)
        -- ABOVE THE TITLE, not under the avatars.
        --
        -- It used to sit dead centre below the pot, which is exactly where the
        -- shortlist rail now lives — and the rail is the more important thing,
        -- because it is the part that tells the player the search is working.
        --
        -- Above the heading rather than beside it: "ASSESSING THE BEST
        -- CANDIDATE" is twenty-eight characters of title font and there is no
        -- room to its right that a shorter status would not leave looking
        -- lopsided. Centred over the whole dialog, it reads as the clock on
        -- all of it.
        local RX, RY = CX, CY + 190
        local R = 30

        local bg = track(self, gui.new_pie_node(vmath.vector3(RX, RY, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(bg, 48)
        pcall(gui.set_inner_radius, bg, R * 0.80)
        gui.set_color(bg, vmath.vector4(0.25, 0.25, 0.25, 0.45))

        local col = time_left <= 3 and C.COL_RED or C.COL_CYAN
        local fg = track(self, gui.new_pie_node(vmath.vector3(RX, RY, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(fg, 48)
        pcall(gui.set_inner_radius, fg, R * 0.80)
        gui.set_rotation(fg, vmath.vector3(0, 0, 90))
        gui.set_fill_angle(fg, frac * 360)
        gui.set_color(fg, col)
        -- Animated over the RING's own remaining time, not the number's. The
        -- angle it starts from comes from the anchor in search_clock, so the
        -- duration has to as well — hand it the smoothed number instead and
        -- the animation and the next redraw's recomputation disagree, which
        -- the node visibly jumps to resolve on every single redraw.
        if sweep > 0 then
            pcall(gui.animate, fg, "fill_angle", 0, gui.EASING_LINEAR, sweep)
        end

        track(self, ui.text(vmath.vector3(RX, RY, 0), tostring(math.ceil(time_left)), "body", col))
    end

    -- Optional cancel button (host owns the matching button id).
    if sr.cancel_id and not sr.found and not sr.failed then
        local cb = track(self, ui.btn9(vmath.vector3(CX, CY - 270, 0), vmath.vector3(170, 48, 0), "secondary_btn"))
        track(self, ui.text(vmath.vector3(CX, CY - 270, 0), "Cancel", "btn_md", vmath.vector4(1, 1, 1, 1)))
        self.buttons[#self.buttons + 1] = { node = cb, id = sr.cancel_id }
    end
end

return M
