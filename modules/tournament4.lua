----------------------------------------------------------------------
-- tournament4.lua
-- OFFLINE multi-player "quick bracket" elimination chamber (1 human + 3 AI).
--
-- One shared deal plays out with the seats taking turns around the table. The
-- instant a seat empties its hand the deal ENDS: every surviving hand is
-- flipped face-up and counted — one card at a time, flown into the centre of
-- the table — and the seat holding the MOST cards leaves the table. A fresh
-- deal starts with the survivors — 4 → 3 → 2 → 1 — until a champion remains.
----------------------------------------------------------------------
local Defs     = require "modules.card_defs"
local deck     = require "modules.deck"
local RE       = require "modules.rules_eval"
local Rules    = require "modules.card_rules"
local AI       = require "modules.ai_player"
local util     = require "modules.game_util"
local BL       = require "modules.board_layout"
local GameMode = require "modules.game_mode"

local M = {}

local GUI_HUD  = "#game"
local GUI_SUIT = "#suit_select"
local GUI_OVER = "#gameover"
local HAND_SIZE = 7
local MAX_BACKS = 10           -- visible backs per AI arch during play
local DEAL_STAGGER = 0.085     -- gap between dealt cards

local AI_NAMES   = { "Cipher", "Rook", "Mamba" }
local AI_AVATARS = { 7, 23, 41 }

local notify = util.notify_gui

-- ── scoring helper ───────────────────────────────────────────────────────────
local function get_card_value(v, s)
    local val = tonumber(v)
    if not val then return 0 end

    if GameMode.is_whot() then
        -- Whot: every card counts its literal face value (a Pick Two "2" is
        -- worth 2, a General Market "14" is worth 14, ...) — no penalty-card
        -- inflation. The one exception is Star-shaped cards, which always
        -- count DOUBLE their face value (a Star "2" scores 4, a Star "5"
        -- scores 10, ...).
        if s == Rules.SHAPE_STAR then return val * 2 end
        return val
    end

    if val == 50 then return 50 end
    if val == 14 or val == 1 or val == 15 then
        if s == "S" then return 60 else return 15 end
    end
    if val == 2 then return 20 end
    if val == 3 then return 30 end
    return val
end

-- ── geometry ─────────────────────────────────────────────────────────────────
local function pile_pos(self)  return vmath.vector3(self.CENTER.x, self.CENTER.y, 0) end

local function anchor_for(self, slot)
    if slot == "bottom" then return vmath.vector3(self.CENTER.x, self.PLAYER_HAND_Y, 0) end
    if slot == "top"    then return vmath.vector3(self.CENTER.x, self.AI_HAND_Y, 0) end
    if slot == "left"   then return vmath.vector3(self.SEAT_LEFT.x, self.SEAT_LEFT.y, 0) end
    return vmath.vector3(self.SEAT_RIGHT.x, self.SEAT_RIGHT.y, 0)
end

local function widget_pos(self, slot)
    if slot == "bottom" then return vmath.vector3(self.CENTER.x - 540, self.PLAYER_HAND_Y + 44, 0) end
    if slot == "top"    then 
        if self.t4 and self.t4.is_heads_up then
            return vmath.vector3(self.CENTER.x - 540, self.AI_HAND_Y - 44, 0)
        else
            return vmath.vector3(self.CENTER.x, self.AI_HAND_Y + 46, 0) 
        end
    end
    if slot == "left"   then return vmath.vector3(self.SEAT_LEFT.x - 66, self.SEAT_LEFT.y,      0) end
    return vmath.vector3(self.SEAT_RIGHT.x + 66, self.SEAT_RIGHT.y, 0)
end

local function base_rot(slot)
    if slot == "left"  then return 90 end
    if slot == "right" then return -90 end
    return 0
end

local function arch_slots(self, slot, n)
    local out = {}
    if n <= 0 then return out end
    local a = anchor_for(self, slot)
    local horizontal = (slot == "bottom" or slot == "top")
    local toward = (slot == "top" or slot == "right") and -1 or 1
    local spacing = math.min(32, (n > 1 and 150 / (n - 1) or 0))
    local fan = math.min(9, n * 1.4)
    local arc = math.min(24, n * 3.4)
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

local function human_hand_slots(self, n)
    local spacing = BL.calc_spacing(self, n)
    local startx = self.CENTER.x - ((n - 1) * spacing) / 2.0
    local arc_amt = math.min(34, n * 5.0)
    local fan_amt = math.min(8, n * 1.3)
    local out = {}
    for i = 1, n do
        local t = (n > 1) and ((i - 1) / (n - 1) - 0.5) or 0
        out[i] = {
            x = startx + (i - 1) * spacing,
            y = self.PLAYER_HAND_Y + (0.25 - t * t) * arc_amt,
            rot = -t * fan_amt,
            z = BL.Z_HAND + i * 0.001,
        }
    end
    return out
end

local function get_seat_slots(self, seat, n)
    if self.t4.is_heads_up then
        if seat.slot == "bottom" then return human_hand_slots(self, n) end
        local spacing = BL.calc_spacing(self, n)
        local startx = self.CENTER.x - ((n - 1) * spacing) / 2.0
        local out = {}
        for i = 1, n do
            out[i] = { x = startx + (i - 1) * spacing, y = self.AI_HAND_Y, rot = 0, z = BL.Z_HAND + i * 0.001 }
        end
        return out
    end
    if seat.slot == "bottom" then return human_hand_slots(self, n) end
    return arch_slots(self, seat.slot, n)
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

