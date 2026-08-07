local ws = require "modules.websocket_manager"
local Defs = require "modules.card_defs"
local CV = require "modules.card_view"
local GameMode = require "modules.game_mode"
local BL = require "modules.board_layout"
local config = require "modules.config"
local RQ = require "modules.reshuffle_queue"
local app_state = require "modules.app_state"

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
    -- Assigned unconditionally, unlike the fields above: a settled General
    -- Market debt has to be CLEARED, and every state this is called with is
    -- authoritative about whether one is outstanding. Only copying it when
    -- non-nil would leave a stale debt pinned forever on the client that
    -- settled it — which reads as "I can never play again".
    self.game_state.pendingMarketDraw = state.pendingMarketDraw

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
        msg.post(GUI_HUD, "turn", { who = "player", duration = duration,
            expires_at = expires_at, grace = config.GRACE_SECONDS })
    elseif current_turn ~= nil and tostring(current_turn) ~= "" then
        self.current_turn = "ai"
        self.waiting = true
        msg.post(GUI_HUD, "turn", { who = "ai", duration = duration,
            expires_at = 0, grace = config.GRACE_SECONDS })
    else
        msg.post(GUI_HUD, "stop_timers")
    end
end

function M.end_turn(self)
    if not self.online_mode then return end
    -- The round is decided; there is no turn left to end. ws.send_move refuses
    -- this too, but stopping here also keeps the local turn bookkeeping below
    -- (waiting, last_local_play, the cleared action list) from running on a
    -- game that has finished.
    if self.game_over then
        print("[ONLINE] end_turn ignored: the game is over")
        return
    end

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
    msg.post(GUI_HUD, "turn", { who = "ai", duration = PLAY_TIMEOUT_DURATION_S,
        expires_at = 0, grace = config.GRACE_SECONDS })

    self.current_turn_actions = {}
end

function M.sync_deck_size(self, target_size)
    if not target_size then return end
    if #self.deck < target_size then
        local diff = target_size - #self.deck
        for i = 1, diff do
            local idx = #self.deck + 1
            -- take_card reuses a hidden card from the pool this same
            -- function's shrink branch below returns cards to, instead of
            -- always spawning a fresh one. See card_view.lua.
            local c = CV.take_card(self, 10, "H", vmath.vector3(self.DECK_POS.x + idx * 0.5, self.DECK_POS.y - idx * 0.5, idx * 0.001))
            table.insert(self.deck, c)
        end
    elseif #self.deck > target_size then
        local diff = #self.deck - target_size
        for i = 1, diff do
            local c = table.remove(self.deck, 1)
            -- Hidden and pooled for reuse, NOT deleted — this was the root
            -- of every "Instance (null) not found" traced in this codebase's
            -- recent history: a reshuffle or a draw already under way can be
            -- holding a reference to exactly the card this shrink is about
            -- to touch, and a go.delete'd instance raises the moment
            -- anything reads its position afterward. A hidden one is still
            -- a perfectly valid object to read a stale position from — it
            -- just isn't drawn. See card_view.lua's release_card/take_card.
            CV.release_card(self, c)
        end
    end
end

