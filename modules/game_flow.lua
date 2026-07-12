----------------------------------------------------------------------
-- game_flow.lua
-- The heart of the game: committing a play and resolving its consequences,
-- drawing (with auto-reshuffle), the reshuffle itself, post-draw skip logic,
-- win detection, end-of-game reveal/scoring, offline turn routing, and the
-- boot dispatcher that picks online vs offline.
----------------------------------------------------------------------
local Rules          = require "modules.card_rules"
local Defs           = require "modules.card_defs"
local GameMode       = require "modules.game_mode"
local ws             = require "modules.websocket_manager"
local app            = require "modules.app_state"
local util           = require "modules.game_util"
local BL             = require "modules.board_layout"
local RE             = require "modules.rules_eval"
local Tut            = require "modules.tutorial"

-- Tutorial hooks must never be able to break live play: route every call
-- through pcall so a walkthrough bug can only ever no-op.
local function tut(name, ...)
    local f = Tut[name]
    if f then pcall(f, ...) end
end
local GS             = require "modules.game_state"
local OnlineHandler  = require "modules.online_handler"
local OfflineHandler = require "modules.offline_handler"

local M = {}

local CARD_SCALE   = BL.CARD_SCALE
local CARD_SCALE_F = BL.CARD_SCALE_F
local Z_FLY        = BL.Z_FLY
local Z_PILE       = BL.Z_PILE

local notify_gui = util.notify_gui
local log        = util.log