local function seat_nodes(self, seat)
    if seat.is_human and self.t4.human_alive then return self.player_hand end
    return seat.cards
end

local function push_seat_hud(self, seat)
    local wp = widget_pos(self, seat.slot)
    notify(GUI_HUD, "t4_seat", {
        slot = seat.slot, name = seat.name, avatar = seat.avatar,
        is_human = seat.is_human and true or false,
        eliminated = seat.eliminated,
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
    if seat.is_human and self.t4.human_alive then return end
    local is_hu = self.t4.is_heads_up
    local n = is_hu and #seat.hand or math.min(#seat.hand, MAX_BACKS)
    local scale_f = is_hu and BL.CARD_SCALE_F or (BL.CARD_SCALE_F * 0.85)
    
    while #seat.cards > n do local c = table.remove(seat.cards); pcall(go.delete, c.id) end
    while #seat.cards < n do
        local a = anchor_for(self, seat.slot)
        local rec = self.spawn_card(10, "H", vmath.vector3(a.x, a.y, BL.Z_HAND))
        go.set(rec.id, "scale", vmath.vector3(scale_f, scale_f, 1))
        self.set_back(rec)
        seat.cards[#seat.cards + 1] = rec
    end
    local slots = get_seat_slots(self, seat, n)
    for i, c in ipairs(seat.cards) do
        local s = slots[i]
        if s then
            local tp = vmath.vector3(s.x, s.y, s.z)
            if animate then
                go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, tp, go.EASING_OUTCUBIC, 0.25)
                go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, s.rot, go.EASING_OUTCUBIC, 0.25)
                go.animate(c.id, "scale", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(scale_f, scale_f, 1), go.EASING_OUTCUBIC, 0.25)
            else
                go.set_position(tp, c.id)
                go.set(c.id, "euler.z", s.rot)
                go.set(c.id, "scale", vmath.vector3(scale_f, scale_f, 1))
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
    if #self.deck >= 5 then return end
    if #self.played_cards <= 1 then return end
    
    local top = table.remove(self.played_cards)
    local to_shuffle = self.played_cards
    self.played_cards = { top }

    -- Bump BEFORE the z reset below — see card_view.lua's animate_to_pile,
    -- which checks this to avoid re-asserting a stale z on this exact card
    -- if its own fly-to-pile animation was still in flight when this ran.
    self.pile_gen = (self.pile_gen or 0) + 1
    go.set(top.id, "position.z", BL.Z_PILE)
    
    local data = {}
    for _, c in ipairs(to_shuffle) do data[#data + 1] = { v = c.v, s = c.s } end
    for _, c in ipairs(to_shuffle) do pcall(go.delete, c.id) end
    
    for i = #data, 2, -1 do local j = math.random(i); data[i], data[j] = data[j], data[i] end
    
    local dp = self.DECK_POS
    local new_deck = {}
    
    for i, d in ipairs(data) do
        local rec = self.spawn_card(d.v, d.s, vmath.vector3(self.CENTER.x, self.CENTER.y, BL.Z_PILE - 0.001))
        self.set_back(rec)
        go.set(rec.id, "euler.z", 0)
        new_deck[#new_deck + 1] = rec
    end
    
    for _, c in ipairs(self.deck) do
        new_deck[#new_deck + 1] = c
    end
    
    self.deck = new_deck
    
    for i, c in ipairs(self.deck) do
        local target_pos = vmath.vector3(dp.x + i * 0.5, dp.y - i * 0.5, i * 0.001)
        go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, target_pos, go.EASING_OUTCUBIC, 0.4)
        go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_OUTCUBIC, 0.4)
    end
    
    self.play_sound("SoundShuffle")
end

local function ai_draw(self, seat, n, done)
    local seq = self._seq
    local is_hu = self.t4.is_heads_up
    local scale_f = is_hu and BL.CARD_SCALE_F or (BL.CARD_SCALE_F * 0.85)

    for i = 1, n do
        local delay = (i - 1) * DEAL_STAGGER
        timer.delay(delay, false, function()
            if seq ~= self._seq then return end
            reshuffle_if_needed(self)
            local d = table.remove(self.deck)
            if not d then return end

            seat.hand[#seat.hand + 1] = { v = d.v, s = d.s }

            go.set(d.id, "scale", vmath.vector3(scale_f, scale_f, 1))
            go.set(d.id, "euler.z", 0)
            self.set_back(d)
            self.play_sound("SoundDraw")

            -- The drawn deck card BECOMES the seat's newest back and the whole
            -- hand fluidly re-organises into the arch — the same feel as the
            -- human draw: a card glides from the deck onto one end of the fan
            -- and the rest shift to make room. If the fan is already at its
            -- visible cap, retire this one to the deck side so layout doesn't
            -- cull a card mid-flight.
            local cap = is_hu and #seat.hand or MAX_BACKS
            if #seat.cards < cap then
                seat.cards[#seat.cards + 1] = d
                layout_seat(self, seat, true)
            else
                local a = anchor_for(self, seat.slot)
                go.animate(d.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(a.x, a.y, BL.Z_FLY), go.EASING_OUTCUBIC, 0.3, 0, function()
                    if seq ~= self._seq then return end
                    pcall(go.delete, d.id)
                    layout_seat(self, seat, true)
                end)
            end
            push_seat_hud(self, seat)
        end)
    end

    local total_duration = (n > 0 and (n - 1) * DEAL_STAGGER or 0) + 0.4
    timer.delay(total_duration, false, function()
        if seq == self._seq and done then done() end
    end)
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
        
        self.t4.turn_timer_seq = (self.t4.turn_timer_seq or 0) + 1
        local seq = self.t4.turn_timer_seq
        timer.delay(30.0, false, function()
            -- Belt-and-suspenders alongside game.script's t4_cancel_afk_timer
            -- (called the instant a tap is accepted, before turn_timer_seq
            -- would otherwise only bump once the play's animation/resolution
            -- fully lands): also refuse to fire while an action is already
            -- mid-flight, so a legal last-second play can never still get
            -- force-eliminated regardless of which path missed the bump.
            if seq == self.t4.turn_timer_seq and not self.game_over and self.t4.human_alive
                and not self.is_local_action_locked and not self.is_animating then
                notify(GUI_HUD, "t4_flash", { text = "TIME OUT!" })
                timer.delay(1.0, false, function()
                    if not self.game_over then 
                        notify(GUI_HUD, "t4_elimination_sequence", { worst_slot = seat.slot, worst_name = "YOU", worst_avatar = seat.avatar })
                        timer.delay(4.5, false, function() M.game_over_human_out(self, seat) end)
                    end
                end)
            end
        end)
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
    self.t4.turn_timer_seq = (self.t4.turn_timer_seq or 0) + 1
    
    if not self.chosen_suit or self.chosen_suit == "" then
        notify(GUI_HUD, "suit_badge", { suit = "" })
        notify(GUI_SUIT, "suit_select", { mode = "close" })
    end
    
    local top = self.played_cards[#self.played_cards]
    local is_cut = false
    if top and self.cutting_card then
        if tostring(top.v) == "7" then
            local cv = tonumber(self.cutting_card.v)
            if cv == 50 then
                -- Target is a Joker: cross-reference color instead of strict suit
                local cs = self.cutting_card.s
                local ts = top.s
                local cut_red = (cs == "H" or cs == "D" or cs == "R")
                local top_red = (ts == "H" or ts == "D")
                local cut_black = (cs == "S" or cs == "C" or cs == "B")
                local top_black = (ts == "S" or ts == "C")
                
                if (cut_red and top_red) or (cut_black and top_black) then
                    is_cut = true
                end
            elseif top.s == self.cutting_card.s then
                -- Target is a normal card: requires strict suit match
                is_cut = true
            end
        end
    end
    
    if is_cut then
        notify(GUI_HUD, "t4_flash", { text = "CUT!" })
        local seq = self._seq
        timer.delay(0.5, false, function()
            if seq == self._seq then M.finish_round(self, self.t4.turn_seat) end
        end)
        return
    end
    
    self.t4.turn_idx = step_index(self, self.t4.turn_idx)
    self.t4.turn_seat = self.t4.seats[self.t4.turn_idx]
    M.begin_turn(self)
end

function M.apply_skip(self, rec)
    local survivors = #alive_seats(self)
    if rec and tonumber(rec.v) == 11 and survivors > 2 then
        self.t4.direction = -(self.t4.direction or 1)
        notify(GUI_HUD, "t4_flash", { text = "REVERSE!" })
        M.advance(self)
    else
        self.t4.turn_idx = step_index(self, self.t4.turn_idx)
        M.advance(self)
    end
end

-- Card 1 (Hold On): the seat that just played takes another turn. Unlike
-- advance(), the turn index is NOT stepped, so the same seat plays again.
function M.apply_hold_on(self)
    if self.game_over or self.t4.revealing then return end
    self.current_turn_actions = {}
    if not self.chosen_suit or self.chosen_suit == "" then
        notify(GUI_HUD, "suit_badge", { suit = "" })
        notify(GUI_SUIT, "suit_select", { mode = "close" })
    end
    notify(GUI_HUD, "t4_flash", { text = "HOLD ON!" })
    M.begin_turn(self) -- self.t4.turn_seat is still the actor
end

-- Card 14 (General Market): every OTHER alive seat draws one card, then the
-- seat that played it goes again (like Hold On). Works for any opponent —
-- AI seats draw into seat.hand, the human seat draws into player_hand.
function M.apply_general_market(self, actor_seat)
    if self.game_over or self.t4.revealing then return end
    self.active_penalty = 0
    self.chosen_suit = ""
    notify(GUI_SUIT, "suit_select", { mode = "close" })
    notify(GUI_HUD, "t4_flash", { text = "GENERAL MARKET!" })

    actor_seat = actor_seat or self.t4.turn_seat

    -- Every OTHER alive seat draws 1 card, ONE AT A TIME in turn order —
    -- not all simultaneously — so the pickup reads as a clean cascading
    -- sequence instead of every hand flying in at once.
    local order = {}
    for _, s in ipairs(alive_seats(self)) do
        if s ~= actor_seat then order[#order + 1] = s end
    end

    local seq = self._seq
    local function draw_next(i)
        if seq ~= self._seq or self.game_over then return end
        local s = order[i]
        if not s then
            -- Everyone has drawn; the actor plays again.
            timer.delay(0.3, false, function()
                if seq == self._seq and not self.game_over then M.apply_hold_on(self) end
            end)
            return
        end
        local function advance() draw_next(i + 1) end
        if s.is_human and self.t4.human_alive then
            self.draw_to_hand(self.player_hand, true, 1, advance)
        else
            ai_draw(self, s, 1, advance)
        end
    end
    draw_next(1)
end

-- ── AI seat turn ─────────────────────────────────────────────────────────────
function M.ai_seat_turn(self, seat)
    if self.game_over or self.t4.revealing then return end
    local penalty = RE.get_active_penalty(self)

    local choice
    local best_score = -math.huge
    
    local next_idx = step_index(self, self.t4.turn_idx)
    local next_seat = self.t4.seats[next_idx]
    local next_hand_size = next_seat and #next_seat.hand or 5
    
    local top_card = self.played_cards[#self.played_cards]
    local current_card = top_card and {v = top_card.v, s = top_card.s} or nil
    
    local ai_state = {
        rules = Rules.RULES_JOKERS,
        currentCard = current_card,
        chosenSuit = self.chosen_suit,
        activePenaltyCount = penalty,
        next_player_cards = next_hand_size
    }

    for _, c in ipairs(seat.hand) do
        local res = RE.evaluate_play(self, c, seat.hand)
        if res.valid then 
            local score = AI.score_card(c, res.type, seat.hand, ai_state)
            if score > best_score then
                best_score = score
                choice = c
            end
        end
    end

    if not choice then
        local n = penalty > 0 and penalty or 1
        self.active_penalty = 0
        ai_draw(self, seat, n, function()
            M.advance(self)
        end)
        return
    end

    -- Evaluate the effect BEFORE animate_to_pile pushes it onto played_cards!
    -- This ensures we evaluate against the actual top card and not falsely
    -- trigger a same_value penalty match against itself.
    local result = RE.evaluate_play(self, choice, seat.hand)

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

    -- Penalties do NOT stack: the next player faces ONLY this card's penalty,
    -- exactly like the 2-player game (game_flow.after_play_settled).
    self.active_penalty = result.next_player_penalty_count or 0

    local NA = Rules.NextActionType
    if result.type == NA.CHOOSE_SUIT then
        self.chosen_suit = AI.best_suit_for_hand(seat.hand)
        notify(GUI_SUIT, "suit_select", { mode = "preview", suit = self.chosen_suit })
        notify(GUI_HUD, "suit_badge", { suit = self.chosen_suit })
        M.advance(self)
    elseif result.type == NA.HOLD_ON then
        -- Card 1: this seat plays again.
        self.chosen_suit = ""
        M.apply_hold_on(self)
    elseif result.type == NA.GENERAL_MARKET then
        -- Card 14: every other seat draws 1, then this seat plays again.
        M.apply_general_market(self, seat)
    elseif result.type == NA.SKIP_TURN then
        M.apply_skip(self, rec)
    elseif result.type == NA.REDUCE_PENALTY then
        -- Partial penalty: THIS player absorbs the balance by drawing it (just
        -- like 2-player); nothing is passed on to the next player.
        local remaining = result.current_penalty_count or 0
        self.active_penalty = 0
        self.chosen_suit = ""
        if remaining > 0 then
            ai_draw(self, seat, remaining, function() M.advance(self) end)
        else
            M.advance(self)
        end
    else
        -- default + TRANSFER_PENALTY: active_penalty already reflects this card.
        self.chosen_suit = ""
        M.advance(self)
    end
end

function M.human_finished(self)
    M.finish_round(self, self.t4.human_seat)
end

-- ── end-of-deal reveal + count + elimination ─────────────────────────────────
local function reveal_seat_faceup(self, seat)
    clear_cards(self, seat)
    local is_hu = self.t4.is_heads_up
    local scale_f = is_hu and BL.CARD_SCALE_F or (BL.CARD_SCALE_F * 0.85)
    local n = #seat.hand
    local cap = is_hu and n or math.min(n, MAX_BACKS + 4)
    local slots = get_seat_slots(self, seat, cap)
    for i = 1, cap do
        local card = seat.hand[i]
        local s = slots[i]
        local rec = self.spawn_card(card.v, card.s, vmath.vector3(s.x, s.y, s.z))
        go.set(rec.id, "scale", vmath.vector3(0.01, scale_f, 1))
        self.set_face(rec)
        go.animate(rec.id, "scale.x", go.PLAYBACK_ONCE_FORWARD, scale_f, go.EASING_OUTBACK, 0.3, i * 0.03)
        go.set(rec.id, "euler.z", s.rot)
        seat.cards[#seat.cards + 1] = rec
    end
end

local function collect_pile_to_deck(self)
    local dp = self.DECK_POS
    for i, c in ipairs(self.played_cards) do
        go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(dp.x + i * 0.5, dp.y - i * 0.5, BL.Z_PILE + i * 0.001), go.EASING_INOUTCUBIC, 0.4)
        go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_INOUTCUBIC, 0.4)
        go.animate(c.id, "scale", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE, go.EASING_INOUTCUBIC, 0.4)
    end
end

local function sweep_nodes_to_deck(self, nodes)
    local dp = self.DECK_POS
    for i, c in ipairs(nodes) do
        local id = c.id
        -- Slower, more deliberate sweep
        go.animate(id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(dp.x + i * 0.5, dp.y - i * 0.5, BL.Z_FLY + i * 0.001), go.EASING_INCUBIC, 0.4, i * 0.05)
        go.animate(id, "scale", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE, go.EASING_INSINE, 0.4, i * 0.05)
        -- delete UNCONDITIONALLY: a swept card must never survive into the next
        -- deal (guarding on self._seq here orphaned face-up cards on transition).
        timer.delay(0.45 + i * 0.05, false, function() pcall(go.delete, id) end)
    end
    for k = #nodes, 1, -1 do nodes[k] = nil end
end

-- Count ONE player at the centre of the table: their avatar slides in to a
-- counting podium, their cards fly into a row beside it one at a time while a
-- running score tallies up, then the avatar slides back to its seat.
local function count_one_seat(self, seat, done)
    local nodes = seat_nodes(self, seat)
    local n = #nodes
    local true_hand = (seat.is_human and self.t4.human_alive) and self.player_hand or seat.hand
    local real_score = 0
    for _, c in ipairs(true_hand) do real_score = real_score + get_card_value(c.v, c.s) end
    seat._count = 0

    -- bring this player's avatar in to the centre podium
    notify(GUI_HUD, "t4_count_focus", { slot = seat.slot, name = seat.name })

    local seq = self._seq
    local step = 46
    local row_cx = self.CENTER.x + 60
    local row_cy = self.CENTER.y

    -- nothing to count (the finisher, or an empty hand)
    if n == 0 then
        seat._count = real_score
        notify(GUI_HUD, "t4_count_tick", { slot = seat.slot, added_val = 0, total = real_score, cx = row_cx, cy = row_cy })
        timer.delay(1.0, false, function()
            if seq ~= self._seq then return end
            notify(GUI_HUD, "t4_count_unfocus", { slot = seat.slot })
            timer.delay(0.5, false, function() if seq == self._seq and done then done() end end)
        end)
        return
    end

    -- let the avatar settle on the podium before the cards come in
    timer.delay(0.55, false, function()
        if seq ~= self._seq then return end
        local k = 0
        local function fly_one()
            k = k + 1
            if k > n then
                seat._count = math.max(seat._count, real_score)
                timer.delay(1.0, false, function()
                    if seq ~= self._seq then return end
                    sweep_nodes_to_deck(self, nodes)
                    notify(GUI_HUD, "t4_count_unfocus", { slot = seat.slot })
                    timer.delay(0.6, false, function() if seq == self._seq and done then done() end end)
                end)
                return
            end
            local c = nodes[k]
            local data_c = true_hand[k]
            local val = data_c and get_card_value(data_c.v, data_c.s) or 0
            -- fold any over-cap cards (rare big hands) into the last visible card
            if k == n and #true_hand > n then
                for i = n + 1, #true_hand do val = val + get_card_value(true_hand[i].v, true_hand[i].s) end
            end
            seat._count = seat._count + val

            local cx = row_cx - ((n - 1) * step) / 2.0 + (k - 1) * step
            local cy = row_cy
            local z = BL.Z_FLY + k * 0.002
            go.set(c.id, "position.z", z)
            go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_OUTSINE, 0.4)
            go.animate(c.id, "scale", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE, go.EASING_OUTSINE, 0.4)
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(cx, cy, z), go.EASING_OUTCUBIC, 0.4, 0, function()
                if seq ~= self._seq then return end
                go.animate(c.id, "scale", go.PLAYBACK_ONCE_PINGPONG, vmath.vector3(BL.CARD_SCALE_F * 1.12, BL.CARD_SCALE_F * 1.12, 1), go.EASING_INOUTSINE, 0.12)
            end)
            self.play_sound("SoundPick")
            notify(GUI_HUD, "t4_count_tick", { slot = seat.slot, added_val = val, total = seat._count, cx = cx, cy = cy })
            timer.delay(0.42, false, function() if seq == self._seq then fly_one() end end)
        end
        fly_one()
    end)
end

local function count_seats(self, list, idx, done)
    if idx > #list then if done then done() end return end
    local seat = list[idx]
    notify(GUI_HUD, "t4_count", { slot = seat.slot })   -- pulse the seat avatar before it travels in
    local seq = self._seq
    timer.delay(0.45, false, function()
        if seq ~= self._seq then return end
        count_one_seat(self, seat, function() count_seats(self, list, idx + 1, done) end)
    end)
end

local function eliminate_seat(self, worst, finisher)
    if worst then worst.eliminated = true end
    local survivors = alive_seats(self)

    if worst then
        notify(GUI_HUD, "t4_elimination_sequence", { worst_slot = worst.slot, worst_name = worst.name, worst_avatar = worst.avatar })
    end

    local seq = self._seq
    if worst and worst.is_human then
        timer.delay(4.5, false, function() if seq == self._seq then M.game_over_human_out(self, finisher) end end)
        return
    end

    timer.delay(4.5, false, function()
        if seq ~= self._seq then return end
        if #survivors <= 1 then M.crown(self, survivors[1] or finisher) else M.deal_round(self) end
    end)
end

function M.finish_round(self, finisher)
    if self.t4.revealing then return end
    self.t4.revealing = true
    self.game_over = true
    notify(GUI_HUD, "stop_timers")
    notify(GUI_HUD, "t4_active", { slot = "none" })

    -- Reveal + count EVERY surviving hand, including the seat that ENDED the
    -- round. A normal finisher emptied their hand (counts 0 and stays safe); a
    -- CUT ends the round with the cutter still holding cards, which must be
    -- counted and added to the board too.
    for _, seat in ipairs(alive_seats(self)) do
        if not (seat.is_human and self.t4.human_alive) then reveal_seat_faceup(self, seat) end
        push_seat_hud(self, seat)
    end

    collect_pile_to_deck(self)

    local counters = {}
    for _, s in ipairs(alive_seats(self)) do counters[#counters + 1] = s end

    local seq = self._seq
    timer.delay(0.7, false, function()
        if seq ~= self._seq then return end
        count_seats(self, counters, 1, function()
            -- Elimination Chamber: add this deal to every running total and
            -- knock out whoever has hit the score cap.
            if self.t4.chamber then
                M.chamber_resolve(self, finisher)
                return
            end

            -- Quick Bracket: the single most-cards seat leaves the table.
            local worst, worst_n = nil, -1
            for _, s in ipairs(counters) do
                local c = s._count or 0
                if c > worst_n then worst_n, worst = c, s end
            end

            local min_score = math.huge
            local next_opener = nil
            for _, s in ipairs(alive_seats(self)) do
                if s ~= worst then
                    local c = s._count or 0
                    if c < min_score then
                        min_score = c
                        next_opener = s
                    end
                end
            end
            self.t4.next_opener = next_opener

            eliminate_seat(self, worst, finisher)
        end)
    end)
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

function M.game_over_human_out(self, finisher)
    self.t4.revealing = false
    -- Unlike finish_round (a normal round end), this path is reached
    -- directly from an AFK timeout / elimination-chamber cutoff without ever
    -- setting self.game_over — so board/hand cards stayed fully tappable
    -- behind the game-over modal whenever the human lost this way.
    self.game_over = true
    notify(GUI_OVER, "game_over", {
        won = false, player_score = 0, ai_score = 0,
        is_cut = false, series_active = false, series_over = true,
        t4_human_out = true,
    })
    self.play_sound("SoundLose")
end

-- ── Elimination Chamber resolution ───────────────────────────────────────────
local function lowest_total_seat(list)
    local lo, best = math.huge, nil
    for _, s in ipairs(list) do
        if (s.total or 0) < lo then lo, best = s.total or 0, s end
    end
    return best
end

local function list_has_human(list)
    for _, s in ipairs(list) do if s.is_human then return true end end
    return false
end

-- Each deal's hand value is ADDED to every alive seat's running total (a normal
-- finisher adds 0; a cutter adds the cards still in hand). Anyone who reaches
-- the score cap leaves. If EVERY remaining player crosses the cap in the same
-- deal, the LOWEST cumulative total (count + history) wins — "whoever makes the
-- less count wins it".
function M.chamber_resolve(self, finisher)
    for _, s in ipairs(alive_seats(self)) do
        s.total = (s.total or 0) + (s._count or 0)
        notify(GUI_HUD, "t4_chamber_update", {
            name = s.name, added = s._count or 0, total = s.total,
            threshold = self.t4.threshold,
            eliminated = (s.total >= self.t4.threshold),
        })
    end
    -- This round's totals are now final — reorder the board once, here,
    -- rather than on every incidental score update.
    notify(GUI_HUD, "t4_chamber_reflow", {})

    local seq = self._seq
    timer.delay(2.0, false, function()
        if seq ~= self._seq then return end

        local crossed, survivors = {}, {}
        for _, s in ipairs(alive_seats(self)) do
            if (s.total or 0) >= self.t4.threshold then crossed[#crossed + 1] = s
            else survivors[#survivors + 1] = s end
        end

        if #crossed == 0 then
            -- nobody crossed the cap: the lowest total opens the next deal
            self.t4.next_opener = lowest_total_seat(alive_seats(self))
            M.deal_round(self)
            return
        end

        if #survivors == 0 then
            -- EVERYONE hit the cap together (e.g. a cut in the 2-player endgame):
            -- the lowest total is the champion, the rest leave the table.
            local champ = lowest_total_seat(crossed)
            local losers = {}
            for _, s in ipairs(crossed) do if s ~= champ then losers[#losers + 1] = s end end
            M.chamber_eliminate(self, losers, 1, finisher, champ)
            return
        end

        -- Some survive: the crossers leave; the survivors play on.
        if list_has_human(crossed) then
            for _, s in ipairs(crossed) do s.eliminated = true end
            local hs = self.t4.human_seat
            notify(GUI_HUD, "t4_elimination_sequence", { worst_slot = hs.slot, worst_name = "YOU", worst_avatar = hs.avatar })
            timer.delay(4.0, false, function() if seq == self._seq then M.game_over_human_out(self, finisher) end end)
            return
        end
        M.chamber_eliminate(self, crossed, 1, finisher)
    end)
end

function M.chamber_eliminate(self, list, idx, finisher, final_champ)
    if idx > #list then
        if final_champ then M.crown(self, final_champ); return end
        local alive = alive_seats(self)
        if #alive <= 1 then M.crown(self, alive[1] or finisher); return end
        -- lowest cumulative total opens the next deal
        self.t4.next_opener = lowest_total_seat(alive)
        M.deal_round(self)
        return
    end
    local s = list[idx]
    s.eliminated = true
    notify(GUI_HUD, "t4_elimination_sequence", { worst_slot = s.slot, worst_name = s.name, worst_avatar = s.avatar })
    local seq = self._seq
    timer.delay(2.6, false, function()
        if seq == self._seq then M.chamber_eliminate(self, list, idx + 1, finisher, final_champ) end
    end)
end

local function assign_slots(self)
    local survivors = alive_seats(self)
    local human_alive = false
    for _, s in ipairs(survivors) do if s.is_human then human_alive = true end end
    self.t4.human_alive = human_alive

    local ordered = {}
    if human_alive then for _, s in ipairs(survivors) do if s.is_human then ordered[#ordered + 1] = s end end end
    for _, s in ipairs(survivors) do if not s.is_human then ordered[#ordered + 1] = s end end

    local layouts = {
        [2] = { "bottom", "top" },
        [3] = { "bottom", "left", "right" },
        [4] = { "bottom", "left", "top", "right" },
    }
    local plan = layouts[#ordered] or layouts[4]
    for i, s in ipairs(ordered) do s.slot = plan[i] or "top" end
end

local function deal_card_to_seat(self, seat, card, k, delay, slot_data)
    local seq = self._seq
    go.set_position(vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_FLY), card.id)
    if seat.is_human and self.t4.human_alive then
        table.insert(self.player_hand, card)
        local sl = slot_data[k] or slot_data[#slot_data]
        go.animate(card.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(sl.x, sl.y, sl.z), go.EASING_OUTCUBIC, 0.3, delay)
        go.animate(card.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, sl.rot or 0, go.EASING_OUTCUBIC, 0.3, delay)
        timer.delay(delay, false, function() if seq == self._seq then self.play_sound("SoundDraw") end end)
        timer.delay(delay + 0.15, false, function() if seq == self._seq then self.set_face(card) end end)
    else
        seat.hand[#seat.hand + 1] = { v = card.v, s = card.s }
        seat.cards[#seat.cards + 1] = card
        
        local is_hu = self.t4.is_heads_up
        local scale_f = is_hu and BL.CARD_SCALE_F or (BL.CARD_SCALE_F * 0.85)
        
        go.set(card.id, "scale", vmath.vector3(BL.CARD_SCALE_F, BL.CARD_SCALE_F, 1))
        self.set_back(card)
        local sl = slot_data[k] or { x = self.CENTER.x, y = self.CENTER.y, rot = base_rot(seat.slot), z = BL.Z_HAND }
        
        go.animate(card.id, "scale", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(scale_f, scale_f, 1), go.EASING_OUTCUBIC, 0.3, delay)
        go.animate(card.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(sl.x, sl.y, sl.z), go.EASING_OUTCUBIC, 0.3, delay)
        go.animate(card.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, sl.rot, go.EASING_OUTCUBIC, 0.3, delay)
        timer.delay(delay, false, function() if seq == self._seq then self.play_sound("SoundDraw") end end)
    end
end

function M.deal_round(self)
    self.t4.revealing = false
    self.game_over = false
    self._seq = (self._seq or 0) + 1
    local seq = self._seq

    if self.cutting_card then pcall(go.delete, self.cutting_card.id); self.cutting_card = nil end
    for _, c in ipairs(self.player_hand) do pcall(go.delete, c.id) end
    for _, c in ipairs(self.played_cards) do pcall(go.delete, c.id) end
    for _, c in ipairs(self.deck) do pcall(go.delete, c.id) end
    self.player_hand, self.played_cards, self.deck = {}, {}, {}
    for _, s in ipairs(self.t4.seats) do clear_cards(self, s); s.hand = {} end

    self.active_penalty, self.chosen_suit = 0, ""
    self.is_animating, self.is_local_action_locked, self.player_has_drawn = true, false, false
    self.t4.direction = 1

    assign_slots(self)

    local survivors = alive_seats(self)
    self.t4.is_heads_up = (#survivors == 2)
    BL.update_layout(self)

    -- Wipe the old per-seat badges (slots are reassigned as the table collapses)
    -- and rebuild them at their NEW seat positions, so none linger on the wrong
    -- seat or with a stale avatar. The graveyard is preserved.
    notify(GUI_HUD, "t4_clear", {})
    for _, s in ipairs(survivors) do push_seat_hud(self, s) end

    local stage = "QUARTER FINALS"
    if #survivors == 3 then stage = "SEMI FINALS"
    elseif #survivors == 2 then stage = "FINALS" end
    notify(GUI_HUD, "t4_flash", { text = stage })

    local data = deck.build()
    for i = #data, 2, -1 do local j = math.random(i); data[i], data[j] = data[j], data[i] end
    local pool = {}
    for i, d in ipairs(data) do
        pool[i] = self.spawn_card(d.v, d.s, vmath.vector3(self.CENTER.x, self.CENTER.y, i * 0.001))
    end

    local all_slots = {}
    for _, s in ipairs(survivors) do
        all_slots[s] = get_seat_slots(self, s, HAND_SIZE)
    end

    self.animate_shuffle(pool, function()
        if seq ~= self._seq then return end
        local delay = 0.0
        local counts = {}
        for _, s in ipairs(survivors) do counts[s] = 0 end
        for _ = 1, HAND_SIZE do
            for _, s in ipairs(survivors) do
                local card = table.remove(pool)
                counts[s] = counts[s] + 1
                deal_card_to_seat(self, s, card, counts[s], delay, all_slots[s])
                delay = delay + DEAL_STAGGER
            end
        end

        local dp = self.DECK_POS
        delay = delay + 0.42
        
        if GameMode.is_whot() then
            -- WHOT: no cutting card. Flip a NORMAL starter card face-up into the
            -- CENTRE pile so the first player must match it by shape or number.
            -- A normal card is never 1/2/5/8/14/20 (power/wild cards).
            self.cutting_card = nil
            if #pool > 0 then
                local function is_special_start(c)
                    local v = tonumber(c.v)
                    return v == 1 or v == 2 or v == 5 or v == 8 or v == 14 or v == 20 or c.s == "W"
                end
                local sidx = 1
                for i, c in ipairs(pool) do
                    if not is_special_start(c) then sidx = i; break end
                end
                local starter = table.remove(pool, sidx)
                -- animate_to_pile faces it up, inserts it as the first played card
                -- and lands it in the centre.
                timer.delay(delay + 0.15, false, function()
                    if seq == self._seq then self.animate_to_pile(starter, false, nil) end
                end)
            end
        elseif #pool > 0 then
            -- MATATU/KADI: park the first non-7 beside the deck as the CUTTING
            -- CARD (the classic pre-Whot deal, restored).
            local cut_idx = 1
            for i, c in ipairs(pool) do
                if tostring(c.v) ~= "7" then
                    cut_idx = i
                    break
                end
            end

            self.cutting_card = table.remove(pool, cut_idx)

            go.set(self.cutting_card.id, "position.z", BL.Z_CUT)
            go.animate(self.cutting_card.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(dp.x + BL.CUTTING_CARD_OFFSET_X, dp.y, BL.Z_CUT), go.EASING_OUTCUBIC, 0.5, delay)
            go.animate(self.cutting_card.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 90, go.EASING_OUTCUBIC, 0.5, delay)
            timer.delay(delay + 0.15, false, function() if seq == self._seq then self.set_face(self.cutting_card) end end)
        end

        for i, c in ipairs(pool) do
            self.deck[#self.deck + 1] = c
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(dp.x + i * 0.5, dp.y - i * 0.5, i * 0.001), go.EASING_OUTCUBIC, 0.5, delay)
            go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_OUTCUBIC, 0.5, delay)
        end
        timer.delay(delay, false, function() if seq == self._seq then self.play_sound("MoveDeck") end end)
        delay = delay + 0.55

        self.t4.round = (self.t4.round or 0) + 1
        
        if self.t4.next_opener then
            for i, s in ipairs(self.t4.seats) do
                if s == self.t4.next_opener then
                    self.t4.opener_idx = i
                    break
                end
            end
            self.t4.next_opener = nil
        end
        
        local opener = self.t4.opener_idx or 1
        while self.t4.seats[opener].eliminated do opener = step_index(self, opener) end
        self.t4.turn_idx = opener
        self.t4.turn_seat = self.t4.seats[opener]
        self.t4.opener_idx = opener

        timer.delay(delay + 0.2, false, function()
            if seq ~= self._seq then return end
            self.is_animating = false
            M.begin_turn(self)
        end)
    end)
end

-- rows describing every seat's cumulative standing (Elimination Chamber).
local function chamber_rows(self)
    local rows = {}
    for _, s in ipairs(self.t4.seats) do
        rows[#rows + 1] = { slot = s.slot, name = s.name, avatar = s.avatar, total = s.total or 0, eliminated = s.eliminated and true or false }
    end
    return rows
end

function M.start(self, me, opts)
    opts = opts or {}
    self._seq = (self._seq or 0) + 1
    self.online_mode = false

    self.t4 = {
        round = 0, opener_idx = math.random(1, 4), direction = 1, human_alive = true,
        chamber = opts.chamber and true or false,
        threshold = tonumber(opts.threshold) or 100,
    }

    local human = { is_human = true, name = (me and me.username) or "You", avatar = (me and me.avatar) or 1, slot = "bottom", eliminated = false, hand = {}, cards = {}, total = 0 }
    self.t4.human_seat = human
    self.t4.seats = {
        human,
        { is_human = false, name = AI_NAMES[1], avatar = AI_AVATARS[1], slot = "left",  eliminated = false, hand = {}, cards = {}, total = 0 },
        { is_human = false, name = AI_NAMES[2], avatar = AI_AVATARS[2], slot = "top",   eliminated = false, hand = {}, cards = {}, total = 0 },
        { is_human = false, name = AI_NAMES[3], avatar = AI_AVATARS[3], slot = "right", eliminated = false, hand = {}, cards = {}, total = 0 },
    }

    notify(GUI_HUD, "t4_mode", { on = true })

    -- Ensure fresh slate for the avatars when launching new tournament
    notify(GUI_HUD, "t4_clear", {})

    -- Elimination Chamber: stand up the all-time score table.
    if self.t4.chamber then
        notify(GUI_HUD, "t4_chamber_init", { threshold = self.t4.threshold, rows = chamber_rows(self) })
    end

    M.deal_round(self)
end

return M