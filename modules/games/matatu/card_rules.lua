-- Faithful Lua port of the original Godot `src/game/card_rules.gd`.
-- Pure logic, no engine dependencies, so it can drive both the offline AI and
-- the local game engine, and validate moves before they are sent online.

local M = {}

-- === SUIT CONSTANTS ===
M.SUIT_HEARTS = "H"
M.SUIT_DIAMONDS = "D"
M.SUIT_SPADES = "S"
M.SUIT_CLUBS = "C"
M.SUIT_RED = "R" -- Red Joker
M.SUIT_BLACK = "B" -- Black Joker

-- === RULE SETS ===
M.RULES_CLASSIC = "CLASSIC"
M.RULES_JOKERS = "JOKERS"

-- === NEXT ACTION TYPES (indices must match original enum order) ===
M.NextActionType = {
  INVALID_MOVE = 0,
  PLAY_CARD = 1,
  CHOOSE_SUIT = 2,
  SKIP_TURN = 3,
  END_TURN = 4,
  REDUCE_PENALTY = 5,
  TRANSFER_PENALTY = 6,
}
local NA = M.NextActionType

M.VALUES = { TWO = 2, THREE = 3, EIGHT = 8, JACK = 11, ACE = 15 }
M.JOKER_PENALTY = 5
M.MASTER_CARD = { v = 15, s = M.SUIT_SPADES } -- Ace of Spades

-- --- Construction ---
function M.create_card(value, suit)
  return { v = math.floor(tonumber(value) or 0), s = tostring(suit) }
end

-- --- Utility predicates ---
function M.is_classic(rules)
  return rules == M.RULES_CLASSIC
end

function M.is_joker(card)
  return card.s == M.SUIT_RED or card.s == M.SUIT_BLACK
end

function M.is_penalty_card(card, rules)
  rules = rules or M.RULES_JOKERS
  if M.is_classic(rules) then
    return card.v == M.VALUES.TWO
  end
  return card.v == M.VALUES.TWO or card.v == M.VALUES.THREE or card.v == 50 or M.is_joker(card)
end

function M.is_ace(card)
  return card.v == M.VALUES.ACE
end

function M.is_master_card(card, rules)
  rules = rules or M.RULES_JOKERS
  if M.is_classic(rules) then
    return false
  end
  return card.v == M.MASTER_CARD.v and card.s == M.MASTER_CARD.s
end

function M.get_card_penalty_value(card)
  if M.is_joker(card) then
    return M.JOKER_PENALTY
  end
  return card.v
end

function M.is_red_suit(suit)
  return suit == M.SUIT_HEARTS or suit == M.SUIT_DIAMONDS
end

function M.is_black_suit(suit)
  return suit == M.SUIT_SPADES or suit == M.SUIT_CLUBS
end

function M.is_valid_joker_move(card, prev_card, selected_suit)
  selected_suit = selected_suit or ""
  if not M.is_joker(card) and not M.is_joker(prev_card) then
    return false
  end

  local joker_card = M.is_joker(card) and card or prev_card
  local target_suit
  if selected_suit ~= "" then
    target_suit = selected_suit
  elseif M.is_joker(card) then
    target_suit = prev_card.s
  else
    target_suit = card.s
  end

  if joker_card.s == M.SUIT_RED then
    return M.is_red_suit(target_suit)
  else
    return M.is_black_suit(target_suit)
  end
end

function M.is_basic_match(card, prev_card, selected_suit, rules)
  selected_suit = selected_suit or ""
  rules = rules or M.RULES_JOKERS
  local allow_joker_check = not M.is_classic(rules)

  if selected_suit ~= "" then
    return card.s == selected_suit
      or (allow_joker_check and M.is_valid_joker_move(card, prev_card, selected_suit))
  end

  return (card.v == prev_card.v)
    or (card.s == prev_card.s)
    or (allow_joker_check and M.is_valid_joker_move(card, prev_card, selected_suit))
end