----------------------------------------------------------------------
-- Commit a play and route its consequences
----------------------------------------------------------------------
function M.play_card(self, rec, is_player, result)
    local actor = is_player and "You" or "Opponent"
    log(actor .. " played " .. Defs.card_name(rec))
    local src_hand = is_player and self.player_hand or self.ai_hand
    local is_last = (#src_hand <= 1)
    
    -- Sequence Tracker for Swift Validation (Rapid Tapping)
    self._play_ticket = (self._play_ticket or 0) + 1
    local current_ticket = self._play_ticket

    RE.trigger_play_effects(self, rec, is_last)

    local src = is_player and self.player_hand or self.ai_hand
    util.remove_from_hand(src, rec)

    notify_gui(self.gui_hud, "skip", { show = false })
    self.chosen_suit = ""
    if is_player and self.online_mode and type(self.game_state) == "table" then
        self.game_state.chosenSuit = ""
    end
    notify_gui(self.gui_suit, "suit_select", { mode = "close" })

    if is_player then
        table.insert(self.current_turn_actions, { type = "PLAY", v = tonumber(rec.v), s = tostring(rec.s) })
        tut("on_card_played", tonumber(rec.v), tostring(rec.s))
    end

    self.animate_to_pile(rec, is_player, function()
        if is_player or not self.online_mode then
            M.after_play_settled(self, rec, is_player, result, current_ticket)
        end
    end)
    self.position_hands(true)
    RE.pre_validate_hand(self)
end

function M.after_play_settled(self, rec, is_player, result, ticket)
    if self.game_over then return end
    
    if ticket and self._play_ticket and ticket < self._play_ticket then
        return
    end

    local actor = is_player and "You" or "Opponent"
    local hand  = is_player and self.player_hand or self.ai_hand
    local NA    = Rules.NextActionType

    if M.check_win(self, rec, is_player, result) then return end

    local hand_now = is_player and self.player_hand or self.ai_hand
    if #hand_now == 0 then
        self.active_penalty = 0
    else
        self.active_penalty = result.next_player_penalty_count or 0
    end

    if result.type == NA.CHOOSE_SUIT then
        if is_player then
            if #self.player_hand == 0 then
                if self.online_mode then
                    self.deactivate_turn()
                    OnlineHandler.end_turn(self)
                else
                    self.next_turn()
                end
            else
                self.is_suit_selection_active = true
                RE.pre_validate_hand(self)
                timer.delay(0.05, false, function() 
                    local cx = self.CENTER and self.CENTER.x or 640
                    local dx = self.DECK_POS and self.DECK_POS.x or 1150
                    local mid_x = cx + (dx - cx) / 2
                    notify_gui(self.gui_suit, "suit_select", { mode = "open", x = mid_x })
                    tut("on_suit_opened")
                end)
            end
            return
        else
            OfflineHandler.do_suit_choice(self)
        end
    elseif result.type == NA.SKIP_TURN then
        log(actor .. " skips opponent!")
        notify_gui(self.gui_suit, "suit_select", { mode = "close" })
        if self.t4 then
            require("modules.tournament4").apply_skip(self, rec)
            return
        end
        if is_player then
            if #self.player_hand == 0 then
                if self.online_mode then
                    self.deactivate_turn()
                    OnlineHandler.end_turn(self)
                else
                    self.next_turn()
                end
                return
            end
            self.player_has_drawn = false
            self.is_local_action_locked = false
            notify_gui(self.gui_hud, "skip", { show = false })
            RE.pre_validate_hand(self)
        else
            OfflineHandler.do_ai_turn(self, true)
        end
    elseif result.type == NA.REDUCE_PENALTY then
        notify_gui(self.gui_suit, "suit_select", { mode = "close" })
        -- `draw_cards` is the last-card-aware amount: it is 0 when this play
        -- empties the hand, so the partial penalty does NOT take effect on a
        -- final card — the player wins instead of being forced to draw.
        local remaining = result.draw_cards or result.current_penalty_count or 0
        self.active_penalty = 0
        if remaining > 0 then
            log(actor .. " reduces penalty — draws " .. remaining .. ".")
            if is_player and self.online_mode then
                M.draw_to_hand(self, hand, is_player, remaining, function()
                    self.deactivate_turn()
                    OnlineHandler.end_turn(self)
                end)
            else
                M.draw_to_hand(self, hand, is_player, remaining, function() self.next_turn() end)
            end
        else
            log(actor .. " cancels the penalty!")
            if is_player and self.online_mode then
                self.deactivate_turn()
                OnlineHandler.end_turn(self)
            else
                self.next_turn()
            end
        end
    elseif result.type == NA.TRANSFER_PENALTY then
        notify_gui(self.gui_suit, "suit_select", { mode = "close" })
        log("Penalty stacked: " .. RE.get_active_penalty(self) .. " pending!")
        if is_player and self.online_mode then
            self.deactivate_turn()
            OnlineHandler.end_turn(self)
        else
            self.next_turn()
        end
    elseif NA.HOLD_ON and result.type == NA.HOLD_ON then
        -- Card 1 (Hold On): the player who just played keeps the turn and
        -- plays again.
        notify_gui(self.gui_suit, "suit_select", { mode = "close" })
        log(actor .. " plays Hold On — plays again!")
        if self.t4 then
            require("modules.tournament4").apply_hold_on(self)
            return
        end
        if is_player then
            if #self.player_hand == 0 then
                if self.online_mode then self.deactivate_turn(); OnlineHandler.end_turn(self)
                else self.next_turn() end
                return
            end
            self.player_has_drawn = false
            self.is_local_action_locked = false
            notify_gui(self.gui_hud, "skip", { show = false })
            RE.pre_validate_hand(self)
        else
            OfflineHandler.do_ai_turn(self, true)
        end
    elseif NA.GENERAL_MARKET and result.type == NA.GENERAL_MARKET then
        -- Card 14 (General Market): every opponent draws one card, then the
        -- player who played it goes again. Heads-up: the single opponent draws.
        notify_gui(self.gui_suit, "suit_select", { mode = "close" })
        log(actor .. " plays General Market — opponent draws 1!")
        if self.t4 then
            require("modules.tournament4").apply_general_market(self, self.t4.turn_seat)
            return
        end
        local function continue_actor()
            if is_player then
                if #self.player_hand == 0 then
                    if self.online_mode then self.deactivate_turn(); OnlineHandler.end_turn(self)
                    else self.next_turn() end
                    return
                end
                self.player_has_drawn = false
                self.is_local_action_locked = false
                notify_gui(self.gui_hud, "skip", { show = false })
                RE.pre_validate_hand(self)
            else
                OfflineHandler.do_ai_turn(self, true)
            end
        end
        if self.online_mode then
            -- The server applies the opponent draw and pushes state; just keep control.
            continue_actor()
        else
            local opp_hand = is_player and self.ai_hand or self.player_hand
            M.draw_to_hand(self, opp_hand, not is_player, 1, function() continue_actor() end)
        end
    else
        notify_gui(self.gui_suit, "suit_select", { mode = "close" })
        local pen = RE.get_active_penalty(self)
        if pen > 0 then log("Penalty: " .. pen .. " cards!") end

        if is_player and self.online_mode then
            self.deactivate_turn()
            OnlineHandler.end_turn(self)
        else
            self.next_turn()
        end
    end
end

----------------------------------------------------------------------
-- Drawing (with auto-reshuffle when the deck runs dry)
----------------------------------------------------------------------
function M.draw_to_hand(self, hand, is_player, count, done)
    if not count or count <= 0 then if done then done(self) end return end
    if is_player then self.is_animating = true end

    local seq         = self._seq
    local STAGGER     = 0.13
    local FLIP_T      = 0.14
    local SETTLE      = 0.30
    local placed      = 0
    local launched    = 0
    local finished    = false
    local reshuffling = false

    local function finish()
        if finished then return end
        finished = true
        if is_player then
            self.is_animating = false
            RE.pre_validate_hand(self)
        end
        if seq == self._seq and done then done(self) end
    end

    local place_one
    place_one = function()
        if finished then return end
        if seq ~= self._seq then finish(); return end

        if #self.deck == 0 then
            if #self.played_cards <= 1 then
                finish(); return
            end
            if reshuffling then
                timer.delay(0.05, false, place_one); return
            end
            reshuffling = true
            M.reshuffle_deck(self, function()
                reshuffling = false
                if seq == self._seq then place_one() else finish() end
            end)
            return
        end

        local c = table.remove(self.deck)
        table.insert(hand, c)

        if is_player and self.online_mode and self.is_player_turn() then
            table.insert(self.current_turn_actions, { type = "DRAW", v = tonumber(c.v), s = tostring(c.s) })
        end

        local y = is_player and self.PLAYER_HAND_Y or self.AI_HAND_Y
        go.set(c.id, "position.z", Z_FLY)
        self.play_sound("SoundDraw")

        if is_player then
            go.animate(c.id, "scale.x", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_INSINE, FLIP_T, 0, function()
                if seq ~= self._seq then return end
                self.set_face(c)
                go.animate(c.id, "scale.x", go.PLAYBACK_ONCE_FORWARD, CARD_SCALE_F, go.EASING_OUTSINE, FLIP_T)
            end)
        else
            self.set_back(c)
        end

        BL.layout_hand(self, hand, y, true)

        placed = placed + 1
        if placed >= count then
            timer.delay(SETTLE, false, finish)
        end
    end

    local launch_next
    launch_next = function()
        if finished or seq ~= self._seq then return end
        if launched >= count then return end
        launched = launched + 1
        place_one()
        if launched < count then
            timer.delay(STAGGER, false, launch_next)
        end
    end

    launch_next()
end

----------------------------------------------------------------------
-- Reshuffle
----------------------------------------------------------------------
function M.reshuffle_deck(self, done)
    if #self.played_cards <= 1 then if done then done() end return end
    log("Reshuffling deck...")

    local seq = self._seq

    local top = table.remove(self.played_cards)
    local recycled = self.played_cards
    self.played_cards = { top }
    -- Bump BEFORE the z reset below, so a same-frame-or-later animate_to_pile
    -- completion for this exact card (still mid-flight when reshuffle fired)
    -- sees a stale generation and skips re-asserting its old, high z.
    self.pile_gen = (self.pile_gen or 0) + 1
    go.set(top.id, "position.z", Z_PILE + 0.001)

    local existing = {}
    for _, c in ipairs(self.deck) do existing[#existing + 1] = c end
    local existing_n = #existing
    local recycled_n = #recycled

    for i = recycled_n, 2, -1 do
        local k = math.random(i)
        recycled[i], recycled[k] = recycled[k], recycled[i]
    end

    local stub, under = {} , {}
    if existing_n > 0 then
        stub  = existing
        under = recycled
    else
        local stub_count = math.min(3, recycled_n)
        for i = 1, recycled_n - stub_count do under[#under + 1] = recycled[i] end
        for i = recycled_n - stub_count + 1, recycled_n do stub[#stub + 1] = recycled[i] end
    end

    local final_deck = {}
    for _, c in ipairs(under) do final_deck[#final_deck + 1] = c end
    for _, c in ipairs(stub)  do final_deck[#final_deck + 1] = c end

    local index_of_card = {}
    for i, c in ipairs(final_deck) do index_of_card[c] = i end

    for i, c in ipairs(recycled) do
        go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
            vmath.vector3(self.CENTER.x, self.CENTER.y, 0.4 + i * 0.001), go.EASING_INOUTSINE, 0.22)
        go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_LINEAR, 0.22)
        timer.delay(0.1, false, function() if seq == self._seq then self.set_back(c) end end)
    end

    timer.delay(0.28, false, function()
        if seq ~= self._seq then return end

        self.animate_shuffle(recycled, function()
            if seq ~= self._seq then return end
            self.play_sound("MoveDeck")

            for _, c in ipairs(stub) do
                local idx = index_of_card[c]
                go.set(c.id, "scale", CARD_SCALE)
                go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
                    BL.deck_slot_pos(self, idx), go.EASING_OUTCUBIC, 0.30)
                go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_OUTCUBIC, 0.30)
            end

            local tuck_delay = (existing_n > 0) and 0.04 or 0.18
            timer.delay(tuck_delay, false, function()
                if seq ~= self._seq then return end
                for _, c in ipairs(under) do
                    local idx = index_of_card[c]
                    go.set(c.id, "scale", CARD_SCALE)
                    go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
                        BL.deck_slot_pos(self, idx), go.EASING_INOUTCUBIC, 0.45)
                    go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_INOUTCUBIC, 0.45)
                end

                self.deck = final_deck

                timer.delay(0.55, false, function()
                    if seq ~= self._seq then return end
                    BL.restack_deck(self)
                    if done then done() end
                end)
            end)
        end)
    end)
