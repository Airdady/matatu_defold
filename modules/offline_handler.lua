local AI    = require "modules.ai_player"
local Defs  = require "modules.card_defs"
local Rules = require "modules.card_rules"
local app   = require "modules.app_state"

local GUI_HUD   = "#game"
local GUI_SUIT  = "#suit_select"
local GUI_OVER  = "#gameover"

local DEAL_DELAY = 0.10
local CUTTING_CARD_OFFSET_X = -60
local PLAY_TIMEOUT_DURATION_S = 30.0

local M = {}

function M.ai_hand_data(hand)
    local t = {}
    for _, c in ipairs(hand) do t[#t + 1] = { v = c.v, s = c.s } end
    return t
end

-- Offline CPU Intelligence execution tree
function M.do_ai_turn(self, is_combo)
    if self.game_over or self.online_mode then return end
    local think = is_combo and (0.25 + math.random() * 0.25) or (1.0 + math.random() * 0.8)
    local seq = self._seq
    
    timer.delay(think, false, function()
        if seq ~= self._seq or self.game_over then return end

        local resp = nil
        local cut_idx = nil
        if self.cutting_card then
            for i, c in ipairs(self.ai_hand) do
                if self.is_cutting_match(c) then cut_idx = i; break end
            end
        end

        if cut_idx and self.hand_score(self.ai_hand) <= 25 then
            resp = { kind = "play", index = cut_idx }
        else
            local tp = self.top_played()
            local prev_data = tp and { v = tp.v, s = tp.s } or {}
            local state = {
                rules = Rules.RULES_JOKERS,
                currentCard = prev_data,
                chosenSuit = self.chosen_suit,
                activePenaltyCount = self.active_penalty,
            }
            resp = AI.decide(state, M.ai_hand_data(self.ai_hand), false)

            if not tp and resp.kind ~= "play" then
                resp = { kind = "play", index = 1 }
            end
        end

        if resp.kind == "draw" then
            if self.active_penalty > 0 then
                local n = self.active_penalty; self.active_penalty = 0
                self.draw_to_hand(self.ai_hand, false, n, function() self.next_turn() end)
            else
                self.draw_to_hand(self.ai_hand, false, 1, function()
                    local cut_idx2 = nil
                    if self.cutting_card then
                        for i, c in ipairs(self.ai_hand) do
                            if self.is_cutting_match(c) then cut_idx2 = i; break end
                        end
                    end
                    local r2 = nil
                    if cut_idx2 and self.hand_score(self.ai_hand) <= 25 then
                        r2 = { kind = "play", index = cut_idx2 }
                    else
                        local s2 = { rules = Rules.RULES_JOKERS, currentCard = self.top_played(),
                            chosenSuit = self.chosen_suit, activePenaltyCount = self.active_penalty }
                        r2 = AI.decide(s2, M.ai_hand_data(self.ai_hand), true)
                    end
                    if r2.kind == "play" then
                        local rec = self.ai_hand[r2.index]
                        if rec then
                            local rule = self.evaluate_play(rec, self.ai_hand)
                            timer.delay(0.6, false, function() if seq == self._seq then self.play_card(rec, false, rule) end end)
                        else self.next_turn() end
                    else self.next_turn() end
                end)
            end
            return
        end

        if resp.kind == "pass" then self.next_turn(); return end

        local rec = self.ai_hand[resp.index]
        if rec then
            local rule = self.evaluate_play(rec, self.ai_hand)
            self.play_card(rec, false, rule)
        else
            self.next_turn()
        end
    end)
end

function M.do_suit_choice(self)
    local chosen = AI.best_suit_for_hand(self.ai_hand)
    if not chosen or chosen == "" then chosen = "H" end
    self.chosen_suit = chosen
    print("Whot Game: Opponent calls " .. Defs.suit_name(chosen))
    self.play_sound("SoundRequestSuit")
    msg.post(GUI_SUIT, "suit_select", { mode = "preview", suit = chosen })
    self.next_turn()
end

function M.build_and_deal(self)
    self.is_animating = true
    local raw = Defs.build_deck()
    
    local function init_shuffle(list)
        for i = #list, 2, -1 do
            local j = math.random(i)
            list[i], list[j] = list[j], list[i]
        end
    end
    init_shuffle(raw)
    
    for i, cd in ipairs(raw) do
        local rec = self.spawn_card(cd.v, cd.s, vmath.vector3(self.CENTER.x, self.CENTER.y, i * 0.001))
        table.insert(self.deck, rec)
    end

    local seq = self._seq
    self.animate_shuffle(self.deck, function()
        if seq ~= self._seq then return end
        local delay = 0.0
        local p_spacing = self.calc_spacing(7)
        local a_spacing = self.calc_spacing(7)
        local p_start = self.CENTER.x - (6 * p_spacing) / 2.0
        local a_start = self.CENTER.x - (6 * a_spacing) / 2.0

        for i = 1, 7 do
            local pc = table.remove(self.deck)
            table.insert(self.player_hand, pc)
            local pt = vmath.vector3(p_start + (#self.player_hand - 1) * p_spacing, self.PLAYER_HAND_Y, self.Z_HAND + i * 0.001)
            go.set_position(vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_FLY), pc.id)
            go.animate(pc.id, "position", go.PLAYBACK_ONCE_FORWARD, pt, go.EASING_OUTCUBIC, 0.3, delay)
            timer.delay(delay, false, function() if seq == self._seq then self.play_sound("SoundDraw") end end)
            timer.delay(delay + 0.15, false, function() if seq == self._seq then self.set_face(pc) end end)
            delay = delay + DEAL_DELAY

            local ac = table.remove(self.deck)
            table.insert(self.ai_hand, ac)
            local at = vmath.vector3(a_start + (#self.ai_hand - 1) * a_spacing, self.AI_HAND_Y, self.Z_HAND + i * 0.001)
            go.set_position(vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_FLY), ac.id)
            go.animate(ac.id, "position", go.PLAYBACK_ONCE_FORWARD, at, go.EASING_OUTCUBIC, 0.3, delay)
            timer.delay(delay, false, function() if seq == self._seq then self.play_sound("SoundDraw") end end)
            delay = delay + DEAL_DELAY
        end

        -- WHOT: there is no "cutting card". Flip a NORMAL starter card face-up
        -- into the CENTRE discard pile, so the first player must match it by
        -- shape or number. A normal card is anything that is NOT a power/wild
        -- card: 1 (Hold On), 2 (Pick Two), 5 (Pick Three), 8 (Suspension),
        -- 14 (General Market) or 20 (Whot).
        self.cutting_card = nil
        local function is_special_start(c)
            local v = tonumber(c.v)
            return v == 1 or v == 2 or v == 5 or v == 8 or v == 14 or v == 20 or c.s == "W"
        end
        local start_idx = nil
        for i, c in ipairs(self.deck) do
            if not is_special_start(c) then start_idx = i; break end
        end
        start_idx = start_idx or 1
        local starter = table.remove(self.deck, start_idx)
        -- animate_to_pile faces the card up, inserts it as the first played
        -- card and lands it in the centre.
        timer.delay(delay + 0.15, false, function()
            if seq == self._seq then self.animate_to_pile(starter, false, nil) end
        end)
        delay = delay + 0.5

        for i, c in ipairs(self.deck) do
            local t = vmath.vector3(self.DECK_POS.x + i * 0.5, self.DECK_POS.y - i * 0.5, i * 0.001)
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, t, go.EASING_OUTCUBIC, 0.55, delay)
        end
        timer.delay(delay, false, function() if seq == self._seq then self.play_sound("MoveDeck") end end)
        delay = delay + 0.55

        timer.delay(delay, false, function()
            if seq ~= self._seq then return end
            self.is_animating = false
            -- Settle both hands into their arched / fanned layout right away so the
            -- curve is there from the first frame of play (the deal above lays the
            -- cards out flat).
            self.position_hands(true)
            local duration = PLAY_TIMEOUT_DURATION_S
            local local_expires_at = (socket.gettime() * 1000) + (duration * 1000)
            msg.post(GUI_HUD, "turn", { who = self.current_turn, duration = duration, expires_at = local_expires_at })
            if self.current_turn == "ai" then M.do_ai_turn(self, false) end
        end)
    end)
end

function M.start_game(self)
    local prev = "ai"
    local ok, data = pcall(sys.load, sys.get_save_file("matatu_defold_state", "state"))
    if ok and data and data.last_starter then prev = data.last_starter end
    self.current_turn = (prev == "ai") and "player" or "ai"
    pcall(sys.save, sys.get_save_file("matatu_defold_state", "state"), { last_starter = self.current_turn })

    if app.last_offline_game_ref ~= app.offline_game then
        app.last_offline_game_ref = app.offline_game
        app.series_p_wins = 0
        app.series_ai_wins = 0
    end
    
    local series = 1
    if app.offline_game then
        series = app.offline_game.series or (app.offline_game.config and app.offline_game.config.series) or app.ai_series or 1
    end
    
    if series > 1 then
        msg.post(GUI_HUD, "update_scoreboard", { 
            show = true, 
            p_score = app.series_p_wins or 0, 
            o_score = app.series_ai_wins or 0, 
            best_of = series 
        })
    else
        msg.post(GUI_HUD, "update_scoreboard", { show = false })
    end

    print("Whot Game: Game started — Whot (Offline).")
    M.build_and_deal(self)
end

function M.next_turn(self)
    self.current_turn_actions = {}
    self.player_has_drawn = false
    msg.post(GUI_HUD, "skip", { show = false })

    self.current_turn = (self.current_turn == "player") and "ai" or "player"
    local duration = PLAY_TIMEOUT_DURATION_S
    local local_expires_at = (socket.gettime() * 1000) + (duration * 1000)
    msg.post(GUI_HUD, "turn", { who = self.current_turn, duration = duration, expires_at = local_expires_at })

    self.turn_count = (self.turn_count or 0) + 1
    if self.turn_count > 600 then
        print("Whot Game: Game length limit — lowest score wins.")
        self.end_game(nil, true)
        return
    end

    local hand = (self.current_turn == "player") and self.player_hand or self.ai_hand
    local can_draw = #self.deck > 0 or #self.played_cards > 1
    local can_act = self.has_playable(hand) or can_draw

    if not can_act then
        self.stuck_count = (self.stuck_count or 0) + 1
        if self.stuck_count >= 2 then
            print("Whot Game: Stalemate — lowest score wins.")
            self.end_game(nil, true)
            return
        end
        print("Whot Game: " .. (self.current_turn == "player" and "You have" or "Opponent has") .. " no move — pass.")
        local seq = self._seq
        timer.delay(0.6, false, function() if seq == self._seq then self.next_turn() end end)
        return
    end
    
    self.stuck_count = 0
    if self.current_turn == "ai" then M.do_ai_turn(self, false) end
end

-- Tally the best of 3/5 matches purely for offline
function M.evaluate_series(self, player_won)
    local is_series_active = false
    local is_series_over = true

    local series = 1
    if app.offline_game then
        series = app.offline_game.series or (app.offline_game.config and app.offline_game.config.series) or app.ai_series or 1
    end

    if series > 1 then
        is_series_active = true
        if player_won then
            app.series_p_wins = (app.series_p_wins or 0) + 1
        else
            app.series_ai_wins = (app.series_ai_wins or 0) + 1
        end

        local p_wins = app.series_p_wins
        local ai_wins = app.series_ai_wins
        local target = math.floor(series / 2) + 1

        msg.post(GUI_HUD, "update_scoreboard", { show = true, p_score = p_wins, o_score = ai_wins, best_of = series })

        if p_wins >= target or ai_wins >= target then
            is_series_over = true
            player_won = p_wins >= target
        else
            is_series_over = false
        end
    end
    
    return is_series_active, is_series_over, player_won
end

return M