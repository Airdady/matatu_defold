----------------------------------------------------------------------
-- tournament4.lua
-- OFFLINE 4-player "quick bracket" elimination chamber (1 human + 3 AI).
--
-- One shared deal plays out with the four seats taking turns. The instant a
-- seat empties its hand that deal is OVER: among the seats that did NOT
-- finish, the one holding the MOST cards is eliminated. A fresh deal then
-- starts with the survivors, and so on — 4 → 3 → 2 → 1 — until one player
-- remains: the champion.
--
-- The human is always the bottom hand (`self.player_hand`), so all the
-- existing human input / play / draw / suit / penalty handling is reused
-- untouched. The three AI opponents live in `self.t4.seats` and are drawn as
-- compact face-down stacks (top / left / right) with a live card count and
-- avatar. The turn engine here REPLACES the 2-player next_turn while a
-- tournament is active (game_flow routes to it when `self.t4` is set).
----------------------------------------------------------------------
local Defs = require "modules.card_defs"
local deck = require "modules.deck"
local RE   = require "modules.rules_eval"
local Rules= require "modules.card_rules"
local AI   = require "modules.ai_player"
local util = require "modules.game_util"
local BL   = require "modules.board_layout"

local M = {}

local GUI_HUD  = "#game"
local GUI_SUIT = "#suit_select"
local GUI_OVER = "#gameover"
local HAND_SIZE = 7

local AI_NAMES   = { "Cipher", "Rook", "Mamba" }
local AI_AVATARS = { 7, 23, 41 }

local notify = util.notify_gui

-- ── seat helpers ────────────────────────────────────────────────────────────
local function seat_pos(self, seat)
    if seat.slot == "top"   then return self.SEAT_TOP end
    if seat.slot == "left"  then return self.SEAT_LEFT end
    return self.SEAT_RIGHT
end

