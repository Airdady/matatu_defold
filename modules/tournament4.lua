----------------------------------------------------------------------
-- tournament4.lua
-- OFFLINE multi-player "quick bracket" elimination chamber (1 human + 3 AI).
--
-- One shared deal plays out with the seats taking turns around the table. The
-- instant a seat empties its hand the deal ENDS: every surviving hand is
-- flipped face-up and counted one player at a time, and the seat holding the
-- MOST cards leaves the table. A fresh deal starts with the survivors —
-- 4 → 3 → 2 → 1 — until a champion remains.
--
-- Natural table feel:
--   * each opponent's cards are an ARCH of backs facing the centre (top / left
--     / right), the human's real hand stays interactive at the bottom;
--   * the central deck sits apart from every seat, and a draw is ANIMATED from
--     the deck into the drawer's hand (AI included);
--   * the active seat is highlighted with a depleting timer pie (AI too);
--   * J/11 REVERSES the direction of play (clockwise ⇄ anticlockwise) while 3+
--     remain, and acts as a skip in the 2-player endgame; 8 skips one seat;
--   * with two players left the table collapses to the classic head-to-head
--     bottom-vs-top layout.
--
-- The 2-player game is untouched: game_flow only routes here while `self.t4`
-- is set.
----------------------------------------------------------------------
local Defs  = require "modules.card_defs"
local deck  = require "modules.deck"
local RE    = require "modules.rules_eval"
local Rules = require "modules.card_rules"
local AI    = require "modules.ai_player"
local util  = require "modules.game_util"
local BL    = require "modules.board_layout"

local M = {}

local GUI_HUD  = "#game"
local GUI_SUIT = "#suit_select"
local GUI_OVER = "#gameover"
local HAND_SIZE = 7
local MAX_BACKS = 9            -- visible backs per AI arch (count badge shows the truth)

local AI_NAMES   = { "Cipher", "Rook", "Mamba" }
local AI_AVATARS = { 7, 23, 41 }

local notify = util.notify_gui

