--- ai_player.lua
-- Offline AI opponent for Matatu. Pure decision logic built on top of the
-- ported `card_rules` engine — it never touches the backend.
--
-- The engine (game_logic) asks the AI for ONE action at a time via decide().
-- The returned action is one of:
--   { kind = "play",  index = <hand index>, suit = <chosen suit or nil> }
--   { kind = "draw" }
--   { kind = "pass" }
--
-- Strategy (lightweight but sensible):
--   * When a penalty is active, prefer to counter/stack a penalty card; if it
--     can't, it draws the penalty.
--   * Otherwise it plays the "best" valid card: shed jokers/high penalty cards
--     when safe, keep aces as flexible wildcards, and prefer suits it holds many
--     of so future turns stay flexible.
--   * Aces pick the suit the AI holds most of.

local rules = require("modules.card_rules")

local M = {}

local function to_rule_card(c)
	return rules.create_card(c.v, c.s)
end

-- Count how many cards of each suit the AI holds (used for ace suit choice and
-- for valuing a candidate play).
local function suit_counts(hand)
	local counts = { H = 0, D = 0, S = 0, C = 0 }
	for _, c in ipairs(hand) do
		if counts[c.s] ~= nil then
			counts[c.s] = counts[c.s] + 1
		end
	end
	return counts
end

-- Pick the suit the AI is strongest in (for an Ace / wildcard choice).
function M.best_suit_for_hand(hand)
	local counts = suit_counts(hand)
	local best, best_n = "H", -1
	for _, s in ipairs({ "H", "D", "S", "C" }) do
		if counts[s] > best_n then
			best, best_n = s, counts[s]
		end
	end
	return best
end

-- Heuristic score for playing a given card (higher = more desirable to play now).
local function score_card(card, action_type)
	local NA = rules.NextActionType
	local score = 0
	-- Shed dangerous / high cards first.
	if card.v == 50 then
		score = score + 60 -- jokers are heavy, dump when legal
	elseif card.v == rules.VALUES.TWO or card.v == rules.VALUES.THREE then
		score = score + 40 -- penalty cards are good to offload
	elseif card.v == rules.VALUES.EIGHT or card.v == rules.VALUES.JACK then
		score = score + 35 -- skip cards grant another action (great in heads-up)
	elseif card.v == rules.VALUES.ACE then
		score = score - 10 -- keep aces; they are flexible wildcards
	else
		score = score + card.v -- shed higher pip cards earlier
	end
	-- Actions that keep control / pressure the opponent are valuable.
	if action_type == NA.SKIP_TURN then
		score = score + 25
	elseif action_type == NA.TRANSFER_PENALTY then
		score = score + 15
	end
	return score
end

--- Decide the AI's next single action given the current game state snapshot.
-- @param state table with: rules, currentCard ({v,s} or nil), chosenSuit (string),
--               activePenaltyCount (int)
-- @param hand  array of the AI's cards
-- @param has_drawn boolean - whether the AI already drew this turn segment
function M.decide(state, hand, has_drawn)
	local rules_mode = state.rules or rules.RULES_JOKERS
	local penalty = state.activePenaltyCount or 0
	local chosen_suit = state.chosenSuit or ""
	local prev = nil
	if state.currentCard ~= nil and next(state.currentCard) ~= nil then
		prev = to_rule_card(state.currentCard)
	end

	-- Evaluate every card in hand for legality + score.
	local candidates = {}
	for i, c in ipairs(hand) do
		local rc = to_rule_card(c)
		local is_last = (#hand == 1)
		local res = rules.get_next_action(
			prev,
			rc,
			penalty > 0,
			chosen_suit,
			penalty,
			0,
			is_last,
			rules_mode
		)
		if res.valid then
			candidates[#candidates + 1] = {
				index = i,
				card = c,
				action_type = res.type,
				score = score_card(c, res.type),
			}
		end
	end

	if #candidates > 0 then
		-- Pick the highest-scoring legal play.
		table.sort(candidates, function(a, b)
			return a.score > b.score
		end)
		local pick = candidates[1]
		local action = { kind = "play", index = pick.index }
		-- If this play needs a suit choice (Ace, or Joker), pre-pick one.
		if pick.action_type == rules.NextActionType.CHOOSE_SUIT then
			-- Don't count the ace we're about to play.
			local remaining = {}
			for i, c in ipairs(hand) do
				if i ~= pick.index then
					remaining[#remaining + 1] = c
				end
			end
			action.suit = M.best_suit_for_hand(remaining)
		end
		return action
	end

	-- No legal play.
	if penalty > 0 then
		-- Must serve the penalty by drawing.
		return { kind = "draw" }
	end

	if not has_drawn then
		return { kind = "draw" }
	end

	-- Already drew and still nothing playable -> pass.
	return { kind = "pass" }
end

return M
