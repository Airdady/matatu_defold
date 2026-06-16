-- ai_player.lua
-- ============================================================================
--  GOD-TIER MATATU AI  —  "the hardest opponent of all time"
-- ============================================================================
--  A single heuristic-evaluation brain that implements every pillar from the
--  strategy spec, tuned for low-end Android (no heavy per-frame search):
--
--    card_memory / card_counting ....... persistent per-deal brain (optional)
--    opponent_modeling ................. per-seat liability + void inference
--    probability_engine / deck_analysis  remaining-suit estimates
--    suit_control / suit_starvation .... steer toward suits we own / they lack
--    opponent_depletion / forced_draws . shove penalties onto loaded victims
--    special_card_conservation ......... hold bombs in bracket, dump in chamber
--    threat_detection / danger_scoring . suppress near-finishers when we're loaded
--    tempo / initiative / position ..... reverse-redirect + skip lockdown
--    kingmaking_prevention ............. don't gift the leader a kill
--    MODE AWARENESS:
--        CHAMBER  -> lowest cumulative VALUE wins  (NEVER cut while holding big
--                    cards; dump bombs early; load the heaviest opponent;
--                    steer the active suit AWAY from the cutting suit when fat).
--        BRACKET  -> most CARDS at the count is eliminated (cut only when you
--                    hold the fewest; hoard specials as weapons).
--
--  Public API (backward compatible with the old module):
--      AI.best_suit_for_hand(hand)
--      AI.best_suit_for_hand_except(hand, exclude)
--      AI.score_card(card, action_type, hand, state)   -- mode-aware now
--      AI.decide(state, hand, has_drawn)
--  New, richer entry points:
--      AI.new_brain() / AI.observe(brain, ev) / AI.reset_deal(brain)
--      AI.build_state(self, seat[, penalty])            -- one-call tournament glue
--      AI.choose(state, hand[, opts])                   -- full decision
-- ============================================================================

local rules = require("modules.card_rules")

local M = {}

local NA = rules.NextActionType
local V  = rules.VALUES or {}

-- ── Evaluation weights (mirrors evaluation_function.weights in the spec) ──────
M.W = {
    going_out          = 6000,   -- emptying the hand always wins the moment
    cut_swing          = 1.0,    -- multiplier on cut_score (already large)
    threat_suppress    = 900,    -- skip/reverse a finisher when we're loaded
    weaponize_special  = 1500,   -- joker/ace used to kill a real threat
    suit_control       = 30,     -- per friendly card kept on the active suit
    starvation         = 200,    -- next player is (likely) void in active suit
    depletion          = 1.4,    -- per victim-value unit of a forced draw
    shed_value_chamber = 2.0,    -- per point dumped while in chamber
    shed_value_bracket = 0.20,   -- value matters far less when only count counts
    base_pip           = 1.0,    -- shed higher pips first as a tie-breaker
    strand_penalty     = 18,     -- stranding ourselves off-suit
    cutsuit_risk       = 9,      -- chamber: per point of fat while feeding cut suit
    kingmaking         = 120,    -- don't hand the leader a free kill
    reverse_redirect   = 3.0,    -- per victim-value delta gained by reversing
}

-- ── Deck assumptions (tune to your real deck composition) ────────────────────
M.SUIT_DECK_SIZE = 13   -- cards per suit used for remaining-suit probability

-- ============================================================================
--  CARD VALUE / TYPE HELPERS
-- ============================================================================

-- EXACTLY mirrors tournament4.get_card_value so chamber estimates == real count.
local function point_value(v, s)
    local val = tonumber(v)
    if not val then return 0 end
    if val == 50 then return 50 end
    if val == 14 or val == 1 or val == 15 then
        if s == "S" then return 60 else return 15 end
    end
    if val == 2 then return 20 end
    if val == 3 then return 30 end
    return val
end

local function hand_value(hand)
    local t = 0
    for _, c in ipairs(hand) do t = t + point_value(c.v, c.s) end
    return t
end

