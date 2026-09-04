-- modules/dialog_party.lua
-- THE PARTY TABLE, ON THE INCOMING DIALOG'S SURFACE.
--
-- A table used to be drawn by dialog_search — the same ring, reel and
-- shortlist rail a tournament search uses — on the theory that the two are the
-- same thing from the player's side: you opened something, and you are
-- watching people arrive.
--
-- They are not the same thing, and the rail is where it shows. A search rail
-- holds CANDIDATES: people the server will pick ONE of, which is why the reel
-- goes on hunting beside them and why the row grows from nothing with no idea
-- how long it will get. A party's seats are neither. The table is a fixed
-- number of chairs, known from the moment it opens, and everybody on it is
-- already in — nobody is being assessed. What a player actually wants to know
-- is how many chairs are LEFT, and that is the one thing a rail that only
-- draws arrivals cannot show.
--
-- So the table takes the incoming dialog's surface instead: the same scrim,
-- backdrop, avatar helper and button list a challenge gets, through the same
-- `ctx` dialog_incoming takes — and every chair is drawn, the empty ones
-- included.
--
-- THERE IS NO WAY OUT, AND THAT IS THE DESIGN.
--
-- This dialog has no button at all. A seat is paid for the instant it is
-- taken, and leaving forfeits the entry — so a LEAVE button is a control whose
-- only function is to take a player's money and give them nothing back, one
-- tap away from a table that was about to deal. The table is resolved by the
-- SERVER and only by the server: it fills and starts, or the window closes on
-- too few players and it is called off. (handlePartyLeave still exists on the
-- backend because a DROPPED SOCKET has to free the chair — a player who is
-- gone cannot hold a seat the others are waiting on. Nothing on screen reaches
-- it.)
--
-- WHAT MOVES, AND IN WHAT ORDER
--
-- One reel, on the next empty chair, hunting through avatars exactly as the
-- search dialog's does — same cadence, same pool, so it reads as the same
-- object rather than a second thing that happens to spin. When that chair
-- fills, the arrival is ONE event told in four beats rather than four things
-- happening at once:
--
--   0.00  the real avatar pops into the chair the reel was standing in
--   0.00  a ring blooms out from behind it and fades
--   0.12  the pot starts counting up to its new total
--   0.34  the reel reappears, on the NEXT empty chair
--
-- The reel is hidden for that third of a second on purpose. Two things
-- competing for the eye at the moment somebody arrives is how an animation
-- ends up reading as a glitch.

local ws = require("modules.websocket_manager")
local ui = require("modules.ui")

local M = {}

-- Chair sizes. Four is the table today; the layout is computed from the count
-- rather than tabulated, so three or five still lands centred and inside the
-- scrim on the narrowest device the app supports.
local SEAT_SIZE_MAX = 84
local SEAT_SIZE_MIN = 58
local SEAT_GAP      = 26
local ROW_MAX_W     = 760

-- The empty chair. Dim, ringed, and unmistakably NOT a player — it used to be
-- tempting to draw nothing at all where nobody is sitting, and a table that
-- only shows the people already in it cannot show you it is still filling.
local SEAT_EMPTY_RING = vmath.vector4(0.30, 0.36, 0.44, 1.00)
local SEAT_EMPTY_FILL = vmath.vector4(0.10, 0.13, 0.17, 0.90)
local SEAT_HOST       = vmath.vector4(1.00, 0.84, 0.20, 1.00)
local SEAT_FLASH      = vmath.vector4(0.20, 0.90, 1.00, 1.00)

-- THE REEL, matching the search dialog's exactly: sixty avatars, a new one
-- every seventy milliseconds. Same numbers on purpose — a player who has
-- watched one search has already learned what a hunting reel means, and a
-- party spinning at a different rate would read as a different thing.
M.REEL_AVATARS = 60
M.REEL_STEP    = 0.07

