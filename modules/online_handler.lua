local ws = require "modules.websocket_manager"
local Defs = require "modules.card_defs"
local CV = require "modules.card_view"

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

function M.public_player_info(p)
    p = p or {}
    return {
        id          = p.id or p._id or "",
        _id         = p._id or p.id or "",
        username    = p.username or p.name,
        name        = p.name,
        avatar      = p.avatar or 1,
        balance     = p.balance,
        winRate     = p.winRate,
        gamesPlayed = p.gamesPlayed,
        isAI        = p.isAI or false,
    }
end

function M.slim_ranks(ranks)
    local out = {}
    if type(ranks) ~= "table" then return out end
    for i, r in ipairs(ranks) do
        if i > 7 then break end
        out[#out + 1] = {
            position = r.position,
            username = r.username,
            points   = r.points,
            -- backend rank rows carry `userId`; keep id/_id fallbacks too
            id       = r.id or r._id or r.userId,
        }
    end
    return out
end

local function scores_from_user_data(t_id)
    if not t_id or t_id == "" then return nil end
    local u = ws.current_user_data or {}
    local function progress_scores(obj)
        if type(obj) ~= "table" then return nil end
        local up = obj.userProgress
        if type(up) == "table" and type(up.currentScores) == "table" then
            return up.currentScores
        end
        return nil
    end
    if type(u.tournaments) == "table" then
        for _, t in ipairs(u.tournaments) do
            if type(t) == "table" and tostring(t._id or t.tournamentId or "") == t_id then
                local sc = progress_scores(t)
                if sc then return sc end
            end
        end
    end
    local mb = u.myBattle
    if type(mb) == "table" and tostring(mb._id or "") == t_id then
        return progress_scores(mb)
    end
    return nil
end

-- ── Knockout (online elimination chamber) ────────────────────────────────────
-- A knockout battle shows the offline-chamber score-cap standings table instead
-- of the normal battle scoreboard. We reuse the t4 chamber messages.
local function is_knockout_state(state)
    local mt = tostring((state or {}).matchType or ""):upper()
    return mt == "KNOCKOUT" or mt == "ELIMINATION"
end

local function knockout_chamber_rows(self, state)
    local rows = {}
    for pid, p in pairs((state or {}).players or {}) do
        rows[#rows + 1] = {
            slot       = (tostring(pid) == tostring(self.my_player_id)) and "bottom" or "top",
            name       = tostring(p.username or p.name or pid),
            avatar     = tonumber(p.avatar) or 1,
            total      = tonumber(p.cumulativeScore) or 0,
            eliminated = p.eliminated and true or false,
        }
    end
    return rows
end

local function knockout_init_chamber(self, state)
    msg.post(GUI_HUD, "t4_chamber_init", {
        threshold = tonumber(state.scoreCap) or 200,
        rows      = knockout_chamber_rows(self, state),
        placement = "left_center",
    })
end

local function knockout_update_chamber(self, state)
    local cap = tonumber((state or {}).scoreCap) or 200
    for pid, p in pairs((state or {}).players or {}) do
        msg.post(GUI_HUD, "t4_chamber_update", {
            name       = tostring(p.username or p.name or pid),
            total      = tonumber(p.cumulativeScore) or 0,
            threshold  = cap,
            eliminated = p.eliminated and true or false,
            added      = 0,
        })
    end
end