end

----------------------------------------------------------------------
-- Turn routing (offline)
----------------------------------------------------------------------
function M.next_turn(self)
    if self.online_mode then
        self.deactivate_turn()
        return
    end
    if self.t4 then
        require("modules.tournament4").advance(self)
        return
    end
    OfflineHandler.next_turn(self)
end

----------------------------------------------------------------------
-- Post-draw: can the player still act, or must we pass?
----------------------------------------------------------------------
function M.check_post_draw(self, frozen_penalty)
    local saved_penalty    = self.active_penalty
    local saved_gs_penalty = self.game_state and self.game_state.activePenaltyCount

    if frozen_penalty ~= nil then
        self.active_penalty = frozen_penalty
        if self.game_state then self.game_state.activePenaltyCount = frozen_penalty end
    end

    -- Whot: drawing always ends the turn, even if the drawn card (or any
    -- other card already in hand) is playable — no "pick and play". The
    -- other games intentionally keep the "play if you can" behavior below.
    local has_any = false
    if GameMode.is_whot() then
        has_any = false
    elseif #self.played_cards == 0 then
        has_any = true
    else
        for _, c in ipairs(self.player_hand) do
            if RE.evaluate_play(self, c, self.player_hand).valid then has_any = true; break end
        end
    end

    self.active_penalty = saved_penalty
    if self.game_state then self.game_state.activePenaltyCount = saved_gs_penalty end

    if has_any then
        self.is_local_action_locked = false
        notify_gui(self.gui_hud, "skip", { show = true })
    else
        notify_gui(self.gui_hud, "skip", { show = false })
        if self.online_mode then
            self.deactivate_turn()
            local seq = self._seq
            timer.delay(0.8, false, function()
                if seq == self._seq then OnlineHandler.end_turn(self) end
            end)
        else
            local seq = self._seq
            timer.delay(0.8, false, function()
                if seq == self._seq then self.next_turn() end
            end)
        end
    end
    RE.pre_validate_hand(self)