local SUITS = { "H", "D", "S", "C" }
local function is_red(s)   return s == "H" or s == "D" or s == "R" end
local function is_black(s) return s == "S" or s == "C" or s == "B" end

local function vnum(c) return tonumber(c.v) end
local function is_joker(c)  return vnum(c) == 50 end
local function is_ace(c)
    local v = vnum(c)
    return v == V.ACE or v == 1 or v == 14 or v == 15
end
local function is_two(c)   return vnum(c) == (V.TWO   or 2) end
local function is_three(c) return vnum(c) == (V.THREE or 3) end
local function is_reverse(c) return vnum(c) == 11 end

-- How much "draw pressure" a card pushes onto the next seat (depletion power).
local function penalty_power(card)
    if is_joker(card) then return 5 end
    if is_three(card) then return 3 end
    if is_two(card)   then return 2 end
    return 0
end

-- Replicates tournament4.advance: does playing this 7 actually END the round?
local function cut_triggers(card, cutting)
    if not cutting then return false end
    if tostring(card.v) ~= "7" then return false end
    local cv = tonumber(cutting.v)
    if cv == 50 then
        local cs, ts = cutting.s, card.s
        return (is_red(cs) and is_red(ts)) or (is_black(cs) and is_black(ts))
    else
        return card.s == cutting.s
    end
end

-- ============================================================================
--  CARD MEMORY / COUNTING  (optional persistent brain)
-- ============================================================================
function M.new_brain()
    return {
        seen      = {},                           -- "v|s" -> true
        suit_seen = { H = 0, D = 0, S = 0, C = 0 },
        void      = {},                           -- void[name][suit] = true
        request   = {},                           -- name -> last forced suit
        deal      = 0,
    }
end

function M.reset_deal(brain)
    if not brain then return end
    brain.seen      = {}
    brain.suit_seen = { H = 0, D = 0, S = 0, C = 0 }
    brain.void      = {}
    brain.deal      = (brain.deal or 0) + 1
end

-- Feed the brain observable events. ev = {kind=..., ...}
--   {kind="play",  v=, s=}                       a card hit the pile
--   {kind="void",  name=, suit=}                 a seat drew instead of following suit
--   {kind="request", name=, suit=}               a seat (Ace) chose a suit
function M.observe(brain, ev)
    if not brain or not ev then return end
    if ev.kind == "play" and ev.s then
        brain.seen[tostring(ev.v) .. "|" .. ev.s] = true
        brain.suit_seen[ev.s] = (brain.suit_seen[ev.s] or 0) + 1
    elseif ev.kind == "void" and ev.name and ev.suit then
        brain.void[ev.name] = brain.void[ev.name] or {}
        brain.void[ev.name][ev.suit] = true
    elseif ev.kind == "request" and ev.name and ev.suit then
        brain.request[ev.name] = ev.suit
    end
end

-- Estimated cards of `suit` still unseen (deck_analysis / probability_engine).
local function suit_remaining(brain, suit, held)
    local seen = (brain and brain.suit_seen[suit]) or 0
    return math.max(0, (M.SUIT_DECK_SIZE) - seen - (held or 0))
end

-- ============================================================================
--  SUIT SELECTION
-- ============================================================================
function M.best_suit_for_hand_except(hand, exclude_card)
    local counts = { H = 0, D = 0, S = 0, C = 0 }
    for _, c in ipairs(hand) do
        if c ~= exclude_card then counts[c.s] = (counts[c.s] or 0) + 1 end
    end
    local best, best_n = "H", -1
    for _, s in ipairs(SUITS) do
        if counts[s] > best_n then best, best_n = s, counts[s] end
    end
    return best
end

function M.best_suit_for_hand(hand)
    return M.best_suit_for_hand_except(hand, nil)
end

-- ============================================================================
--  OPPONENT MODELLING  (danger_scoring / threat_detection / kingmaking)
-- ============================================================================

-- How "loaded" a rival is — i.e. how much we'd like the deal to end on THEM.
local function opp_liability(o, mode)
    if not o then return 0 end
    if mode == "chamber" then
        -- closer to the cap + a bigger hand = more incoming points
        return (o.total or 0) + (o.cards or 0) * 8
    end
    return (o.cards or 0)