function M.process_scoreboard(self, state)
    state = state or {}

    -- Knockout games render the score-cap chamber table, so the battle
    -- scoreboard stays hidden. Use the sticky per-game flag too, because some
    -- mid-game state syncs don't echo matchType.
    if is_knockout_state(state) or self._is_knockout then
        msg.post(GUI_HUD, "update_scoreboard", { show = false })
        return
    end

    local function read_scores(scores)
        if type(scores) ~= "table" then return nil, nil end
        local mine, theirs, found = 0, 0, false
        for pid, sc in pairs(scores) do
            found = true
            if tostring(pid) == tostring(self.my_player_id) then mine = tonumber(sc) or 0
            else theirs = tonumber(sc) or theirs end
        end
        if not found then return nil, nil end
        return mine, theirs
    end

    local ts = (type(state.tournamentScore) == "table") and state.tournamentScore or nil
    local fmt, stage, p_score, o_score

    if ts then
        fmt = tonumber(ts.matchFormat)
        local lvl = tonumber(ts.currentLevel)
        if lvl then stage = "Level " .. lvl end
        p_score, o_score = read_scores(ts.scores)
    end

    -- ✅ FIXED: Implemented state locking logic from Godot.
    -- Prevents wiping the final score during the dead time between games.
    if state.gameOverState and type(state.gameOverState) == "table" then
        local gos = state.gameOverState
        if gos.isMatchComplete == true or gos.tournamentCompleted == true then
            self._final_state_locked = true
            local final_scores = gos.currentScores
            if type(final_scores) == "table" then
                p_score, o_score = read_scores(final_scores)
            end
        end
    else
        if self._final_state_locked then
            self._final_state_locked = false
        end
    end

    if not fmt then fmt = tonumber(state.matchFormat) end
    if not fmt and type(state.tournament) == "table" then fmt = tonumber(state.tournament.matchFormat) end
    
    -- Only fallback to currentScores if not locked
    if p_score == nil and not self._final_state_locked then 
        p_score, o_score = read_scores(state.currentScores) 
    end

    -- Track the series' tournament id across moves...
    local t_id = tostring(state.tournamentId or "")
    if t_id ~= "" then self._sb_tid = t_id else t_id = tostring(self._sb_tid or "") end
    
    -- Only fallback to user data if not locked
    if p_score == nil and not self._final_state_locked then 
        p_score, o_score = read_scores(scores_from_user_data(t_id)) 
    end

    if type(state.headToHead) == "table" then self._h2h = state.headToHead end
    local h2h_msg = nil
    if type(self._h2h) == "table" then
        local hp, ho = read_scores(self._h2h.scores)
        local form = nil
        if type(self._h2h.form) == "table" then
            form = self._h2h.form[tostring(self.my_player_id)]
        end
        h2h_msg = {
            p = hp or 0,
            o = ho or 0,
            total = self._h2h.totalGames or 0,
            form = (type(form) == "table") and form or {},
        }
    end

    -- ✅ FIXED: If final state is locked, force `is_series` to true so the HUD stays active
    local is_series = (ts ~= nil)
        or (state.gameType == "TOURNAMENT")
        or (type(state.tournamentId) == "string" and state.tournamentId ~= "")
        or (fmt ~= nil)
        or (type(state.tournament) == "table")
        or self._final_state_locked

    if is_series then
        self._sb_active = true
        self._sb_format = fmt or self._sb_format or 3
        if stage then self._sb_stage = stage end
    end
    
    if self._sb_active and p_score ~= nil then
        self._sb_p, self._sb_o = p_score, o_score
    end

    if self._sb_active then
        msg.post(GUI_HUD, "update_scoreboard", {
            show = true,
            series = true,
            p_score = self._sb_p or 0,
            o_score = self._sb_o or 0,
            best_of = self._sb_format or 3,
            stage = self._sb_stage,
            h2h = h2h_msg,
        })
    elseif h2h_msg then
        msg.post(GUI_HUD, "update_scoreboard", {
            show = true,
            series = false,
            h2h = h2h_msg,
        })
    else
        msg.post(GUI_HUD, "update_scoreboard", { show = false })
    end
end

