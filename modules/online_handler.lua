local ws = require "modules.websocket_manager"
local Defs = require "modules.card_defs"

local GUI_HUD   = "#game"
local GUI_SUIT  = "#suit_select"
local GUI_OVER  = "#gameover"

local PLAY_TIMEOUT_DURATION_S = 30.0
local DEAL_DELAY = 0.10
local CUTTING_CARD_OFFSET_X = -60

local M = {}

function M.sync_timers(self, state)
    if self.game_over then return end
    state = state or {}

    if type(self.game_state) ~= "table" then self.game_state = {} end
    if state.currentTurn        ~= nil then self.game_state.currentTurn        = state.currentTurn end
    if state.turnExpiresAt      ~= nil then self.game_state.turnExpiresAt      = state.turnExpiresAt end
    if state.activePenaltyCount ~= nil then self.game_state.activePenaltyCount = state.activePenaltyCount end
    if state.chosenSuit         ~= nil then self.game_state.chosenSuit         = state.chosenSuit end

    local current_turn = state.currentTurn or ""
    local expires_at   = state.turnExpiresAt or 0
    local now_ms       = socket.gettime() * 1000.0

    local duration = state.totalTurnTime or state.turnTimeLeft or PLAY_TIMEOUT_DURATION_S

    if state.activePenaltyCount ~= nil then
        self.active_penalty = state.activePenaltyCount or 0
    end

    if expires_at == 0 then
        expires_at = now_ms + (duration * 1000)
    end

    local remaining_sec = math.max(0, (expires_at - now_ms) / 1000.0)
    if remaining_sec > duration + 2.0 then
        expires_at = now_ms + (duration * 1000)
    end

    if tostring(current_turn) == tostring(self.my_player_id) then
        self.current_turn = "player"
        self.waiting = false
        msg.post(GUI_HUD, "turn", { who = "player", duration = duration, expires_at = expires_at })
    elseif current_turn ~= nil and tostring(current_turn) ~= "" then
        self.current_turn = "ai"
        self.waiting = true
        msg.post(GUI_HUD, "turn", { who = "ai", duration = duration, expires_at = 0 })
    else
        msg.post(GUI_HUD, "stop_timers")
    end
end

function M.end_turn(self)
    if not self.online_mode then return end

    local actions_to_send = {}
    local last_card = nil

    for i, act in ipairs(self.current_turn_actions) do
        if act.type == "PLAY" or act.type == "DRAW" then
            table.insert(actions_to_send, act)
        end
        if act.type == "PLAY" then last_card = act end
    end

    if last_card then
        self.last_local_play = { v = tonumber(last_card.v), s = last_card.s }
    end

    ws.send_move(self.online_game_id, self.my_player_id, self.opponent_id,
        actions_to_send, self.chosen_suit, self.active_penalty)

    self.waiting = true
    self.is_waiting_for_server_response = true

    self.current_turn = "ai"
    msg.post(GUI_HUD, "turn", { who = "ai", duration = PLAY_TIMEOUT_DURATION_S, expires_at = 0 })

    self.current_turn_actions = {}
end

function M.sync_deck_size(self, target_size)
    if not target_size then return end
    if #self.deck < target_size then
        local diff = target_size - #self.deck
        for i = 1, diff do
            local idx = #self.deck + 1
            local c = self.spawn_card(10, "H", vmath.vector3(self.DECK_POS.x + idx * 0.5, self.DECK_POS.y - idx * 0.5, idx * 0.001))
            table.insert(self.deck, c)
        end
    elseif #self.deck > target_size then
        local diff = #self.deck - target_size
        for i = 1, diff do
            local c = table.remove(self.deck, 1)
            pcall(go.delete, c.id)
        end
    end
end

