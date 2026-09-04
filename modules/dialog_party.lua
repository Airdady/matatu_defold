-- modules/dialog_party.lua
-- THE PARTY TABLE, ON THE INCOMING DIALOG'S SURFACE.
--
-- A table used to be drawn by dialog_search — the same ring, reel and
-- shortlist rail a tournament search uses — on the theory that the two are the
-- same thing from the player's side: you opened something and you are watching
-- people arrive.
--
-- They are not the same thing, and the rail is where it shows. A search rail
-- holds CANDIDATES: people who answered, out of whom the server will pick one,
-- which is why the reel goes on hunting beside them and why the row grows from
-- nothing with no idea how long it will get. A party's seats are neither. The
-- table is FOUR CHAIRS, known from the moment it opens, and everybody on it is
-- already in — there is no shortlist, nobody is being assessed, and the reel
-- hunting next to a filled table asks a question the mode never answers.
--
-- What a player actually wants to know is how many chairs are left, and that
-- is the one thing a rail that only draws arrivals cannot show. So the table
-- takes the incoming dialog's surface instead: the same scrim, backdrop,
-- avatar helper and button list a challenge gets, through the same `ctx`
-- dialog_incoming takes — and every chair is drawn, the empty ones included.
--
-- An unfilled seat is a placeholder, in the position it will be taken in, so
-- an arrival lands in a space the player was already looking at rather than
-- shunting the whole row one place left. The number of them is the SERVER's
-- seatsRemaining, never a table size this side made up: a client counting down
-- from its own idea of PARTY_SIZE draws the wrong number of chairs the day
-- that constant moves.
--
-- The payload is partyView's, exactly as it comes off the wire (see
-- websocket_manager's PARTY_ROSTER branch and be_matatu's partyRules.ts), so
-- there is no second shape to keep in step with it.

local ws = require("modules.websocket_manager")

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
    return {
        party_id  = tostring(d.partyId or ""),
        host_id   = tostring(d.hostId or ""),
        entry     = tonumber(d.entry) or 0,
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

--- One filled chair.
local function draw_seat(self, ctx, x, y, size, seat, is_me, is_host, a)
    local track, ui, with_a, C = ctx.track, ctx.ui, ctx.with_a, ctx.C

    ctx.dlg_avatar(self, x, y, size, seat.avatar, a)

    -- HOST sits ABOVE the chair rather than beside the name: the names are
    -- already the widest thing in the row, and a suffix on one of them would
    -- push that one label past its neighbours.
    if is_host then
        track(self, ui.text(vmath.vector3(x, y + size / 2 + 16, 0), "HOST", "small",
            with_a(SEAT_HOST, a)))
    end

    local label = is_me and "YOU" or tostring(seat.username):upper()
    if #label > 10 then label = label:sub(1, 9) .. "." end
    track(self, ui.text(vmath.vector3(x, y - size / 2 - 18, 0), label, "small",
        with_a(is_me and ctx.DLG_SEARCH or C.COL_WHITE, a)))
end

--- One empty chair, in the seat it is going to be taken in.
local function draw_empty_seat(self, ctx, x, y, size, a)
    local track, ui, with_a, C = ctx.track, ctx.ui, ctx.with_a, ctx.C

    -- Ring first, then the well inside it, so the ring reads as an outline
    -- rather than as a disc with something drawn on top of it.
    track(self, ui.pie(vmath.vector3(x, y, 0), size / 2 + 6,
        with_a(SEAT_EMPTY_RING, 0.55 * (a or 1))))
    track(self, ui.pie(vmath.vector3(x, y, 0), size / 2, with_a(SEAT_EMPTY_FILL, a)))
    track(self, ui.text(vmath.vector3(x, y, 0), "?", "title", with_a(SEAT_EMPTY_RING, a)))
    track(self, ui.text(vmath.vector3(x, y - size / 2 - 18, 0), "WAITING", "small",
        with_a(C.COL_DIM, a)))
end

--- The whole table.
-- `d` is the dialog record incoming.gui_script built from a PARTY_ROSTER:
--   { party_view = <M.view result>, time_left }
--
-- `party_view` rather than `party`: the overlay already uses `dialog.party`
-- for the OFFER strip — an invitation to a table you are not at — and one
-- field meaning two things is how the seated table would close itself the
-- moment the lobby stopped advertising it.
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

    local p     = (type(d.party_view) == "table") and d.party_view or M.view(nil)
    local seats = p.seats or {}
    local n     = math.max(#seats, p.size or 4)

    -- Same scrim, same backdrop and the same "dlg_block" catcher a challenge
    -- gets: a table is modal for the same reason a challenge is — there is a
    -- clock on it and one decision to make.
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
    local size, left, step = seat_layout(CX, n)
    local seat_y = CY + 40
    local my_id  = tostring(ws.get_current_user_id() or "")

    for i = 1, n do
        local x, seat = left + (i - 1) * step, seats[i]
        if seat then
            draw_seat(self, ctx, x, seat_y, size, seat,
                seat.user_id == my_id, seat.user_id == p.host_id, a)
        else
            draw_empty_seat(self, ctx, x, seat_y, size, a)
        end
    end

    -- ── The pot, and how long is left ────────────────────────────────────────
    -- What has ACTUALLY been paid in: the entry times the seats that are
    -- filled, never times the table size. Promising a four-way pot at a table
    -- of two would be a prize out of money nobody put in.
    local entry = p.entry
    local pot   = entry * math.max(1, #seats)
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
    elseif p.remaining <= 0 then
        line, col = "Table full - starting", C.COL_GREEN
    elseif secs <= 0 then
        -- ZERO IS NOT A FAILURE. The server decides the table at zero —
        -- whoever is seated plays — and says so a moment later. Counting down
        -- into "nobody came" would be the search dialog's own old bug, drawn
        -- on a different surface.
        line, col = "Closing the table...", C.COL_GOLD
    else
        line = string.format("%d seat%s left  -  %ds", p.remaining,
            p.remaining == 1 and "" or "s", secs)
        col = (secs <= 5) and C.COL_RED or C.COL_GOLD
    end
    track(self, ui.text(vmath.vector3(CX, CY - 108, 0), line, "body", with_a(col, a)))

    -- ── The one decision ─────────────────────────────────────────────────────
    -- LEAVE only, and only while the table is still filling. There is no
    -- ACCEPT: the seat is bought and taken, so there is nothing left to agree
    -- to — and once the table is STARTING there is nothing left to leave.
    if not starting then
        mkbtn(self, "party_leave", vmath.vector3(CX, CY - 162, 0), vmath.vector3(180, 48, 0),
            "LEAVE TABLE", "primary_btn")
        -- Said plainly under the button, because it is the thing a player is
        -- most likely to get wrong: leaving is not a refund.
        track(self, ui.text(vmath.vector3(CX, CY - 194, 0),
            "Your entry stays with the table", "small", with_a(C.COL_DIM, a)))
    end
end

return M