-- THE ARRIVAL, AS A TIMELINE. See the note at the top: these are the beats of
-- one event, and the gaps between them are what stops it reading as a glitch.
M.POP_SECONDS    = 0.30   -- the avatar overshooting into its chair
M.POP_SETTLE     = 0.16   -- and settling back to true size
M.FLASH_SECONDS  = 0.45   -- the ring blooming out behind it
M.POT_DELAY      = 0.12   -- before the pot starts counting
M.POT_SECONDS    = 0.50   -- and how long it takes to get there
M.REEL_RESUME    = 0.34   -- before the reel appears on the next chair

--- Read a table off the wire shape, defensively.
-- Everything is optional: a payload from a server older than any given field
-- has to draw something rather than take the dialog down with it.
function M.view(d)
    d = (type(d) == "table") and d or {}
    local seats = {}
    for _, s in ipairs((type(d.seats) == "table") and d.seats or {}) do
        seats[#seats + 1] = {
            user_id  = tostring(s.userId or ""),
            username = tostring(s.username or "Player"),
            avatar   = tonumber(s.avatar) or 1,
        }
    end
    local remaining = tonumber(d.seatsRemaining) or 0
    if remaining < 0 then remaining = 0 end
    local entry = tonumber(d.entry) or 0
    return {
        party_id  = tostring(d.partyId or ""),
        host_id   = tostring(d.hostId or ""),
        entry     = entry,
        mode      = tostring(d.mode or "NORMAL"),
        score_cap = tonumber(d.scoreCap) or 0,
        status    = tostring(d.status or "FILLING"),
        seats     = seats,
        remaining = remaining,
        -- The table's SIZE, arrived at from the server's own two numbers so
        -- this side never has to hold a copy of PARTY_SIZE.
        size      = #seats + remaining,
        closes_at = tonumber(d.closesAt) or 0,
    }
end

