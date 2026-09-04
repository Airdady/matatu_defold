-- modules/dialog_party.lua
-- THE PARTY TABLE, DRAWN ON THE INCOMING DIALOG'S OWN SURFACE.
--
-- A party is not a second kind of overlay. It arrives the same way a challenge
-- does — unannounced, on whatever screen the player happens to be on, with a
-- clock on it — and it is answered with the same one decision. So it takes the
-- surface that already exists for exactly that: incoming.gui_script's modal,
-- with its scrim, its backdrop, its avatar helper and its button list, handed
-- in through the same `ctx` dialog_incoming takes.
--
-- Building a separate party overlay would have meant a second modal claim, a
-- second countdown, a second copy of the watchdogs that stop a dialog with no
-- buttons from freezing the app, and two surfaces to keep in step. The seats
-- are the only thing here that a challenge does not already have.
--
-- WHAT THE PLAYER IS ACTUALLY WATCHING
--
-- Not "please wait". The point of a table filling in real time is that you can
-- SEE it fill, so every chair is drawn — the ones with somebody in them and,
-- just as deliberately, the ones without. An empty chair is a placeholder with
-- a dashed ring and the word WAITING under it, in the seat it will be taken
-- in, so an arrival lands in a space the player was already looking at rather
-- than making the whole row jump one place to the left.
--
-- The number of chairs is the SERVER's (partyView's seatsRemaining plus the
-- seats it sent), never a constant of ours — a client counting down from its
-- own idea of a table size draws the wrong number of empty chairs the day
-- PARTY_SIZE changes.

local ws = require("modules.websocket_manager")

local M = {}

-- How many chairs fit on one row before the row itself has to shrink. Four is
-- the table size today; the layout still works for three or five because the
-- spacing is computed from the count rather than tabulated.
local SEAT_SIZE_MAX = 84
local SEAT_SIZE_MIN = 58
local SEAT_GAP      = 26

-- The empty chair. Dim, ringed, and unmistakably NOT a player: it used to be
-- tempting to draw nothing at all in a seat nobody has taken, and a table that
-- only shows the people already in it cannot show you it is still filling.
local SEAT_EMPTY_RING = vmath.vector4(0.30, 0.36, 0.44, 1.00)
local SEAT_EMPTY_FILL = vmath.vector4(0.10, 0.13, 0.17, 0.90)
local SEAT_HOST       = vmath.vector4(1.00, 0.84, 0.20, 1.00)

--- Where each chair sits, for a table of `n`.
-- Centred as a row on `cx`, so a table of two is not drawn hugging the left
-- edge of the space a table of four would have used.
local function seat_layout(cx, n)
    n = math.max(1, math.floor(n or 4))
    local size = SEAT_SIZE_MAX
    -- Shrink rather than overflow. The dialog is 1280 wide at its widest and
    -- the row has to stay inside the scrim on the narrowest device the app
    -- supports.
    local total = n * size + (n - 1) * SEAT_GAP
    if total > 760 then
        size = math.max(SEAT_SIZE_MIN, math.floor((760 - (n - 1) * SEAT_GAP) / n))
        total = n * size + (n - 1) * SEAT_GAP
    end
    local left = cx - total / 2 + size / 2
    return size, left, size + SEAT_GAP
end

--- One filled chair.
local function draw_seat(self, ctx, x, y, size, seat, is_me, is_host, a)
    local track  = ctx.track
    local ui     = ctx.ui
    local with_a = ctx.with_a
    local C      = ctx.C

    ctx.dlg_avatar(self, x, y, size, tonumber(seat.avatar) or 1, a)

    -- HOST above the chair rather than beside the name: the names are already
    -- the longest thing in the row and a suffix on one of them would push that
    -- one chair's label wider than its neighbours.
    if is_host then
        track(self, ui.text(vmath.vector3(x, y + size / 2 + 16, 0), "HOST", "small",
            with_a(SEAT_HOST, a)))
    end

    local label = is_me and "YOU" or tostring(seat.username or "PLAYER"):upper()
    -- Long names are cut rather than allowed to run into the next chair.
    if #label > 10 then label = label:sub(1, 9) .. "." end
    track(self, ui.text(vmath.vector3(x, y - size / 2 - 18, 0), label, "small",
        with_a(is_me and ctx.DLG_SEARCH or C.COL_WHITE, a)))
end

--- One empty chair, in the seat it is going to be taken in.
local function draw_empty_seat(self, ctx, x, y, size, a)
    local track  = ctx.track
    local ui     = ctx.ui
    local with_a = ctx.with_a
    local C      = ctx.C

    -- Ring first, then the well inside it, so the ring reads as an outline
    -- rather than as a disc with something drawn on top.
    track(self, ui.pie(vmath.vector3(x, y, 0), size / 2 + 6, with_a(SEAT_EMPTY_RING, 0.55 * (a or 1))))
    track(self, ui.pie(vmath.vector3(x, y, 0), size / 2, with_a(SEAT_EMPTY_FILL, a)))
    track(self, ui.text(vmath.vector3(x, y, 0), "?", "title", with_a(SEAT_EMPTY_RING, a)))
    track(self, ui.text(vmath.vector3(x, y - size / 2 - 18, 0), "WAITING", "small",
        with_a(C.COL_DIM, a)))
