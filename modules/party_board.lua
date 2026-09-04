----------------------------------------------------------------------
-- party_board.lua
-- Drawing an ONLINE party table of two to four seats.
--
-- The board already knows how to seat four people: tournament4.lua's offline
-- chamber puts one human and three AI round a table, and t4_ui.lua draws the
-- badges, the turn ring and the elimination state for it. All of that is
-- message-driven ("t4_seat", "t4_active") and knows nothing about where the
-- players came from — so an online party does not need a new board, it needs
-- to drive the one that exists from server state instead of from local AI.
--
-- That is all this module is. It takes the game state the server sent and
-- pushes the same messages the offline chamber pushes.
--
-- WHY NOT REUSE tournament4 ITSELF: that module owns the offline GAME — it
-- deals, it runs the AI, it decides eliminations. A party's answers to all
-- three come from the server. Sharing its renderer is the part worth sharing.
----------------------------------------------------------------------
local BL = require "modules.board_layout"
local util = require "modules.game_util"
-- The chamber's own rule for a jack and an eight, so the words this board
-- flashes and the turn game_flow gives up agree with the server.
local PartyRules = require "modules.party_rules"

local M = {}

local GUI_HUD = "#game"
local MAX_BACKS = 10  -- visible backs per opponent arch, as the chamber uses

-- ── seating ─────────────────────────────────────────────────────────────────
--
-- YOU ARE ALWAYS AT THE BOTTOM. The server's seatOrder is the true rotation
-- and every client gets the same one, so each player rotates it until their
-- own id is first — then the player to your left on screen is genuinely the
-- player who plays after you, on every device at the table.
--
-- Slots by table size, going round in turn order from you:
--   2 players   opponent opposite you
--   3 players   next on your left, the other across
--   4 players   left, across, right
--
-- Pure, and separated from the drawing below so the mapping can be reasoned
-- about (and tested) without a GUI.
local SLOTS_BY_COUNT = {
    [2] = { "top" },
    [3] = { "left", "right" },
    [4] = { "left", "top", "right" },
}