end

----------------------------------------------------------------------
-- Win detection & Game Over
----------------------------------------------------------------------
function M.check_win(self, rec, is_player, result)
    if self.online_mode then return false end

    if self.t4 then
        if #self.player_hand == 0 then
            require("modules.tournament4").human_finished(self)
            return true
        end
        return false
    end

    if RE.is_cutting_match(self, rec) then
        log("Cutting card played! Game over instantly.")
        M.end_game(self, nil, true)
        return true
    end

    if #self.player_hand == 0 then M.end_game(self, true, false); return true end
    if #self.ai_hand == 0 then M.end_game(self, false, false); return true end
    return false
end

local function slim_results(res)
    res = type(res) == "table" and res or {}
    local function two_player_map(m)
        if type(m) ~= "table" then return nil end
        local c = {}
        for k, v in pairs(m) do c[tostring(k)] = v end
        return c
    end
    local out = {
        reason                   = res.reason,
        isNoShowScenario         = res.isNoShowScenario,
        gameType                 = res.gameType,
        points                   = res.points,
        tournamentCompleted      = res.tournamentCompleted,
        tournamentEndedByTimeout = res.tournamentEndedByTimeout,
        isMatchComplete          = res.isMatchComplete,
        rewards                  = two_player_map(res.rewards),
        currentScores            = two_player_map(res.currentScores),
        cardTotals               = two_player_map(res.cardTotals),
    }
    if type(res.stake) == "table" then
        out.stake = { amount = res.stake.amount, charge = res.stake.charge, points = res.stake.points }
    end
    if type(res.tournamentData) == "table" and type(res.tournamentData.grandPrize) == "table" then
        out.tournamentData = { grandPrize = {
            value  = res.tournamentData.grandPrize.value,
            points = res.tournamentData.grandPrize.points,
        } }
    end
    return out
end