function M.setup_ws_listeners(self)
    if self.ws_listeners then
        for _, token in ipairs(self.ws_listeners) do ws.off(token) end
    end
    self.ws_listeners = {}

    local board = msg.url()

    table.insert(self.ws_listeners, ws.on("game_move", function(move_data, gs)
        ws.queue_move(move_data, gs)
        msg.post(board, "ws_game_move")
    end))
    table.insert(self.ws_listeners, ws.on("timer_update", function(d)
        msg.post(board, "ws_timer_update", { data = d })
    end))
    table.insert(self.ws_listeners, ws.on("game_over", function(results)
        ws.last_game_over = results or {}
        msg.post(board, "ws_game_over")
    end))
    table.insert(self.ws_listeners, ws.on("network_quality", function(d)
        msg.post(board, "ws_network_quality", d)
    end))

    table.insert(self.ws_listeners, ws.on("game_start", function(gs)
        if type(gs) ~= "table" or next(gs) == nil then return end
        local incoming = tostring(gs.id or gs.gameId or "")
        local is_new = (incoming ~= "" and incoming ~= tostring(self.online_game_id))
        
        if is_new or self.game_over then
            ws.active_game_state = gs
            msg.post(board, "ws_new_game_start")
        elseif not self.game_over then
            -- Authoritative START for the current game (the backend only sends
            -- this once EVERY player is ready): release the post-deal hold, start
            -- the timers, and let any queued opponent move animate now.
            self._await_start = false
            M.sync_timers(self, gs)
            M.pump_move_queue(self)
        end
    end))

    -- ✅ FIXED: Removed redundant `game_request_accepted` listener to prevent double-firing race conditions.
    -- Controller.script is now solely responsible for hearing accepted requests and telling the board to restart.
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
        pcall(function() require("modules.tutorial").on_opponent_played() end)
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
            self.trigger_play_effects({ v = v, s = s }, #self.ai_hand == 0)

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

    if state.rank then msg.post(GUI_HUD, "update_standings", { ranks = M.slim_ranks(state.rank) }) end
    M.process_scoreboard(self, state)
    if is_knockout_state(state) then knockout_update_chamber(self, state) end

    local function do_sync()
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

    local deck_target     = state.deckCount or (state.deck and #state.deck) or #self.deck
    local incoming_played = (type(state.playedCards) == "table") and #state.playedCards or nil
    local pile_was_reset  = incoming_played ~= nil and incoming_played <= 1
    local deck_jumped     = deck_target >= (#self.deck + 6)
    local should_reshuffle = (#self.played_cards > 3) and (pile_was_reset or deck_jumped)

    if should_reshuffle and not self._online_reshuffling then
        self._online_reshuffling = true
        msg.post(GUI_HUD, "skip", { show = false })
        self.reshuffle_deck(function()
            self._online_reshuffling = false
            do_sync()
        end)
    else
        do_sync()
    end
end

function M.process_my_actions(self, actions, done)
    local idx = 1
    local seq = self._seq
    local INTER  = 0.24
    local SETTLE = 0.30

    local function next_act()
        if seq ~= self._seq then return end
        if idx > #actions then
            timer.delay(SETTLE, false, function()
                if seq == self._seq then if done then done() end end
            end)
            return
        end

        local act = actions[idx]
        idx = idx + 1

        if act.type == "PLAY" then
            local v = tonumber(act.v) or 10
            local s = tostring(act.s or "H")
            local rec = nil
            for i, c in ipairs(self.player_hand) do
                if tonumber(c.v) == v and tostring(c.s) == s then
                    rec = table.remove(self.player_hand, i)
                    break
                end
            end
            if not rec and #self.player_hand > 0 then
                rec = table.remove(self.player_hand, #self.player_hand)
                rec.v, rec.s = v, s
                self.set_face(rec)
            elseif not rec then
                rec = self.spawn_card(v, s, vmath.vector3(self.CENTER.x, self.PLAYER_HAND_Y, self.Z_FLY))
                self.set_face(rec)
            end

            msg.post(GUI_SUIT, "suit_select", { mode = "close" })
            self.trigger_play_effects({ v = v, s = s }, #self.player_hand == 0)
            self.animate_to_pile(rec, true)
            self.position_hands(true)
            timer.delay(INTER, false, next_act)

        elseif act.type == "DRAW" then
            local count = tonumber(act.count) or 1
            self.draw_to_hand(self.player_hand, true, count, function()
                if seq == self._seq then next_act() end
            end)
        else
            next_act()
        end
    end

    if #actions == 0 then
        if done then done() end
    else
        next_act()
    end
end

local function sync_my_hand(self, state)
    local me = (state.players or {})[self.my_player_id] or {}
    local real = (type(me.hand) == "table") and me.hand or nil
    if not real then return end
    while #self.player_hand > #real do
        local c = table.remove(self.player_hand)
        pcall(go.delete, c.id)
    end
    for i, c in ipairs(self.player_hand) do
        local rc = real[i]
        if rc then
            c.v = tonumber(rc.v) or c.v
            c.s = tostring(rc.s or c.s)
            self.set_face(c)
        end
    end
    if #self.player_hand < #real then
        local diff = #real - #self.player_hand
        self.draw_to_hand(self.player_hand, true, diff, function()
            for i, c in ipairs(self.player_hand) do
                local rc = real[i]
                if rc then
                    c.v = tonumber(rc.v) or c.v
                    c.s = tostring(rc.s or c.s)
                    self.set_face(c)
                end
            end
            self.pre_validate_hand()
        end)
    else
        self.position_hands(true)
        self.pre_validate_hand()
    end
end

function M.handle_single_move(self, move_data, new_state, done)
    if self.game_over then done(); return end

    local sender      = tostring((move_data and (move_data._id or move_data.from)) or "")
    local is_my_move  = (sender ~= "" and sender == tostring(self.my_player_id))
    local actions     = (move_data and move_data.actions) or {}
    local has_actions = #actions > 0
    local ai_for_me   = is_my_move and (move_data and move_data.aiOnBehalf) and true or false

    if not is_my_move and has_actions then
        local suit = move_data.chosenSuit
        if (not suit or suit == "") and new_state then suit = new_state.chosenSuit end
        M.process_opponent_actions(self, actions, suit or "", new_state, function()
            M.finalize_state_sync(self, new_state, function() done() end)
        end)
    elseif ai_for_me and has_actions then
        -- Akira consumed our turn: anything we half-did before timing out
        -- (a draw, a staged play, a suit pick) is now void — drop it so the
        -- NEXT turn we send starts from a clean slate and validates.
        self.current_turn_actions = {}
        self.player_has_drawn = false
        self.is_local_action_locked = false
        M.process_my_actions(self, actions, function()
            M.finalize_state_sync(self, new_state, function()
                sync_my_hand(self, new_state or {})
                done()
            end)
        end)
    else
        M.finalize_state_sync(self, new_state, function() done() end)
    end
end

function M.pump_move_queue(self)
    if self.is_processing_move then return end
    if #self.move_queue == 0    then return end
    if self.game_over           then return end
    -- Hold opponent moves in the queue until OUR shuffle/deal is done and the
    -- backend START has unlocked play, so the opponent's move never animates on
    -- a half-dealt board.
    if self.is_animating        then return end
    if self._await_start        then return end

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
    self._online_reshuffling = false
    self._await_start = false

    M.setup_ws_listeners(self)

    self.my_player_id = ws.get_current_user_id()
    self.online_game_id = state.id or state.gameId or ws.active_game_id or ""

    -- Deterministic pile scatter, seeded by the game id: the discard pile's
    -- random rotations/positions reproduce identically after a resume.
    self.scatter_seed = CV.seed_from_string(self.online_game_id)
    self.pile_index_base = 0

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

    local ts = (type(state.tournamentScore) == "table") and state.tournamentScore or nil
    local fmt = (ts and ts.matchFormat) or state.matchFormat
        or (type(state.tournament) == "table" and state.tournament.matchFormat) or nil
    local series_key = ""
    local t_id = tostring(state.tournamentId or "")
    if t_id ~= "" then
        series_key = "t:" .. t_id
    elseif fmt then
        series_key = "b:" .. tostring(self.opponent_id) .. ":" .. tostring(fmt)
    end
    local is_continuation = (series_key ~= "" and series_key == self._sb_series_key)
    if not is_continuation then
        self._sb_active, self._sb_format, self._sb_stage = false, nil, nil
        self._sb_p, self._sb_o = nil, nil
        self._sb_tid = (t_id ~= "" and t_id) or nil
        self._h2h = nil
    end
    self._sb_series_key = series_key

    local hand_data = mp.hand or {}
    local opp_hand  = (type(op.hand) == "table") and op.hand or nil
    local opp_count = op.handCount or (opp_hand and #opp_hand) or 7
    local top_card  = state.currentCard
    local cut_card  = state.cuttingCard

    self.active_penalty = state.activePenaltyCount or 0
    self.chosen_suit    = state.chosenSuit or ""

    if state.rank then msg.post(GUI_HUD, "update_standings", { ranks = M.slim_ranks(state.rank) }) end

    local my_pub = M.public_player_info(mp)
    local op_pub = M.public_player_info(op)
    msg.post(GUI_HUD, "setup_avatars", { my_info = my_pub, op_info = op_pub })
    msg.post(GUI_OVER, "setup_avatars", { my_info = my_pub, op_info = op_pub })
    self._is_knockout = is_knockout_state(state)
    M.process_scoreboard(self, state)
    if self._is_knockout then knockout_init_chamber(self, state) end

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

        -- Rebuild the discard pile EXACTLY as the player left it: each card
        -- re-lands on its deterministic scatter (seeded by the game id), so
        -- the random rotations/positions survive an app close + resume.
        local played = (type(state.playedCards) == "table") and state.playedCards or {}
        if #played > 0 then
            local first = math.max(1, #played - 11)
            self.pile_index_base = first - 1
            for i = first, #played do
                local pc = played[i]
                local rec = self.spawn_card(tonumber(pc.v) or 10, tostring(pc.s or "H"),
                    vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_PILE))
                local ox, oy, rot = CV.pile_scatter(self, i)
                go.set_position(vmath.vector3(self.CENTER.x + ox, self.CENTER.y + oy,
                    self.Z_PILE + (i - first + 1) * 0.001), rec.id)
                go.set(rec.id, "euler.z", rot)
                rec.pile_offset = vmath.vector3(ox, oy, 0)
                table.insert(self.played_cards, rec)
                self.set_face(rec)
            end
        elseif top_card and top_card.v then
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
    -- Rounds of a running series deal exactly like a fresh game — the
    -- round-story interstitial already covers the transition, so nothing is
    -- rushed; the old 0.04s fast-deal read as glitchy.
    local deal_step = DEAL_DELAY

    local function run_deal()
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
                delay = delay + deal_step
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
                delay = delay + deal_step
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
            -- Settle both hands into their arched / fanned layout so the curve is
            -- present from the first frame (the deal above lays the cards flat).
            self.position_hands(true)
            pcall(function() require("modules.tutorial").on_dealing_completed() end)

            local st_final = tostring(state.status or "")
            local is_res_final = (st_final == "STARTED" or st_final == "PLAYING" or st_final == "RESHUFFLING")
            if is_res_final then
                -- Resuming an already-started game: timers run right away and any
                -- queued opponent moves can play now that dealing is done.
                M.sync_timers(self, state)
                M.pump_move_queue(self)
            else
                -- Fresh game: shuffle + deal are fully done, so tell the backend
                -- we are READY and then HOLD timers + input until it broadcasts
                -- START (which it only does once EVERY player is ready). This
                -- keeps both clients in lock-step for normal and tournament games.
                self._await_start = true
                local gid = state.gameId or state.id or self.online_game_id
                ws.send_message("PLAYER_READY", { gameId = gid, _id = self.my_player_id })

                -- Safety net: if the START somehow never arrives (lost packet),
                -- release the hold and START THE TIMERS. This must fire BEFORE a
                -- turn could silently time out, otherwise the player sits on a
                -- board with no timer on either side and is then eliminated with
                -- no warning. Use the freshest state and make sure it carries a
                -- currentTurn (else sync_timers would just stop the timers).
                local seq = self._seq
                timer.delay(12.0, false, function()
                    if seq == self._seq and self._await_start and not self.game_over then
                        self._await_start = false
                        local recover = self.game_state or state or {}
                        if not recover.currentTurn or tostring(recover.currentTurn) == "" then
                            recover.currentTurn = state.currentTurn
                        end
                        M.sync_timers(self, recover)
                        M.pump_move_queue(self)
                    end
                end)
            end
        end)
    end

    self.animate_shuffle(mock_deck, run_deal)
end

return M