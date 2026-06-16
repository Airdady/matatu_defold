--- ai_player.lua
-- God-Tier AI opponent for Matatu. 
-- Built on an Expectiminimax-style heuristic evaluation targeting:
-- Suit starvation, Opponent depletion, Threat scoring, and Endgame lockdown.

local rules = require("modules.card_rules")

local M = {}

local function to_rule_card(c)
  return rules.create_card(c.v, c.s)
end

-- Counts suits in hand while excluding a specific card (useful for predicting future board state)
function M.best_suit_for_hand_except(hand, exclude_card)
  local counts = { H = 0, D = 0, S = 0, C = 0 }
  for _, c in ipairs(hand) do
    if c ~= exclude_card then
      counts[c.s] = (counts[c.s] or 0) + 1
    end
  end
  local best, best_n = "H", -1
  for _, s in ipairs({ "H", "D", "S", "C" }) do
    if counts[s] > best_n then
      best, best_n = s, counts[s]
    end
  end
  return best
end

function M.best_suit_for_hand(hand)
  return M.best_suit_for_hand_except(hand, nil)
end

--- The God-Tier Heuristic Evaluation Function
-- Assigns a strategic threat/value score to a specific valid move.
function M.score_card(card, action_type, hand, state)
  local NA = rules.NextActionType
  local score = 0
  local is_last = (#hand == 1)

  -- Environment Awareness (Danger Scoring)
  local next_opp_cards = state.next_player_cards or 4
  local is_threat = next_opp_cards <= 2
  local someone_winning = is_threat -- Can be expanded if we track all players

  -- 1. BASE CARD WEIGHTING & SPECIAL CARD CONSERVATION
  local v = tonumber(card.v)
  if v == 50 then
    -- Jokers: Ultimate weapons. Hold unless killing a threat, going out, or forced.
    if is_last then score = score + 5000
    elseif is_threat then score = score + 2000
    elseif someone_winning then score = score + 500 -- Dump heavy cards if losing
    else score = score - 100 end -- Conserve it!
  elseif v == rules.VALUES.ACE then
    -- Aces: Suit control. Hold unless necessary.
    if is_last then score = score + 5000
    elseif card.s == "S" and someone_winning then score = score + 300 -- Dump heavy 60pt card
    else score = score - 20 end
  elseif v == rules.VALUES.TWO or v == rules.VALUES.THREE then
    -- Penalties: Opponent depletion
    if is_threat then score = score + 1000
    else score = score + 50 end
  elseif v == rules.VALUES.EIGHT or v == rules.VALUES.JACK then
    -- Skips: Action denial / Special Lock
    if is_threat then score = score + 1500
    elseif next_opp_cards >= 5 then score = score - 15 -- Don't waste on safe players
    else score = score + 40 end
  else
    -- Normal cards: Shed higher values first to minimize points
    score = score + v
  end

  -- 2. SUIT STARVATION & CHOKE (Force play toward suits AI controls)
  local next_suit = card.s
  if action_type == NA.CHOOSE_SUIT then
    next_suit = M.best_suit_for_hand_except(hand, card)
  elseif v == 50 then
    -- Joker maintains or assumes current color
    next_suit = (state.chosenSuit and state.chosenSuit ~= "") and state.chosenSuit or ((state.currentCard) and state.currentCard.s or card.s)
  end

  local suit_matches = 0
  for _, c in ipairs(hand) do
    if c ~= card and c.s == next_suit then
      suit_matches = suit_matches + 1
    end
  end
  -- Highly prioritize maintaining favorable suits (Resource control)
  score = score + (suit_matches * 40) 

  -- 3. COMBOS & INITIATIVE CONTROL
  if action_type == NA.SKIP_TURN then
    score = score + 60
  elseif action_type == NA.TRANSFER_PENALTY then
    score = score + 80
  elseif action_type == NA.REDUCE_PENALTY then
    score = score - 20 -- Absorbing penalty is a last resort compared to transferring
  end

  -- 4. ENDGAME LOCKDOWN
  -- If the next player is about to win, try not to play a plain card that 
  -- keeps a suit we don't control, attempting to break their predicted hand.
  if is_threat and action_type == NA.END_TURN and v ~= rules.VALUES.ACE then
    if suit_matches == 0 then score = score + 25 end
  end

  return score
end

--- Decide the AI's next single action given the current game state snapshot.
function M.decide(state, hand, has_drawn)
  local rules_mode = state.rules or rules.RULES_JOKERS
  local penalty = state.activePenaltyCount or 0
  local chosen_suit = state.chosenSuit or ""
  local prev = nil
  if state.currentCard ~= nil and next(state.currentCard) ~= nil then
    prev = to_rule_card(state.currentCard)
  end

  local candidates = {}
  for i, c in ipairs(hand) do
    local rc = to_rule_card(c)
    local is_last = (#hand == 1)
    local res = rules.get_next_action(
      prev, rc, penalty > 0, chosen_suit, penalty, 0, is_last, rules_mode
    )
    if res.valid then
      candidates[#candidates + 1] = {
        index = i,
        card = c,
        action_type = res.type,
        score = M.score_card(c, res.type, hand, state),
      }
    end
  end

  if #candidates > 0 then
    -- Pick the highest-scoring optimal play
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local pick = candidates[1]
    local action = { kind = "play", index = pick.index }

    -- If this play needs a suit choice (Ace), pre-pick one.
    if pick.action_type == rules.NextActionType.CHOOSE_SUIT then
      action.suit = M.best_suit_for_hand_except(hand, pick.card)
    end
    return action
  end

  -- No legal play.
  if penalty > 0 or not has_drawn then
    return { kind = "draw" }
  end

  return { kind = "pass" }
end

return M