-- ── geometry ─────────────────────────────────────────────────────────────────
-- The discard pile lives at CENTER (matching animate_to_pile's target); the
-- draw deck sits well to the left of it, apart from every seat.
local function deck_pos(self)  return vmath.vector3(self.CENTER.x - 170, self.CENTER.y, 0) end
local function pile_pos(self)  return vmath.vector3(self.CENTER.x, self.CENTER.y, 0) end

local function anchor_for(self, slot)
    if slot == "bottom" then return vmath.vector3(self.CENTER.x, self.PLAYER_HAND_Y, 0) end
    if slot == "top"    then return vmath.vector3(self.CENTER.x, self.AI_HAND_Y, 0) end
    if slot == "left"   then return vmath.vector3(self.SEAT_LEFT.x, self.SEAT_LEFT.y, 0) end
    return vmath.vector3(self.SEAT_RIGHT.x, self.SEAT_RIGHT.y, 0)
end

-- HUD widget (avatar + pie + name + count) anchor for a slot.
local function widget_pos(self, slot)
    local a = anchor_for(self, slot)
    if slot == "bottom" then return vmath.vector3(a.x - 380, a.y + 10, 0) end
    if slot == "top"    then return vmath.vector3(a.x - 380, a.y, 0) end
    if slot == "left"   then return vmath.vector3(a.x, a.y - 150, 0) end
    return vmath.vector3(a.x, a.y - 150, 0)
end

local function base_rot(slot)
    if slot == "left"  then return 90 end
    if slot == "right" then return -90 end
    return 0
end

-- Arch slot transforms for `n` cards at `slot`.
local function arch_slots(self, slot, n)
    local out = {}
    if n <= 0 then return out end
    local a = anchor_for(self, slot)
    local horizontal = (slot == "bottom" or slot == "top")
    local toward = (slot == "top" or slot == "right") and -1 or 1
    local spacing = math.min(32, (n > 1 and 150 / (n - 1) or 0))
    local fan, arc = 9, 24
    local br = base_rot(slot)
    for i = 1, n do
        local t = (n == 1) and 0 or ((i - 1) / (n - 1) - 0.5)
        local along = t * spacing * (n - 1)
        local bump = (0.25 - t * t) * arc * toward
        local x, y, rot
        if horizontal then
            x, y = a.x + along, a.y + bump
            rot = br - t * fan * 2 * toward
        else
            y, x = a.y - along, a.x + bump
            rot = br - t * fan * 2 * toward
        end
        out[i] = { x = x, y = y, rot = rot, z = BL.Z_HAND + i * 0.001 }
    end
    return out
end

-- ── seat helpers ────────────────────────────────────────────────────────────
local function alive_seats(self)
    local out = {}
    for _, s in ipairs(self.t4.seats) do if not s.eliminated then out[#out + 1] = s end end
    return out
end

local function seat_count(self, seat)
    if seat.is_human and not seat.eliminated and self.t4.human_alive then return #self.player_hand end
    return #seat.hand
end

local function push_seat_hud(self, seat)
    local wp = widget_pos(self, seat.slot)
    notify(GUI_HUD, "t4_seat", {
        slot = seat.slot, name = seat.name, avatar = seat.avatar,
        count = seat_count(self, seat), eliminated = seat.eliminated,
        active = (self.t4.turn_seat == seat) and not self.t4.revealing,
        x = wp.x, y = wp.y,
    })
end

-- ── AI arch rendering (face-down backs) ──────────────────────────────────────
local function clear_cards(self, seat)
    for _, c in ipairs(seat.cards or {}) do pcall(go.delete, c.id) end
    seat.cards = {}
end

local function layout_seat(self, seat, animate)
    if seat.is_human and self.t4.human_alive then return end -- human uses player_hand
    local n = math.min(#seat.hand, MAX_BACKS)
    -- spawn/cull back nodes to match n
    while #seat.cards > n do local c = table.remove(seat.cards); pcall(go.delete, c.id) end
    while #seat.cards < n do
        local a = anchor_for(self, seat.slot)
        local rec = self.spawn_card(10, "H", vmath.vector3(a.x, a.y, BL.Z_HAND))
        go.set(rec.id, "scale", vmath.vector3(BL.CARD_SCALE_F * 0.72, BL.CARD_SCALE_F * 0.72, 1))
        self.set_back(rec)
        seat.cards[#seat.cards + 1] = rec
    end
    local slots = arch_slots(self, seat.slot, n)
    for i, c in ipairs(seat.cards) do
        local s = slots[i]
        if s then
            local tp = vmath.vector3(s.x, s.y, s.z)
            if animate then
                go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, tp, go.EASING_OUTCUBIC, 0.25)
                go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, s.rot, go.EASING_OUTCUBIC, 0.25)
            else
                go.set_position(tp, c.id)
                go.set(c.id, "euler.z", s.rot)
            end
        end
    end
end

local function render_all(self, animate)
    for _, s in ipairs(self.t4.seats) do
        layout_seat(self, s, animate)
        push_seat_hud(self, s)
    end
end

-- ── direction-aware rotation ─────────────────────────────────────────────────
local function step_index(self, from)
    local seats = self.t4.seats
    local n = #seats
    local dir = self.t4.direction or 1
    for k = 1, n do
        local idx = ((from - 1 + dir * k) % n + n) % n + 1
        if not seats[idx].eliminated then return idx end
    end
    return from
end

-- ── deck / draw ──────────────────────────────────────────────────────────────
local function reshuffle_if_needed(self)
    if #self.deck > 0 then return end
    if #self.played_cards <= 1 then return end
    local top = table.remove(self.played_cards)
    for _, c in ipairs(self.played_cards) do pcall(go.delete, c.id) end
    local data = {}
    for _, c in ipairs(self.played_cards) do data[#data + 1] = { v = c.v, s = c.s } end
    self.played_cards = { top }
    for i = #data, 2, -1 do local j = math.random(i); data[i], data[j] = data[j], data[i] end
    local dp = deck_pos(self)
    self.deck = {}
    for i, d in ipairs(data) do
        local rec = self.spawn_card(d.v, d.s, vmath.vector3(dp.x + i * 0.4, dp.y - i * 0.4, i * 0.001))
        self.deck[#self.deck + 1] = rec
    end
    self.play_sound("SoundShuffle")
end

-- Animate `n` cards from the deck into an AI seat's hand. done() after.
local function ai_draw(self, seat, n, done)
    local i = 0
    local function one()
        i = i + 1
        if i > n then if done then done() end return end
        reshuffle_if_needed(self)
        local d = table.remove(self.deck)
        if not d then if done then done() end return end
        seat.hand[#seat.hand + 1] = { v = d.v, s = d.s }
        -- fly the (face-down) deck card to the seat, then settle into the arch
        local a = anchor_for(self, seat.slot)
        go.set(d.id, "scale", vmath.vector3(BL.CARD_SCALE_F * 0.72, BL.CARD_SCALE_F * 0.72, 1))
        self.set_back(d)
        self.play_sound("SoundDraw")
        go.animate(d.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(a.x, a.y, BL.Z_FLY),
            go.EASING_OUTCUBIC, 0.3, 0, function()
                pcall(go.delete, d.id)
                layout_seat(self, seat, true)
                push_seat_hud(self, seat)
                local seq = self._seq
                timer.delay(0.12, false, function() if seq == self._seq then one() end end)
            end)
    end
    one()
end

-- ── turn engine ──────────────────────────────────────────────────────────────
function M.begin_turn(self)
    if self.game_over or self.t4.revealing then return end
    local seat = self.t4.turn_seat
    render_all(self)
    notify(GUI_HUD, "t4_active", { slot = seat.slot, duration = seat.is_human and 30 or 3.0 })

    if seat.is_human and self.t4.human_alive then
        self.current_turn = "player"
        self.waiting = false
        self.is_local_action_locked = false
        self.player_has_drawn = false
        notify(GUI_HUD, "turn", { who = "player", duration = 30, expires_at = (socket.gettime() * 1000) + 30000 })
        RE.pre_validate_hand(self)
    else
        self.current_turn = "ai"
        self.waiting = true
        notify(GUI_HUD, "turn", { who = "ai", duration = 3, expires_at = 0 })
        local seq = self._seq
        timer.delay(1.4 + math.random() * 1.4, false, function()
            if seq == self._seq and not self.game_over and not self.t4.revealing then M.ai_seat_turn(self, seat) end
        end)
    end
end

function M.advance(self)
    if self.game_over or self.t4.revealing then return end
    self.current_turn_actions = {}
    self.t4.turn_idx = step_index(self, self.t4.turn_idx)
    self.t4.turn_seat = self.t4.seats[self.t4.turn_idx]
    M.begin_turn(self)
end

-- 8 / Jack handling: 8 skips one seat; Jack reverses with 3+, skips with 2.
function M.apply_skip(self, rec)
    local survivors = #alive_seats(self)
    if rec and tonumber(rec.v) == 11 and survivors > 2 then
        self.t4.direction = -(self.t4.direction or 1)
        notify(GUI_HUD, "t4_flash", { text = "REVERSE!" })
        M.advance(self)
    else
        -- skip the next seat, then continue
        self.t4.turn_idx = step_index(self, self.t4.turn_idx)
        M.advance(self)
    end
end

-- ── AI seat turn ─────────────────────────────────────────────────────────────
function M.ai_seat_turn(self, seat)
    if self.game_over or self.t4.revealing then return end
    local penalty = RE.get_active_penalty(self)

    local choice
    for _, c in ipairs(seat.hand) do
        if RE.evaluate_play(self, c, seat.hand).valid then choice = c; break end
    end

    if not choice then
        local n = penalty > 0 and penalty or 1
        self.active_penalty = 0
        ai_draw(self, seat, n, function()
            M.advance(self)
        end)
        return
    end

    -- remove from data hand, repurpose one back node as the played card
    for i, c in ipairs(seat.hand) do
        if c.v == choice.v and c.s == choice.s then table.remove(seat.hand, i); break end
    end
    local rec = table.remove(seat.cards)
    if rec then rec.v, rec.s = choice.v, choice.s; self.set_face(rec)
    else local a = anchor_for(self, seat.slot); rec = self.spawn_card(choice.v, choice.s, vmath.vector3(a.x, a.y, BL.Z_FLY)); self.set_face(rec) end

    local is_last = (#seat.hand == 0)
    RE.trigger_play_effects(self, rec, is_last)
    self.animate_to_pile(rec, false)
    layout_seat(self, seat, true)
    push_seat_hud(self, seat)

    if #seat.hand == 0 then
        local seq = self._seq
        timer.delay(0.5, false, function() if seq == self._seq then M.finish_round(self, seat) end end)
        return
    end

    local result = RE.evaluate_play(self, rec, seat.hand)
    self.active_penalty = result.next_player_penalty_count or 0
    local NA = Rules.NextActionType
    if result.type == NA.CHOOSE_SUIT then
        self.chosen_suit = AI.best_suit_for_hand(seat.hand)
        notify(GUI_SUIT, "suit_select", { mode = "preview", suit = self.chosen_suit })
        notify(GUI_HUD, "suit_badge", { suit = self.chosen_suit })
        M.advance(self)
    elseif result.type == NA.SKIP_TURN then
        M.apply_skip(self, rec)
    else
        self.chosen_suit = ""
        M.advance(self)
    end
end

-- Called by game_flow when the human empties their hand.
function M.human_finished(self)
    M.finish_round(self, self.t4.human_seat)
end

-- ── end-of-deal reveal + count + elimination ─────────────────────────────────
-- Flip every surviving hand face-up, count them one player at a time, then the
-- most-cards seat leaves the table.
function M.finish_round(self, finisher)
    if self.t4.revealing then return end
    self.t4.revealing = true
    self.game_over = true
    notify(GUI_HUD, "stop_timers")
    notify(GUI_HUD, "t4_active", { slot = "none" })

    -- 1. reveal: turn each AI seat's hidden hand into a face-up fan
    for _, seat in ipairs(alive_seats(self)) do
        if not (seat.is_human and self.t4.human_alive) then
            clear_cards(self, seat)
            local n = #seat.hand
            local slots = arch_slots(self, seat.slot, math.min(n, MAX_BACKS + 4))
            for i = 1, math.min(n, MAX_BACKS + 4) do
                local card = seat.hand[i]
                local s = slots[i]
                local rec = self.spawn_card(card.v, card.s, vmath.vector3(s.x, s.y, s.z))
                go.set(rec.id, "scale", vmath.vector3(0.01, BL.CARD_SCALE_F * 0.72, 1))
                self.set_face(rec)
                go.animate(rec.id, "scale.x", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE_F * 0.72, go.EASING_OUTBACK, 0.3, i * 0.03)
                go.set(rec.id, "euler.z", s.rot)
                seat.cards[#seat.cards + 1] = rec
            end
        end
        push_seat_hud(self, seat)
    end

    -- 2. count each non-finisher one at a time, then eliminate the worst
    local counters = {}
    for _, s in ipairs(alive_seats(self)) do if s ~= finisher then counters[#counters + 1] = s end end

    local idx = 0
    local worst, worst_n = nil, -1
    local function step()
        idx = idx + 1
        if idx > #counters then
            -- choose & eliminate the worst
            if worst then worst.eliminated = true end
            local survivors = alive_seats(self)
            notify(GUI_HUD, "t4_eliminated", { name = worst and worst.name or "", remaining = #survivors })
            if worst then
                -- slide the eliminated seat's cards off the table; the human's
                -- cards live in player_hand rather than the seat's back nodes.
                local nodes = worst.cards or {}
                if worst.is_human and self.t4.human_alive then nodes = self.player_hand end
                for _, c in ipairs(nodes) do
                    local pz = go.get_position(c.id)
                    go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(pz.x, pz.y - 300, pz.z), go.EASING_INBACK, 0.6, 0)
                    go.animate(c.id, "scale", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(0.2, 0.2, 1), go.EASING_INSINE, 0.6, 0)
                end
            end
            local seq = self._seq
            timer.delay(2.0, false, function()
                if seq ~= self._seq then return end
                if #survivors <= 1 then
                    M.crown(self, survivors[1] or finisher)
                else
                    M.deal_round(self)
                end
            end)
            return
        end
        local s = counters[idx]
        local n = seat_count(self, s)
        if n > worst_n then worst_n, worst = n, s end
        notify(GUI_HUD, "t4_count", { slot = s.slot, count = n })
        self.play_sound("SoundPick")
        local seq = self._seq
        timer.delay(0.9, false, function() if seq == self._seq then step() end end)
    end
    -- small beat so the reveal flip is visible before counting
    local seq = self._seq
    timer.delay(0.8, false, function() if seq == self._seq then step() end end)
end

function M.crown(self, champ)
    self.t4.revealing = false
    notify(GUI_OVER, "game_over", {
        won = champ.is_human, player_score = 0, ai_score = 0,
        is_cut = false, series_active = false, series_over = true,
        t4_champion = champ.name, t4_is_human = champ.is_human,
    })
    if champ.is_human then self.play_sound("SoundWinAlt") else self.play_sound("SoundLose") end
end

-- ── slot assignment (collapses toward the 2-player layout) ────────────────────
local function assign_slots(self)
    local survivors = alive_seats(self)
    local human_alive = false
    for _, s in ipairs(survivors) do if s.is_human then human_alive = true end end
    self.t4.human_alive = human_alive

    -- order: human first (if alive), then AIs in their fixed order
    local ordered = {}
    if human_alive then for _, s in ipairs(survivors) do if s.is_human then ordered[#ordered + 1] = s end end end
    for _, s in ipairs(survivors) do if not s.is_human then ordered[#ordered + 1] = s end end

    local layouts = {
        [2] = { "bottom", "top" },
        [3] = { "bottom", "left", "right" },
        [4] = { "bottom", "top", "left", "right" },
    }
    local plan = layouts[#ordered] or layouts[4]
    for i, s in ipairs(ordered) do s.slot = plan[i] or "top" end
end

-- ── deal a fresh round among the survivors ───────────────────────────────────
function M.deal_round(self)
    self.t4.revealing = false
    self.game_over = false
    self._seq = (self._seq or 0) + 1

    -- wipe board
    for _, c in ipairs(self.player_hand) do pcall(go.delete, c.id) end
    for _, c in ipairs(self.played_cards) do pcall(go.delete, c.id) end
    for _, c in ipairs(self.deck) do pcall(go.delete, c.id) end
    self.player_hand, self.played_cards, self.deck = {}, {}, {}
    for _, s in ipairs(self.t4.seats) do clear_cards(self, s); s.hand = {} end

    self.active_penalty, self.chosen_suit = 0, ""
    self.is_animating, self.is_local_action_locked, self.player_has_drawn = false, false, false
    self.t4.direction = 1

    assign_slots(self)

    -- shuffle + deal
    local d = deck.build()
    for i = #d, 2, -1 do local j = math.random(i); d[i], d[j] = d[j], d[i] end
    local survivors = alive_seats(self)
    for _ = 1, HAND_SIZE do
        for _, s in ipairs(survivors) do
            local card = table.remove(d)
            if s.is_human and self.t4.human_alive then
                local rec = self.spawn_card(card.v, card.s, vmath.vector3(self.CENTER.x, self.CENTER.y, BL.Z_HAND))
                self.set_face(rec)
                table.insert(self.player_hand, rec)
            else
                table.insert(s.hand, { v = card.v, s = card.s })
            end
        end
    end

    -- start card (avoid a power card)
    local top
    repeat top = table.remove(d) until not top or (top.v ~= 50 and top.v ~= Rules.VALUES.ACE
        and top.v ~= Rules.VALUES.TWO and top.v ~= Rules.VALUES.THREE
        and top.v ~= Rules.VALUES.EIGHT and top.v ~= Rules.VALUES.JACK) or #d == 0
    local pp = pile_pos(self)
    if top then
        local rec = self.spawn_card(top.v, top.s, vmath.vector3(pp.x, pp.y, BL.Z_PILE))
        self.set_face(rec)
        table.insert(self.played_cards, rec)
    end

    -- remaining → draw pile, near the centre, distant from the seats
    local dp = deck_pos(self)
    for i, card in ipairs(d) do
        local rec = self.spawn_card(card.v, card.s, vmath.vector3(dp.x + i * 0.4, dp.y - i * 0.4, i * 0.001))
        table.insert(self.deck, rec)
    end

    -- wipe stale seat widgets (slots may have been reassigned on collapse)
    notify(GUI_HUD, "t4_clear", {})
    self.position_hands(true)
    render_all(self, true)

    -- opener rotates each deal
    self.t4.round = (self.t4.round or 0) + 1
    local opener = self.t4.opener_idx or 1
    while self.t4.seats[opener].eliminated do opener = step_index(self, opener) end
    self.t4.turn_idx = opener
    self.t4.turn_seat = self.t4.seats[opener]
    self.t4.opener_idx = step_index(self, opener)

    local seq = self._seq
    timer.delay(0.5, false, function() if seq == self._seq then M.begin_turn(self) end end)
end

-- ── boot ─────────────────────────────────────────────────────────────────────
function M.start(self, me)
    self._seq = (self._seq or 0) + 1
    self.online_mode = false
    self.t4 = { round = 0, opener_idx = 1, direction = 1, human_alive = true }

    local human = { is_human = true, name = (me and me.username) or "You", avatar = (me and me.avatar) or 1, slot = "bottom", eliminated = false, hand = {}, cards = {} }
    self.t4.human_seat = human
    self.t4.seats = {
        human,
        { is_human = false, name = AI_NAMES[1], avatar = AI_AVATARS[1], slot = "top",   eliminated = false, hand = {}, cards = {} },
        { is_human = false, name = AI_NAMES[2], avatar = AI_AVATARS[2], slot = "left",  eliminated = false, hand = {}, cards = {} },
        { is_human = false, name = AI_NAMES[3], avatar = AI_AVATARS[3], slot = "right", eliminated = false, hand = {}, cards = {} },
    }

    notify(GUI_HUD, "t4_mode", { on = true })
    M.deal_round(self)
end

return M
