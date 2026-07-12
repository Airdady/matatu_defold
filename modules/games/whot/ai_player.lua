--------------------------------------------------------------------
-- ai_player.lua  (WHOT build)
--
-- Pure-Lua Whot AI, ported from whot_ai.lua / WhotProAI.gd, plus a thin
-- decide()/choose() adapter so the existing offline engine and tournament
-- driver (game_logic.lua, offline_handler.lua, tournament4.lua) can keep
-- calling AI.decide(state, hand, has_drawn) unchanged.
--------------------------------------------------------------------

local Rules = require "modules.card_rules"

local M = {}

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------
local function is_empty(t) return t == nil or next(t) == nil end
local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end
local function get(t, key, default)
    if t == nil then return default end
    local v = t[key]
    if v == nil then return default end
    return v
end

----------------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------------
M.AI_CONFIG = {
    error_rate          = 0.01,
    bluff_frequency     = 0.35,
    lookahead_depth     = 5,
    risk_tolerance      = 0.9,
    suspicion_threshold = 0.65,
}

local NAT = Rules.NextActionType

M.SCORING_WEIGHTS = {
    handReduction         = 10,
    comboSetup            = 25,
    opponentDisruption    = 25,
    finishingPotential    = 40,
    whotControlValue      = 50,
    penaltyNeutralization = 45,
    holdOnCombo           = 40,
    generalMarketBonus    = 35,
    suspicionPenalty      = -150,
    reservationPenalty    = -300,
    unleashBonus          = 200,
    actionTypeBonus = {
        [NAT.CHOOSE_SHAPE]     = 60,
        [NAT.HOLD_ON]          = 50,
        [NAT.TRANSFER_PENALTY] = 40,
        [NAT.GENERAL_MARKET]   = 35,
        [NAT.SKIP_TURN]        = 25,
        [NAT.END_TURN]         = 5,
        [NAT.INVALID_MOVE]     = -100,
    },
}

----------------------------------------------------------------------
-- CARD TYPE HELPERS
----------------------------------------------------------------------
local PENALTY_VALUES        = { 2, 5 }
local SKIP_VALUES           = { 8 }
local HOLD_ON_VALUES        = { 1 }
local GENERAL_MARKET_VALUES = { 14 }
local WHOT_VALUE            = 20
M.SHAPES                    = { "C", "T", "X", "S", "R" }

function M.is_whot(card)
    return get(card, "v", 0) == WHOT_VALUE or get(card, "s", "") == "W"
end
function M.is_penalty_card(card)
    if is_empty(card) then return false end
    return contains(PENALTY_VALUES, get(card, "v", 0))
end
function M.is_skip_card(card)
    if is_empty(card) then return false end
    return contains(SKIP_VALUES, get(card, "v", 0))
end
function M.is_hold_on(card)
    if is_empty(card) then return false end
    return contains(HOLD_ON_VALUES, get(card, "v", 0))
end
function M.is_general_market(card)
    if is_empty(card) then return false end
    return contains(GENERAL_MARKET_VALUES, get(card, "v", 0))
end

----------------------------------------------------------------------
-- helpers to read hands out of game_state
----------------------------------------------------------------------
local function players(game_state) return get(game_state, "players", {}) end

local function hand_of(game_state, player_id)
    local p = players(game_state)[player_id]
    return get(p, "hand", {})
end