-- --- Card effects ---
function M.get_card_effect(card, is_penalty_active, rules)
  is_penalty_active = is_penalty_active or false
  rules = rules or M.RULES_JOKERS

  if not M.is_classic(rules) and M.is_joker(card) then
    return {
      type = NA.TRANSFER_PENALTY,
      allow_suit_choice = true,
      penalty_cards = M.JOKER_PENALTY,
      message = string.format("Joker played - %d cards penalty transferred", M.JOKER_PENALTY),
    }
  end

  if M.is_master_card(card, rules) and is_penalty_active then
    return { type = NA.END_TURN, message = "Master card cancels all penalties" }
  end

  if M.is_ace(card) and not is_penalty_active then
    return { type = NA.CHOOSE_SUIT, allow_suit_choice = true, message = "Choose a suit for the ace" }
  end

  local v = card.v
  if v == M.VALUES.TWO then
    return { type = NA.TRANSFER_PENALTY, penalty_cards = 2, message = "Next player draws 2 cards" }
  elseif v == M.VALUES.THREE then
    if not M.is_classic(rules) then
      return { type = NA.TRANSFER_PENALTY, penalty_cards = 3, message = "Next player draws 3 cards" }
    end
  elseif v == M.VALUES.EIGHT then
    return { type = NA.SKIP_TURN, skip_turns = 1, message = "Next player skips their turn" }
  elseif v == M.VALUES.JACK then
    return { type = NA.SKIP_TURN, skip_turns = 1, message = "Next player skips their turn" }
  elseif v == 50 then
    if not M.is_classic(rules) then
      return { type = NA.TRANSFER_PENALTY, penalty_cards = M.JOKER_PENALTY, message = "Next player draws 5 cards" }
    end
  end

  return { type = NA.END_TURN, message = "Turn ends normally" }
end

-- --- Penalty calculation ---
function M.calculate_penalty_action(played_card, prev_card, current_penalty, selected_suit, is_last_card, rules)
  selected_suit = selected_suit or ""
  is_last_card = is_last_card or false
  rules = rules or M.RULES_JOKERS

  local reference_suit = selected_suit ~= "" and selected_suit or prev_card.s
  local prev_penalty = M.get_card_penalty_value(prev_card)
  local played_penalty = M.get_card_penalty_value(played_card)

  local prev_is_penalty = M.is_penalty_card(prev_card, rules)
  local same_value = prev_is_penalty and prev_penalty == played_penalty
  local same_suit = prev_is_penalty and reference_suit == played_card.s
  local prev_stronger = prev_is_penalty and prev_penalty > played_penalty

  local color_match = false
  if not M.is_classic(rules) then
    color_match = M.is_valid_joker_move(played_card, prev_card, selected_suit)
  end

  if same_value then
    return {
      type = NA.TRANSFER_PENALTY,
      next_player_penalty_count = played_penalty,
      current_penalty_count = 0,
      message = string.format("Penalty transferred to next player (%d cards)", played_penalty),
    }
  end

  if same_suit then
    if prev_stronger then
      local remaining = math.max(current_penalty - played_penalty, 0)
      local draw_amount = is_last_card and 0 or remaining
      return {
        type = NA.REDUCE_PENALTY,
        next_player_penalty_count = 0,
        current_penalty_count = remaining,
        draw_cards = draw_amount,
        message = string.format(
          "Penalty reduced by %d, remaining: %d cards",
          math.min(current_penalty, played_penalty),
          remaining
        ),
      }
    end
    return {
      type = NA.TRANSFER_PENALTY,
      next_player_penalty_count = played_penalty,
      current_penalty_count = 0,
      message = string.format("Same suit weaker card - penalty transferred (%d cards)", played_penalty),
    }
  end

  if color_match then
    if prev_stronger then
      local remaining = math.max(current_penalty - played_penalty, 0)
      local draw_amount = is_last_card and 0 or remaining
      return {
        type = NA.REDUCE_PENALTY,
        next_player_penalty_count = 0,
        current_penalty_count = remaining,
        draw_cards = draw_amount,
        message = string.format("Color match stronger - penalty reduced, draw %d cards", remaining),
      }
    end
    return {
      type = NA.TRANSFER_PENALTY,
      next_player_penalty_count = math.max(current_penalty, played_penalty),
      current_penalty_count = 0,
      message = string.format(
        "Color match weaker - penalty increased to %d cards",
        math.max(current_penalty, played_penalty)
      ),
    }
  end

  local card_effect = M.get_card_effect(played_card, true, rules)
  return {
    type = card_effect.type,
    next_player_penalty_count = current_penalty,
    current_penalty_count = 0,
    message = card_effect.message,
  }