end

-- How good it is to dump a penalty / redirect the turn onto this seat.
local function victim_value(o, mode)
    if not o then return 0 end
    if mode == "chamber" then return (o.total or 0) + (o.cards or 0) * 8 end
    return (o.cards or 0) * 10
end

-- ============================================================================
--  CUT REASONING  (the heart of "don't cut while holding the big cards")
-- ============================================================================
local function cut_score(card, hand, ctx)
    local mode = ctx.mode
    local rem_val, rem_cnt, skipped = 0, 0, false
    for _, c in ipairs(hand) do
        if (not skipped) and c == card then skipped = true
        else rem_cnt = rem_cnt + 1; rem_val = rem_val + point_value(c.v, c.s) end
    end

    local opps = ctx.opponents or {}

    if mode == "chamber" then
        -- A cut ENDS the deal and you KEEP your hand — its value is added to
        -- your total. So cutting while fat is suicide; only cut featherweight.
        local load, n = 0, 0
        for _, o in ipairs(opps) do load = load + opp_liability(o, mode); n = n + 1 end
        local avg  = (n > 0) and (load / n) or 0
        local mine = rem_val + (ctx.my_total or 0)

        if mine >= (ctx.threshold or 100) then return -2400 end          -- cut would eliminate ME
        if rem_val >= math.max(20, 0.30 * (ctx.threshold or 100)) then
            return -1200 - rem_val * 4                                   -- holding bombs: NEVER cut
        end
        -- light hand + heavy opponents => a cut is a fantastic weapon
        return (avg - rem_val) * 4 + 30
    else
        -- bracket: the MOST-cards seat at the count is eliminated.
        local maxopp = 0
        for _, o in ipairs(opps) do if (o.cards or 0) > maxopp then maxopp = o.cards end end
        if rem_cnt > maxopp then
            return -1500 - rem_cnt * 30                                  -- I'd be the one eliminated
        elseif rem_cnt == maxopp then
            return -200                                                  -- coin-flip tie, avoid
        else
            return 200 + (maxopp - rem_cnt) * 40                         -- I'm safe: end it, burn them
        end
    end
end

-- ============================================================================
--  REVERSE REDIRECTION  (tempo_control / initiative_control / position)
--  Reverse flips direction: the seat that becomes "next" is prev_player.
--  We want that to be the HEAVIER victim, or to deny a near-finisher their turn.
-- ============================================================================
local function reverse_score(ctx)
    local mode = ctx.mode
    local nxt, prv = ctx.next_player, ctx.prev_player
    if not nxt or not prv then return 0 end
    local s = (victim_value(prv, mode) - victim_value(nxt, mode)) * M.W.reverse_redirect
    -- deny the about-to-win neighbour their turn while we're carrying liability
    if (nxt.cards or 9) <= 2 and ctx.i_am_loaded then s = s + 120 end
    return s
end