local function min_opponent_cards(game_state, player_id)
    local minc = 999
    for pid, pdata in pairs(players(game_state)) do
        if pid ~= player_id then
            minc = math.min(minc, #get(pdata, "hand", {}))
        end
    end
    if minc == 999 then return 7 end -- no opponent info: assume a typical hand
    return minc
end

----------------------------------------------------------------------
-- PHASE RULES
----------------------------------------------------------------------
function M.is_finishing_phase(game_state, player_id)
    local ai_hand = hand_of(game_state, player_id)
    local min_opp = min_opponent_cards(game_state, player_id)
    return #ai_hand <= 2 or (#ai_hand <= 3 and min_opp >= 4)
end

----------------------------------------------------------------------
-- CARD VALIDATION
----------------------------------------------------------------------
function M.can_play_card(card, game_state, player_id)
    player_id = player_id or ""
    local prev_dict = get(game_state, "current_card", {})
    local prev_obj = nil
    if type(prev_dict) == "table" and not is_empty(prev_dict) then
        prev_obj = Rules.create_card(get(prev_dict, "v", 0), get(prev_dict, "s", ""))
    end

    local play_obj = Rules.create_card(get(card, "v", 0), get(card, "s", ""))

    local is_last_card = false
    if player_id ~= "" then
        is_last_card = (#hand_of(game_state, player_id) == 1)
    end

    local result = Rules.get_next_action(
        prev_obj,
        play_obj,
        get(game_state, "active_penalty_count", 0) > 0,
        get(game_state, "chosen_shape", ""),
        get(game_state, "active_penalty_count", 0),
        0,
        is_last_card)

    return {
        canPlay = result.valid and result.type ~= NAT.INVALID_MOVE,
        result = result,
    }
end

----------------------------------------------------------------------
-- EVALUATION
----------------------------------------------------------------------
function M.calculate_hand_points(hand)
    local total = 0
    for _, card in ipairs(hand) do
        if M.is_whot(card) then total = total + 20
        else total = total + get(card, "v", 0) end
    end
    return total
end

function M.should_reserve_card(card, game_state, player_id)
    local ai_hand = hand_of(game_state, player_id)
    local min_opp = min_opponent_cards(game_state, player_id)

    if M.is_whot(card) then
        if min_opp <= 2 then return { reserve = false, reason = "Emergency Defense", urgency = 100 } end
        if #ai_hand <= 2 then return { reserve = false, reason = "Finishing Move", urgency = 95 } end
        return { reserve = true, reason = "Hoarding Whot 20", urgency = 80 }
    end
    return { reserve = false, reason = "Standard play", urgency = 40 }
end

function M.evaluate_card(card, game_state, player_id)
    local playability = M.can_play_card(card, game_state, player_id)
    if not playability.canPlay then return -1000.0 end

    local result   = playability.result
    local ai_hand  = hand_of(game_state, player_id)
    local min_opp  = min_opponent_cards(game_state, player_id)
    local W        = M.SCORING_WEIGHTS

    local reservation = M.should_reserve_card(card, game_state, player_id)
    local score = W.handReduction

    if reservation.reserve then score = score + W.reservationPenalty
    elseif reservation.urgency >= 90 then score = score + W.unleashBonus end

    if M.is_whot(card) then
        score = score + W.whotControlValue
        if #ai_hand == 1 then score = score + 500 end -- insta win
    end

    if M.is_hold_on(card) then
        score = score + W.holdOnCombo
        if #ai_hand <= 3 then score = score + 100 end
    end

    if M.is_penalty_card(card) then
        if get(game_state, "active_penalty_count", 0) > 0 then
            score = score + W.penaltyNeutralization
        elseif min_opp <= 3 then
            score = score + W.opponentDisruption * 2
        end
    end

    if M.is_general_market(card) then
        score = score + W.generalMarketBonus
        if min_opp <= 2 then score = score + 80 end
    end

    score = score + (W.actionTypeBonus[result.type] or 0)
    if M.is_finishing_phase(game_state, player_id) then
        score = score + W.finishingPotential
    end

    return score
end

----------------------------------------------------------------------
-- COMBO ANALYSIS
----------------------------------------------------------------------
function M.find_combos(hand, _game_state, _player_id)
    local combos = {}
    local hold_ons = {}
    for _, c in ipairs(hand) do
        if M.is_hold_on(c) then table.insert(hold_ons, c) end
    end

    if #hold_ons > 0 then
        for _, shape in ipairs(M.SHAPES) do
            local chain = {}
            local matching = {}
            for _, h in ipairs(hold_ons) do
                if get(h, "s", "") == shape then table.insert(chain, h) end
            end
            for _, c in ipairs(hand) do
                if get(c, "s", "") == shape and not M.is_hold_on(c) and not M.is_whot(c) then
                    table.insert(matching, c)
                end
            end
            if #chain > 0 and #matching > 0 then
                local cards = {}
                for _, cc in ipairs(chain) do table.insert(cards, cc) end
                table.insert(cards, matching[1])
                table.insert(combos, {
                    type = "HOLD_ON_CHAIN",
                    cards = cards,
                    score = 100 + (#chain * 50),
                    priority = 85,
                    reasoning = "Hold On chain in " .. shape,
                })
            end
        end
    end

    table.sort(combos, function(a, b) return a.priority > b.priority end)
    return combos
end

----------------------------------------------------------------------
-- BEST CARD FINDER
----------------------------------------------------------------------
function M.find_best_playable_card(hand, game_state, player_id)
    local playable = {}
    for _, c in ipairs(hand) do
        if M.can_play_card(c, game_state, player_id).canPlay then
            table.insert(playable, c)
        end
    end
    if #playable == 0 then return {} end

    local scored = {}
    for _, c in ipairs(playable) do
        table.insert(scored, { card = c, score = M.evaluate_card(c, game_state, player_id) })
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    return scored[1].card
end

----------------------------------------------------------------------
-- STRATEGIC DECISIONS
----------------------------------------------------------------------
function M.should_handle_penalty(game_state, player_id)
    if get(game_state, "active_penalty_count", 0) == 0 then return {} end

    local hand = hand_of(game_state, player_id)
    local best_pen, best_score = {}, -1.0
    for _, c in ipairs(hand) do
        if M.is_penalty_card(c) and M.can_play_card(c, game_state, player_id).canPlay then
            local sc = M.evaluate_card(c, game_state, player_id)
            if sc > best_score then best_score = sc; best_pen = c end
        end
    end

    if not is_empty(best_pen) then
        return { strategy = "DEFEND_PENALTY", priority = 95,
                 reasoning = "Transferring Penalty", cardToPlay = best_pen }
    end
    return { strategy = "DRAW_PENALTY", priority = 50,
             reasoning = "Drawing penalty", shouldDraw = true }
end

function M.select_optimal_shape(game_state, player_id)
    local hand = hand_of(game_state, player_id)
    local counts = {}
    for _, c in ipairs(hand) do
        if not M.is_whot(c) then
            local s = get(c, "s", "")
            counts[s] = (counts[s] or 0) + 1
        end
    end
    local best, maxc = "C", -1
    for _, shape in ipairs(M.SHAPES) do
        if (counts[shape] or 0) > maxc then maxc = counts[shape] or 0; best = shape end
    end
    return best
end

function M.make_strategic_decision(game_state, player_id)
    local hand = hand_of(game_state, player_id)

    local pen = M.should_handle_penalty(game_state, player_id)
    if not is_empty(pen) then return pen end

    local combos = M.find_combos(hand, game_state, player_id)
    if #combos > 0 then
        local first = combos[1].cards[1]
        if M.can_play_card(first, game_state, player_id).canPlay then
            return { strategy = "COMBO", priority = combos[1].priority,
                     reasoning = combos[1].reasoning, cardToPlay = first }
        end
    end

    local best = M.find_best_playable_card(hand, game_state, player_id)
    if not is_empty(best) then
        local res = M.should_reserve_card(best, game_state, player_id)
        if res.reserve and res.urgency < 70 then
            for _, c in ipairs(hand) do
                if c ~= best
                   and M.can_play_card(c, game_state, player_id).canPlay
                   and not M.should_reserve_card(c, game_state, player_id).reserve then
                    return { strategy = "REGULAR", priority = 50,
                             reasoning = "Reserving Whot card", cardToPlay = c }
                end
            end
        end
        return { strategy = "REGULAR", priority = 50,
                 reasoning = "Standard play", cardToPlay = best }
    end

    return { strategy = "DRAW", priority = 10,
             reasoning = "No playable cards", shouldDraw = true }
end

----------------------------------------------------------------------
-- PUBLIC ENTRY POINT (Whot-native)
----------------------------------------------------------------------
function M.get_ai_decision(game_state, player_id)
    local decision = M.make_strategic_decision(game_state, player_id)
    local chosen_shape = ""
    if decision.cardToPlay and not is_empty(decision.cardToPlay) then
        if M.is_whot(decision.cardToPlay) then
            chosen_shape = M.select_optimal_shape(game_state, player_id)
        end
    end
    return { decision = decision, selectedShape = chosen_shape }
end

----------------------------------------------------------------------
-- COMPAT ADAPTER for the existing Matatu-shaped callers.
--
-- decide(state, hand, has_drawn) returns one of:
--   { kind = "play", index = <i in hand>, suit = <chosen shape | ""> }
--   { kind = "draw" }
--   { kind = "pass" }
--
-- `state` may use either the server/offline key style (currentCard,
-- chosenSuit, activePenaltyCount) or the Whot-native style; both are read.
----------------------------------------------------------------------
local function normalize_state(state, hand)
    state = state or {}
    local prev = state.current_card or state.currentCard
    if type(prev) == "table" and is_empty(prev) then prev = nil end

    local chosen = state.chosen_shape or state.chosenSuit or ""
    if chosen == "null" or chosen == nil then chosen = "" end

    local penalty = state.active_penalty_count or state.activePenaltyCount or 0

    local plist = state.players
    local gs_players
    if type(plist) == "table" and plist.ai then
        gs_players = plist                      -- already Whot-native
        gs_players.ai = gs_players.ai or {}
        gs_players.ai.hand = hand               -- trust the explicit hand arg
    else
        gs_players = { ai = { hand = hand } }
        -- best-effort opponent hand size for finishing logic
        if type(plist) == "table" then
            for pid, pdata in pairs(plist) do
                if pid ~= "ai" and type(pdata) == "table" and pdata.hand then
                    gs_players.opp = { hand = pdata.hand }
                    break
                end
            end
        end
    end

    return {
        game_id              = state.game_id or "offline",
        current_card         = prev or {},
        chosen_shape         = chosen,
        active_penalty_count = penalty,
        deck_size            = (state.deck and #state.deck) or state.deck_size or 20,
        played_cards         = {},
        players              = gs_players,
    }
end

function M.choose(state, hand, opts)
    opts = opts or {}
    local has_drawn = opts.has_drawn or false
    local gs = normalize_state(state, hand)
    local penalty = gs.active_penalty_count

    local resp     = M.get_ai_decision(gs, "ai")
    local decision = resp.decision or {}
    local card     = decision.cardToPlay

    if decision.shouldDraw or not card or is_empty(card) then
        if penalty > 0 or not has_drawn then return { kind = "draw" } end
        return { kind = "pass" }
    end

    -- Drawing always ends the turn in Whot — never "pick and play" the card
    -- just drawn (or any other card) once has_drawn is true.
    if has_drawn then return { kind = "pass" } end

    for i, c in ipairs(hand) do
        if c.v == card.v and c.s == card.s then
            return { kind = "play", index = i, suit = resp.selectedShape or "" }
        end
    end
    return { kind = "draw" }
end

function M.decide(state, hand, has_drawn)
    return M.choose(state, hand, { has_drawn = has_drawn })
end

-- Legacy helper used by tournament4/offline_handler: pick the strongest shape
-- to call after a Whot card.
function M.best_suit_for_hand(hand)
    return M.select_optimal_shape({ players = { ai = { hand = hand } } }, "ai")
end
function M.best_suit_for_hand_except(hand, _exclude)
    return M.best_suit_for_hand(hand)
end

-- Legacy scoring hook. Builds a minimal state and scores the card.
function M.score_card(card, _action_type, hand, state)
    local gs = normalize_state(state, hand)
    return M.evaluate_card(card, gs, "ai")
end

-- Legacy brain/observation API — Whot AI is stateless, so these are no-ops
-- kept so older call sites don't nil-error.
function M.new_brain() return {} end
function M.reset_deal(_brain) end
function M.observe(_brain, _ev) end
function M.build_state(_self, _seat, _penalty) return {} end

return M
