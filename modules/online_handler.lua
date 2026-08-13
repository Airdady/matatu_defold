local ws = require "modules.websocket_manager"
local Defs = require "modules.card_defs"
local CV = require "modules.card_view"
local GameMode = require "modules.game_mode"
local BL = require "modules.board_layout"
local config = require "modules.config"
local app = require "modules.app_state"

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

-- THE PILE'S TOP CARD, FROM THE SERVER.
--
-- The one collection nothing reconciled. stamp_deck fixes the deck,
-- stamp_ai_hand the opponent's hand, sync_my_hand the player's — the discard
-- pile had no equivalent, so a wrong identity on it stayed wrong for the rest
-- of the game.
--
-- It could get one easily. process_opponent_actions, when it cannot find the
-- played card in the opponent's hand, takes ANY card from that hand and
-- RELABELS it (`rec.v, rec.s = v, s`) before flying it to the pile. That is the
-- right call for the animation — something has to fly — but it means the pile
-- can end up showing a card the server never played.
--
-- Paired with sync_my_hand, which correctly restores the real card into the
-- player's hand, the result is the same card visible in two places at once:
-- once in the hand, once on the pile. Exactly the reported duplicate.
--
-- Only the TOP is stamped. It is the card in play, the only one whose identity
-- is legible, and the only one any rule reads. The cards beneath are scatter.
local function stamp_pile_top(self, state)
    local top = (state or {}).currentCard
    if type(top) ~= "table" or top.v == nil then return end
    local rec = self.played_cards and self.played_cards[#self.played_cards]
    if not rec or not rec.id then return end

    local v, sv = tonumber(top.v), tostring(top.s or "")
    if v == nil or sv == "" then return end
    if tonumber(rec.v) == v and tostring(rec.s) == sv then return end

    rec.v, rec.s = v, sv
    -- Face-up, unlike the deck and the opponent's hand, so the sprite has to be
    -- redrawn — setting the fields alone would leave the old art on screen.
    pcall(self.set_face, rec)
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
            -- sync: replaying draws the server already dealt to the opponent.
            self.draw_to_hand(self.ai_hand, false, count, function()
                if seq == self._seq then next_act() end
            end, { sync = true })
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

    -- Syncs against the LATEST state, not the one this call was handed.
    --
    -- A reshuffle animation defers its do_sync() by ~1.5-2.6s. Newer server
    -- messages keep arriving during it, and every finalize_state_sync call
    -- assigns self.game_state synchronously at the top — so by the time the
    -- deferred sync finally runs, the state it captured is stale. Applying the
    -- stale one used to revert currentTurn/activePenaltyCount to their
    -- pre-reshuffle values; since every self-healing watchdog is gated on
    -- is_player_turn(), a wrong currentTurn there locks the turn for good.
    --
    -- It matters twice as much for the deck. stamp_deck is the ONLY thing that
    -- gives self.deck the server's card identities, and those identities are
    -- what every DRAW action is validated against — stamping a stale deck is
    -- not a cosmetic lag, it is the client disagreeing with the server about
    -- which card is on top, which costs the next move entirely.
    --
    -- self.game_state is always whatever the most recent call set it to, so
    -- reading it here is a no-op in the common case and the fix in the race.
    local function do_sync(sync_state)
        sync_state = sync_state or self.game_state or state

        local op        = (sync_state.players or {})[self.opponent_id] or {}
        local real_hand = (type(op.hand) == "table") and op.hand or nil
        local target    = op.handCount or (real_hand and #real_hand) or #self.ai_hand

        local deck_target = sync_state.deckCount or (sync_state.deck and #sync_state.deck) or #self.deck
        M.sync_deck_size(self, deck_target)
        stamp_deck(self, sync_state.deck)
        stamp_pile_top(self, sync_state)

        local function settle()
            stamp_ai_hand(self, real_hand)
            M.sync_timers(self, self.game_state)
            if on_complete then on_complete() end
        end

        if #self.ai_hand < target then
            local diff = target - #self.ai_hand
            -- sync: closing the gap to the server's opponent hand count;
            -- stamp_ai_hand in settle() gives these cards their identities.
            self.draw_to_hand(self.ai_hand, false, diff, function() settle() end, { sync = true })
        else
            while #self.ai_hand > target do
                local c = table.remove(self.ai_hand)
                pcall(go.delete, c.id)
            end
            self.position_hands(true)
            settle()
        end
    end

    -- The server TELLS us it reshuffled. handleDeckReshuffle sets
    -- status = "RESHUFFLING" purely as a flag for this animation, and
    -- handleMove broadcasts the state while it is still set (it resets to
    -- PLAYING only after the send loop). So the flag is on the MOVE payload
    -- for both players, and reading it is exact where the guesswork below is
    -- not: the old heuristic both missed real reshuffles and fired on moves
    -- that were not one, and a spurious reshuffle animation takes ownership of
    -- self.deck for seconds at a time.
    --
    -- The heuristic stays as a fallback for a server that did not send a
    -- status at all, so a build mismatch degrades to the old behavior instead
    -- of never animating.
    local server_status    = state.status and tostring(state.status) or nil
    local should_reshuffle
    if server_status then
        should_reshuffle = (server_status == "RESHUFFLING")
    else
        local deck_target     = state.deckCount or (state.deck and #state.deck) or #self.deck
        local incoming_played = (type(state.playedCards) == "table") and #state.playedCards or nil
        local pile_was_reset  = incoming_played ~= nil and incoming_played <= 1
        local deck_jumped     = deck_target >= (#self.deck + 6)
        should_reshuffle = (#self.played_cards > 3) and (pile_was_reset or deck_jumped)
    end

    if should_reshuffle and not self._online_reshuffling then
        self._online_reshuffling = true
        msg.post(GUI_HUD, "skip", { show = false })
        self.reshuffle_deck(function()
            self._online_reshuffling = false
            do_sync()
        end)
    elseif self._online_reshuffling then
        -- A reshuffle triggered by an EARLIER sync is still mid-animation and
        -- owns self.deck — game_flow.lua's reshuffle_deck/draw_to_hand is
        -- actively table.remove-ing and go.set/go.animate-ing its cards on a
        -- staggered schedule that can run several seconds. do_sync() below
        -- calls sync_deck_size(), which ALSO table.remove()s and go.delete()s
        -- straight out of self.deck with no coordination at all — running it
        -- here, concurrently, is exactly what let a card the in-flight
        -- reshuffle still expected to draw get deleted out from under it:
        -- "could not find any instance with id '/instanceN'" out of
        -- game_flow.place_one, which then left the turn permanently stuck
        -- (the crash aborts the draw before it can ever release the
        -- is_animating/is_local_action_locked flags it set).
        --
        -- Skip the sync here and let the reshuffle already running finish —
        -- its own completion callback calls do_sync() once reshuffle_deck no
        -- longer owns self.deck. Nothing is lost by deferring: do_sync() reads
        -- self.game_state, which this call has already updated to THIS state a
        -- few lines above, so the deferred sync converges on the newest server
        -- truth rather than the state that triggered the reshuffle.
        --
        -- on_complete still fires immediately either way: it resolves to
        -- handle_single_move's `done()`, which drains pump_move_queue — not
        -- calling it here would stall every move queued up behind this one,
        -- not just the deck visual.
        if on_complete then on_complete() end
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
            -- sync: this is a REPLAY of a move the server already accepted and
            -- echoed back, so it reports nothing and the identities are
            -- reconciled by sync_my_hand right after.
            self.draw_to_hand(self.player_hand, true, count, function()
                if seq == self._seq then next_act() end
            end, { sync = true })
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

local function sync_my_hand(self, state)
    local me = (state.players or {})[self.my_player_id] or {}
    local real = (type(me.hand) == "table") and me.hand or nil
    if not real then return end

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
            pcall(go.delete, c.id)
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
        -- sync: this is CATCH-UP, not a draw. Every card in `to_add` was read
        -- out of the server's own copy of this hand, so it has already been
        -- dealt — reporting it as a DRAW action would send it back with the
        -- next move and ask to be dealt it again, against a deck top that no
        -- longer holds it. The loop below stamps each card's real identity.
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
        end, { sync = true })
    else
        self.position_hands(true)
        self.pre_validate_hand()
    end
end

-- Bring the discard pile back down to the server's count, oldest first.
--
-- Only needed after a REPLAYED move. A catch-up animates a card onto a pile
-- that the IDENTIFY rebuild has ALREADY placed it on, so the pile ends up one
-- card deeper than the server's. Nothing else reconciles it: do_sync converges
-- the deck and both hands, but never playedCards.
--
-- Left alone that surplus is not just cosmetic — reshuffle_deck recycles
-- whatever is on the pile, so the client would hand a card back to the deck
-- that the server still counts as played, and the two decks would disagree on
-- length at exactly the moment draws are being validated against them.
--
-- Trims from the BOTTOM and never touches the last card: the top of the pile is
-- the card in play, and the ones underneath it are inert scatter.
local function trim_pile_to(self, target)
    if type(target) ~= "number" or target < 1 then return end
    while #self.played_cards > target and #self.played_cards > 1 do
        local c = table.remove(self.played_cards, 1)
        if c and c.id then pcall(go.delete, c.id) end
    end
end

function M.handle_single_move(self, move_data, new_state, done)
    if self.game_over then done(); return end

    local sender      = tostring((move_data and (move_data._id or move_data.from)) or "")
    local is_my_move  = (sender ~= "" and sender == tostring(self.my_player_id))
    local actions     = (move_data and move_data.actions) or {}
    local has_actions = #actions > 0
    local ai_for_me   = is_my_move and (move_data and move_data.aiOnBehalf) and true or false
    local is_replay   = (move_data and move_data.isReplay) and true or false

    -- A catch-up plays out like any other move — that is the point of it — but
    -- the pile it lands on already contains the card, so square it up after.
    local original_done = done
    if is_replay then
        done = function()
            local served = (type(new_state) == "table" and type(new_state.playedCards) == "table")
                and #new_state.playedCards or nil
            trim_pile_to(self, served)
            original_done()
        end
    end

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
                sync_my_hand(self, new_state or {})
                done()
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

-- ── WHICH SERIES DOES THIS STATE BELONG TO? ─────────────────────────────────
--
-- A stable identity for "the match/ladder these rounds are rounds OF", so two
-- consecutive game states can be compared: same key means the next state
-- continues what is already on screen, a different key (or none) means it is a
-- new match and everything showing belongs to the previous one.
--
-- Derived from the STATE rather than from self, because the two callers ask at
-- different moments: game_flow's start_game asks before the board has been
-- rebuilt (self.opponent_id has just been cleared by fresh_state), M.start_game
-- asks while building it. Reading the opponent out of state.players makes both
-- answers identical, which is the whole point — they gate different halves of
-- the same decision.
function M.series_key(self, state)
    state = type(state) == "table" and state or {}

    local ts  = (type(state.tournamentScore) == "table") and state.tournamentScore or nil
    local fmt = (ts and ts.matchFormat) or state.matchFormat
        or (type(state.tournament) == "table" and state.tournament.matchFormat) or nil

    local my_id = self.my_player_id
    if my_id == nil or my_id == "" then my_id = ws.get_current_user_id() end
    my_id = tostring(my_id or "")

    local opp = ""
    for k, v in pairs(state.players or {}) do
        local pid = tostring((type(v) == "table" and (v.id or v._id)) or k)
        if pid ~= my_id then opp = pid break end
    end

    local t_id = tostring(state.tournamentId or "")
    if t_id ~= "" then
        -- Include the opponent id: tournamentId alone stays identical across
        -- different freelancer opponents at the same level (a level can be
        -- replayed against someone new after the previous match was
        -- abandoned/unfinished), which previously made a new pairing look like
        -- a continuation and kept rendering the stale scoreboard from the old
        -- opponent.
        return "t:" .. t_id .. ":" .. opp
    elseif fmt then
        return "b:" .. opp .. ":" .. tostring(fmt)
    end
    return ""
end

-- Does this incoming state continue the series currently on screen?
--
-- False for the first game of anything, for a one-off match, and — the case
-- that matters — for a game of a DIFFERENT shape following the last one: a
-- tournament started right after a knockout, a battle after a tournament. Those
-- must tear the board furniture down, not inherit it.
function M.continues_series(self, state)
    local key = M.series_key(self, state)
    return key ~= "" and key == self._sb_series_key
end

-- Re-skin every card currently on the board.
--
-- card.script chooses its atlas in init() and re-chooses on an "apply_theme"
-- message; this is what sends it. Posted per card because Defold has no
-- broadcast to factory-created instances — and the board's cards are exactly
-- these five places, which is also why this lives here rather than in
-- app_state, which cannot see any of them.
--
-- Frame names are identical across the theme atlases, so a re-skin does not
-- disturb what each card is showing: a face stays a face, a back stays a back.
function M.apply_theme_to_cards(self)
    -- Each group carries whether its cards are face UP, because switching the
    -- atlas resets the sprite to its default animation — so every card has to
    -- be told what to show afterwards, and only the board knows which side each
    -- one is on. A hand and the pile are faces; the deck and the opponent's
    -- hand are backs.
    local groups = {
        { cards = self.deck,         face = false },
        { cards = self.ai_hand,      face = false },
        { cards = self.player_hand,  face = true  },
        { cards = self.played_cards, face = true  },
        { cards = self.cutting_card and { self.cutting_card } or nil, face = true },
    }
    local back = Defs.back_frame()
    for _, group in ipairs(groups) do
        for _, c in ipairs(group.cards or {}) do
            if c and c.id then
                local frame = back
                if group.face then
                    local ok, name = pcall(Defs.frame_name, c)
                    if ok and name then frame = name end
                end
                -- "script" is the component id in main/card.go, the same way
                -- card_view.sprite_url targets "sprite".
                pcall(msg.post, msg.url(nil, c.id, "script"), "apply_theme", { frame = frame })
            end
        end
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
    -- The server has already decided which of the two players' active themes is
    -- worth showing off — cardUtils.ts's selectWinningTheme, higher price wins —
    -- and puts the answer on the state. Both clients apply that SAME one here
    -- instead of each rendering its own local pick, so the two people are
    -- looking at the same board. Whoever owns the better theme is the one
    -- everybody sees.
    --
    -- Runs on EVERY start_game, not just the first, so a new round of a series
    -- re-applies it rather than drifting back to the local default partway
    -- through a best-of-three.
    --
    -- PINNED, not merely assigned. sync_theme_from_user runs on IDENTIFY, and
    -- IDENTIFY fires on every reconnect — so simply setting app.theme here let
    -- a mid-game reconnect quietly reset the board to the VIEWER's own theme.
    -- For the player who does not own the match's theme that is the default
    -- sheet, and card.script reads the theme when a card is created, so every
    -- draw carrier and deck placeholder spawned afterwards was built from the
    -- wrong one — the reported "drawing a card shows the default theme".
    -- set_match_theme makes sync_theme_from_user stand down until the game
    -- screen clears it (game.script's "disable" handler).
    local match_theme = state and (state.theme or (type(state.activeTheme) == "table" and state.activeTheme.id))
    app.set_match_theme(match_theme)
    -- Re-skin anything still on the board from the previous game. Cards pick
    -- their atlas at creation, so leftovers would otherwise keep the old art
    -- until they were destroyed.
    M.apply_theme_to_cards(self)

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

    -- Same key, computed the same way, as the one game_flow's start_game used a
    -- moment ago to decide whether to tear the scoreboard and chamber down (see
    -- M.series_key). The two must agree: one decides whether the FURNITURE
    -- survives, this one decides whether the SCORES on it do.
    local t_id = tostring(state.tournamentId or "")
    local series_key = M.series_key(self, state)
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