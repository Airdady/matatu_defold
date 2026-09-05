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
-- THE SAME TABLE THE OFFLINE CHAMBER USES, minus the "bottom" entry that is
-- always you. tournament4.lua's assign_slots reads:
--
--   [2] = { "bottom", "top" }
--   [3] = { "bottom", "left", "right" }
--   [4] = { "bottom", "left", "top", "right" }
--
-- and that correspondence is the whole point: three players offline sit
-- bottom/left/right with NOBODY across, and three players online have to sit
-- the same way or the two modes are two different games.
--
-- Pure, and separated from the drawing below so the mapping can be reasoned
-- about (and tested) without a GUI.
local SLOTS_BY_COUNT = {
    [2] = { "top" },
    [3] = { "left", "right" },
    [4] = { "left", "top", "right" },
}

-- ── WHEN A TABLE IS DOWN TO TWO, IT IS NOT A TABLE ANY MORE ──────────────────
--
-- A party seats its opponents in arches round the edge: face-down backs at 85%
-- scale, capped at ten, on 18px spacing. That is the right drawing for three
-- people you are looking at across a table and the wrong one for the last two
-- players in the game, who are playing an ordinary duel — and the app already
-- has a board for that, with its own hand spacing and its own card size, which
-- every other two-player match in the game uses.
--
-- So heads-up is not a party layout with two of the chairs hidden. The party
-- board stands DOWN entirely and hands the opponent back to the ordinary
-- renderer, which is what draws every other duel in the app. Two players who
-- started alone and two players who are all that is left of four get the same
-- board, because they are playing the same game.
--
-- The seat order never shrinks — the server fixes it when the cards are dealt
-- and marks eliminations as a flag, which is right, because the turn
-- arithmetic reads through it. So "how many are left" is a question about the
-- flags, not about the length of the list.

--- Is this game state a party at all?
function M.is_party(game_state)
    if type(game_state) ~= "table" then return false end
    local order = game_state.seatOrder
    return type(order) == "table" and #order > 0
end

