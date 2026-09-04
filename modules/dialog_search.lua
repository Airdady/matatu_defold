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

-- ---------------------------------------------------------------------------
-- WHAT THE DIALOG SAYS, AS PURE FUNCTIONS.
--
-- Pulled out of the drawing code because the words change far more often than
-- the LAYOUT does — every half second for the dots, every time somebody
-- arrives — and rebuilding a screen to change a string is what made this
-- dialog cost what it cost. M.animate sets them on the existing nodes instead,
-- and it needs the same answers the builder used.

--- The heading. An arrival is not a match: the opponent is chosen when the
--- window closes, and titling the first arrival "OPPONENT FOUND" would be the
--- first-to-tap rule again, drawn rather than enforced.
function M.title_for(sr)
    sr = sr or {}
    local joined = #((type(sr.roster) == "table") and sr.roster or {})

    -- A PARTY IS THE SAME DIALOG WITH DIFFERENT WORDS.
    --
    -- Everything the tournament search does here a party also does: it opens,
    -- players arrive one by one, and it resolves. What it never does is
    -- CHOOSE — a party takes everybody who sat down — so the assessing state
    -- has no meaning and "opponent", singular, is the wrong noun throughout.
    if sr.party then
        if sr.found then return "TABLE READY!" end
        if sr.failed then return "TABLE DID NOT FILL" end
        return (joined > 0) and "PLAYERS JOINING" or "TABLE OPEN"
    end

    if sr.found then return "OPPONENT FOUND!" end
    if sr.failed then return "NO OPPONENT FOUND" end
    if search_clock.is_choosing(sr) then return "ASSESSING THE BEST CANDIDATE" end
    return (joined > 0) and "OPPONENTS FOUND" or "SEARCHING FOR OPPONENT"
end

local function plural(n, word)
    return tostring(n) .. " " .. word .. ((n == 1) and "" or "s")
end

--- The line under it.
--
-- Zero on the ring is the shortlist CLOSING, not the search giving up. The
-- dialog used to announce "no opponent" the instant the ring emptied, which on
-- a ladder was two seconds before the server had finished choosing between the
-- players who had accepted.
function M.status_for(sr)
    sr = sr or {}
    if sr.failed then
        return sr.fail_msg or (sr.party and "Nobody else sat down in time"
                                        or "No one accepted your invite")
    end
    if sr.found then return "get ready\226\128\166" end

    local joined = #((type(sr.roster) == "table") and sr.roster or {})
    local line
    if sr.party then
        -- Seats, not candidates. The count is what a player is watching, and
        -- the table plays with whoever is on it when the clock runs out — so
        -- "still searching" would promise a selection that never happens.
        line = (joined > 0)
            and (plural(joined + 1, "player") .. " at the table")
            or (sr.subtitle or "waiting for players to join")
        return line .. string.rep(".", 1 + (math.floor((sr.anim_t or sr.t or 0) * 2) % 3))
    end
    if search_clock.is_choosing(sr) then
        line = (joined > 0) and ("assessing " .. plural(joined, "candidate"))
            or "picking the best match"
    elseif joined > 0 then
        -- The reassurance the old spinner never gave: somebody IS there, and
        -- the search keeps running because a better match may still answer.
        line = plural(joined, "player") .. " joined, still searching"
    else
        line = sr.subtitle or "inviting a player to your battle"
    end
    -- The dots are a clock, not decoration: they are the only proof the dialog
    -- has not frozen during a quiet stretch.
    return line .. string.rep(".", 1 + (math.floor((sr.anim_t or sr.t or 0) * 2) % 3))
end

--- What would make the LAYOUT wrong, as a string to compare against.
--
-- Everything else — the words, the countdown, where a candidate is on their
-- way to the rail — M.animate can change on the nodes that already exist. Only
-- these need the screen rebuilt, and only these should ever ask for one.
function M.structure_key(sr)
    if type(sr) ~= "table" then return "none" end
    return table.concat({
        #((type(sr.roster) == "table") and sr.roster or {}),
        tostring(sr.chosen_id or ""),
        sr.found and "F" or "-",
        sr.failed and "X" or "-",
        (tonumber((sr.stake or {}).amount) or 0) > 0 and "$" or "-",
        tostring(sr.cancel_id or ""),
    }, "|")