function M.process_scoreboard(self, state)
    if state.tournamentScore then
        local ts = state.tournamentScore
        local format = tonumber(ts.matchFormat) or 3
        local scores = ts.scores or {}
        local p_score = tonumber(scores[self.my_player_id]) or 0
        local o_score = tonumber(scores[self.opponent_id]) or 0
        msg.post(GUI_HUD, "update_scoreboard", { show = true, p_score = p_score, o_score = o_score, best_of = format })
    elseif state.matchFormat then
        local format = tonumber(state.matchFormat) or 3
        msg.post(GUI_HUD, "update_scoreboard", { show = true, p_score = 0, o_score = 0, best_of = format })
    else
        msg.post(GUI_HUD, "update_scoreboard", { show = false })
    end
end

function M.setup_ws_listeners(self)
    if self.ws_listeners then
        for _, token in ipairs(self.ws_listeners) do ws.off(token) end
    end
    self.ws_listeners = {}

    table.insert(self.ws_listeners, ws.on("game_move", function(move_data, gs)
        ws.queue_move(move_data, gs)
        msg.post("#", "ws_game_move")
    end))
    table.insert(self.ws_listeners, ws.on("timer_update", function(d)
        msg.post("#", "ws_timer_update", { data = d })
    end))
    table.insert(self.ws_listeners, ws.on("game_over", function(results)
        ws.last_game_over = results or {}
        msg.post("#", "ws_game_over")
    end))
    table.insert(self.ws_listeners, ws.on("network_quality", function(d)
        msg.post("#", "ws_network_quality", d)
    end))

    table.insert(self.ws_listeners, ws.on("game_start", function(gs)
        if type(gs) ~= "table" or next(gs) == nil then return end
        local incoming = tostring(gs.id or gs.gameId or "")
        if incoming ~= "" and incoming ~= tostring(self.online_game_id) then
            -- We are getting a brand new game (e.g., opponent accepted replay)
            msg.post("#", "ws_new_game_start", { state = gs })
        else
            if not self.game_over then
                M.sync_timers(self, gs)
            end
        end
    end))
end

local function stamp_ai_hand(self, real_hand)
    if type(real_hand) ~= "table" then return end
    for i, c in ipairs(self.ai_hand) do
        local rc = real_hand[i]
        if rc then
            c.v = tonumber(rc.v) or c.v
            c.s = tostring(rc.s or c.s)
        end
    end
end

local function stamp_deck(self, real_deck)
    if type(real_deck) ~= "table" then return end
    for i, c in ipairs(self.deck) do
        local rc = real_deck[i]
        if rc then
            c.v = tonumber(rc.v) or c.v
            c.s = tostring(rc.s or c.s)
        end
    end
end