--- Everybody still in, in seat order.
function M.survivors(game_state)
    local out = {}
    if type(game_state) ~= "table" then return out end
    local order = type(game_state.seatOrder) == "table" and game_state.seatOrder or {}
    local players = type(game_state.players) == "table" and game_state.players or {}
    for _, raw in ipairs(order) do
        local id = tostring(raw or "")
        if id ~= "" and not (players[id] or {}).eliminated then out[#out + 1] = id end
    end
    return out
end

--- Is this party down to two players (or dealt as two)?
--
-- Two OR FEWER: a table with one survivor is a game that has just ended, and
-- the last thing it should do on the way out is put an arch back on screen.
function M.is_heads_up(game_state)
    if not M.is_party(game_state) then return false end
    return #M.survivors(game_state) <= 2
end

--- Who is out, by id. Nil-safe, and empty for anything that is not a party.
function M.eliminated_set(game_state)
    local out = {}
    local players = (type(game_state) == "table" and type(game_state.players) == "table")
        and game_state.players or {}
    for id, p in pairs(players) do
        if type(p) == "table" and p.eliminated then out[tostring(id)] = true end
    end
    return out
end

--- Where everybody sits, from your chair.
--
-- `out` is the set from M.eliminated_set. Omit it and nobody is treated as
-- eliminated, which is the right answer for a fresh deal and for the callers
-- that only want the rotation.
--
-- THE TABLE COLLAPSES AROUND THE PEOPLE WHO ARE LEFT.
--
-- The seat ORDER never shrinks — the server fixes it when the cards are dealt
-- and marks eliminations as a flag, which is right, because the turn
-- arithmetic reads through it. The LAYOUT is a different question, and it used
-- to be answered off the length of that fixed order: a table of four that lost
-- a player kept left/top/right, with a dead chair greyed where the fourth had
-- been, for the rest of the game.
--
-- The offline chamber has never done that. assign_slots reseats the survivors
-- on every deal, so three players sit bottom/left/right and the seat across
-- the table is not there at all — and three players online are playing the
-- same game on the same board, so they get the same three chairs.
--
-- The rotation is taken FIRST and the eliminated dropped after, so who plays
-- after whom is still read off the server's order rather than off whoever
-- happens to be left.
function M.seating(seat_order, my_id, out)
    out = out or {}
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

    -- Everybody still in, in turn order starting from the player on your left.
    local live = {}
    for i = 2, #rotated do
        if not out[rotated[i]] then live[#live + 1] = rotated[i] end
    end

    -- Keyed on how many people are AT the table, you included — the same
    -- number the offline chamber keys its own layout on.
    local slots = SLOTS_BY_COUNT[#live + 1]
    if not slots then
        -- A table size the layout has no map for (one seat, or five if the
        -- server ever allows it). Everyone but you goes opposite: wrong-looking
        -- is recoverable, drawing nobody is not.
        slots = {}
        for i = 1, #live do slots[i] = "top" end
    end

    local seats = {}
    for i, id in ipairs(live) do
        seats[#seats + 1] = { id = id, slot = slots[i] or "top" }
    end
    return seats, rotated
end

-- ── geometry ────────────────────────────────────────────────────────────────
-- The same anchors the offline chamber uses, so the two modes put a seat in
-- the same place and neither has its own idea of where "left" is.
-- THE BADGE AND THE CARDS HAD SWAPPED PLACES.
--
-- The chamber puts the CARDS on the seat anchor and the BADGE outboard of it,
-- 66px further towards the screen edge, and the top badge 46px ABOVE the
-- opponent's row. This module had the two the other way round: the badge sat
-- exactly on the seat anchor and the cards were pushed out past it, and the
-- top badge sat directly ON the top arch rather than above it. Same anchors,
-- opposite roles — so the same table drew with its avatars in the middle of
-- its hands offline and behind them online.
--
-- Both functions now read the chamber's, value for value (tournament4.lua's
-- widget_pos / anchor_for). The heads-up branch of the chamber's widget_pos is
-- not carried across because a party at two players has no seats at all — the
-- board stands down and the ordinary duel renderer takes the opponent.
local function widget_pos(self, slot)
    if slot == "left"  then return vmath.vector3(self.SEAT_LEFT.x - 66,  self.SEAT_LEFT.y,  0) end
    if slot == "right" then return vmath.vector3(self.SEAT_RIGHT.x + 66, self.SEAT_RIGHT.y, 0) end
    return vmath.vector3(self.CENTER.x, self.AI_HAND_Y + 46, 0)
end

local function anchor_for(self, slot)
    if slot == "left"  then return vmath.vector3(self.SEAT_LEFT.x,  self.SEAT_LEFT.y,  0) end
    if slot == "right" then return vmath.vector3(self.SEAT_RIGHT.x, self.SEAT_RIGHT.y, 0) end
    return vmath.vector3(self.CENTER.x, self.AI_HAND_Y, 0)
end

local function base_rot(slot)
    if slot == "left"  then return 90 end
    if slot == "right" then return -90 end
    return 0
end

-- ── THE CHAMBER'S ARCH, NOT A SECOND ONE ────────────────────────────────────
--
-- This was a flat line of backs on a fixed 18px pitch, with every card at the
-- seat's base rotation. The chamber's opponents are ARCHES: the pitch opens up
-- to 32px for a small hand and closes as the hand grows, the row bows towards
-- the middle of the table, and each card is turned a little further than the
-- one before so the hand fans.
--
-- On a five-card hand the difference is 18px of flat stack against 32px of
-- fanned arch — which is the "squeezed" hand, and it is squeezed for no reason
-- other than that this file had invented its own spacing. It now IS
-- tournament4's arch_slots: same pitch, same fan, same arc, same signs.
--
--   spacing  min(32, 150/(n-1))  — a whole hand spans 150px however many
--                                  cards are in it, up to a 32px pitch
--   fan      min(9,  n*1.4)      — degrees between the ends of the hand
--   arc      min(24, n*3.4)      — how far the middle of the row bows
--   toward   which way the bow and the fan point, so top and right curve
--            back towards the table and left and bottom curve out
local function arch_slots(self, slot, n)
    local out = {}
    if n <= 0 then return out end
    local a = anchor_for(self, slot)
    local horizontal = (slot == "top")
    local toward = (slot == "top" or slot == "right") and -1 or 1
    local spacing = math.min(32, (n > 1 and 150 / (n - 1) or 0))
    local fan = math.min(9, n * 1.4)
    local arc = math.min(24, n * 3.4)
    local br = base_rot(slot)
    for i = 1, n do
        local t = (n == 1) and 0 or ((i - 1) / (n - 1) - 0.5)
        local along = t * spacing * (n - 1)
        local bump = (0.25 - t * t) * arc * toward
        local x, y
        if horizontal then
            x, y = a.x + along, a.y + bump
        else
            y, x = a.y - along, a.x + bump
        end
        out[i] = { x = x, y = y, rot = br - t * fan * 2 * toward, z = BL.Z_HAND + i * 0.001 }
    end
    return out
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

    local slots = arch_slots(self, seat.slot, n)
    for i, c in ipairs(seat.cards) do
        local sl = slots[i] or slots[#slots]
        if sl then
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
                vmath.vector3(sl.x, sl.y, sl.z), go.EASING_OUTQUAD, 0.18)
            -- The fan is per card, so the rotation moves with the position
            -- rather than being snapped to one angle for the whole hand.
            go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, sl.rot,
                go.EASING_OUTQUAD, 0.18)
        end
    end
end

-- ── dealing, the way the offline chamber deals ──────────────────────────────
--
-- A party used to deal to ONE seat. online_handler's deal loop was written for
-- a duel — a card to you, a card to the opponent, round after round — and a
-- party has no "the opponent", so opp_count fell to zero and the loop dealt
-- the local hand and nothing else. The other seats' cards did not fly
-- anywhere: layout_backs popped them into their arches, fully formed, the
-- moment the roster synced.
--
-- The offline chamber has always done this properly: for each of the seven
-- rounds it gives one card to every surviving seat IN TURN, each a stagger
-- behind the last, so the deal reads as a deal. That is the shape adopted
-- here, and it is the same shape because it is the same table.
--
-- The two halves are split so online_handler can interleave them with the
-- local player's own card: deal_plan works out where every back is going
-- BEFORE any of them moves (the slots depend on the final count, so they
-- cannot be discovered one card at a time), and deal_back flies one.

--- Who is being dealt to, in turn order from the player on your left, and how
--- many cards each is getting.
--
-- Returns nil for anything that is not a party, so the caller can fall through
-- to the ordinary two-player deal without asking twice.
function M.deal_plan(self, game_state)
    if type(game_state) ~= "table" then return nil end
    local order = game_state.seatOrder
    if type(order) ~= "table" or #order == 0 then return nil end

    -- DOWN TO TWO DEALS NO BACKS, AND THIS IS WHERE THAT WAS MISSED.
    --
    -- M.sync stands the party board down at heads-up and online_handler hands
    -- the opponent to the ordinary duel renderer — but the DEAL is planned
    -- before either of those runs, and it was planned off the seats alone.
    -- So the last two players got both: the duel's arch, at the ordinary
    -- spacing and card size, AND a party arch of squeezed 85%-scale backs on
    -- 18px spacing flown to whichever chair that opponent had been sitting in.
    -- Two hands, two card designs, one opponent — reported as exactly that.
    --
    -- It is the same rule as everywhere else in this file, applied at the one
    -- point that had its own copy of the question: two players is a duel, and
    -- a duel has no party seats to deal to.
    if M.is_heads_up(game_state) then return nil end

    local players = type(game_state.players) == "table" and game_state.players or {}
    local seats = M.seating(order, self.my_player_id, M.eliminated_set(game_state))
    if #seats == 0 then return nil end

    local plan = {}
    for _, s in ipairs(seats) do
        local p = players[s.id] or {}
        local count = tonumber(p.handCount) or (type(p.hand) == "table" and #p.hand) or 0
        -- Capped at MAX_BACKS here rather than after the fact: the mock deck
        -- is sized off this plan, so an uncapped count spawns backs that fly
        -- to a slot that does not exist, land stacked on the tenth, and are
        -- deleted by the very next reconcile. Ten is what the arch shows.
        count = math.min(count, MAX_BACKS)
        if not p.eliminated and count > 0 then
            plan[#plan + 1] = {
                id = s.id, slot = s.slot, count = count,
                -- The very arithmetic layout_backs uses, so the deal and the
                -- reconcile cannot drift into disagreeing about where a
                -- seat's cards live.
                slots = arch_slots(self, s.slot, count),
            }
        end
    end
    if #plan == 0 then return nil end
    return plan
end

--- How many cards the deal has to spawn for the other seats.
-- The caller sizes its mock deck from this: a card short and the deal runs out
-- half way round the table.
function M.deal_card_count(plan)
    local n = 0
    for _, s in ipairs(plan or {}) do n = n + s.count end
    return n
end

--- Fly ONE back to seat `s`, as its `i`th card.
--
-- Face-down and at the seat scale from the instant it leaves the middle: an
-- opponent's card has a known size here, so there is no shrink tween to watch
-- and nothing to resize once the deal lands.
function M.deal_back(self, s, card, i, delay, seq)
    local held = self.party_seats and self.party_seats[s.id]
    if not held then
        held = { slot = s.slot, cards = {} }
        self.party_seats = self.party_seats or {}
        self.party_seats[s.id] = held
    end
    held.slot = s.slot
    held.cards[#held.cards + 1] = card

    local f = BL.CARD_SCALE_F * 0.85
    go.set(card.id, "scale", vmath.vector3(f, f, 1))
    self.set_back(card)

    local sl = s.slots[i] or s.slots[#s.slots]
    if not sl then return end
    go.set(card.id, "euler.z", base_rot(s.slot))
    go.set_position(vmath.vector3(self.CENTER.x, self.CENTER.y, BL.Z_HAND), card.id)
    go.animate(card.id, "position", go.PLAYBACK_ONCE_FORWARD,
        vmath.vector3(sl.x, sl.y, sl.z), go.EASING_OUTCUBIC, 0.3, delay)
    -- Turned into the fan on the way, the way the chamber's deal does it,
    -- rather than landing flat and being straightened afterwards.
    go.animate(card.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, sl.rot,
        go.EASING_OUTCUBIC, 0.3, delay)
    timer.delay(delay, false, function()
        if (not seq) or seq == self._seq then self.play_sound("SoundDraw") end
    end)
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

    -- DOWN TO TWO: STAND DOWN. See the note above — the last two players are
    -- playing a duel, and the ordinary board draws that with its own spacing
    -- and its own card size. Any seats this drew earlier go with it, so a
    -- four-hander that came down to two does not leave two dead chairs and an
    -- arch of backs behind the duel it has become.
    if M.is_heads_up(game_state) then
        if self.party_seats then M.clear(self) end
        return
    end

    local seats = M.seating(order, self.my_player_id, M.eliminated_set(game_state))
    self.party_seats = self.party_seats or {}

    -- THIS IS A TABLE, NOT A DUEL — AND THE HUD HAS TO BE TOLD.
    --
    -- t4_mode is what swaps the board's chrome from a two-player match to a
    -- table: it takes down the duel's opponent avatar plate, their name label
    -- and the two network badges, because at a table every seat has its own
    -- badge and the one plate at the top belongs to nobody in particular.
    --
    -- The offline chamber sends it (tournament4's start). An online party
    -- never did, so a party of four ran with the duel's opponent plate still
    -- up — parked at the top of the screen, over the top seat's own badge,
    -- naming whichever player the ordinary board had picked. One board's
    -- furniture left standing on another's, which is the same class of bug as
    -- the two hands of cards, and it is a large part of why a party "looks
    -- like a normal game".
    --
    -- Latched: reset_hud turns it back off on every board rebuild, so this is
    -- re-asserted whenever the arrangement is (re)established, and only when
    -- it changes rather than on every state push.
    if not self._party_t4_mode then
        self._party_t4_mode = true
        util.notify_gui(GUI_HUD, "t4_mode", { on = true })
    end

    -- THE CHAIRS THAT ARE NO LONGER THERE.
    --
    -- Seating collapses around the survivors, the way the offline chamber's
    -- assign_slots does, so a player who is out is not in `seats` at all. Two
    -- things have to follow them off the table, and neither happens by itself:
    --
    --   THEIR CARDS. layout_backs below only touches seats it is given, so an
    --   arch belonging to somebody who has gone would simply stay on the
    --   board, face down, for the rest of the game.
    --
    --   THEIR BADGE. t4_ui keys badges by SLOT, not by player — so when four
    --   becomes three and the two survivors move to left/right, the badge at
    --   "top" is not moved by anything, it is merely never addressed again. It
    --   would sit there, a chair with a name in it and nobody at the table.
    --   The chamber's answer is to wipe the badges and re-push the survivors
    --   at their new seats (see tournament4's deal_round), which is exactly
    --   what happens here — but only when the arrangement actually changes,
    --   because this runs on every state push and rebuilding the badges on
    --   each one would be a table that flickers every move.
    local seated = {}
    for _, s in ipairs(seats) do seated[s.id] = true end
    for id, held in pairs(self.party_seats) do
        if not seated[id] then
            for _, c in ipairs(held.cards or {}) do pcall(go.delete, c.id) end
            self.party_seats[id] = nil
        end
    end

    local arrangement = {}
    for _, s in ipairs(seats) do arrangement[#arrangement + 1] = s.slot end
    table.sort(arrangement)
    local plan_key = table.concat(arrangement, ",")
    if self._party_slot_plan and self._party_slot_plan ~= plan_key then
        util.notify_gui(GUI_HUD, "t4_clear", {})
    end
    self._party_slot_plan = plan_key

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

    -- EVERY SEAT HERE IS A LIVE ONE — the seating dropped the rest. The
    -- eliminated guards below are kept anyway: they are what stops a badge or
    -- a turn ring appearing on a player who is out should the two answers ever
    -- disagree (a state where `players` says eliminated and the seat order
    -- does not), and they cost a field read.
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
    --
    -- AND NEVER ON A CHAIR NOBODY IS IN. The seat payload above already refuses
    -- to mark an eliminated player active; this loop did not, so the same state
    -- could grey a seat and then start a countdown on it.
    --
    -- The state that produces it is real rather than hypothetical: the server's
    -- nextTurn skips players who are out, but PARTY_PLAYER_OUT carries
    -- currentTurn only when the turn actually moved. A seat that drops out when
    -- it was NOT their turn leaves the client holding "eliminated, and the turn
    -- is still theirs" for exactly as long as it takes the next state to
    -- arrive — and that is the window this drew a ring in.
    for _, s in ipairs(seats) do
        if tostring(s.id) == current and not (players[s.id] or {}).eliminated then
            util.notify_gui(GUI_HUD, "t4_active", { slot = s.slot, duration = 3.0 })
            break
        end
    end
end

--- Take every seat's CARDS off the table, leaving the seats themselves.
--
-- What a fresh deal needs. sync lays the backs out the moment a roster
-- arrives, which is right for a resync and wrong immediately before a deal:
-- the cards are what the deal is about, and flying them to chairs that already
-- hold a full hand shows the hand twice. The badges stay, because a table that
-- deals before it names its seats reads as a game against nobody.
function M.clear_cards(self)
    for _, seat in pairs(self.party_seats or {}) do
        for _, c in ipairs(seat.cards or {}) do pcall(go.delete, c.id) end
        seat.cards = {}
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
    -- The badges are gone with the table, so the next sync must not think it
    -- is looking at an arrangement that is still on screen.
    self._party_slot_plan = nil
    pcall(BL.update_layout, self)
    util.notify_gui(GUI_HUD, "t4_clear", {})
    -- And the duel's chrome comes back with the duel. A party that has come
    -- down to two hands the opponent to the ordinary renderer, and that board
    -- wants its avatar plate and its name label — the same two the table took
    -- down when it opened.
    if self._party_t4_mode then
        self._party_t4_mode = nil
        util.notify_gui(GUI_HUD, "t4_mode", { on = false })
    end
end

return M