end

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
    local t_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1) or (sr.failed and C.COL_GOLD or C.COL_WHITE)
    local title_node = track(self, ui.text(vmath.vector3(CX, CY + 130, 0), M.title_for(sr), "title", t_col))
    local sub_node = track(self, ui.text(vmath.vector3(CX, CY + 96, 0), M.status_for(sr), "small", C.COL_DIM))

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
    local CARD_W, CARD_GAP = 86, 8

    local chosen
    if sr.chosen_id then
        for _, r in ipairs(roster) do
            if r.userId == sr.chosen_id then chosen = r end
        end
    end

    -- Seats are laid out for the whole roster at once, so a player still in
    -- flight is heading for the place they will actually land rather than for
    -- wherever the row happened to end when they left.
    local function seat_x(i)
        local row_w = joined * CARD_W + math.max(0, joined - 1) * CARD_GAP
        return CX - row_w / 2 + CARD_W / 2 + (i - 1) * (CARD_W + CARD_GAP)
    end

    -- The server sends the tier as a WORD, and the two ends do not spell the
    -- bottom one the same way (AMATEUR there, BEGINNER here). rank_badge owns
    -- that translation so every surface reading a server tier gets it.
    local function tier_colors(entry)
        local c = rank_badge.colors_for((entry or {}).skillTier)
        if not c then return nil end
        return vmath.vector4(c.bg[1], c.bg[2], c.bg[3], c.bg[4]),
               vmath.vector4(c.tx[1], c.tx[2], c.tx[3], c.tx[4])
    end

    -- --- the slot itself --------------------------------------------------
    local frame_col = sr.found and GREEN
        or (sr.failed and vmath.vector4(0.85, 0.25, 0.25, 1) or vmath.vector4(0.25, 0.25, 0.30, 1))
    local frame = track(self, ui.box(vmath.vector3(bx, ay, 0), vmath.vector3(124, 124, 0), frame_col))

    -- The reel keeps hunting whenever nobody is standing in the slot. That is
    -- the point of the whole rearrangement: an acceptance no longer stops the
    -- search, it steps through the slot and moves aside, and the hunt visibly
    -- carries on behind it.
    local reel = track(self, ui.avatar(vmath.vector3(bx, ay, 0), vmath.vector3(SLOT, SLOT, 0), sr.reel_ix or 1))
    self[reel_key] = reel
    if sr.failed then
        gui.set_color(reel, vmath.vector4(0.55, 0.55, 0.55, 1))
        self[reel_key] = nil
    end

    -- THE GREEN LIGHT behind the slot. Built once and driven by its alpha
    -- rather than created when it is wanted — a node that only exists on the
    -- frames it is visible can only appear on a rebuild, which is exactly the
    -- thing this dialog no longer does to animate.
    local flash_node
    if not sr.failed then
        flash_node = track(self, ui.box(vmath.vector3(bx, ay, 0), vmath.vector3(150, 150, 0),
            vmath.vector4(0.15, 0.85, 0.35, 0)))
        pcall(gui.set_texture, flash_node, "ui")
        pcall(gui.play_flipbook, flash_node, hash("circle"))
    end

    -- The name under the slot, for when nobody is standing in it. A candidate
    -- carries their own name, so this empties rather than doubling up. Built
    -- blank: M.animate owns what it says, and a placeholder baked in here
    -- would be one more thing that can only change on a rebuild.
    local slot_name = track(self, ui.text(vmath.vector3(bx, ay - 86, 0), "", "body", C.COL_DIM))

    -- --- the shortlist rail, and everybody on their way to it -------------
    local rail_label, cards = nil, {}
    if joined > 0 and not sr.failed then
        -- WHAT THE RAIL IS, WHICH IS NOT THE SAME THING IN BOTH MODES.
        --
        -- In a search these are CANDIDATES: they accepted, they are being held
        -- while the window runs, and one of them will be chosen on tier fit at
        -- the end of it. At a party they are PLAYERS: they sat down, they are
        -- in, and nothing is going to choose between them — the table takes
        -- whoever is on it when the clock stops, in the order they arrived.
        -- "Held for you" over a party roster describes an assessment that
        -- never happens.
        rail_label = track(self, ui.text(vmath.vector3(CX, ry + SEAT / 2 + 22, 0),
            sr.party and "AT THE TABLE" or "HELD FOR YOU", "small", C.COL_DIM))

        for i, r in ipairs(roster) do
            local sx = seat_x(i)
            local box = track(self, ui.box(vmath.vector3(sx, ry, 0), vmath.vector3(SEAT + 8, SEAT + 8, 0),
                vmath.vector4(0.25, 0.25, 0.30, 1)))
            local av  = track(self, ui.avatar(vmath.vector3(sx, ry, 0), vmath.vector3(SEAT, SEAT, 0), r.avatar or 1))
            -- Always the small font, scaled up as they reach the slot. A font
            -- cannot be swapped on a live node, and swapping the NODE would
            -- mean rebuilding to animate.
            local nm  = track(self, ui.text(vmath.vector3(sx, ry - SEAT / 2 - 16, 0),
                string.upper(r.username or "PLAYER"), "small", C.COL_WHITE))
            -- AND NO TIER BADGE ON A PARTY SEAT, for the same reason.
            --
            -- The badge is on a candidate because their tier is the thing the
            -- window will judge them by. Nobody at a table is being judged by
            -- anything: the seats are first come, first served, and badging
            -- them says a table sorts its players when it does not.
            local tbg, ttx = nil, nil
            if not sr.party then tbg, ttx = tier_colors(r) end
            local tb, tt
            if tbg then
                tb = track(self, ui.box(vmath.vector3(sx, ry - SEAT / 2 - 34, 0), vmath.vector3(62, 15, 0), tbg))
                tt = track(self, ui.text(vmath.vector3(sx, ry - SEAT / 2 - 34, 0),
                    string.upper(tostring(r.skillTier)), "small", ttx))
            end
            cards[#cards + 1] = { entry = r, seat = sx, box = box, av = av, name = nm, tbg = tb, ttx = tt }
        end
    end

    -- Everything the per-frame updater needs, and nothing it would have to
    -- recompute a layout to learn.
    self.search_anim = {
        sr = sr, reel_key = reel_key,
        bx = bx, ay = ay, ry = ry, SLOT = SLOT, SEAT = SEAT, GREEN = GREEN,
        dim = C.COL_DIM, white = C.COL_WHITE, cyan = C.COL_CYAN, red = C.COL_RED,
        title = title_node, sub = sub_node,
        frame = frame, reel = reel, flash = flash_node, slot_name = slot_name,
        rail_label = rail_label, cards = cards,
        key = M.structure_key(sr),
    }

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
        -- THE COUNTDOWN RING, ABOVE THE TITLE.
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
        --
        -- fill_angle is tweened NATIVELY, so the ring runs at the display's
        -- own rate between rebuilds for free. M.retime_ring aims it, and only
        -- has to re-aim it when search_clock re-anchors — once per search.
        local RX, RY = CX, CY + 190
        local R = 30

        local bg = track(self, gui.new_pie_node(vmath.vector3(RX, RY, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(bg, 48)
        pcall(gui.set_inner_radius, bg, R * 0.80)
        gui.set_color(bg, vmath.vector4(0.25, 0.25, 0.25, 0.45))

        local fg = track(self, gui.new_pie_node(vmath.vector3(RX, RY, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(fg, 48)
        pcall(gui.set_inner_radius, fg, R * 0.80)
        gui.set_rotation(fg, vmath.vector3(0, 0, 90))
        gui.set_color(fg, C.COL_CYAN)

        local num = track(self, ui.text(vmath.vector3(RX, RY, 0), "", "body", C.COL_CYAN))

        local anim = self.search_anim
        anim.ring, anim.ring_num = fg, num
    end

    M.animate(self, sr)

    -- Optional cancel button (host owns the matching button id).
    if sr.cancel_id and not sr.found and not sr.failed then
        local cb = track(self, ui.btn9(vmath.vector3(CX, CY - 270, 0), vmath.vector3(170, 48, 0), "secondary_btn"))
        track(self, ui.text(vmath.vector3(CX, CY - 270, 0), "Cancel", "btn_md", vmath.vector4(1, 1, 1, 1)))
        self.buttons[#self.buttons + 1] = { node = cb, id = sr.cancel_id }
    end
end

-- ---------------------------------------------------------------------------
-- ANIMATING WITHOUT REBUILDING
--
-- WHY THIS EXISTS.
--
-- The hosts used to ask for a full screen rebuild twice a second for as long
-- as this dialog was open — the online screen's entire player list, both
-- panels, the dividers and the banner, or the whole tournament map, destroyed
-- and recreated from nothing — so that a countdown digit could change and
-- three dots could cycle. Hundreds of gui nodes a second, to animate a string.
-- That is where the frame rate went.
--
-- It was also a ceiling on what could be animated at all: a rebuild every
-- 500ms means a 450ms flight across the dialog gets exactly ONE frame, and an
-- entrance meant to travel simply teleports.
--
-- So the layout is built once and the moving parts are set on the nodes that
-- already exist — positions, sizes, colours, scales, strings. No allocation,
-- no deletion, nothing for the host to rebuild. A rebuild is needed only when
-- the LAYOUT is actually wrong: a player joined, a winner was named, the
-- search ended. That is what M.structure_key answers.

--- (Re)aim the native countdown tween at zero.
--
-- The ring is the one thing that needs no per-frame work at all: gui.animate
-- tweens fill_angle natively, so once aimed it runs at the display's own rate
-- for free. It only has to be re-aimed when search_clock re-anchors it, which
-- happens once per search — when the server names its window.
function M.retime_ring(a, sr)
    if not a or not a.ring then return false end
    local anchor = tostring(sr.arc_t0 or "") .. "/" .. tostring(sr.arc_secs or "")
    if a.ring_anchor == anchor then return false end
    a.ring_anchor = anchor

    pcall(gui.cancel_animation, a.ring, "fill_angle")
    local ok = pcall(gui.set_fill_angle, a.ring, search_clock.arc(sr) * 360)
    local sweep = search_clock.arc_secs(sr)
    if ok and sweep > 0 then
        pcall(gui.animate, a.ring, "fill_angle", 0, gui.EASING_LINEAR, sweep)
    end
    return true
end

--- One frame of the dialog, on the nodes the last draw left behind.
--
-- Safe to call when there is nothing to animate: no record, a record for a
-- different search, or nodes a rebuild has already deleted. It returns false
-- in all of those, so a host can simply call it every frame.
function M.animate(self, sr)
    local a = self and self.search_anim
    if not a or not sr or a.sr ~= sr then return false end

    local ok, err = pcall(function()
        local GREEN, SLOT, SEAT = a.GREEN, a.SLOT, a.SEAT
        local bx, ay, ry = a.bx, a.ay, a.ry

        -- The words. Set only when they actually change: gui.set_text relays
        -- the string, and doing that sixty times a second for a value that
        -- changes twice is the same waste in miniature.
        local title = M.title_for(sr)
        if title ~= a.last_title then a.last_title = title; gui.set_text(a.title, title) end
        local status = M.status_for(sr)
        if status ~= a.last_status then a.last_status = status; gui.set_text(a.sub, status) end

        -- The countdown. The RING is tweened natively and only re-aimed when
        -- search_clock re-anchors it; the DIGIT follows the smoothed number,
        -- the one a player reads and the one that never runs backwards.
        M.retime_ring(a, sr)
        if a.ring_num then
            local shown = tonumber(sr.shown) or search_clock.target(sr)
            local secs  = math.ceil(shown)
            if secs ~= a.last_secs then
                a.last_secs = secs
                gui.set_text(a.ring_num, tostring(secs))
                gui.set_color(a.ring_num, (shown <= 3) and a.red or a.cyan)
            end
        end

        local chosen
        if sr.chosen_id then
            for _, c in ipairs(a.cards) do
                if c.entry.userId == sr.chosen_id then chosen = c end
            end
        end
        local spot = (not sr.found and not sr.failed) and search_clock.spotlight(sr) or nil
        local slot_taken = (spot ~= nil) or (chosen ~= nil)

        -- The reel hunts whenever nobody is standing in the slot, and the host
        -- only spins the handle it is given — so dropping it here is what
        -- actually stops the flipbook churning behind a visible candidate.
        if not sr.failed then
            gui.set_color(a.reel, vmath.vector4(1, 1, 1, slot_taken and 0 or 1))
            self[a.reel_key] = (not slot_taken) and a.reel or nil
        end

        -- The name under the slot. A candidate carries their own, so this
        -- hides rather than saying the same thing twice.
        -- Emptied rather than merely faded when somebody is standing there.
        -- An invisible node still holding "? ? ?" is a lie to anything reading
        -- the dialog back — a screen reader, a test — and the alpha is only
        -- true for whoever happens to be looking at the pixels.
        local want = slot_taken and ""
            or (sr.found and string.upper(tostring(sr.opp_name or "PLAYER"))
            or (sr.failed and "\226\128\148" or "? ? ?"))
        if want ~= a.last_slot_name then
            a.last_slot_name = want
            gui.set_text(a.slot_name, want)
        end
        local nm_col = sr.found and a.white or a.dim
        gui.set_color(a.slot_name, vmath.vector4(nm_col.x, nm_col.y, nm_col.z,
            slot_taken and 0 or 1))

        if a.flash then
            local f = search_clock.flash(sr)
            local size = 150 + 40 * f
            gui.set_size(a.flash, vmath.vector3(size, size, 0))
            gui.set_color(a.flash, vmath.vector4(0.15, 0.85, 0.35, 0.35 * f))
        end

        if a.rail_label then
            local lab = chosen and "MATCHED" or "HELD FOR YOU"
            if lab ~= a.last_rail then
                a.last_rail = lab
                gui.set_text(a.rail_label, lab)
                gui.set_color(a.rail_label, chosen and GREEN or a.dim)
            end
        end

        local ret = chosen and search_clock.return_progress(sr) or 0
        for _, c in ipairs(a.cards) do
            local r = c.entry
            local is_won = chosen and (r.userId == chosen.entry.userId)
            local stage, p = search_clock.arrival_stage(sr, r)

            -- Where they are: 1 is the slot, 0 is their seat. The entrance and
            -- the winner's return are the same journey in opposite directions.
            local k
            if is_won then
                k = 1 - (1 - ret) * (1 - ret)        -- eased, lands softly
            elseif chosen then
                k = 0                                 -- everybody else stays seated
            elseif spot and r.userId ~= spot.userId then
                -- ONLY ONE PLAYER HOLDS THE SLOT. Two accepting close together
                -- means the newer takes it and the older goes straight to its
                -- seat; two entrances overlapping in one box reads as a glitch,
                -- and the seat is where the older one was heading anyway.
                k = 0
            elseif stage == "hold" then
                k = 1
            elseif stage == "fly" then
                k = 1 - p
            else
                k = 0
            end

            local pop = (stage == "hold" and not chosen)
                and search_clock.arrival_scale(sr, r) or 1
            local x = c.seat + (bx - c.seat) * k
            local y = ry + (ay - ry) * k
            local size = (SEAT + (SLOT - SEAT) * k) * pop
            local pad  = 8 + 8 * k

            gui.set_position(c.box, vmath.vector3(x, y, 0))
            gui.set_size(c.box, vmath.vector3(size + pad, size + pad, 0))
            gui.set_position(c.av, vmath.vector3(x, y, 0))
            gui.set_size(c.av, vmath.vector3(size, size, 0))

            -- The green of a fresh arrival fades into the neutral border; the
            -- chosen player keeps it, and breathes once they are home.
            if is_won then
                local pulse = search_clock.pulse(sr)
                gui.set_color(c.box, vmath.vector4(0.15, 0.85 - 0.15 * pulse, 0.35, 1))
            else
                local glow = search_clock.arrival_glow(sr, r)
                gui.set_color(c.box, vmath.vector4(
                    0.25 + (0.15 - 0.25) * glow,
                    0.25 + (0.85 - 0.25) * glow,
                    0.30 + (0.35 - 0.30) * glow, 1))
            end

            -- Name and tier ride along, growing as they reach the slot. The
            -- losers dim once a winner is named rather than vanishing: they
            -- did turn up, and the player watched them do it.
            local faded = (chosen and not is_won) and 0.45 or 1
            gui.set_position(c.name, vmath.vector3(x, y - size / 2 - 16 - 6 * k, 0))
            gui.set_scale(c.name, vmath.vector3(1 + 0.35 * k, 1 + 0.35 * k, 1))
            gui.set_color(c.name, vmath.vector4(a.white.x, a.white.y, a.white.z, faded))
            if c.tbg then
                local ty = y - size / 2 - 34 - 10 * k
                gui.set_position(c.tbg, vmath.vector3(x, ty, 0))
                gui.set_size(c.tbg, vmath.vector3(62 + 20 * k, 15 + 4 * k, 0))
                gui.set_position(c.ttx, vmath.vector3(x, ty, 0))
                gui.set_scale(c.ttx, vmath.vector3(1 + 0.2 * k, 1 + 0.2 * k, 1))
            end
        end
    end)

    if not ok then
        -- The nodes have been deleted out from under us (a rebuild, a screen
        -- change). Drop the record rather than throwing at sixty hertz.
        self.search_anim = nil
        if os.getenv and os.getenv("DEBUG_DRAW") then print("animate: " .. tostring(err)) end
        return false
    end
    return true
end

return M