function M.seating(seat_order, my_id)
    local order = {}
    for _, id in ipairs(type(seat_order) == "table" and seat_order or {}) do
        local s = tostring(id or "")
        if s ~= "" then order[#order + 1] = s end
    end
    my_id = tostring(my_id or "")

    local at = nil
    for i, id in ipairs(order) do
        if id == my_id then at = i break end
    end
    -- Not at this table (a spectator, or state that arrived before identify):
    -- draw it from seat one rather than not at all.
    if not at then at = 1 end

    local rotated = {}
    for i = 1, #order do
        rotated[i] = order[((at - 1 + i - 1) % #order) + 1]
    end

    local slots = SLOTS_BY_COUNT[#rotated]
    if not slots then
        -- A table size the layout has no map for (one seat, or five if the
        -- server ever allows it). Everyone but you goes opposite: wrong-looking
        -- is recoverable, drawing nobody is not.
        slots = {}
        for i = 1, math.max(0, #rotated - 1) do slots[i] = "top" end
    end

    local seats = {}
    for i = 2, #rotated do
        seats[#seats + 1] = { id = rotated[i], slot = slots[i - 1] or "top" }
    end
    return seats, rotated
end

-- ── geometry ────────────────────────────────────────────────────────────────
-- The same anchors the offline chamber uses, so the two modes put a seat in
-- the same place and neither has its own idea of where "left" is.
local function widget_pos(self, slot)
    if slot == "left"  then return vmath.vector3(self.SEAT_LEFT.x,  self.SEAT_LEFT.y,  0) end
    if slot == "right" then return vmath.vector3(self.SEAT_RIGHT.x, self.SEAT_RIGHT.y, 0) end
    return vmath.vector3(self.CENTER.x, self.AI_HAND_Y, 0)
end

local function anchor_for(self, slot)
    if slot == "left"  then return vmath.vector3(self.SEAT_LEFT.x - 66, self.SEAT_LEFT.y, 0) end
    if slot == "right" then return vmath.vector3(self.SEAT_RIGHT.x + 66, self.SEAT_RIGHT.y, 0) end
    return vmath.vector3(self.CENTER.x, self.AI_HAND_Y, 0)
end

local function rot_for(slot)
    if slot == "left"  then return 90 end
    if slot == "right" then return -90 end
    return 0
end

-- ── card backs ──────────────────────────────────────────────────────────────
--
-- Face-down, count-capped at MAX_BACKS like the chamber: past ten backs the
-- arch stops reading as a hand and starts reading as a wall, and the number on
-- the badge is what a player actually reads a count off anyway.
local function layout_backs(self, seat, count)
    seat.cards = seat.cards or {}
    local n = math.min(math.max(0, count or 0), MAX_BACKS)

    while #seat.cards > n do
        local c = table.remove(seat.cards)
        pcall(go.delete, c.id)
    end
    while #seat.cards < n do
        local a = anchor_for(self, seat.slot)
        local rec = self.spawn_card(10, "H", vmath.vector3(a.x, a.y, BL.Z_HAND))
        local f = BL.CARD_SCALE_F * 0.85
        go.set(rec.id, "scale", vmath.vector3(f, f, 1))
        self.set_back(rec)
        seat.cards[#seat.cards + 1] = rec
    end

    local spacing = 18
    local start = -((n - 1) * spacing) / 2
    local base = anchor_for(self, seat.slot)
    local horizontal = (seat.slot == "top")
    for i, c in ipairs(seat.cards) do
        local off = start + (i - 1) * spacing
        local p = horizontal
            and vmath.vector3(base.x + off, base.y, BL.Z_HAND + i * 0.001)
            or  vmath.vector3(base.x, base.y + off, BL.Z_HAND + i * 0.001)
        go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, p, go.EASING_OUTQUAD, 0.18)
        go.set(c.id, "euler.z", rot_for(seat.slot))
    end
end

-- ── the one entry point ─────────────────────────────────────────────────────
--
-- Called whenever party game state arrives. Idempotent: it reconciles what is
-- on screen with what the state says, so a resync redraws correctly rather
-- than stacking a second set of badges.
function M.sync(self, game_state)
    if type(game_state) ~= "table" then return end
    local players = type(game_state.players) == "table" and game_state.players or {}

    local order = game_state.seatOrder
    if type(order) ~= "table" or #order == 0 then
        -- No seat order means a game dealt by the two-player path; the ordinary
        -- board is already drawing it and must not be redrawn as a party.
        return
    end

    local seats = M.seating(order, self.my_player_id)
    self.party_seats = self.party_seats or {}

    -- HOW MANY ARE STILL IN, kept on self for two things that are not drawing:
    -- game_flow asks it to decide whether a skip card ends this player's turn
    -- (PartyRules.keeps_turn), and the layout below asks it for the geometry
    -- the offline chamber uses at three or more.
    local live = PartyRules.live_count(game_state) or #seats
    local was_live = self.party_live_count
    self.party_live_count = live

    -- THE OFFLINE TABLE'S OWN GEOMETRY, not a duel's.
    --
    -- board_layout keys the deck position — and the arch the player's own hand
    -- is drawn in — off how many people are at the table. The offline chamber
    -- tells it through self.t4; an online party told it nothing, so a table of
    -- four was drawn with the deck at the far right edge where a two-player
    -- match puts it, and a flat hand. Same table, two different boards.
    --
    -- Recomputed only when the count CHANGES: update_layout walks the whole
    -- screen, and this runs on every state push.
    -- update_layout repositions both hands and the deck itself, so there is
    -- nothing to reflow afterwards.
    if was_live ~= live then pcall(BL.update_layout, self) end

    local current = tostring(game_state.currentTurn or "")
    for _, s in ipairs(seats) do
        local p = players[s.id] or {}
        local held = self.party_seats[s.id] or { slot = s.slot, cards = {} }
        -- A player whose slot changed (a seat emptied and the table reflowed)
        -- keeps its cards but moves; layout_backs animates them across.
        held.slot = s.slot
        self.party_seats[s.id] = held

        local wp = widget_pos(self, s.slot)
        util.notify_gui(GUI_HUD, "t4_seat", {
            slot = s.slot,
            name = p.username or "PLAYER",
            avatar = p.avatar or 1,
            is_human = false,
            eliminated = p.eliminated and true or false,
            active = (not p.eliminated) and (tostring(s.id) == current),
            x = wp.x, y = wp.y,
        })

        local count = tonumber(p.handCount)
            or (type(p.hand) == "table" and #p.hand)
            or 0
        layout_backs(self, held, p.eliminated and 0 or count)
    end

    -- WHAT THE TABLE JUST DID, in the chamber's own words.
    --
    -- At a table of four the player who lost their turn cannot otherwise tell
    -- they were skipped rather than passed over by a reversal — the turn ring
    -- simply lands somewhere unexpected. The server puts the answer on the
    -- state for exactly one broadcast (moves/index.ts), and the chamber
    -- already has the banner: t4_flash, the same one that says REVERSE! when a
    -- bot plays a jack.
    --
    -- Keyed on lastActionAt, not on the text: two eights in a row are two
    -- separate SKIP!s and both should be seen, while the same state arriving
    -- twice (a resync, a reconnect) must not flash again.
    local flash = tostring(game_state.lastTurnEffect or "")
    local stamp = tostring(game_state.lastActionAt or "")
    if flash ~= "" and stamp ~= "" and stamp ~= self._party_flash_at then
        self._party_flash_at = stamp
        util.notify_gui(GUI_HUD, "t4_flash", { text = flash })
    end

    -- Whose clock is running. Only for an opponent — the local player's own
    -- turn already drives the ordinary "turn" HUD, and pushing both would put
    -- two countdowns on screen for the same turn.
    for _, s in ipairs(seats) do
        if tostring(s.id) == current then
            util.notify_gui(GUI_HUD, "t4_active", { slot = s.slot, duration = 3.0 })
            break
        end
    end
end

-- Tear every party seat down. Called when the board unloads or the table ends,
-- so a following game does not inherit badges from this one.
function M.clear(self)
    for _, seat in pairs(self.party_seats or {}) do
        for _, c in ipairs(seat.cards or {}) do pcall(go.delete, c.id) end
    end
    self.party_seats = nil
    -- The layout reads this, so a duel following a party must not inherit a
    -- four-seat deck position.
    self.party_live_count = nil
    self._party_flash_at = nil
    pcall(BL.update_layout, self)
    util.notify_gui(GUI_HUD, "t4_clear", {})
end

return M