function M.process_opponent_actions(self, actions, chosen_suit, new_game_state, done)
    local idx = 1
    local seq = self._seq

    local INTER  = 0.24
    local SETTLE = 0.42

    local function finish()
        if seq ~= self._seq then return end
        if chosen_suit and chosen_suit ~= "" and #self.ai_hand > 0 then
            self.chosen_suit = chosen_suit
            msg.post(GUI_SUIT, "suit_select", { mode = "preview", suit = chosen_suit })
            msg.post(GUI_HUD, "suit_badge", { suit = chosen_suit })
        end
        if done then done() end
    end

    local function next_act()
        if seq ~= self._seq then return end
        if idx > #actions then
            timer.delay(SETTLE, false, function()
                if seq == self._seq then finish() end
            end)
            return
        end

        local act = actions[idx]
        idx = idx + 1

        if act.type == "PLAY" then
            local v = tonumber(act.v) or 10
            local s = tostring(act.s or "H")
            local rec = nil

            for i, c in ipairs(self.ai_hand) do
                if tonumber(c.v) == v and tostring(c.s) == s then
                    rec = table.remove(self.ai_hand, i)
                    break
                end
            end

            if not rec and #self.ai_hand > 0 then
                rec = table.remove(self.ai_hand, #self.ai_hand)
                rec.v, rec.s = v, s
            elseif not rec then
                rec = self.spawn_card(v, s, vmath.vector3(self.CENTER.x, self.AI_HAND_Y, self.Z_FLY))
            end

            msg.post(GUI_SUIT, "suit_select", { mode = "close" })
            self.trigger_play_effects({ v = v, s = s })

            self.animate_to_pile(rec, false)
            self.position_hands(true)
            timer.delay(INTER, false, next_act)

        elseif act.type == "DRAW" then
            self.draw_to_hand(self.ai_hand, false, 1)
            timer.delay(INTER, false, next_act)
        else
            next_act()
        end
    end

    if #actions == 0 then
        finish()
    else
        next_act()
    end
end

function M.finalize_state_sync(self, state, on_complete)
    state = state or {}
    self.game_state = state
    self.is_waiting_for_server_response = false

    self.active_penalty = state.activePenaltyCount or 0

    if state.chosenSuit and state.chosenSuit ~= "" then
        self.chosen_suit = state.chosenSuit
        msg.post(GUI_SUIT, "suit_select", { mode = "preview", suit = self.chosen_suit })
    else
        self.chosen_suit = ""
        msg.post(GUI_SUIT, "suit_select", { mode = "close" })
    end

    if state.rank then msg.post(GUI_HUD, "update_standings", { ranks = state.rank }) end
    M.process_scoreboard(self, state)

    local deck_target = state.deckCount or (state.deck and #state.deck) or #self.deck
    M.sync_deck_size(self, deck_target)
    stamp_deck(self, state.deck)

    local op = (state.players or {})[self.opponent_id] or {}
    local real_hand = (type(op.hand) == "table") and op.hand or nil
    local target = op.handCount or (real_hand and #real_hand) or #self.ai_hand

    local function settle()
        stamp_ai_hand(self, real_hand)
        M.sync_timers(self, state)
        if on_complete then on_complete() end
    end

    if #self.ai_hand < target then
        local diff = target - #self.ai_hand
        self.draw_to_hand(self.ai_hand, false, diff, function() settle() end)
    else
        while #self.ai_hand > target do
            local c = table.remove(self.ai_hand)
            pcall(go.delete, c.id)
        end
        self.position_hands(true)
        settle()
    end
end

function M.handle_single_move(self, move_data, new_state, done)
    if self.game_over then done(); return end

    local sender      = tostring((move_data and (move_data._id or move_data.from)) or "")
    local is_my_move  = (sender ~= "" and sender == tostring(self.my_player_id))
    local actions     = (move_data and move_data.actions) or {}
    local has_actions = #actions > 0

    if not is_my_move and has_actions then
        local suit = move_data.chosenSuit
        if (not suit or suit == "") and new_state then suit = new_state.chosenSuit end
        M.process_opponent_actions(self, actions, suit or "", new_state, function()
            M.finalize_state_sync(self, new_state, function() done() end)
        end)
    else
        M.finalize_state_sync(self, new_state, function() done() end)
    end
end

function M.pump_move_queue(self)
    if self.is_processing_move then return end
    if #self.move_queue == 0    then return end
    if self.game_over           then return end

    self.is_processing_move = true
    local seq = self._seq
    local item = table.remove(self.move_queue, 1)

    local function on_done()
        self.is_processing_move = false
        if seq ~= self._seq then return end
        M.pump_move_queue(self)
    end

    if item.type == "MOVE" then
        M.handle_single_move(self, item.move, item.state, on_done)
    else
        on_done()
    end
end

function M.start_game(self, state)
    self.is_animating = true
    self.online_mode  = true
    self.game_state = state or {}
    self._seq = (self._seq or 0) + 1
    self.move_queue = {}
    self.is_processing_move = false
    self.is_waiting_for_server_response = false

    M.setup_ws_listeners(self)

    self.my_player_id = ws.get_current_user_id()
    self.online_game_id = state.id or state.gameId or ws.active_game_id or ""

    local players = state.players or {}
    local mp = {}
    local op = {}

    for k, v in pairs(players) do
        local pid = v.id or v._id or k
        if pid == self.my_player_id then
            mp = v
        elseif pid ~= self.my_player_id and self.opponent_id == "" then
            self.opponent_id = pid
            op = v
        end
    end

    local hand_data = mp.hand or {}
    local opp_hand  = (type(op.hand) == "table") and op.hand or nil
    local opp_count = op.handCount or (opp_hand and #opp_hand) or 7
    local top_card  = state.currentCard
    local cut_card  = state.cuttingCard

    self.active_penalty = state.activePenaltyCount or 0
    self.chosen_suit    = state.chosenSuit or ""

    if state.stake then msg.post(GUI_HUD, "update_stake", { amount = state.stake }) end
    if state.rank then msg.post(GUI_HUD, "update_standings", { ranks = state.rank }) end

    msg.post(GUI_HUD, "setup_avatars", { my_info = mp, op_info = op })
    msg.post(GUI_OVER, "setup_avatars", { my_info = mp, op_info = op })
    M.process_scoreboard(self, state)

    local p_count = #hand_data
    local a_count = opp_count
    local deck_count = state.deckCount or (state.deck and #state.deck) or 30
    local total_cards = deck_count + p_count + a_count + (cut_card and cut_card.v and 1 or 0)

    local mock_deck = {}
    for i = 1, total_cards do
        local c = self.spawn_card(10, "H", vmath.vector3(self.CENTER.x, self.CENTER.y, i * 0.001))
        table.insert(mock_deck, c)
    end

    local st = tostring(state.status or "")
    local is_resume = (st == "STARTED" or st == "PLAYING" or st == "RESHUFFLING") or (state.playedCards and #state.playedCards > 1)

    if is_resume then
        -- Snap cards directly, skipping double shuffle animation
        for i = 1, p_count do
            local pc = table.remove(mock_deck)
            local hdata = hand_data[i] or {}
            pc.v = tonumber(hdata.v) or 10
            pc.s = tostring(hdata.s or "H")
            table.insert(self.player_hand, pc)
            self.set_face(pc)
        end
        for i = 1, a_count do
            local ac = table.remove(mock_deck)
            if opp_hand and opp_hand[i] then
                ac.v = tonumber(opp_hand[i].v) or 10
                ac.s = tostring(opp_hand[i].s or "H")
            end
            table.insert(self.ai_hand, ac)
        end
        if cut_card and cut_card.v then
            local rec = table.remove(mock_deck, 1)
            rec.v = tonumber(cut_card.v) or 10
            rec.s = tostring(cut_card.s or "H")
            self.cutting_card = rec
            self.set_face(rec)
            go.set_position(vmath.vector3(self.DECK_POS.x + CUTTING_CARD_OFFSET_X, self.DECK_POS.y, self.Z_CUT), rec.id)
            go.set(rec.id, "euler.z", 90)
        end
        for i, c in ipairs(mock_deck) do
            table.insert(self.deck, c)
            go.set_position(vmath.vector3(self.DECK_POS.x + i * 0.5, self.DECK_POS.y - i * 0.5, i * 0.001), c.id)
        end
        stamp_deck(self, state.deck)

        if top_card and top_card.v then
            local rec = self.spawn_card(tonumber(top_card.v) or 10, tostring(top_card.s or "H"),
                vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_PILE))
            table.insert(self.played_cards, rec)
            self.set_face(rec)
        end

        self.position_hands(false)
        msg.post(GUI_SUIT, "suit_badge", { suit = self.chosen_suit })
        self.is_animating = false
        M.sync_timers(self, state)
        return
    end

    local seq = self._seq

    self.animate_shuffle(mock_deck, function()
        if seq ~= self._seq then return end

        local delay = 0.0
        local max_deal = math.max(p_count, a_count)

        local p_spacing = self.calc_spacing(p_count)
        local a_spacing = self.calc_spacing(a_count)
        local p_start = self.CENTER.x - ((p_count - 1) * p_spacing) / 2.0
        local a_start = self.CENTER.x - ((a_count - 1) * a_spacing) / 2.0

        for i = 1, max_deal do
            if i <= p_count then
                local pc = table.remove(mock_deck)
                local hdata = hand_data[i] or {}
                pc.v = tonumber(hdata.v) or 10
                pc.s = tostring(hdata.s or "H")
                table.insert(self.player_hand, pc)

                local pt = vmath.vector3(p_start + (i - 1) * p_spacing, self.PLAYER_HAND_Y, self.Z_HAND + i * 0.001)
                go.set_position(vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_FLY), pc.id)
                go.animate(pc.id, "position", go.PLAYBACK_ONCE_FORWARD, pt, go.EASING_OUTCUBIC, 0.3, delay)
                timer.delay(delay, false, function() if seq == self._seq then self.play_sound("SoundDraw") end end)
                timer.delay(delay + 0.15, false, function() if seq == self._seq then self.set_face(pc) end end)
                delay = delay + DEAL_DELAY
            end

            if i <= a_count then
                local ac = table.remove(mock_deck)
                if opp_hand and opp_hand[i] then
                    ac.v = tonumber(opp_hand[i].v) or 10
                    ac.s = tostring(opp_hand[i].s or "H")
                end
                table.insert(self.ai_hand, ac)
                local at = vmath.vector3(a_start + (i - 1) * a_spacing, self.AI_HAND_Y, self.Z_HAND + i * 0.001)
                go.set_position(vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_FLY), ac.id)
                go.animate(ac.id, "position", go.PLAYBACK_ONCE_FORWARD, at, go.EASING_OUTCUBIC, 0.3, delay)
                timer.delay(delay, false, function() if seq == self._seq then self.play_sound("SoundDraw") end end)
                delay = delay + DEAL_DELAY
            end
        end

        if cut_card and cut_card.v then
            local rec = table.remove(mock_deck, 1)
            rec.v = tonumber(cut_card.v) or 10
            rec.s = tostring(cut_card.s or "H")
            self.cutting_card = rec
            local cut_pos = vmath.vector3(self.DECK_POS.x + CUTTING_CARD_OFFSET_X, self.DECK_POS.y, self.Z_CUT)

            go.set(rec.id, "position.z", self.Z_FLY)
            timer.delay(delay + 0.15, false, function() if seq == self._seq then self.set_face(rec) end end)

            go.animate(rec.id, "position", go.PLAYBACK_ONCE_FORWARD, cut_pos, go.EASING_OUTCUBIC, 0.5, delay,
                function()
                    if seq == self._seq then go.set(rec.id, "position.z", self.Z_CUT) end
                end)
            go.animate(rec.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 90, go.EASING_OUTCUBIC, 0.5, delay)
            delay = delay + 0.5
        end

        for i, c in ipairs(mock_deck) do
            table.insert(self.deck, c)
            local t = vmath.vector3(self.DECK_POS.x + i * 0.5, self.DECK_POS.y - i * 0.5, i * 0.001)
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, t, go.EASING_OUTCUBIC, 0.55, delay)
        end
        stamp_deck(self, state.deck)
        timer.delay(delay, false, function() if seq == self._seq then self.play_sound("MoveDeck") end end)
        delay = delay + 0.55

        timer.delay(delay, false, function()
            if seq ~= self._seq then return end

            if top_card and top_card.v then
                local rec = self.spawn_card(tonumber(top_card.v) or 10, tostring(top_card.s or "H"),
                    vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_PILE))
                table.insert(self.played_cards, rec)
                self.set_face(rec)
            end

            msg.post(GUI_SUIT, "suit_badge", { suit = self.chosen_suit })

            self.is_animating = false
            M.sync_timers(self, state)

            local st_final = tostring(state.status or "")
            local is_res_final = (st_final == "STARTED" or st_final == "PLAYING" or st_final == "RESHUFFLING")
            if not is_res_final then
                local gid = state.gameId or state.id or self.online_game_id
                ws.send_message("PLAYER_READY", { gameId = gid, _id = self.my_player_id })
            end
        end)
    end)
end

return M