local function alive_seats(self)
    local out = {}
    for _, s in ipairs(self.t4.seats) do if not s.eliminated then out[#out+1] = s end end
    return out
end

-- Card count for any seat (human reads the live visual hand).
local function seat_count(self, seat)
    if seat.is_human then return #self.player_hand end
    return #seat.hand
end

-- ── AI opponent stack rendering (face-down mini-fan + count badge) ───────────
local function clear_seat_visual(self, seat)
    for _, c in ipairs(seat.cards or {}) do pcall(go.delete, c.id) end
    seat.cards = {}
end

local function render_seat(self, seat)
    if seat.is_human then return end
    clear_seat_visual(self, seat)
    local p = seat_pos(self, seat)
    local n = math.min(#seat.hand, 5)
    for i = 1, n do
        local off = (i - (n + 1) / 2) * 16
        local z = BL.Z_HAND + i * 0.001
        local rec = self.spawn_card(10, "H", vmath.vector3(p.x + off, p.y, z))
        go.set(rec.id, "scale", vmath.vector3(BL.CARD_SCALE_F * 0.7, BL.CARD_SCALE_F * 0.7, 1))
        seat.cards[#seat.cards + 1] = rec
    end
    -- live count + name badge under the stack
    notify(GUI_HUD, "t4_seat", {
        slot = seat.slot, name = seat.name, avatar = seat.avatar,
        count = #seat.hand, eliminated = seat.eliminated,
        active = (self.t4.turn_seat == seat),
        x = p.x, y = p.y,
    })
end

local function render_all_seats(self)
    for _, s in ipairs(self.t4.seats) do render_seat(self, s) end
end

-- ── turn rotation ────────────────────────────────────────────────────────────
local function next_alive_index(self, from)
    local seats = self.t4.seats
    local n = #seats
    for step = 1, n do
        local idx = ((from - 1 + step) % n) + 1
        if not seats[idx].eliminated then return idx end
    end
    return from
end

-- ── deal a fresh round among the current survivors ───────────────────────────
local function deal_round(self)
    -- wipe board visuals
    for _, c in ipairs(self.player_hand) do pcall(go.delete, c.id) end
    for _, c in ipairs(self.played_cards) do pcall(go.delete, c.id) end
    for _, c in ipairs(self.deck) do pcall(go.delete, c.id) end
    if self.cutting_card then pcall(go.delete, self.cutting_card.id); self.cutting_card = nil end
    self.player_hand, self.played_cards, self.deck = {}, {}, {}
    for _, s in ipairs(self.t4.seats) do clear_seat_visual(self, s); s.hand = {} end

    self.active_penalty = 0
    self.chosen_suit = ""
    self.game_over = false
    self.is_animating = false
    self.is_local_action_locked = false
    self.player_has_drawn = false

    -- build + shuffle a deck, deal HAND_SIZE to each survivor
    local d = deck.build()
    for i = #d, 2, -1 do local j = math.random(i); d[i], d[j] = d[j], d[i] end

    local survivors = alive_seats(self)
    for _ = 1, HAND_SIZE do
        for _, s in ipairs(survivors) do
            local card = table.remove(d)
            if s.is_human then
                local rec = self.spawn_card(card.v, card.s, vmath.vector3(self.CENTER.x, self.CENTER.y, BL.Z_HAND))
                self.set_face(rec)
                table.insert(self.player_hand, rec)
            else
                table.insert(s.hand, { v = card.v, s = card.s })
            end
        end
    end

    -- starting top card (avoid a power card)
    local top
    repeat top = table.remove(d) until not top or (top.v ~= 50 and top.v ~= Rules.VALUES.ACE
        and top.v ~= Rules.VALUES.TWO and top.v ~= Rules.VALUES.THREE
        and top.v ~= Rules.VALUES.EIGHT and top.v ~= Rules.VALUES.JACK) or #d == 0
    if top then
        local rec = self.spawn_card(top.v, top.s, vmath.vector3(self.CENTER.x, self.CENTER.y, BL.Z_PILE))
        self.set_face(rec)
        table.insert(self.played_cards, rec)
    end

    -- remaining cards become the draw pile
    for i, card in ipairs(d) do
        local rec = self.spawn_card(card.v, card.s, vmath.vector3(self.DECK_POS.x + i * 0.5, self.DECK_POS.y - i * 0.5, i * 0.001))
        table.insert(self.deck, rec)
    end

    self.position_hands(true)
    render_all_seats(self)

    -- the round opener rotates each deal so it isn't always the human
    self.t4.round = (self.t4.round or 0) + 1
    local opener = self.t4.opener_idx or 1
    while self.t4.seats[opener].eliminated do opener = next_alive_index(self, opener) end
    self.t4.turn_idx = opener
    self.t4.turn_seat = self.t4.seats[opener]
    self.t4.opener_idx = next_alive_index(self, opener)

    M.begin_turn(self)
end

-- ── elimination between deals ────────────────────────────────────────────────
local function finish_round(self, finisher)
    self.game_over = true
    notify(GUI_HUD, "stop_timers")

    -- among NON-finishers, eliminate the one holding the most cards
    local worst, worst_n = nil, -1
    for _, s in ipairs(alive_seats(self)) do
        if s ~= finisher then
            local n = seat_count(self, s)
            if n > worst_n then worst_n, worst = n, s end
        end
    end
    if worst then worst.eliminated = true end

    local survivors = alive_seats(self)
    if #survivors <= 1 then
        local champ = survivors[1] or finisher
        notify(GUI_OVER, "game_over", {
            won = champ.is_human, player_score = 0, ai_score = 0,
            is_cut = false, series_active = false, series_over = true,
            t4_champion = champ.name, t4_is_human = champ.is_human,
        })
        if champ.is_human then self.play_sound("SoundWinAlt") else self.play_sound("SoundLose") end
        return
    end

    -- interstitial then next deal
    notify(GUI_HUD, "t4_eliminated", {
        name = worst and worst.name or "",
        finisher = finisher.name,
        remaining = #survivors,
    })
    local seq = self._seq
    timer.delay(2.2, false, function()
        if seq == self._seq then deal_round(self) end
    end)
end

-- Called by game_flow when the human empties their hand in tournament mode.
function M.human_finished(self)
    finish_round(self, self.t4.human_seat)
end

-- ── AI seat turn ─────────────────────────────────────────────────────────────
local function ai_play_card(self, seat, rec_data)
    -- spawn a face-up card at the seat and fly it to the pile
    local p = seat_pos(self, seat)
    local rec = self.spawn_card(rec_data.v, rec_data.s, vmath.vector3(p.x, p.y, BL.Z_FLY))
    self.set_face(rec)
    -- remove from the seat's data hand
    for i, c in ipairs(seat.hand) do
        if c.v == rec_data.v and c.s == rec_data.s then table.remove(seat.hand, i); break end
    end
    local is_last = (#seat.hand == 0)
    RE.trigger_play_effects(self, rec, is_last)
    self.animate_to_pile(rec, false)
    render_seat(self, seat)
    return rec
end

local function ai_seat_turn(self, seat)
    if self.game_over then return end
    -- penalty owed?
    local penalty = RE.get_active_penalty(self)

    -- find a valid card
    local choice
    for _, c in ipairs(seat.hand) do
        if RE.evaluate_play(self, c, seat.hand).valid then choice = c; break end
    end

    if not choice then
        -- must draw / serve penalty
        local n = penalty > 0 and penalty or 1
        self.active_penalty = 0
        local drew = {}
        for _ = 1, n do
            if #self.deck == 0 then self.reshuffle_deck(function() end) end
            local d = table.remove(self.deck)
            if d then table.insert(seat.hand, { v = d.v, s = d.s }); pcall(go.delete, d.id) end
        end
        render_seat(self, seat)
        self.play_sound("SoundDraw")
        M.advance(self)
        return
    end

    local rec = ai_play_card(self, seat, choice)
    local result = RE.evaluate_play(self, rec, seat.hand)

    -- did this empty the hand? → round over
    if #seat.hand == 0 then
        timer.delay(0.45, false, function() finish_round(self, seat) end)
        return
    end

    -- apply effects
    self.active_penalty = result.next_player_penalty_count or 0
    local NA = Rules.NextActionType
    if result.type == NA.CHOOSE_SUIT then
        self.chosen_suit = AI.best_suit_for_hand(seat.hand)
        notify(GUI_SUIT, "suit_select", { mode = "preview", suit = self.chosen_suit })
        notify(GUI_HUD, "suit_badge", { suit = self.chosen_suit })
        M.advance(self)
    elseif result.type == NA.SKIP_TURN then
        -- skip the next seat: advance twice
        self.t4.turn_idx = next_alive_index(self, self.t4.turn_idx)
        M.advance(self)
    else
        self.chosen_suit = ""
        M.advance(self)
    end
end

-- ── public turn API ──────────────────────────────────────────────────────────
function M.begin_turn(self)
    if self.game_over then return end
    local seat = self.t4.turn_seat
    render_all_seats(self)

    if seat.is_human then
        self.current_turn = "player"
        self.waiting = false
        self.is_local_action_locked = false
        self.player_has_drawn = false
        notify(GUI_HUD, "turn", { who = "player", duration = 30, expires_at = (socket.gettime() * 1000) + 30000 })
        RE.pre_validate_hand(self)
    else
        self.current_turn = "ai"
        self.waiting = true
        notify(GUI_HUD, "turn", { who = "ai", duration = 30, expires_at = 0 })
        local seq = self._seq
        local think = 0.7 + math.random() * 0.9
        timer.delay(think, false, function()
            if seq == self._seq and not self.game_over then ai_seat_turn(self, seat) end
        end)
    end
end

-- Advance to the next surviving seat and begin its turn.
function M.advance(self)
    if self.game_over then return end
    self.current_turn_actions = {}
    self.t4.turn_idx = next_alive_index(self, self.t4.turn_idx)
    self.t4.turn_seat = self.t4.seats[self.t4.turn_idx]
    M.begin_turn(self)
end

-- Skip-card (8 / Jack): the NEXT surviving seat loses its turn, so we step
-- the pointer once extra before advancing normally.
function M.skip_and_advance(self)
    if self.game_over then return end
    self.t4.turn_idx = next_alive_index(self, self.t4.turn_idx)
    M.advance(self)
end

-- ── boot ─────────────────────────────────────────────────────────────────────
function M.start(self, me)
    self._seq = (self._seq or 0) + 1
    self.online_mode = false
    self.t4 = { round = 0, opener_idx = 1 }

    local human = { is_human = true, name = (me and me.username) or "You", avatar = (me and me.avatar) or 1, slot = "bottom", eliminated = false, hand = nil }
    self.t4.human_seat = human
    self.t4.seats = {
        human,
        { is_human = false, name = AI_NAMES[1], avatar = AI_AVATARS[1], slot = "top",   eliminated = false, hand = {}, cards = {} },
        { is_human = false, name = AI_NAMES[2], avatar = AI_AVATARS[2], slot = "left",  eliminated = false, hand = {}, cards = {} },
        { is_human = false, name = AI_NAMES[3], avatar = AI_AVATARS[3], slot = "right", eliminated = false, hand = {}, cards = {} },
    }

    notify(GUI_HUD, "setup_avatars", { my_info = { username = human.name, avatar = human.avatar }, op_info = { username = "Bracket", avatar = AI_AVATARS[1] } })
    notify(GUI_HUD, "t4_intro", { players = 4 })

    deal_round(self)
end

return M