function M.public_player_info(p)
    p = p or {}
    -- Display the chosen USERNAME only — never the identity-provider /
    -- mobile-money `names` field. An unset/empty username is normalized to
    -- nil so each display site's own placeholder ("PLAYER" / "Opponent")
    -- kicks in instead of a blank or someone's real name.
    local uname = p.username
    if uname == "" then uname = nil end
    return {
        id          = p.id or p._id or "",
        _id         = p._id or p.id or "",
        username    = uname,
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
    local my_id = tostring(ws.get_current_user_id() or "")
    for i, r in ipairs(ranks) do
        if i > 7 then break end
        -- backend rank rows carry `userId`; keep id/_id fallbacks too
        local id = r.id or r._id or r.userId
        out[#out + 1] = {
            position = r.position,
            username = r.username,
            points   = r.points,
            id       = id,
            -- Decide "YOU" locally against this client's own id rather than
            -- trusting the row's `active` flag — a game-over standings row
            -- is broadcast identically to both players, so a server-set
            -- flag would mark BOTH the winner's and loser's row as "YOU"
            -- on every client.
            active   = tostring(id or "") == my_id,
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
            -- Username only, never the `names` field.
            name       = (p.username ~= nil and p.username ~= "" and tostring(p.username)) or "PLAYER",
            avatar     = tonumber(p.avatar) or 1,
            total      = tonumber(p.cumulativeScore) or 0,
            eliminated = p.eliminated and true or false,
        }
    end
    return rows
end

-- Re-seed the cumulative-counting baseline from the server every time the
-- board is built.
--
-- _knockout_scores is what the round-end counting animation counts UP FROM, so
-- it has to survive between rounds of a series — which is why it was never
-- cleared, and why a previous series' totals used to live on and get added to.
-- Clearing it instead would break the counting (every round would count up
-- from zero). Overwriting it with the server's authoritative cumulative totals
-- does both jobs: correct within a series, and impossible to inherit across
-- one.
function M.seed_knockout_totals(self, state)
    local seeded, sum = {}, 0
    for pid, p in pairs((state or {}).players or {}) do
        local t = tonumber(p.cumulativeScore) or 0
        seeded[tostring(pid)] = t
        sum = sum + t
    end
    self._knockout_scores = seeded
    -- Everyone on zero means this is round 1 of a fresh series, so the
    -- per-round history from the last one must not be carried into it. Mid
    -- series it is left alone — those rows are this series' own record.
    if sum == 0 then self._knockout_history = nil end
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
    local changed = false
    self._ko_totals = self._ko_totals or {}

    for pid, p in pairs((state or {}).players or {}) do
        local total = tonumber(p.cumulativeScore) or 0
        if self._ko_totals[tostring(pid)] ~= total then
            self._ko_totals[tostring(pid)] = total
            changed = true
        end
        msg.post(GUI_HUD, "t4_chamber_update", {
            name       = (p.username ~= nil and p.username ~= "" and tostring(p.username)) or "PLAYER",
            total      = total,
            threshold  = cap,
            eliminated = p.eliminated and true or false,
            added      = 0,
        })
    end

    -- Re-sort the standings (lowest total on top, so whoever has MORE points
    -- sits below, and eliminated players sink to the bottom). t4_ui only
    -- reflows when told to — deliberately not on every chamber_update — and
    -- the online path never sent this at all, so the rows stayed in whatever
    -- order they were first inserted. Only fire it when a total actually
    -- moved, which in a 2-player knockout means once per round transition.
    if changed then
        msg.post(GUI_HUD, "t4_chamber_reflow", {})
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

    -- Knockout games render the score-cap chamber table, so the battle
    -- scoreboard flippers stay hidden. BUT pass h2h_msg so the last 5 games form strip displays!
    if is_knockout_state(state) or self._is_knockout then
        msg.post(GUI_HUD, "update_scoreboard", { show = false, h2h = h2h_msg })
        return
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
    -- NOBODY WAS LISTENING TO THIS, AND IT IS THE SERVER SAYING "NO".
    --
    -- websocket_manager emits `error` for every ERROR frame, and not one
    -- subscriber existed anywhere in the client — so a refused move was
    -- emitted into nothing. handleMove refuses a draw it cannot satisfy with
    -- exactly that and returns, sending no state and never changing the turn,
    -- which leaves is_waiting_for_server_response set with nothing to clear
    -- it. The board then froze until the app was restarted.
    --
    -- An ERROR arriving while we are waiting IS the answer to our move. The
    -- watchdog in update() would catch it ten seconds later regardless; this
    -- makes it immediate, which is the difference between a hitch and a hang.
    table.insert(self.ws_listeners, ws.on("error", function(message)
        msg.post(board, "ws_server_error", { message = tostring(message or "") })
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
    -- Gap between two consecutive PLAYs of a combo: cards still overlap in
    -- flight (each flight is 0.42s), but with enough daylight between
    -- launches that every card reads clearly — 0.13 made a big combo blur
    -- into one motion. Spreading the launches out also lowers PEAK per-frame
    -- animation load, which is what dents the frame rate for anything else
    -- animating at the same time (emoji reactions, most visibly).
    local PLAY_STAGGER = 0.22
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

        if act.type == "PLAY" then
            idx = idx + 1
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
            local nxt = actions[idx]
            local in_combo = nxt and nxt.type == "PLAY"
            -- Mid-combo, DON'T reflow the whole hand after every single
            -- card — each reflow re-tweens every remaining card in both
            -- hands, and stacking one of those per combo card was the
            -- single biggest chunk of concurrent animation work (the thing
            -- that starved any emoji animation running at the same time).
            -- One reflow when the combo finishes closes all the gaps at
            -- once, which also reads cleaner.
            if not in_combo then self.position_hands(true) end
            -- Combo: the next card of a multi-card play launches after only a
            -- small stagger, overlapping this one's flight to the pile.
            timer.delay(in_combo and PLAY_STAGGER or INTER, false, next_act)

        elseif act.type == "DRAW" then
            -- Coalesce this and every immediately-following DRAW into ONE
            -- staggered batch through draw_to_hand (0.13/card, all in flight
            -- together) — exactly how the player's own multi-draw animates —
            -- instead of one hard-coded single-card draw per action with a
            -- fixed beat in between. Honors act.count when the server sends
            -- a batched draw action (mirrors process_my_actions).
            local count = tonumber(act.count) or 1
            idx = idx + 1
            while actions[idx] and actions[idx].type == "DRAW" do
                count = count + (tonumber(actions[idx].count) or 1)
                idx = idx + 1
            end
            self.draw_to_hand(self.ai_hand, false, count, function()
                if seq == self._seq then next_act() end
            end)
        else
            idx = idx + 1
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

    -- Same guard M.process_opponent_actions' finish() already applies before
    -- showing the shape-preview overlay: never open it once either hand has
    -- actually emptied (the round is over on this exact move). Missing this
    -- guard here — this function runs on EVERY server sync, not just
    -- opponent PLAYs — let a Whot wildcard (rank 20) played as the winning
    -- last card leave the full-screen suit_select overlay open (it renders
    -- above the game-over modal and swallows all input even while
    -- invisible in "preview" mode) with nothing left to ever post it a
    -- "close" — ordinarily the next play does that, but there is no next
    -- play once the game has ended.
    local op_for_suit = (state.players or {})[self.opponent_id] or {}
    local op_hand_for_suit = (type(op_for_suit.hand) == "table") and op_for_suit.hand or nil
    local opp_hand_count = op_for_suit.handCount or (op_hand_for_suit and #op_hand_for_suit) or #self.ai_hand
    local game_still_active = opp_hand_count > 0 and #self.player_hand > 0

    if state.chosenSuit and state.chosenSuit ~= "" and game_still_active then
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

        local op = op_for_suit
        local real_hand = op_hand_for_suit
        local target = opp_hand_count

        local function settle()
            stamp_ai_hand(self, real_hand)
            -- self.game_state, NOT the closure-captured `state`. A reshuffle
            -- animation defers this settle() by ~1.5-2.6s (see
            -- M.reshuffle_deck below); if a newer MOVE/game_start arrives
            -- while it's in flight, that newer call runs synchronously up to
            -- `self.game_state = state` (above) and, finding
            -- self._online_reshuffling already true, calls do_sync()
            -- immediately with the CORRECT state. This older settle() then
            -- fires later and used to reapply its own stale `state` on top —
            -- silently reverting currentTurn/activePenaltyCount to the
            -- pre-reshuffle values. Every self-healing watchdog is gated on
            -- is_player_turn(), so a wrong currentTurn here permanently
            -- locks the turn (and, for the same reason, the draw pile on a
            -- penalty) with nothing left to re-sync until the app restarts.
            -- self.game_state is always whatever the most recent call set it
            -- to, so re-applying it here is a no-op in the common case and
            -- the fix in the race.
            M.sync_timers(self, self.game_state)
            if on_complete then on_complete() end
        end

        if #self.ai_hand < target then
            local diff = target - #self.ai_hand
            self.draw_to_hand(self.ai_hand, false, diff, function() settle() end)
        else
            while #self.ai_hand > target do
                local c = table.remove(self.ai_hand)
                -- Same reasoning as sync_deck_size's shrink branch above: an
                -- opponent card is just as anonymous/face-down as a deck
                -- card until it is actually played, so it is just as safe to
                -- hide and reuse instead of deleting out from under whatever
                -- else might still be holding a reference to it.
                CV.release_card(self, c)
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
    elseif RQ.is_running(self) then
        -- A DIFFERENT sync's reshuffle is still animating (self.deck holds
        -- its own snapshot of the pre-reshuffle deck the whole time — see
        -- M.reshuffle_deck). This state sync didn't trigger should_reshuffle
        -- itself, but running do_sync() right now would still call
        -- sync_deck_size on self.deck WHILE that snapshot is in flight —
        -- including go.delete'ing a card the reshuffle still holds a
        -- reference to, which used to raise inside its own delayed
        -- go.set/go.animate calls and abort it partway, leaving the board
        -- locked and the recycled cards stranded mid-sweep. Queue behind the
        -- reshuffle instead of racing it; RQ answers every waiter once it
        -- finishes, abandoned or not.
        RQ.wait(self, do_sync)
    else
        do_sync()
    end
end

function M.process_my_actions(self, actions, done)
    local idx = 1
    local seq = self._seq
    local INTER  = 0.24
    -- Same combo treatment as process_opponent_actions: consecutive PLAYs
    -- overlap in flight, spaced far enough apart to read clearly and keep
    -- peak per-frame animation load down.
    local PLAY_STAGGER = 0.22
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

        if act.type == "PLAY" then
            idx = idx + 1
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
            local nxt = actions[idx]
            local in_combo = nxt and nxt.type == "PLAY"
            -- Same as process_opponent_actions: one hand reflow at combo
            -- end, not one per card — keeps peak animation load flat.
            if not in_combo then self.position_hands(true) end
            timer.delay(in_combo and PLAY_STAGGER or INTER, false, next_act)

        elseif act.type == "DRAW" then
            -- Coalesce consecutive DRAW actions into one staggered batch —
            -- own-turn draws are recorded one action per card (see
            -- game_flow.draw_to_hand), so a +4 replay would otherwise run as
            -- four separate single-card batches back to back.
            local count = tonumber(act.count) or 1
            idx = idx + 1
            while actions[idx] and actions[idx].type == "DRAW" do
                count = count + (tonumber(actions[idx].count) or 1)
                idx = idx + 1
            end
            self.draw_to_hand(self.player_hand, true, count, function()
                if seq == self._seq then next_act() end
            end)
        else
            idx = idx + 1
            next_act()
        end
    end

    if #actions == 0 then
        if done then done() end
    else
        next_act()
    end
end

-- `done` IS NOT OPTIONAL BOOKKEEPING — IT IS THE END OF THE APPLY.
--
-- handle_single_move called this and then released is_processing_move on the
-- very next line. When the reconciliation below has cards to add, it LAUNCHES
-- draw_to_hand and returns immediately, so the lock came off while the
-- player's own new cards were still flying into their hand — which is exactly
-- the window in the report: the opponent's move has landed, the board is still
-- moving, and a tap goes straight out as a move.
local function sync_my_hand(self, state, done)
    local finish = function() if done then done() end end
    local me = (state.players or {})[self.my_player_id] or {}
    local real = (type(me.hand) == "table") and me.hand or nil
    if not real then finish(); return end

    -- Reconcile by card identity (value+suit) as a multiset, not by array
    -- position. The local and server hand arrays aren't guaranteed to stay
    -- in the same relative order (a forced draw or a removed play can land
    -- anywhere), so an index-for-index overwrite could silently reassign a
    -- still-held card's face onto a DIFFERENT card's game object — reading
    -- as a random card "vanishing" — instead of only touching the cards
    -- that actually changed. This especially broke around duplicate cards
    -- (Whot has 5 identical 20/W wildcards, so two never-played copies
    -- could still get relabeled into looking like just one).
    local pool = {}
    for _, rc in ipairs(real) do
        local key = tostring(rc.v) .. "|" .. tostring(rc.s)
        pool[key] = pool[key] or {}
        table.insert(pool[key], rc)
    end

    local kept = {}
    for _, c in ipairs(self.player_hand) do
        local key = tostring(c.v) .. "|" .. tostring(c.s)
        local bucket = pool[key]
        if bucket and #bucket > 0 then
            table.remove(bucket) -- consume one matching server card
            kept[#kept + 1] = c
        else
            -- Released, not deleted — same reasoning as sync_deck_size's and
            -- the AI-hand shrink's own release_card calls: this card being
            -- reconciled away here could still be mid-animation (a play
            -- that hasn't finished flying to the pile yet) even with the
            -- self.game_state freshness fix above, and a hidden-but-alive
            -- object degrades that race into nothing instead of "Instance
            -- (null) not found".
            CV.release_card(self, c)
        end
    end
    for i = #self.player_hand, 1, -1 do self.player_hand[i] = nil end
    for i, c in ipairs(kept) do self.player_hand[i] = c end

    -- Whatever's left in `pool` are server cards this client hasn't
    -- represented locally yet (new draws) — add exactly that many.
    local to_add = {}
    for _, bucket in pairs(pool) do
        for _, rc in ipairs(bucket) do to_add[#to_add + 1] = rc end
    end

    if #to_add > 0 then
        self.draw_to_hand(self.player_hand, true, #to_add, function()
            local n = #self.player_hand
            for i = 1, #to_add do
                local c = self.player_hand[n - #to_add + i]
                local rc = to_add[i]
                if c and rc then
                    c.v = tonumber(rc.v) or c.v
                    c.s = tostring(rc.s or c.s)
                    self.set_face(c)
                end
            end
            self.pre_validate_hand()
            finish()
        end)
    else
        self.position_hands(true)
        self.pre_validate_hand()
        finish()
    end
end

-- FULL BOARD RESYNC — deck, opponent hand, played pile/timers, AND our own
-- hand, all reconciled against server truth. Exactly the sequence
-- handle_single_move already runs after every ordinary move (finalize_state_
-- sync then sync_my_hand); exposed here so a live in-app reconnect
-- (ws_player_rc/ws_net_up in game.script) can run the SAME full catch-up
-- instead of only sync_timers's narrow turn/timer bookkeeping.
--
-- That narrower sync was the actual bug behind two reports that looked
-- unrelated: a card played right before a disconnect (or one that arrived
-- from the opponent, or a partial penalty draw) never showing up anywhere —
-- not in hand, not on the played pile — until some LATER move finally
-- triggered a real resync via handle_single_move and the board visibly
-- lurched to catch up all at once. sync_timers alone was never going to fix
-- that: it only ever touched currentTurn/turnExpiresAt/activePenaltyCount/
-- chosenSuit/pendingMarketDraw on self.game_state, never the actual card
-- objects in self.player_hand, self.played_cards or self.deck. A reconnect
-- has exactly as much to catch up on as an ordinary move does — it needs
-- the same machinery, not a smaller one.
-- A RECONNECT MUST NEVER RACE A MOVE THAT IS ALREADY BEING APPLIED.
--
-- handle_single_move's own finalize_state_sync/sync_my_hand run serialized —
-- pump_move_queue holds self.is_processing_move true for the whole apply, so
-- only ever one is in flight. full_resync did not check that flag at all: a
-- reconnect landing WHILE a healthy (not stuck — the stall watchdog is a
-- separate, already-safe path that explicitly clears the flag before taking
-- over, see rebuild_from_server in game.script) move was still animating
-- would start a SECOND, concurrent finalize_state_sync racing the first —
-- both independently deciding self.ai_hand needs N more cards, from a count
-- neither had finished writing yet, and both drawing them. Reported as extra
-- cards on the opponent's side that were never real and never went away,
-- even once the game ended, because destroy_all deletes whatever ends up IN
-- self.ai_hand — it just never asked whether some of it was a duplicate.
--
-- Polled rather than queued through pump_move_queue itself: this can fire
-- from a screen the queue is not currently draining (round transition,
-- suit-selection wait), and the ordinary move it is waiting on will finish
-- and flip the flag on its own regardless of who else is watching for that.
-- Capped, not indefinite — the flag WILL eventually go false (the move
-- finishes, or the stall watchdog forces it), but a coordinated wait must
-- still not be a way for a Lua state to leak polling forever if the game
-- object is torn down while this is pending.
local RESYNC_WAIT_POLL_S = 0.1
local RESYNC_WAIT_CAP_S  = 5.0

function M.full_resync(self, state, done)
    local function run()
        M.finalize_state_sync(self, state, function()
            -- self.game_state, not the `state` argument — finalize_state_sync's
            -- own do_sync can be deferred behind a reshuffle for over a second,
            -- and a newer state can land and overwrite self.game_state while
            -- that's in flight. Same reasoning as handle_single_move's two call
            -- sites for sync_my_hand.
            sync_my_hand(self, self.game_state or state or {}, done)
        end)
    end

    if not self.is_processing_move then
        run()
        return
    end

    local waited = 0
    local function poll()
        if self.game_over or not self.is_processing_move or waited >= RESYNC_WAIT_CAP_S then
            run()
            return
        end
        waited = waited + RESYNC_WAIT_POLL_S
        timer.delay(RESYNC_WAIT_POLL_S, false, poll)
    end
    timer.delay(RESYNC_WAIT_POLL_S, false, poll)
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
            -- Reconcile the human's own hand against server truth too, not
            -- just the opponent's — an opponent's move can change OUR hand
            -- server-side (Whot's General Market/14 forces the human to
            -- draw as a side effect of the OPPONENT'S play), and until now
            -- only the ai_for_me branch below ever called sync_my_hand.
            -- Left uncorrected here, the client's local player_hand quietly
            -- drifts from the server's authoritative hand and stays wrong
            -- until some later, unrelated resync happens to catch it.
            M.finalize_state_sync(self, new_state, function()
                -- self.game_state, NOT the closure-captured new_state — same
                -- reasoning as settle() above. process_opponent_actions runs
                -- staggered per-card animations before this callback fires,
                -- and finalize_state_sync's own do_sync can be deferred
                -- behind a reshuffle for ~1.3s+ on top of that. A newer move
                -- (the player's OWN just-played card getting confirmed, or
                -- another opponent action) can land and overwrite
                -- self.game_state while this chain is still unwinding —
                -- reconciling against the stale new_state then means
                -- sync_my_hand sees a hand that still includes a card the
                -- player has since played, and adds it right back. Reported
                -- as "I played a card and it reappeared in my hand".
                sync_my_hand(self, self.game_state or new_state or {}, done)
            end)
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
                -- self.game_state, NOT new_state — see the identical fix and
                -- reasoning just above in the opponent-move branch.
                sync_my_hand(self, self.game_state or new_state or {}, done)
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

    -- THE MATCH'S THEME, NOT EITHER PLAYER'S OWN.
    --
    -- The server already resolved which of the two players' active themes is
    -- worth showing off (cardUtils.ts's selectWinningTheme — higher price
    -- wins) and put the plain id on state.theme; both clients apply the SAME
    -- one here rather than each rendering their own local pick, so the
    -- winner's theme is what both people actually see for this game. Runs on
    -- every call, not just the first — a new round of the same series is a
    -- new state.theme too (see the backend comment on why), and the ONLY two
    -- render call sites (card_defs.lua's back_frame, card.script's card_set)
    -- both call app_state.get_theme() fresh rather than caching it, so
    -- overriding the single shared app_state.theme here is enough to cover
    -- both without either needing its own change. Restored to the player's
    -- OWN theme when they leave the game screen — see game.script's
    -- "disable" handler.
    local match_theme = state and state.theme
    app_state.theme = (type(match_theme) == "string" and match_theme ~= "") and match_theme or "default"

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
        -- Include the opponent id: tournamentId alone stays identical across
        -- different freelancer opponents at the same level (a level can be
        -- replayed against someone new after the previous match was
        -- abandoned/unfinished), which previously made is_continuation below
        -- wrongly true and kept rendering the stale scoreboard from the old
        -- opponent instead of resetting for the new pairing.
        series_key = "t:" .. t_id .. ":" .. tostring(self.opponent_id)
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
    -- Matatu-only: a side "cutting card" placed beside the deck. The server
    -- sends `cuttingCard` for every game (it's the Whot/Kadi initial deal's
    -- starter too), but only Matatu treats it as a persistent side card —
    -- Whot/Kadi's true top-of-pile lives in state.currentCard/playedCards
    -- (rebuilt into the discard pile below), so never render it as one there.
    local cut_card  = GameMode.is_matatu() and state.cuttingCard or nil

    self.active_penalty = state.activePenaltyCount or 0
    self.chosen_suit    = state.chosenSuit or ""

    if state.rank then msg.post(GUI_HUD, "update_standings", { ranks = M.slim_ranks(state.rank) }) end

    local my_pub = M.public_player_info(mp)
    local op_pub = M.public_player_info(op)
    msg.post(GUI_HUD, "setup_avatars", { my_info = my_pub, op_info = op_pub })
    msg.post(GUI_OVER, "setup_avatars", { my_info = my_pub, op_info = op_pub })
    self._is_knockout = is_knockout_state(state)
    -- The chamber is rebuilt from scratch here, so drop the change-tracking
    -- totals with it — otherwise the first update of a new round would look
    -- unchanged and skip the reflow.
    self._ko_totals = nil
    if self._is_knockout then M.seed_knockout_totals(self, state) end
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
        -- Same tightened ratio layout_hand uses for the smaller opponent
        -- cards — dealing at full spacing made the first reflow visibly
        -- squeeze the hand right after the deal finished.
        local a_spacing = self.calc_spacing(a_count, BL.OPPONENT_SCALE_RATIO)
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
                pc._hand_target = vmath.vector3(pt.x, pt.y, pt.z)
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
                go.set(ac.id, "scale", BL.CARD_SCALE)
                ac._hand_target = vmath.vector3(at.x, at.y, at.z)
                go.animate(ac.id, "position", go.PLAYBACK_ONCE_FORWARD, at, go.EASING_OUTCUBIC, 0.3, delay)
                timer.delay(delay, false, function()
                    if seq ~= self._seq then return end
                    -- Known-up-front opponent size: the card takes its ACTUAL
                    -- final scale the instant its deal flight starts — no
                    -- shrink tween, no post-deal batch resize.
                    go.set(ac.id, "scale", BL.OPPONENT_CARD_SCALE)
                    self.play_sound("SoundDraw")
                end)
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
                -- The starter card is dealt off the deck like any other card
                -- rather than simply materialising in the middle of the board:
                -- it launches face-down from the deck the moment the deck has
                -- settled into its final position, flips over mid-flight, and
                -- lands on the pile. Previously it just appeared, which read as
                -- a glitch next to every other card's dealt animation.
                local rec = self.spawn_card(tonumber(top_card.v) or 10, tostring(top_card.s or "H"),
                    vmath.vector3(self.DECK_POS.x, self.DECK_POS.y, self.Z_FLY))
                self.set_back(rec)
                table.insert(self.played_cards, rec)

                local FLIGHT = 0.32
                self.play_sound("SoundDraw")
                go.animate(rec.id, "position", go.PLAYBACK_ONCE_FORWARD,
                    vmath.vector3(self.CENTER.x, self.CENTER.y, self.Z_FLY),
                    go.EASING_OUTCUBIC, FLIGHT, 0,
                    function()
                        if seq == self._seq then go.set(rec.id, "position.z", self.Z_PILE) end
                    end)
                -- Flip at the halfway point so it arrives already face-up.
                timer.delay(FLIGHT * 0.5, false, function()
                    if seq == self._seq then self.set_face(rec) end
                end)
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