--- What is actually in the pot.
--
-- Entry times the seats that are FILLED, and it grows as they fill: a table at
-- 200 a seat is 200 when the host is alone, 400 when somebody sits down, 600
-- on the third. Never entry times the table SIZE, which would promise a
-- four-way prize out of money nobody has put in — and would then have to
-- count DOWN if the table started short, which is not a thing a pot should
-- ever be seen doing.
function M.pot_of(view)
    view = view or {}
    return (tonumber(view.entry) or 0) * math.max(1, #((view.seats) or {}))
end

--- Which coin bundle stands for a pot this size.
--
-- Delegated to ui.lua, where the ladder now lives once. This used to be a
-- fifth copy of it, and the bundle it fed was drawn with ui.image — which sets
-- the "ui" atlas and asks it for an animation called "coins" that does not
-- exist there. play_flipbook is pcall'd, so the miss was silent and the pot
-- was an untextured box. The real pot is the "coins" atlas with the TIER as
-- the animation, the way every other surface draws it.
M.bundle_for = ui.coin_pot_image

--- The first chair nobody is sitting in — where the reel stands.
function M.next_empty(view)
    view = view or {}
    local filled = #((view.seats) or {})
    local size   = math.max(filled, tonumber(view.size) or 0)
    if filled >= size then return nil end
    return filled + 1
end

--- Where each chair sits, for a table of `n`.
-- Centred as a row, so a table of two is not drawn hugging the left edge of
-- the space a table of four would have used.
local function seat_layout(cx, n)
    n = math.max(1, math.floor(n or 4))
    local size  = SEAT_SIZE_MAX
    local total = n * size + (n - 1) * SEAT_GAP
    if total > ROW_MAX_W then
        size  = math.max(SEAT_SIZE_MIN, math.floor((ROW_MAX_W - (n - 1) * SEAT_GAP) / n))
        total = n * size + (n - 1) * SEAT_GAP
    end
    return size, cx - total / 2 + size / 2, size + SEAT_GAP
end

-- ── THE VERTICAL RHYTHM, DERIVED RATHER THAN PICKED ──────────────────────────
--
-- The pot was landing ON the empty chairs. Its bundle sat at a hand-picked
-- offset from the dialog's centre while the chairs sat at another, and with an
-- 88px pile and 84px chairs the two numbers simply overlapped: the coins were
-- drawn straight through the placeholder avatars.
--
-- Two offsets chosen independently will always be one layout change away from
-- colliding, so nothing below the chairs is chosen any more. The row's own
-- bottom edge — the chair, its label, and the ink that label actually occupies
-- — is measured, and everything under it hangs off that. Shrink the chairs on
-- a narrow screen and the pot follows them up; grow them and it moves down.
local SEAT_LABEL_DROP = 18   -- the name's baseline, below the chair's edge
local SEAT_LABEL_INK  = 10   -- how far a "small" label reaches below its baseline
local POT_CLEARANCE   = 18   -- clear air between that ink and the top of the pile
local POT_SIZE        = 88   -- the same pile the search dialog draws
local POT_FIGURE_GAP  = 18   -- the figure, under the pile
local POT_EACH_GAP    = 22   -- "200 each", under the figure
local STATUS_GAP      = 26   -- and the countdown under that

--- Every y this dialog uses, worked out from the one row that has a size.
--
-- Exposed so the layout can be asserted rather than eyeballed: the property
-- that matters is that `pot_top` sits BELOW `chairs_bottom`, and that is a
-- number a test can read.
function M.layout(cx, cy, n)
    local size, left, step = seat_layout(cx, n)
    local seat_y   = cy + 52
    local label_y  = seat_y - size / 2 - SEAT_LABEL_DROP
    -- The lowest ink in the chair row: the bottom of the WAITING / name label,
    -- not the bottom of the avatar.
    local chairs_bottom = label_y - SEAT_LABEL_INK
    local pot_y    = chairs_bottom - POT_CLEARANCE - POT_SIZE / 2
    local figure_y = pot_y - POT_SIZE / 2 - POT_FIGURE_GAP
    return {
        seat_size = size, seat_left = left, seat_step = step,
        seat_y = seat_y,
        seat_label_y = label_y,
        host_y = seat_y + size / 2 + 16,
        chairs_bottom = chairs_bottom,
        pot_y = pot_y,
        pot_size = POT_SIZE,
        pot_top = pot_y + POT_SIZE / 2,
        figure_y = figure_y,
        each_y = figure_y - POT_EACH_GAP,
        status_y = figure_y - POT_EACH_GAP - STATUS_GAP,
    }
end

--- The whole table.
--
-- `d` is the dialog record incoming.gui_script built from a PARTY_ROSTER:
--   { party_view, time_left, arrived_index, pot_from }
--
-- `party_view` rather than `party`: the overlay already uses `dialog.party`
-- for the OFFER strip — an invitation to a table you are not at — and one
-- field meaning two things is how the seated table would close itself the
-- moment the lobby stopped advertising it.
--
-- Leaves `self.party_anim` behind for M.animate to drive, the same contract
-- dialog_search's draw/animate pair uses.
function M.draw(self, ctx, d, a)
    local C         = ctx.C
    local track     = ctx.track
    local ui        = ctx.ui
    local commas    = ctx.commas
    local with_a    = ctx.with_a
    local CX        = ctx.CX
    local CY        = ctx.CY
    local LOGICAL_W = ctx.LOGICAL_W
    local LOGICAL_H = ctx.LOGICAL_H

    local p     = (type(d.party_view) == "table") and d.party_view or M.view(nil)
    local seats = p.seats or {}
    local n     = math.max(#seats, p.size or 4)

    -- Same scrim, same backdrop and the same "dlg_block" catcher a challenge
    -- gets. Modal, and with nothing to press: every tap is swallowed, which is
    -- the honest shape for a decision that has already been made and paid for.
    local scrim = track(self, ui.box(vmath.vector3(CX, CY, 0),
        vmath.vector3(LOGICAL_W * 2, LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.62 * a)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dlg_block" }
    local grad = track(self, ui.grad_backdrop(LOGICAL_W, LOGICAL_H))
    gui.set_color(grad, vmath.vector4(1, 1, 1, a))

    local starting = p.status == "STARTING"

    track(self, ui.text(vmath.vector3(CX, CY + 168, 0),
        starting and "PARTY STARTING" or "PARTY TABLE", "title",
        with_a(starting and C.COL_GREEN or C.COL_CYAN, a)))

    -- HOW THE TABLE IS WON, on the line under the title. A capped party and a
    -- normal one are different games, and the seated players are about to play
    -- one of them. "CAP 200" rather than "SCORE CAP 200", matching the word the
    -- lobby's knockout row already uses for the same ladder.
    local mode_txt = (p.mode == "SCORECAP")
        and ("CAP " .. tostring(math.floor(p.score_cap)))
        or "PLAY IT OUT"
    track(self, ui.text(vmath.vector3(CX, CY + 138, 0), mode_txt, "small", with_a(C.COL_MID, a)))

    -- ── The chairs ───────────────────────────────────────────────────────────
    -- Every y below the title comes from one place, so the pot cannot land on
    -- the chairs again. See M.layout.
    local L       = M.layout(CX, CY, n)
    local size, left, step = L.seat_size, L.seat_left, L.seat_step
    local seat_y  = L.seat_y
    local my_id   = tostring(ws.get_current_user_id() or "")
    local arrived = tonumber(d.arrived_index)
    local reel_at = M.next_empty(p)

    local chairs = {}

    for i = 1, n do
        local x, seat = left + (i - 1) * step, seats[i]

        if seat then
            -- The bloom, BEHIND the avatar, so it reads as light coming out
            -- from under the chair rather than a disc laid over the face.
            -- Created for every filled chair but only driven for the one that
            -- just arrived: a node that exists costs nothing until animate
            -- gives it a size, and creating it lazily would mean creating it
            -- in the one frame that is already doing the most work.
            local flash = track(self, ui.pie(vmath.vector3(x, seat_y, 0), size / 2 + 6,
                with_a(SEAT_FLASH, 0)))

            ctx.dlg_avatar(self, x, seat_y, size, seat.avatar, a)
            -- dlg_avatar tracks two nodes — the well and the face — and the
            -- face is the second, which is the one that pops.
            local face = self.nodes[#self.nodes]

            -- HOST sits ABOVE the chair rather than beside the name: the names
            -- are already the widest thing in the row, and a suffix on one of
            -- them would push that label past its neighbours.
            if seat.user_id == p.host_id then
                track(self, ui.text(vmath.vector3(x, L.host_y, 0), "HOST",
                    "small", with_a(SEAT_HOST, a)))
            end

            local is_me = seat.user_id == my_id
            local label = is_me and "YOU" or tostring(seat.username):upper()
            if #label > 10 then label = label:sub(1, 9) .. "." end
            track(self, ui.text(vmath.vector3(x, L.seat_label_y, 0), label, "small",
                with_a(is_me and ctx.DLG_SEARCH or C.COL_WHITE, a)))

            chairs[i] = { face = face, flash = flash, base = size }

            -- THE ARRIVAL. Started here rather than in animate because it is a
            -- one-shot native tween: gui.animate runs at the display's own
            -- rate between frames, and a scale driven by hand from update()
            -- would step at whatever rate the rest of the dialog happens to
            -- rebuild at.
            if i == arrived then
                gui.set_scale(face, vmath.vector3(0.55, 0.55, 1))
                gui.animate(face, "scale", vmath.vector3(1.12, 1.12, 1),
                    gui.EASING_OUTBACK, M.POP_SECONDS, 0, function()
                        pcall(gui.animate, face, "scale", vmath.vector3(1, 1, 1),
                            gui.EASING_OUTSINE, M.POP_SETTLE)
                    end)
            end
        else
            -- Ring first, then the well inside it, so the ring reads as an
            -- outline rather than as a disc with something drawn on top.
            track(self, ui.pie(vmath.vector3(x, seat_y, 0), size / 2 + 6,
                with_a(SEAT_EMPTY_RING, 0.55 * (a or 1))))
            track(self, ui.pie(vmath.vector3(x, seat_y, 0), size / 2, with_a(SEAT_EMPTY_FILL, a)))

            if i == reel_at and not starting then
                -- THE REEL, and only ever one of them. It stands in the chair
                -- that is next to be taken, so the thing that is moving is
                -- also the thing about to change — the player is already
                -- looking at the right chair when somebody lands in it.
                local reel = track(self, ui.avatar(vmath.vector3(x, seat_y, 0),
                    vmath.vector3(size, size, 0), math.random(M.REEL_AVATARS)))
                gui.set_color(reel, vmath.vector4(1, 1, 1, (arrived and 0 or 1) * (a or 1)))
                chairs[i] = { reel = reel, base = size }
            else
                track(self, ui.text(vmath.vector3(x, seat_y, 0), "?", "title",
                    with_a(SEAT_EMPTY_RING, a)))
            end

            track(self, ui.text(vmath.vector3(x, L.seat_label_y, 0), "WAITING", "small",
                with_a(C.COL_DIM, a)))
        end
    end

    -- ── The pot, BELOW the chairs ────────────────────────────────────────────
    local entry    = p.entry
    local pot      = M.pot_of(p)
    local pot_from = tonumber(d.pot_from) or pot

    local bundle
    if entry > 0 then
        -- THE REAL POT BUNDLE, the same one the challenge dialog and the board
        -- HUD draw: the "coins" atlas, the tier as the animation, through the
        -- one helper that knows that pair. The pile above, the figure directly
        -- under it, exactly as the search dialog stacks them — and hung off
        -- the chair row's own bottom edge, so it can no longer be drawn
        -- through the placeholder avatars.
        bundle = track(self, ui.coin_pot(
            vmath.vector3(CX, L.pot_y, 0), vmath.vector3(L.pot_size, L.pot_size, 0), pot_from))
        gui.set_color(bundle, vmath.vector4(1, 1, 1, a))
    end

    -- A practice table has no pile, so its words take the pile's place rather
    -- than leaving a hole in the middle of the column.
    local pot_node = track(self, ui.text(
        vmath.vector3(CX, entry > 0 and L.figure_y or L.pot_y, 0),
        entry > 0 and (commas(math.floor(pot_from)) .. " POT") or "PRACTICE TABLE",
        "helvetica_black", with_a(C.COL_GOLD, a)))
    if entry > 0 then
        track(self, ui.text(vmath.vector3(CX, L.each_y, 0),
            commas(entry) .. " each", "small", with_a(C.COL_MID, a)))
    end

    -- ── How long is left ─────────────────────────────────────────────────────
    local line_node = track(self, ui.text(vmath.vector3(CX, L.status_y, 0), "", "body",
        with_a(C.COL_GOLD, a)))

    -- Everything the per-frame updater needs, and nothing it would have to
    -- recompute a layout to learn — the same contract dialog_search's
    -- search_anim uses.
    self.party_anim = {
        party_id = p.party_id,
        view     = p,
        alpha    = a,
        chairs   = chairs,
        reel_at  = reel_at,
        reel_ix  = 0,
        reel_t   = 0,
        arrived  = arrived,
        -- Seconds since the arrival, which is what the timeline above is read
        -- against. nil when the table simply appeared.
        since    = arrived and 0 or nil,
        pot_node = pot_node,
        bundle   = bundle,
        pot_from = pot_from,
        pot_to   = pot,
        pot_t    = 0,
        pot_tier = M.bundle_for(pot_from),
        line     = line_node,
        gold     = C.COL_GOLD,
        red      = C.COL_RED,
        green    = C.COL_GREEN,
        commas   = commas,
        with_a   = with_a,
    }

    -- Painted once now so the first frame is not blank, then owned by animate.
    M.animate(self, d, 0)
end

--- One frame of the table, on the nodes the last draw left behind.
--
-- Safe to call when there is nothing to animate: no record, a record for a
-- different table, or nodes a rebuild has already deleted. It returns false in
-- all of those, so the host can simply call it every frame.
function M.animate(self, d, dt)
    local an = self and self.party_anim
    if not an or type(d) ~= "table" then return false end
    local p = (type(d.party_view) == "table") and d.party_view or nil
    if not p or p.party_id ~= an.party_id then return false end

    dt = tonumber(dt) or 0

    local ok = pcall(function()
        if an.since then an.since = an.since + dt end

        -- ── THE REEL ─────────────────────────────────────────────────────────
        -- Hidden for the third of a second after somebody lands, so the
        -- arrival has the eye to itself. Then it comes back, in the next
        -- chair, hunting at the same rate a search reel does.
        local chair = an.reel_at and an.chairs[an.reel_at]
        if chair and chair.reel then
            local waiting = an.since and an.since < M.REEL_RESUME
            gui.set_color(chair.reel,
                vmath.vector4(1, 1, 1, waiting and 0 or (an.alpha or 1)))
            if not waiting then
                an.reel_t = an.reel_t + dt
                if an.reel_t >= M.REEL_STEP then
                    an.reel_t = 0
                    an.reel_ix = math.random(M.REEL_AVATARS)
                    pcall(gui.play_flipbook, chair.reel, "avatar_" .. an.reel_ix)
                end
            end
        end

        -- ── THE BLOOM behind the chair that just filled ──────────────────────
        local landed = an.arrived and an.chairs[an.arrived]
        if landed and landed.flash and an.since then
            local f = an.since / M.FLASH_SECONDS
            if f >= 1 then
                gui.set_color(landed.flash, vmath.vector4(0, 0, 0, 0))
            else
                gui.set_scale(landed.flash, vmath.vector3(1 + 0.6 * f, 1 + 0.6 * f, 1))
                gui.set_color(landed.flash, vmath.vector4(
                    SEAT_FLASH.x, SEAT_FLASH.y, SEAT_FLASH.z, 0.6 * (1 - f) * (an.alpha or 1)))
            end
        end

        -- ── THE POT, COUNTING UP ─────────────────────────────────────────────
        -- A number that jumps says a new figure; a number that climbs says
        -- somebody just paid into it. Delayed a fraction so the eye goes to
        -- the chair first and then follows the money.
        if an.pot_node and (an.view.entry or 0) > 0 then
            local shown = an.pot_to
            if an.pot_from ~= an.pot_to then
                local elapsed = (an.since or math.huge) - M.POT_DELAY
                if elapsed <= 0 then
                    shown = an.pot_from
                elseif elapsed >= M.POT_SECONDS then
                    shown = an.pot_to
                else
                    local f = elapsed / M.POT_SECONDS
                    shown = an.pot_from + (an.pot_to - an.pot_from) * f
                end
            end
            local whole = math.floor(shown + 0.5)
            if whole ~= an.last_pot then
                an.last_pot = whole
                gui.set_text(an.pot_node, an.commas(whole) .. " POT")
                -- The pile keeps step with the figure as it climbs, so the
                -- picture and the number never disagree about how much is on
                -- the table.
                local tier = M.bundle_for(whole)
                if an.bundle and tier ~= an.pot_tier then
                    an.pot_tier = ui.set_coin_pot(an.bundle, whole)
                end
            end
        end

        -- ── THE CLOCK ────────────────────────────────────────────────────────
        -- Owned here rather than by a rebuild every whole second: the dialog
        -- is full of tweens now, and tearing every node down once a second to
        -- change two characters would restart all of them.
        local secs = math.max(0, math.ceil(tonumber(d.time_left) or 0))
        local line, col
        if p.status == "STARTING" then
            line, col = "Dealing you in...", an.green
        elseif p.remaining <= 0 then
            line, col = "Table full - starting", an.green
        elseif secs <= 0 then
            -- ZERO IS NOT A FAILURE. The server decides the table at zero —
            -- whoever is seated plays — and says so a moment later. Counting
            -- down into "nobody came" would be the search dialog's own old bug
            -- drawn on a different surface.
            line, col = "Closing the table...", an.gold
        else
            line = string.format("%d seat%s left  -  %ds", p.remaining,
                p.remaining == 1 and "" or "s", secs)
            col = (secs <= 5) and an.red or an.gold
        end
        if line ~= an.last_line then
            an.last_line = line
            gui.set_text(an.line, line)
            gui.set_color(an.line, an.with_a(col, an.alpha or 1))
        end
    end)

    return ok
end

return M