-- ============================================================================
--  CORE HEURISTIC  —  score a single legal play
-- ============================================================================
function M.evaluate_play(card, action_type, hand, ctx)
    ctx = ctx or {}
    local mode      = ctx.mode or "bracket"
    local opps      = ctx.opponents or {}
    local survivors = ctx.num_alive or (#opps + 1)
    local W         = M.W
    local score     = 0

    -- remaining hand stats after this play (skip one matching ref) ------------
    local rem_val, rem_cnt, skipped = 0, 0, false
    for _, c in ipairs(hand) do
        if (not skipped) and c == card then skipped = true
        else rem_cnt = rem_cnt + 1; rem_val = rem_val + point_value(c.v, c.s) end
    end
    local is_last = (rem_cnt == 0)
    local pv      = point_value(card.v, card.s)

    -- (1) GOING OUT — dominates everything -----------------------------------
    if is_last then return W.going_out + pv end

    -- (2) "am I loaded?" — the trigger for defensive play --------------------
    local i_am_loaded
    if mode == "chamber" then
        i_am_loaded = rem_val >= math.max(20, 0.25 * (ctx.threshold or 100))
    else
        local maxopp = 0
        for _, o in ipairs(opps) do if (o.cards or 0) > maxopp then maxopp = o.cards end end
        i_am_loaded = (maxopp > 0) and (rem_cnt >= maxopp)
    end
    ctx.i_am_loaded = i_am_loaded

    -- (3) SHED LIABILITY ------------------------------------------------------
    -- Chamber: aggressively dump high-value cards (bombs become 0 in hand).
    -- Bracket: value barely matters; still shed bigger first as a hedge.
    if mode == "chamber" then
        score = score + pv * W.shed_value_chamber
    else
        score = score + pv * W.shed_value_bracket
    end
    score = score + pv * W.base_pip * 0.1

    -- (4) SPECIAL-CARD CONSERVATION & WEAPONISATION --------------------------
    -- A "guard target" is a rival at <=2 cards: if the deal ends now and we're
    -- loaded, we suffer — so suppress them.
    local guard = false
    for _, o in ipairs(opps) do if (o.cards or 9) <= 2 then guard = true end end
    if ctx.next_player and (ctx.next_player.cards or 9) <= 2 then guard = true end
    local must_suppress = guard and i_am_loaded

    if is_joker(card) then
        if mode == "chamber" then
            score = score + 60                                   -- 50pt bomb: get it gone
            if must_suppress then score = score + W.weaponize_special end
        else
            if must_suppress then score = score + W.weaponize_special
            else score = score - 120 end                         -- hoard the nuke
        end
    elseif is_ace(card) then
        -- Ace = suit control. Spade ace is a 60pt brick in chamber.
        if mode == "chamber" then
            score = score + (card.s == "S" and 90 or 20)
        else
            score = score + (must_suppress and 60 or 10)
        end
    end

    -- (5) OPPONENT DEPLETION / FORCED DRAWS ----------------------------------
    local pp = penalty_power(card)
    if pp > 0 and ctx.next_player then
        score = score + victim_value(ctx.next_player, mode) * W.depletion * (pp / 5)
    end
    if action_type == NA.TRANSFER_PENALTY and ctx.next_player then
        score = score + victim_value(ctx.next_player, mode) * 0.6 + 80
    elseif action_type == NA.REDUCE_PENALTY then
        score = score - 20                                       -- absorbing < transferring
    end

    -- (6) SUIT CONTROL / STARVATION / CHOKE ----------------------------------
    local next_suit = card.s
    if action_type == NA.CHOOSE_SUIT then
        next_suit = M.best_suit_for_hand_except(hand, card)
    elseif is_joker(card) then
        next_suit = (ctx.chosen_suit and ctx.chosen_suit ~= "" and ctx.chosen_suit)
                 or (ctx.current_card and ctx.current_card.s) or card.s
    end

    local matches, sk = 0, false
    for _, c in ipairs(hand) do
        if (not sk) and c == card then sk = true
        elseif c.s == next_suit then matches = matches + 1 end
    end
    score = score + matches * W.suit_control                     -- keep a suit we own

    -- starve the next seat: prefer suits they're (likely) void in
    if ctx.brain and ctx.next_name and ctx.brain.void[ctx.next_name]
       and ctx.brain.void[ctx.next_name][next_suit] then
        score = score + W.starvation
    elseif ctx.brain then
        -- globally scarce suit => everyone is more likely off it
        local rem = suit_remaining(ctx.brain, next_suit, matches)
        if rem <= 3 then score = score + (4 - rem) * 25 end
    end

    -- (7) THREAT SUPPRESSION / SPECIAL LOCK ----------------------------------
    if must_suppress then
        if action_type == NA.SKIP_TURN then
            score = score + W.threat_suppress                    -- skip/reverse the finisher
        elseif pp > 0 then
            score = score + 500                                  -- bury them in cards
        elseif action_type == NA.END_TURN then
            score = score - 120                                  -- don't dawdle while loaded
        end
    end

    -- (8) CUT HANDLING (mode-aware, large magnitude) -------------------------
    if cut_triggers(card, ctx.cutting) then
        score = score + cut_score(card, hand, ctx) * W.cut_swing
    end

    -- (9) REVERSE REDIRECTION -------------------------------------------------
    if is_reverse(card) and action_type == NA.SKIP_TURN and survivors > 2 then
        score = score + reverse_score(ctx)
    end

    -- (10) CHAMBER: AVOID FEEDING THE CUT SUIT WHILE FAT ----------------------
    -- If we're carrying value, don't make the active suit match the cutting
    -- card's suit — that hands someone an easy cut that catches us loaded.
    if mode == "chamber" and ctx.cutting and rem_val > 20
       and next_suit == ctx.cutting.s and not is_last then
        score = score - rem_val * (W.cutsuit_risk / 10)
    end

    -- (11) PLAYABILITY FLEXIBILITY (resource_management) ---------------------
    if matches == 0 and action_type == NA.END_TURN and not is_last then
        score = score - W.strand_penalty                         -- don't strand ourselves
    end

    -- (12) KINGMAKING PREVENTION (light) -------------------------------------
    -- In 3+ alive, don't dump a penalty onto the trailing seat in a way that
    -- effectively gifts the leader a clean kill / runaway lead.
    if survivors > 2 and pp > 0 and ctx.leader and ctx.next_player
       and ctx.next_player ~= ctx.leader then
        local trailing = (victim_value(ctx.next_player, mode) <
                          victim_value(ctx.leader, mode) * 0.5)
        if trailing then score = score - W.kingmaking end
    end

    return score
end

-- ============================================================================
--  BACKWARD-COMPATIBLE SCORER (used by tournament4's selection loop)
-- ============================================================================
-- Accepts the old lightweight `state` AND any of the richer fields below:
--   state.mode | state.chamber, state.threshold, state.cutting,
--   state.opponents, state.next_player, state.prev_player, state.num_alive,
--   state.my_total, state.leader, state.brain, state.next_name
function M.score_card(card, action_type, hand, state)
    state = state or {}
    local mode = state.mode
    if not mode then mode = state.chamber and "chamber" or "bracket" end

    local ctx = {
        mode         = mode,
        threshold    = state.threshold or 100,
        cutting      = state.cutting,
        opponents    = state.opponents,
        next_player  = state.next_player
                       or (state.next_player_cards and { cards = state.next_player_cards })
                       or nil,
        prev_player  = state.prev_player,
        num_alive    = state.num_alive,
        my_total     = state.my_total or 0,
        chosen_suit  = state.chosenSuit or state.chosen_suit,
        current_card = state.currentCard or state.current_card,
        leader       = state.leader,
        brain        = state.brain,
        next_name    = state.next_name,
    }
    return M.evaluate_play(card, action_type, hand, ctx)
end

-- ============================================================================
--  LEGAL-MOVE ENUMERATION + FULL DECISION
-- ============================================================================
local function to_rule_card(c) return rules.create_card(c.v, c.s) end

local function legal_plays(state, hand)
    local rules_mode  = state.rules or rules.RULES_JOKERS
    local penalty     = state.activePenaltyCount or state.penalty or 0
    local chosen_suit = state.chosenSuit or state.chosen_suit or ""
    local prev
    local cc = state.currentCard or state.current_card
    if cc ~= nil and next(cc) ~= nil then prev = to_rule_card(cc) end

    local out = {}
    for i, c in ipairs(hand) do
        local is_last = (#hand == 1)
        local res = rules.get_next_action(prev, to_rule_card(c),
            penalty > 0, chosen_suit, penalty, 0, is_last, rules_mode)
        if res.valid then
            out[#out + 1] = { index = i, card = c, action_type = res.type }
        end
    end
    return out
end

-- Full decision: returns { kind="play", index, suit? } | { kind="draw" } | { kind="pass" }
function M.choose(state, hand, opts)
    state, opts = state or {}, opts or {}
    local mode = state.mode or (state.chamber and "chamber" or "bracket")

    local ctx = {
        mode         = mode,
        threshold    = state.threshold or 100,
        cutting      = state.cutting,
        opponents    = state.opponents,
        next_player  = state.next_player
                       or (state.next_player_cards and { cards = state.next_player_cards }),
        prev_player  = state.prev_player,
        num_alive    = state.num_alive,
        my_total     = state.my_total or 0,
        chosen_suit  = state.chosenSuit or state.chosen_suit,
        current_card = state.currentCard or state.current_card,
        leader       = state.leader,
        brain        = state.brain,
        next_name    = state.next_name,
    }

    local cands = legal_plays(state, hand)
    if #cands > 0 then
        local best, best_score = nil, -math.huge
        for _, c in ipairs(cands) do
            local s = M.evaluate_play(c.card, c.action_type, hand, ctx)
            if s > best_score then best_score, best = s, c end
        end
        local action = { kind = "play", index = best.index, score = best_score }
        if best.action_type == NA.CHOOSE_SUIT then
            action.suit = M.best_suit_for_hand_except(hand, best.card)
        end
        return action
    end

    local penalty   = state.activePenaltyCount or state.penalty or 0
    local has_drawn = opts.has_drawn or state.has_drawn
    if penalty > 0 or not has_drawn then return { kind = "draw" } end
    return { kind = "pass" }
end

-- Backward-compatible thin wrapper.
function M.decide(state, hand, has_drawn)
    return M.choose(state, hand, { has_drawn = has_drawn })
end

-- ============================================================================
--  TOURNAMENT GLUE — build a full state straight from self.t4
-- ============================================================================
local function seat_card_count(self, s)
    if s.is_human and self.t4.human_alive then return #self.player_hand end
    return #s.hand
end

-- direction-aware ring step over non-eliminated seats
local function ring_step(seats, from, dir)
    local n = #seats
    for k = 1, n do
        local idx = ((from - 1 + dir * k) % n + n) % n + 1
        if not seats[idx].eliminated then return idx end
    end
    return from
end

-- Call this in M.ai_seat_turn:  local state = AI.build_state(self, seat)
function M.build_state(self, seat, penalty)
    local t4   = self.t4
    local mode = t4.chamber and "chamber" or "bracket"
    local dir  = t4.direction or 1

    local top = self.played_cards[#self.played_cards]
    local current = top and { v = top.v, s = top.s } or nil

    local nxt_idx = ring_step(t4.seats, t4.turn_idx, dir)
    local prv_idx = ring_step(t4.seats, t4.turn_idx, -dir)
    local nxt = t4.seats[nxt_idx]
    local prv = t4.seats[prv_idx]

    local function pack(s)
        if not s then return nil end
        return { name = s.name, slot = s.slot, cards = seat_card_count(self, s), total = s.total or 0 }
    end

    -- opponents (everyone alive but us) + leader (lowest total in chamber)
    local opponents, leader = {}, nil
    for _, s in ipairs(t4.seats) do
        if not s.eliminated and s ~= seat then
            local o = pack(s)
            o.is_next = (s == nxt)
            opponents[#opponents + 1] = o
            if mode == "chamber" then
                if not leader or (s.total or 0) < (leader.total or math.huge) then leader = o end
            end
        end
    end

    local alive = 0
    for _, s in ipairs(t4.seats) do if not s.eliminated then alive = alive + 1 end end

    return {
        rules             = rules.RULES_JOKERS,
        mode              = mode,
        chamber           = t4.chamber and true or false,
        threshold         = t4.threshold or 100,
        currentCard       = current,
        chosenSuit        = self.chosen_suit,
        activePenaltyCount= penalty or self.active_penalty or 0,
        cutting           = self.cutting_card and { v = self.cutting_card.v, s = self.cutting_card.s } or nil,
        num_alive         = alive,
        my_total          = seat.total or 0,
        next_player       = pack(nxt),
        prev_player       = pack(prv),
        next_player_cards = nxt and seat_card_count(self, nxt) or 5,
        next_name         = nxt and nxt.name or nil,
        opponents         = opponents,
        leader            = leader,
        brain             = self.t4.brain,   -- optional persistent memory
    }
end

return M