end

-- --- Main validation ---
-- Returns a result table matching Godot's NextActionResult exactly.
function M.get_next_action(prev_card, played_card, is_penalty_active, selected_suit, current_penalty_count, next_player_penalty_count, is_last_card, rules)
  is_penalty_active = is_penalty_active or false
  selected_suit = selected_suit or ""
  current_penalty_count = current_penalty_count or 0
  next_player_penalty_count = next_player_penalty_count or 0
  is_last_card = is_last_card or false
  rules = rules or M.RULES_JOKERS

  -- Helper to construct a strictly formatted result
  local function make_result(partial)
    local base = {
      valid = true,
      type = NA.END_TURN,
      next_player_penalty_count = 0,
      current_penalty_count = 0,
      message = "",
      allow_suit_choice = false,
      penalty_cards = 0,
      skip_turns = 0,
      draw_cards = 0
    }
    if partial then
        for k, val in pairs(partial) do
          base[k] = val
        end
    end
    return base
  end

  -- Helper to construct a strictly formatted invalid result
  local function make_invalid(msg)
    return {
      valid = false,
      type = NA.INVALID_MOVE,
      next_player_penalty_count = next_player_penalty_count,
      current_penalty_count = current_penalty_count,
      message = msg,
      allow_suit_choice = false,
      penalty_cards = 0,
      skip_turns = 0,
      draw_cards = 0
    }
  end

  -- First move or after a master card with no chosen suit
  if prev_card == nil or (M.is_master_card(prev_card, rules) and selected_suit == "") then
    local effect = M.get_card_effect(played_card, is_penalty_active, rules)
    effect.next_player_penalty_count = effect.penalty_cards or 0
    return make_result(effect)
  end

  -- Basic move validation
  local is_valid_move = (
    M.is_basic_match(played_card, prev_card, selected_suit, rules)
    or M.is_master_card(played_card, rules)
    or (selected_suit ~= "" and played_card.s == selected_suit)
    or M.is_ace(played_card)
  )

  if not is_valid_move then
    return make_invalid(string.format("Cannot play %d of %s", played_card.v, played_card.s))
  end

  -- Active penalties
  if is_penalty_active and current_penalty_count > 0 then
    if M.is_master_card(played_card, rules) then
      local effect = M.get_card_effect(played_card, is_penalty_active, rules)
      effect.next_player_penalty_count = 0
      effect.current_penalty_count = 0
      return make_result(effect)
    end

    if M.is_penalty_card(played_card, rules) and M.is_basic_match(played_card, prev_card, selected_suit, rules) then
      return make_result(
        M.calculate_penalty_action(played_card, prev_card, current_penalty_count, selected_suit, is_last_card, rules)
      )
    end

    local penalty_text = M.is_classic(rules) and "2" or "2 or 3"
    return make_invalid(string.format(
      "Must play a penalty card (%s) or master card when penalty is active (%d cards pending)",
      penalty_text,
      current_penalty_count
    ))
  end

  -- Regular play
  local effect = M.get_card_effect(played_card, is_penalty_active, rules)
  effect.next_player_penalty_count = effect.penalty_cards or 0
  effect.current_penalty_count = 0
  return make_result(effect)
end

return M