-- ======================================================================
-- EXPLICIT EVENT API FOR EXTERNAL SCRIPTS TO CALL
-- Call `GF.finish_round_transition(self)` when the story/UI is fully complete.
-- ======================================================================
function M.finish_round_transition(self, force)
    if self._knockout_story_locked and not force then return end
    self._knockout_story_locked = false

    if not self.is_transitioning_round then return end
    self.is_transitioning_round = false
    
    if self.online_mode and self._continuation_request_id then
        log("Sending GAME_REQUEST_ACCEPTED for continuation: " .. tostring(self._continuation_request_id))
        ws.accept_game_request(self._continuation_request_id)
        self._continuation_request_id = nil
        return -- Do NOT call M.start_game here. Wait for the server's START event.
    end

    if self.queued_start_game then
        self.queued_start_game = false
        log("Executing queued next round via EXPLICIT finish event!")
        M.start_game(self)
    end
end

function M.end_game(self, player_won, is_cut, backend_results)
    if self.game_over then return end
    self.game_over = true
    
    -- GAME QUEUE LOCK:
    -- Prevent background processing from ripping the board away while 
    -- we are transitioning between rounds or counting scores!
    self.is_transitioning_round = true
    self.queued_start_game = false
    
    notify_gui(self.gui_hud, "stop_timers")
    -- The suit wheel must never linger into the game-over screen: if the round
    -- ends while it is still open (e.g. a timeout mid-selection) close it now.
    notify_gui(self.gui_suit, "suit_select", { mode = "close" })
    tut("on_game_over")

    local round_continues = false
    local story = nil
    local is_knockout = false
    
    if self.online_mode and type(backend_results) == "table" then
        self._continuation_request_id = backend_results.continuationRequestId
        
        local gt = tostring(backend_results.gameType or ""):upper()
        local mt = tostring(backend_results.matchType or ""):upper()
        
        if gt == "KNOCKOUT" or mt == "KNOCKOUT" then is_knockout = true end
        if type(backend_results.tournamentData) == "table" and tostring(backend_results.tournamentData.matchType or ""):upper() == "KNOCKOUT" then
            is_knockout = true
        end
        
        round_continues = (gt == "TOURNAMENT" or is_knockout)
            and not backend_results.isMatchComplete
            and not backend_results.tournamentCompleted
            and not backend_results.isNoShowScenario

        if not round_continues then
            if type(backend_results.balances) == "table" then
                local bal = tonumber(backend_results.balances[tostring(self.my_player_id)])
                if bal ~= nil then
                    notify_gui(self.gui_hud, "update_balance", { balance = bal })
                end
            end
        end

        if not is_knockout then
            if backend_results.currentScores or backend_results.headToHead then
                OnlineHandler.process_scoreboard(self, {
                    currentScores = backend_results.currentScores,
                    headToHead    = backend_results.headToHead,
                })
            end
        end

        if round_continues then
            local p_sc, o_sc = 0, 0
            if not is_knockout then
                for pid, sc in pairs(backend_results.currentScores or {}) do
                    if tostring(pid) == tostring(self.my_player_id) then p_sc = tonumber(sc) or 0
                    else o_sc = tonumber(sc) or 0 end
                end
            end
            
            local target = tonumber(backend_results.requiredWins) or 0
            if target <= 0 and not is_knockout then target = math.max(p_sc, o_sc) + 1 end
            
            local next_rnd = p_sc + o_sc + 1
            if is_knockout then
                self._knockout_round = (self._knockout_round or 0) + 1
                next_rnd = ""
                target = tonumber(backend_results.scoreCap) or 200
            end

            local round_history = backend_results.roundHistory
            if not round_history or #round_history == 0 then
                self._knockout_history = self._knockout_history or {}
                if backend_results.roundScores and not self._history_added_this_round then
                    table.insert(self._knockout_history, backend_results.roundScores)
                    self._history_added_this_round = true
                end
                round_history = self._knockout_history
            end

            story = {
                won = player_won and true or false,
                p_score = p_sc,
                o_score = o_sc,
                target = target,
                next_round = next_rnd,
                last_round = (not is_knockout) and (p_sc == target - 1) and (o_sc == target - 1) or false,
                is_knockout = is_knockout,
                history = round_history,
                players = backend_results.players
            }
        else
            self._knockout_round = 0
        end
    end

    local p_score = RE.hand_score(self.player_hand)
    local a_score = RE.hand_score(self.ai_hand)

    if is_cut and not self.online_mode then
        player_won = p_score < a_score
    end

    if self.online_mode and backend_results then
        local op_data = {}
        if backend_results.players then
            for k, v in pairs(backend_results.players) do
                local pid = v.id or v._id or k
                if pid == self.opponent_id then
                    op_data = v
                    break
                end
            end
        end

        local opp_real_hand = op_data.hand or (backend_results.hands and backend_results.hands[self.opponent_id])

        if not opp_real_hand then
            local gs = ws.get_active_game() or {}
            local p = (gs.players or {})[self.opponent_id]
            if p and type(p.hand) == "table" then opp_real_hand = p.hand end
        end

        if opp_real_hand then
            for i, c in ipairs(self.ai_hand) do
                local real_card = opp_real_hand[i]
                if real_card then
                    c.v = tonumber(real_card.v) or c.v
                    c.s = tostring(real_card.s) or c.s
                end
            end
        end
    end

    timer.delay(0.4, false, function()
        if player_won then self.play_sound("SoundWinAlt") else self.play_sound("SoundLose") end
    end)

    local is_series_active, is_series_over = false, true
    if not self.online_mode then
        is_series_active, is_series_over, player_won = OfflineHandler.evaluate_series(self, player_won)
    end

    -- ======================================================================
    -- BULLETPROOF EVENT-DRIVEN ANIMATION CHAIN
    -- ======================================================================

    local function final_resolution()
        if round_continues then
            
            -- NEW UX STORYTELLING FLOW
            if is_knockout then
                self._knockout_story_locked = true
                self.round_story_active = true
                if story then notify_gui(self.gui_hud, "round_story", story) end
                
                -- Wait for ROUND WON text to settle
                timer.delay(1.5, false, function()
                    -- Trigger History List Expansion
                    notify_gui(self.gui_hud, "t4_chamber_expand", { 
                        history = story.history, 
                        players = story.players, 
                        my_id = self.my_player_id 
                    })
                    
                    -- Hold table open for exactly 2 seconds (+0.5 for animation)
                    timer.delay(2.5, false, function()
                        -- Trigger Table Collapse back to minimal
                        notify_gui(self.gui_hud, "t4_chamber_collapse", {})
                        
                        -- Wait for Collapse animation to finish
                        timer.delay(0.5, false, function()
                            -- NOW safely accept and transition!
                            M.finish_round_transition(self, true)
                        end)
                    end)
                end)
            else
                if story then 
                    self.round_story_active = true
                    notify_gui(self.gui_hud, "round_story", story) 
                end
                timer.delay(8.0, false, function() M.finish_round_transition(self) end)
            end
            
        else
            notify_gui(self.gui_over, "game_over", {
                won = player_won, player_score = p_score, ai_score = a_score,
                is_cut = is_cut, my_id = self.my_player_id, results = slim_results(backend_results),
                series_active = is_series_active, series_over = is_series_over
            })
            if is_series_active and not is_series_over then
                timer.delay(4.0, false, function() M.finish_round_transition(self) end)
            else
                M.finish_round_transition(self)
            end
        end
    end

    local function count_next_player(idx, done_cb)
        local to_count = {
            { pid = self.my_player_id, hand = self.player_hand },
            { pid = self.opponent_id, hand = self.ai_hand }
        }
        if idx > #to_count then done_cb(); return end
        
        local cur = to_count[idx]
        local pid = cur.pid
        local hand = cur.hand

        local cs = backend_results.currentScores or backend_results.cumulativeScores or {}
        local cap = tonumber(backend_results.scoreCap) or 200
        self._knockout_scores = self._knockout_scores or {}
        local players = (self.game_state or {}).players or {}

        local function get_card_value(v, s)
            local val = tonumber(v)
            if not val then return 0 end

            if GameMode.is_whot() then
                -- Whot: literal face value for every card, except Star-shaped
                -- cards which always count DOUBLE (see tournament4.lua's
                -- get_card_value for the same rule, offline).
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

        local current_total = tonumber(self._knockout_scores[tostring(pid)]) or 0
        local final_total = tonumber(cs[tostring(pid)]) or 0
        local added_so_far = 0
        local server_added = math.max(0, final_total - current_total)

        -- Fallback: if the backend score didn't advance (missing / stale
        -- currentScores) but the player is still holding cards, reconstruct this
        -- round's add from the actual hand. Otherwise a hand full of cards would
        -- silently populate the total and skip the counting story entirely.
        if server_added == 0 and #hand > 0 then
            local local_sum = 0
            for _, c in ipairs(hand) do local_sum = local_sum + get_card_value(c.v, c.s) end
            if local_sum > 0 then
                server_added = local_sum
                final_total  = current_total + local_sum
            end
        end

        if #hand == 0 or server_added == 0 then
            self._knockout_scores[tostring(pid)] = final_total
            notify_gui(self.gui_hud, "t4_chamber_update", {
                name = (players[pid] or {}).username or (players[pid] or {}).name or pid,
                total = final_total, threshold = cap, eliminated = final_total >= cap
            })
            count_next_player(idx + 1, done_cb)
            return
        end

        local k = 0
        local step = 46
        local row_cx = self.CENTER and self.CENTER.x or 640
        local row_cy = self.CENTER and self.CENTER.y or 360

        local function fly_one()
            k = k + 1
            if k > #hand then
                local dp = self.DECK_POS or vmath.vector3(1150, 360, 0)
                local orig_h_size = #hand 
                local swept = 0
                
                for i, c in ipairs(hand) do
                    local cid = c.id
                    if pcall(go.get_position, cid) then
                        go.animate(cid, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(dp.x + i * 0.5, dp.y - i * 0.5, BL.Z_FLY + i * 0.001), go.EASING_INCUBIC, 0.4, i * 0.05)
                        go.animate(cid, "scale", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE, go.EASING_INSINE, 0.4, i * 0.05, function()
                            pcall(go.delete, cid)
                            swept = swept + 1
                            if swept == orig_h_size then
                                timer.delay(0.3, false, function() count_next_player(idx + 1, done_cb) end)
                            end
                        end)
                    else
                        swept = swept + 1
                        if swept == orig_h_size then 
                            timer.delay(0.3, false, function() count_next_player(idx + 1, done_cb) end)
                        end
                    end
                end
                
                if current_total + added_so_far ~= final_total then
                    self._knockout_scores[tostring(pid)] = final_total
                    notify_gui(self.gui_hud, "t4_chamber_update", {
                        name = (players[pid] or {}).username or (players[pid] or {}).name or pid,
                        total = final_total, threshold = cap, eliminated = final_total >= cap
                    })
                end
                
                for i = orig_h_size, 1, -1 do hand[i] = nil end
                return
            end
            
            local c = hand[k]
            local val = get_card_value(c.v, c.s)
            if k == #hand then val = server_added - added_so_far end
            
            added_so_far = added_so_far + val
            local new_total = current_total + added_so_far
            self._knockout_scores[tostring(pid)] = new_total

            local cx = row_cx - ((#hand - 1) * step) / 2.0 + (k - 1) * step
            local cy = row_cy
            local z = BL.Z_FLY + k * 0.002
            
            if pcall(go.get_position, c.id) then
                go.set(c.id, "position.z", z)
                go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_OUTSINE, 0.4)
                go.animate(c.id, "scale", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE, go.EASING_OUTSINE, 0.4)
                go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(cx, cy, z), go.EASING_OUTCUBIC, 0.4, 0, function()
                    if pcall(go.get_position, c.id) then
                        go.animate(c.id, "scale", go.PLAYBACK_ONCE_PINGPONG, vmath.vector3(BL.CARD_SCALE_F * 1.12, BL.CARD_SCALE_F * 1.12, 1), go.EASING_INOUTSINE, 0.12)
                    end
                    
                    self.play_sound("SoundPick")
                    local p_name = (players[pid] or {}).username or (players[pid] or {}).name or pid
                    notify_gui(self.gui_hud, "t4_chamber_update", {
                        name = p_name, total = new_total, threshold = cap, eliminated = new_total >= cap,
                        added = val, cx = cx, cy = cy
                    })
                    
                    timer.delay(0.15, false, function() fly_one() end)
                end)
            else
                fly_one()
            end
        end
        
        fly_one()
    end

    local function sweep_played_cards(on_complete)
        if not self.played_cards or #self.played_cards == 0 then on_complete(); return end
        local swept = 0
        local total = #self.played_cards
        local dp = self.DECK_POS or vmath.vector3(1150, 360, 0)
        
        for i, c in ipairs(self.played_cards) do
            local cid = c.id
            if pcall(go.get_position, cid) then
                go.animate(cid, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(dp.x, dp.y, BL.Z_FLY + i * 0.001), go.EASING_INCUBIC, 0.35, 0)
                go.animate(cid, "scale", go.PLAYBACK_ONCE_FORWARD, BL.CARD_SCALE, go.EASING_INSINE, 0.35, 0, function()
                    pcall(go.delete, cid)
                    swept = swept + 1
                    if swept == total then timer.delay(0.3, false, on_complete) end
                end)
            else
                swept = swept + 1
                if swept == total then timer.delay(0.3, false, on_complete) end
            end
        end
        self.played_cards = {}
    end

    local function flip_ai_hand(on_complete)
        if #self.ai_hand == 0 then on_complete(); return end
        local flipped = 0
        local total = #self.ai_hand
        
        for i, c in ipairs(self.ai_hand) do
            local cc = c
            timer.delay((i - 1) * 0.18 + 0.5, false, function()
                if not pcall(go.get_position, cc.id) then
                    flipped = flipped + 1; if flipped == total then on_complete() end
                    return
                end
                
                local start_y = go.get_position(cc.id).y
                go.animate(cc.id, "position.y", go.PLAYBACK_ONCE_PINGPONG, start_y + 26, go.EASING_INOUTSINE, 0.35)
                go.animate(cc.id, "scale.x", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_INSINE, 0.18, 0, function()
                    if pcall(go.get_position, cc.id) then
                        self.set_face(cc)
                        -- Opponent cards render smaller while face-down (scale.y
                        -- shrunk in layout_hand); snap y back to full before
                        -- animating x back up so the revealed card isn't stretched.
                        go.set(cc.id, "scale.y", CARD_SCALE_F)
                        go.animate(cc.id, "scale.x", go.PLAYBACK_ONCE_FORWARD, CARD_SCALE_F, go.EASING_OUTSINE, 0.18, 0, function()
                            flipped = flipped + 1
                            if flipped == total then on_complete() end
                        end)
                    else
                        flipped = flipped + 1; if flipped == total then on_complete() end
                    end
                end)
            end)
        end
    end

    flip_ai_hand(function()
        timer.delay(0.9, false, function()
            if is_knockout then
                sweep_played_cards(function()
                    count_next_player(1, function()
                        final_resolution()
                    end)
                end)
            else
                final_resolution()
            end
        end)
    end)