end

--- The whole table.
-- `d` is the dialog record incoming.gui_script built from a PARTY_ROSTER:
--   { party = <ws.parse_party result>, time_left, max_time }
function M.draw(self, ctx, d, a)
    local C         = ctx.C
    local track     = ctx.track
    local ui        = ctx.ui
    local mkbtn     = ctx.mkbtn
    local commas    = ctx.commas
    local with_a    = ctx.with_a
    local CX        = ctx.CX
    local CY        = ctx.CY
    local LOGICAL_W = ctx.LOGICAL_W
    local LOGICAL_H = ctx.LOGICAL_H

    local p = (type(d.party) == "table") and d.party or {}
    local seats = (type(p.seats) == "table") and p.seats or {}
    local size_n = math.max(#seats, tonumber(p.size) or 4)

    -- Same scrim and same backdrop as a challenge, and the same "dlg_block"
    -- catcher: a party table is modal for the same reason a challenge is —
    -- there is a clock on it and one decision to make.
    local scrim = track(self, ui.box(vmath.vector3(CX, CY, 0),
        vmath.vector3(LOGICAL_W * 2, LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.62 * a)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dlg_block" }
    local grad = track(self, ui.grad_backdrop(LOGICAL_W, LOGICAL_H))
    gui.set_color(grad, vmath.vector4(1, 1, 1, a))

    local starting = tostring(p.status or "FILLING") == "STARTING"

    track(self, ui.text(vmath.vector3(CX, CY + 168, 0),
        starting and "PARTY STARTING" or "PARTY TABLE", "title",
        with_a(starting and C.COL_GREEN or C.COL_CYAN, a)))

    -- How the table is won, on the line under the title. A capped party and a
    -- normal one are different games and the seated players are about to play
    -- one of them.
    local mode_txt = (tostring(p.mode) == "SCORECAP")
        and ("SCORE CAP " .. tostring(math.floor(tonumber(p.score_cap) or 0)))
        or "PLAY IT OUT"
    track(self, ui.text(vmath.vector3(CX, CY + 138, 0), mode_txt, "small", with_a(C.COL_MID, a)))

    -- ── The chairs ───────────────────────────────────────────────────────────
    local seat_size, left, step = seat_layout(CX, size_n)
    local seat_y = CY + 40
    local my_id = tostring(ws.get_current_user_id() or "")

    for i = 1, size_n do
        local x = left + (i - 1) * step
        local seat = seats[i]
        if seat then
            draw_seat(self, ctx, x, seat_y, seat_size, seat,
                tostring(seat.user_id) == my_id,
                tostring(seat.user_id) == tostring(p.host_id or ""), a)
        else
            draw_empty_seat(self, ctx, x, seat_y, seat_size, a)
        end
    end

    -- ── What is at stake, and how long is left ───────────────────────────────
    local entry = tonumber(p.entry) or 0
    local pot   = entry * math.max(1, #seats)

    -- The pot is what has ACTUALLY been paid in — entry times the seats that
    -- are filled, never times the table size. Promising a four-way pot at a
    -- table of two would be a prize out of money nobody put in.
    local pot_y = CY - 62
    track(self, ui.text(vmath.vector3(CX, pot_y, 0),
        entry > 0 and (commas(pot) .. " POT") or "PRACTICE TABLE",
        "helvetica_black", with_a(C.COL_GOLD, a)))
    if entry > 0 then
        track(self, ui.text(vmath.vector3(CX, pot_y - 24, 0),
            commas(entry) .. " each", "small", with_a(C.COL_MID, a)))
    end

    local secs = math.max(0, math.ceil(d.time_left or 0))
    local line, col
    if starting then
        line, col = "Dealing you in...", C.COL_GREEN
    elseif (tonumber(p.seats_remaining) or 0) <= 0 then
        line, col = "Table full - starting", C.COL_GREEN
    elseif secs <= 0 then
        -- Zero on the clock is not failure. The server decides the table at
        -- zero and says so a moment later; counting down into "nobody came"
        -- would be the search dialog's old bug drawn on a different surface.
        line, col = "Closing the table...", C.COL_GOLD
    else
        line = string.format("%d seat%s left  -  %ds",
            tonumber(p.seats_remaining) or 0,
            (tonumber(p.seats_remaining) or 0) == 1 and "" or "s", secs)
        col = (secs <= 5) and C.COL_RED or C.COL_GOLD
    end
    track(self, ui.text(vmath.vector3(CX, CY - 108, 0), line, "body", with_a(col, a)))

    -- ── The one decision ─────────────────────────────────────────────────────
    -- LEAVE only, and only while the table is still filling. There is no
    -- ACCEPT: the seat is already paid for and taken, so there is nothing left
    -- to agree to. Once it is STARTING there is nothing to leave either.
    if not starting then
        mkbtn(self, "party_leave", vmath.vector3(CX, CY - 162, 0), vmath.vector3(180, 48, 0),
            "LEAVE TABLE", "primary_btn")
        -- Said plainly under the button, because it is the thing a player is
        -- most likely to get wrong: this is not a refund.
        track(self, ui.text(vmath.vector3(CX, CY - 194, 0),
            "Your entry stays with the table", "small", with_a(C.COL_DIM, a)))
    end
end

return M
