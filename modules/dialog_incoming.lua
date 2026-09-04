-- modules/dialog_incoming.lua
-- Handles the incoming game request dialog rendering.

local ws   = require("modules.websocket_manager")
local rank = require("modules.rank_badge")
-- The arrival easing, borrowed rather than written again: a seat filling here
-- and a candidate landing on the search rail are the same beat, and they
-- should overshoot and settle identically.
local search_clock = require("modules.search_clock")

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
    -- THE OPPONENT'S STANDING, AS A TIER RATHER THAN A PERCENTAGE.
    --
    -- This slot used to read "WR 48%" in one of three colours. The number is
    -- the wrong shape for the glance it gets: the player has ten seconds and
    -- one decision, and working out whether 48 is good takes context nobody
    -- holds at that moment. The tier says it in a word — BEGINNER, PRO, MASTER,
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

    -- Simple text countdown timer strictly below the bundle
    local secs      = math.max(0, math.ceil(d.time_left or 0))
    local timer_col = ((d.time_left or 0) <= 3) and C.COL_RED or C.COL_GOLD
    local timer_pos = vmath.vector3(CX, bundle_y - bundle_h/2 - 12, 0)
    track(self, ui.text(timer_pos, secs .. "s", "body", with_a(timer_col, a)))

    -- Plain gold text below the timer — no boxed/bordered container, same
    -- icon-then-amount style the in-game coin pot HUD already uses
    -- (coins.gui_script's ensure_pot), instead of a separate bordered chip.
    local st_txt = amt == 0 and "PRACTICE" or commas(pot_amt)
    local stake_pos = vmath.vector3(CX, timer_pos.y - 30, 0)

    local stake_node = track(self, ui.text(stake_pos, st_txt, "helvetica_black", with_a(C.COL_GOLD, a)))
    gui.set_scale(stake_node, vmath.vector3(0.85, 0.85, 0.85))

    -- Additional Status Info cleanly separated
    track(self, ui.text(vmath.vector3(CX, CY - 95, 0), "Wants to play!", "small", with_a(C.COL_MID, a)))

    if hv then draw_h2h_row(self, CX, CY - 118, hv, a) end

    mkbtn(self, "decline", vmath.vector3(CX - 95, CY - 162, 0), vmath.vector3(150, 48, 0), "DECLINE", "primary_btn")
    mkbtn(self, "accept",  vmath.vector3(CX + 95, CY - 162, 0), vmath.vector3(150, 48, 0), "ACCEPT",  "secondary_btn")
end

-- ── THE PARTY TABLE, AS THE REQUEST DIALOG ──────────────────────────────────
--
-- A party waiting room is the same KIND of thing an incoming challenge is: a
-- centred plate, the people in it, what is at stake, and a clock — so it is
-- drawn by this file rather than by a second surface that would drift from it.
--
-- What it is NOT is a search. The reel dialog it replaced was built for an
-- opponent hunt: a spinning slot, a rail of candidates "HELD FOR YOU", one of
-- whom would be chosen at the end. None of that happens at a table. Everybody
-- who sits down is in, in the order they arrived, and the only thing a player
-- is actually watching is CHAIRS FILLING — which the reel could not show,
-- because it had no concept of a chair that is still empty.
--
-- So the empty seats are drawn. All of them, from the first frame: four
-- places, some with a player in them and some waiting, and the waiting ones
-- breathe so the table reads as live rather than broken. A player can see at a
-- glance how many more are needed, which is the one question the old dialog
-- could not answer.

--- Normalise a party into seats to draw, stamping when each one filled.
--
-- `seen` is a table the CALLER owns and keeps between frames: the first time a
-- user id appears it is stamped with `now`, and that stamp is what drives the
-- arrival pop. It lives with the caller rather than here because the two
-- surfaces that draw this run on different clocks — a stamp taken against one
-- would replay or freeze on the other.
--
-- Returns the seats in join order and how many are new this frame, so a caller
-- can make a sound for an arrival without diffing the list again.
function M.party_seats(seen, party, my_id, now)
    local seats, fresh = {}, 0
    local list = (type(party) == "table" and type(party.seats) == "table") and party.seats or {}
    for i, s in ipairs(list) do
        local id = tostring(s.userId or ("seat" .. i))
        if seen[id] == nil then
            seen[id] = now
            fresh = fresh + 1
        end
        seats[#seats + 1] = {
            userId     = id,
            username   = tostring(s.username or "PLAYER"),
            avatar     = tonumber(s.avatar) or 1,
            is_me      = my_id ~= nil and id == tostring(my_id),
            arrived_at = seen[id],
        }
    end
    return seats, fresh
end

--- What the table is doing, in words.
--
-- Its own function for the same reason the breathing is: the draw and the
-- per-frame update both need it, and two copies would let the sentence and its
-- dots disagree the moment one of them was edited.
--
-- PARTY_MIN_TO_START is 2 — a table can deal with two — so the wording turns
-- over there rather than at four. A player who has waited out a countdown with
-- one other person is playing, and should not be told the table is short.
function M.party_line(d)
    d = type(d) == "table" and d or {}
    if d.failed then return d.fail_msg or "Nobody else sat down in time" end
    if d.found then return "dealing you in\226\128\166" end

    local taken = #((type(d.seats) == "table") and d.seats or {})
    -- The dots are a clock. On a screen where nothing else moves between
    -- arrivals they are the only proof the dialog has not frozen.
    local dots = string.rep(".", 1 + (math.floor((tonumber(d.now) or 0) * 2) % 3))
    if taken <= 1 then
        return (d.subtitle or "waiting for players to join") .. dots
    end
    return taken .. " at the table - it can start" .. dots
end

--- How lit an empty chair is right now, 0.18 to 0.28 and back.
--
-- Its own function because the draw and the per-frame update must agree: two
-- copies of one sine is a placeholder that jumps every time the dialog is
-- rebuilt.
function M.seat_breath(now, i)
    return 0.18 + 0.10 * (0.5 + 0.5 * math.sin((tonumber(now) or 0) * 2.4 + i))
end

--- One frame of the waiting room, on the nodes the last draw left behind.
--
-- Safe to call when there is nothing to animate — no record, or nodes a
-- rebuild has already deleted — so a host can simply call it every frame.
function M.animate_party(self, d)
    local anim = self and self.party_anim
    if not anim or type(d) ~= "table" then return false end
    local now = tonumber(d.now) or 0

    local ok = pcall(function()
        for i, s in pairs(anim.seats) do
            local pop = search_clock.arrival_scale({ anim_t = now }, s.entry)
            if s.ring then gui.set_size(s.ring, vmath.vector3((anim.av_size + 24) * pop, (anim.av_size + 24) * pop, 0)) end
            local back = (anim.av_size + 12) * pop
            if s.back then gui.set_size(s.back, vmath.vector3(back, back, 0)) end
            if s.av then gui.set_size(s.av, vmath.vector3(anim.av_size * pop, anim.av_size * pop, 0)) end
        end
        for i, h in pairs(anim.holes) do
            local breathe = M.seat_breath(now, i)
            if h.halo then gui.set_color(h.halo, vmath.vector4(1, 1, 1, breathe * 0.35)) end
            if h.mark then gui.set_color(h.mark, vmath.vector4(1, 1, 1, breathe)) end
        end
        if anim.secs then
            local secs = math.max(0, math.ceil(tonumber(d.secs) or 0))
            gui.set_text(anim.secs, secs .. "s")
            gui.set_color(anim.secs, secs <= 5 and anim.red or anim.gold)
        end
        -- The dots are the only proof the dialog has not frozen between
        -- arrivals, so they are set here rather than waiting for a rebuild.
        local line = M.party_line(d)
        if anim.line and line ~= anim.line_text then
            gui.set_text(anim.line, line)
            anim.line_text = line
        end
    end)
    return ok
end

--- What the table CURRENTLY IS, as a string to compare against.
--
-- A rebuild is needed when the table changes — a chair filled, it dealt, it
-- was called off — and never merely because a second passed.
function M.party_key(d)
    d = type(d) == "table" and d or {}
    return table.concat({
        tostring(#((type(d.seats) == "table") and d.seats or {})),
        tostring(d.size or 4),
        d.found and "F" or "-",
        d.failed and "X" or "-",
    }, "/")
end

--- The waiting room.
--
-- d = {
--   seats    = M.party_seats(...)      who is in, in join order
--   size     = 4                       how many chairs the table has
--   entry    = 200                     per seat; the pot is entry x seated
--   secs     = 12.4                    seconds left, already smoothed
--   now      = anim clock, seconds     for the pop and the breathing
--   subtitle = "opening your table"    shown when nobody else is in yet
--   found / failed / fail_msg
-- }
function M.draw_party(self, ctx, d, a)
    local C          = ctx.C
    local track      = ctx.track
    local ui         = ctx.ui
    local commas     = ctx.commas
    local with_a     = ctx.with_a
    local CX, CY     = ctx.CX, ctx.CY

    a = a or 1
    d = type(d) == "table" and d or {}
    local now   = tonumber(d.now) or 0
    local size  = math.max(2, math.floor(tonumber(d.size) or 4))
    local seats = type(d.seats) == "table" and d.seats or {}
    local taken = #seats

    local scrim = track(self, ui.box(vmath.vector3(CX, CY, 0),
        vmath.vector3(ctx.LOGICAL_W * 2, ctx.LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.72 * a)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dlg_block" }
    local grad = track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))
    gui.set_color(grad, vmath.vector4(1, 1, 1, a))

    local title = "PARTY TABLE"
    local tcol  = C.COL_GOLD
    if d.found then title, tcol = "TABLE IS READY", C.COL_GREEN
    elseif d.failed then title, tcol = "TABLE CALLED OFF", C.COL_RED end
    track(self, ui.text(vmath.vector3(CX, CY + 168, 0), title, "title", with_a(tcol, a)))

    -- ── the chairs ──
    --
    -- Laid out for the WHOLE table, not for the players in it, so a seat does
    -- not move when the one beside it fills. Chairs are places; a row that
    -- re-centres itself on every arrival is a list.
    local av_size = size > 3 and 84 or 96
    local col_gap = size > 3 and 150 or 180
    local av_y    = CY + 40
    local function seat_x(i) return CX + (i - (size + 1) / 2) * col_gap end

    -- THE MOVING PARTS, KEPT SO THEY CAN BE SET RATHER THAN REBUILT.
    --
    -- Same rule the search dialog learned the hard way: rebuilding the whole
    -- screen to advance a countdown digit or breathe a placeholder is hundreds
    -- of nodes a second to animate a string. draw_party records the handful of
    -- nodes that actually move; M.animate_party sets them every frame, and a
    -- rebuild happens only when the TABLE changes.
    local anim = { seats = {}, holes = {}, size = size, av_size = av_size, av_y = av_y }

    for i = 1, size do
        local x = seat_x(i)
        local seat = seats[i]

        if seat then
            -- POPS ON ARRIVAL, once, and settles. This is the event the whole
            -- dialog exists to show.
            local pop = search_clock.arrival_scale({ anim_t = now }, seat)
            -- Wider than dlg_avatar's own backing (radius + 6) so a rim of it
            -- shows: gold for our own chair, so a player can find themselves
            -- at a table of four without reading four names.
            -- The chair is drawn HERE rather than through ctx.dlg_avatar, so
            -- these three nodes are held rather than fished back out of the
            -- host's node list by index. The animation resizes all of them
            -- every frame, and an off-by-one there would scale whatever the
            -- previous seat happened to leave behind.
            local ring = track(self, ui.pie(vmath.vector3(x, av_y, 0), (av_size / 2 + 12) * pop,
                with_a(seat.is_me and C.COL_GOLD or vmath.vector4(0.22, 0.22, 0.27, 1), a)))
            local back = track(self, ui.pie(vmath.vector3(x, av_y, 0), (av_size / 2 + 6) * pop,
                vmath.vector4(0.20, 0.20, 0.20, 0.50 * a)))
            local av = track(self, ui.avatar(vmath.vector3(x, av_y, 0),
                vmath.vector3(av_size * pop, av_size * pop, 0), seat.avatar))
            gui.set_color(av, vmath.vector4(1, 1, 1, a))
            anim.seats[i] = { entry = seat, ring = ring, back = back, av = av }
            track(self, ui.text(vmath.vector3(x, av_y - av_size / 2 - 26, 0),
                seat.is_me and "YOU" or string.upper(seat.username), "body",
                with_a(seat.is_me and ctx.DLG_SEARCH or C.COL_WHITE, a)))
        else
            -- AN EMPTY CHAIR, DRAWN AS ONE. It breathes so the table reads as
            -- open rather than stalled — the difference between "waiting for
            -- somebody" and "nothing is happening" is the only thing a player
            -- staring at a gap wants to know.
            local breathe = M.seat_breath(now, i)
            local halo = track(self, ui.pie(vmath.vector3(x, av_y, 0), av_size / 2 + 8,
                vmath.vector4(1, 1, 1, breathe * 0.35 * a)))
            track(self, ui.pie(vmath.vector3(x, av_y, 0), av_size / 2,
                vmath.vector4(0.10, 0.10, 0.13, 0.92 * a)))
            local mark = track(self, ui.text(vmath.vector3(x, av_y, 0), "?", "title",
                vmath.vector4(1, 1, 1, breathe * a)))
            anim.holes[i] = { halo = halo, mark = mark }
            track(self, ui.text(vmath.vector3(x, av_y - av_size / 2 - 26, 0), "OPEN SEAT", "small",
                with_a(C.COL_DIM, a)))
        end
    end

    -- ── what is on the table ──
    --
    -- The pot GROWS as chairs fill, because it does: every seat pays the same
    -- entry and the winner takes all of it. A fixed four-seat figure would be
    -- a promise the table has not collected yet.
    local entry = tonumber(d.entry) or 0
    local pot   = entry * math.max(1, taken)
    local pot_y = av_y - av_size / 2 - 78

    if entry > 0 then
        local img = "100"
        if pot >= 2000 then img = "2000"
        elseif pot >= 1000 then img = "1000"
        elseif pot >= 500 then img = "500"
        elseif pot >= 200 then img = "200"
        end
        local bundle = track(self, gui.new_box_node(vmath.vector3(CX, pot_y, 0), vmath.vector3(72, 72, 0)))
        gui.set_color(bundle, vmath.vector4(1, 1, 1, a))
        pcall(function() gui.set_texture(bundle, "coins"); gui.play_flipbook(bundle, hash(img)) end)
        local amt = track(self, ui.text(vmath.vector3(CX, pot_y - 52, 0), commas(pot), "helvetica_black",
            with_a(C.COL_GOLD, a)))
        gui.set_scale(amt, vmath.vector3(0.85, 0.85, 0.85))
    else
        track(self, ui.text(vmath.vector3(CX, pot_y, 0), "PRACTICE", "title", with_a(C.COL_GOLD, a)))
    end

    -- ── the clock, and what it is waiting for ──
    local secs = math.max(0, math.ceil(tonumber(d.secs) or 0))
    local line = M.party_line(d)

    if not (d.found or d.failed) then
        local col = secs <= 5 and C.COL_RED or C.COL_GOLD
        anim.secs = track(self, ui.text(vmath.vector3(CX, CY - 150, 0), secs .. "s", "body", with_a(col, a)))
        anim.red, anim.gold = with_a(C.COL_RED, a), with_a(C.COL_GOLD, a)
    end
    anim.line = track(self, ui.text(vmath.vector3(CX, CY - 182, 0), line, "small", with_a(C.COL_MID, a)))
    anim.line_text = line
    self.party_anim = anim

    -- NO BUTTONS, AND THAT IS THE HONEST SURFACE.
    --
    -- The entry is committed the moment a seat is taken, so there is nothing
    -- to cancel; a button that cannot cancel is worse than none. The table
    -- resolves on its own clock — it deals, or it is called off and every
    -- entry goes back.
end

return M