end

----------------------------------------------------------------------
-- Boot dispatcher
----------------------------------------------------------------------
local function apply_stake_background(self)
    local amt = 0
    if app.mode == "online" then
        local st = (ws.get_active_game() or {}).stake
        amt = tonumber(type(st) == "table" and st.amount or st) or 0
    else
        local sel = app.selected_stake
        amt = tonumber(type(sel) == "table" and sel.amount or sel) or 0
    end
    local bg = "bg_1"
    if amt > 500 then bg = "bg_3"
    elseif amt > 200 then bg = "bg_2" end
    pcall(function()
        sprite.play_flipbook("#background", hash(bg))
        local sz = go.get("#background", "size")
        if sz and sz.x > 0 then self.bg_img_w, self.bg_img_h = sz.x, sz.y end
    end)
    BL.fit_background(self)
end

function M.start_game(self)
    if self.is_transitioning_round then
        log("start_game: Round arrived but board is currently transitioning/busy. Queuing...")
        self.queued_start_game = true
        return
    end
    
    self.queued_start_game = false
    self.is_transitioning_round = false
    self._history_added_this_round = false
    
    GS.destroy_all(self)
    GS.fresh_state(self)
    apply_stake_background(self)
    BL.update_layout(self)

    notify_gui(self.gui_hud, "reset_hud", { keep_scoreboard = true })
    notify_gui(self.gui_suit, "reset_hud")
    notify_gui(self.gui_over, "reset_hud")

    -- Every game start clears any leftover walkthrough state; only the online
    -- scripted tutorial game below re-arms it. Without this a half-finished
    -- tutorial would keep is_active() true and gate card taps (locking the hand)
    -- in the next offline / tournament game.
    tut("start_game", false)

    if app.mode == "online" then
        local state = ws.get_active_game()
        if state and next(state) ~= nil then
            -- A scripted 50-stake game vs the backend tutorial bot drives the
            -- in-game walkthrough. Prefer the backend's isScripted flag, falling
            -- back to the Godot heuristic (50 stake + an AI opponent).
            local scripted = false
            if state.isScripted == true then
                scripted = true
            elseif (tonumber((state.stake or {}).amount) or 0) == 50 and type(state.players) == "table" then
                for _, p in pairs(state.players) do
                    if type(p) == "table" and (p.isAI or p.isAi) then scripted = true; break end
                end
            end
            tut("start_game", scripted)
            OnlineHandler.start_game(self, state)
            return
        end
    end

    if app.mode == "tournament4" or app.mode == "chamber4" then
        local me = ws.current_user_data or {}
        require("modules.tournament4").start(self, me, {
            chamber   = (app.mode == "chamber4"),
            threshold = app.chamber_threshold or 100,
        })
        return
    end

    OfflineHandler.start_game(self)
end

return M