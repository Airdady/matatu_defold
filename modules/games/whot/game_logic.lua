--- game_logic.lua
-- Self-contained OFFLINE Matatu engine (Quick Play vs the AI). There is no
-- server in offline mode, so this module is the single source of truth: it
-- deals, validates moves through `card_rules`, applies penalties / suit choices
-- / skips, reshuffles, drives the AI, and detects the winner.
--
-- The state table is intentionally shaped like the server's game state so the
-- game board GUI can render offline and online games the same way:
--   state = {
--     rules, status ("PLAYING"/"GAME_OVER"), winner,
--     currentTurn, currentCard = {v,s}, chosenSuit, activePenaltyCount,
--     deck = {..}, played = {..},
--     players = { [id] = { hand={..}, username, avatar, isAI } },
--   }

local deck_mod = require("modules.deck")
local rules = require("modules.card_rules")
local ai = require("modules.ai_player")

local M = {}

local HAND_SIZE = 7

-- ── helpers ────────────────────────────────────────────────────────────────
local function other_id(g, id)
	if id == g.human_id then
		return g.ai_id
	end
	return g.human_id
end

local function hand_of(g, id)
	return g.state.players[id].hand
end

local function is_plain_starter(card)
	-- Avoid starting the discard pile on a power/wild Whot card.
	if card.v == rules.VALUES.WHOT or card.s == "W" then
		return false
	end -- Whot wildcard (choose shape)
	if card.v == rules.VALUES.HOLD_ON then
		return false
	end -- Hold On (play again)
	if card.v == rules.VALUES.PICK_TWO or card.v == rules.VALUES.PICK_THREE then
		return false
	end -- penalty
	if card.v == rules.VALUES.SUSPENSION or card.v == rules.VALUES.GENERAL_MARKET then
		return false
	end -- skip / general market
	return true
end

local function reshuffle(g)
	local played = g.state.played
	if #played <= 1 then
		return
	end
	local top = played[#played]
	local rest = {}
	for i = 1, #played - 1 do
		rest[#rest + 1] = played[i]
	end
	deck_mod.shuffle(rest)
	g.state.deck = rest
	g.state.played = { top }
end

local function draw_cards(g, id, n)
	local drew = {}
	local hand = hand_of(g, id)
	for _ = 1, n do
		if #g.state.deck == 0 then
			reshuffle(g)
			if #g.state.deck == 0 then
				break
			end
		end
		local card = table.remove(g.state.deck) -- pop from top
		hand[#hand + 1] = card
		drew[#drew + 1] = card
	end
	return drew
end

local function to_rule_prev(g)
	local cc = g.state.currentCard
	if cc == nil or next(cc) == nil then
		return nil
	end
	return rules.create_card(cc.v, cc.s)
end

local function validate(g, id, card)
	local hand = hand_of(g, id)
	return rules.get_next_action(
		to_rule_prev(g),
		rules.create_card(card.v, card.s),
		(g.state.activePenaltyCount or 0) > 0,
		g.state.chosenSuit or "",
		g.state.activePenaltyCount or 0,
		0,
		(#hand == 1),
		g.state.rules
	)
end

--- True if `id` holds at least one legal move right now.
function M.has_any_playable(g, id)
	for _, c in ipairs(hand_of(g, id)) do
		if validate(g, id, c).valid then
			return true
		end
	end
	return false
end

local function switch_turn(g)
	g.state.currentTurn = other_id(g, g.state.currentTurn)
	g.has_drawn = false
	g.must_continue = false
end

-- ── construction ─────────────────────────────────────────────────────────--
--- Create a new offline game. opts: { human_id, human_name, human_avatar,
---   ai_id, ai_name, ai_avatar, rules, stake }
function M.new(opts)
	opts = opts or {}
	local g = {
		human_id = opts.human_id or "you",
		ai_id = opts.ai_id or "ai",
		has_drawn = false,
		must_continue = false,
		awaiting_suit = false,
		-- Persist the requested match length so the board can tell a single
		-- Quick Play game (series == 1, no scoreboard) apart from a Battle-AI
		-- best-of series. Without this, callers fell through to app.ai_series
		-- (default 3) and Quick Play wrongly showed a best-of-3 scoreboard.
		series = opts.series or 1,
		config = opts.config or opts,
	}
	local d = deck_mod.new_shuffled()

	local state = {
		rules = opts.rules or rules.RULES_JOKERS,
		status = "PLAYING",
		winner = nil,
		currentTurn = g.human_id,
		currentCard = {},
		chosenSuit = "",
		activePenaltyCount = 0,
		deck = d,
		played = {},
		stake = opts.stake or { amount = 0, points = 0 },
		players = {
			[g.human_id] = {
				hand = {},
				username = opts.human_name or "You",
				avatar = opts.human_avatar or 1,
				isAI = false,
			},
			[g.ai_id] = {
				hand = {},
				username = opts.ai_name or "Whot Bot",
				avatar = opts.ai_avatar or 2,
				isAI = true,
			},
		},
	}
	g.state = state

	-- Deal alternately.
	for _ = 1, HAND_SIZE do
		table.insert(state.players[g.human_id].hand, table.remove(d))
		table.insert(state.players[g.ai_id].hand, table.remove(d))
	end

	-- Flip a plain starter card onto the discard pile.
	local starter
	for i = #d, 1, -1 do
		if is_plain_starter(d[i]) then
			starter = table.remove(d, i)
			break
		end
	end
	starter = starter or table.remove(d)
	state.currentCard = { v = starter.v, s = starter.s }
	state.played[#state.played + 1] = state.currentCard

	return g
end

function M.get_state(g)
	return g.state
end
function M.is_human_turn(g)
	return g.state.status == "PLAYING" and g.state.currentTurn == g.human_id
end
function M.is_ai_turn(g)
	return g.state.status == "PLAYING" and g.state.currentTurn == g.ai_id
end
function M.is_over(g)
	return g.state.status == "GAME_OVER"
end

-- ── core apply ─────────────────────────────────────────────────────────────
-- Apply a validated play for player `id`. `chosen_suit` is supplied up-front by
-- the AI for ace/joker plays; for the human it is nil and resolved separately.
local function apply_play(g, id, index, res, chosen_suit)
	local hand = hand_of(g, id)
	local card = table.remove(hand, index)
	g.state.currentCard = { v = card.v, s = card.s }
	g.state.played[#g.state.played + 1] = g.state.currentCard
	g.state.chosenSuit = ""

	local summary = { ok = true, kind = "play", played = card, message = res.message, actor = id }

	-- Win: emptied hand.
	if #hand == 0 then
		g.state.status = "GAME_OVER"
		g.state.winner = id
		summary.game_over = true
		summary.winner = id
		return summary
	end

	local NA = rules.NextActionType
	local t = res.type

	-- NA.CHOOSE_SUIT is an alias of NA.CHOOSE_SHAPE in the Whot engine, so a
	-- Whot card lands here. `chosen_suit` carries the chosen *shape*.
	if t == NA.CHOOSE_SHAPE then
		if chosen_suit and chosen_suit ~= "" then
			g.state.chosenSuit = chosen_suit
			summary.chosen_suit = chosen_suit
			switch_turn(g)
			summary.turn_changed = true
		else
			g.awaiting_suit = true
			summary.needs_suit_choice = true
		end
	elseif t == NA.TRANSFER_PENALTY then
		g.state.activePenaltyCount = res.next_player_penalty_count or 0
		switch_turn(g)
		summary.turn_changed = true
	elseif t == NA.REDUCE_PENALTY then
		local draw_n = res.draw_cards or res.current_penalty_count or 0
		g.state.activePenaltyCount = 0
		if draw_n > 0 then
			summary.drew = draw_cards(g, id, draw_n)
		end
		switch_turn(g)
		summary.turn_changed = true
	elseif t == NA.SKIP_TURN or t == NA.HOLD_ON then
		-- Suspension (8): heads-up, skipping the opponent keeps control.
		-- Hold On (1): the actor explicitly plays again. Both keep control.
		g.state.activePenaltyCount = 0
		g.has_drawn = false
		g.must_continue = true
		summary.continue_turn = true
	elseif t == NA.GENERAL_MARKET then
		-- General Market (14): every opponent draws 1, then the actor plays
		-- again. Heads-up means the single opponent draws one card.
		g.state.activePenaltyCount = 0
		local opp = other_id(g, id)
		summary.opp_drew = draw_cards(g, opp, res.draw_cards or 1)
		summary.opp_id = opp
		g.has_drawn = false
		g.must_continue = true
		summary.continue_turn = true
	else -- END_TURN / default
		g.state.activePenaltyCount = 0
		switch_turn(g)
		summary.turn_changed = true
	end

	return summary
end

-- ── human actions ────────────────────────────────────────────────────────--
function M.player_play(g, index)
	if not M.is_human_turn(g) or g.awaiting_suit then
		return { ok = false, message = "Not your turn" }
	end
	local hand = hand_of(g, g.human_id)
	local card = hand[index]
	if not card then
		return { ok = false, message = "No such card" }
	end
	local res = validate(g, g.human_id, card)
	if not res.valid then
		return { ok = false, message = res.message }
	end
	return apply_play(g, g.human_id, index, res, nil)
end

function M.player_choose_suit(g, suit)
	if not g.awaiting_suit then
		return { ok = false, message = "No suit choice pending" }
	end
	g.state.chosenSuit = suit
	g.awaiting_suit = false
	switch_turn(g)
	return { ok = true, kind = "choose_suit", chosen_suit = suit, turn_changed = true, actor = g.human_id }
end

function M.player_draw(g)
	if not M.is_human_turn(g) or g.awaiting_suit then
		return { ok = false, message = "Not your turn" }
	end
	local penalty = g.state.activePenaltyCount or 0
	if penalty > 0 then
		local drew = draw_cards(g, g.human_id, penalty)
		g.state.activePenaltyCount = 0
		switch_turn(g)
		return { ok = true, kind = "draw", drew = drew, turn_changed = true, message = "Drew penalty", actor = g.human_id }
	end

	if g.has_drawn then
		return M.player_pass(g)
	end

	-- Whot: drawing always ends the turn — no "pick and play" of the card
	-- just drawn (or any other card already in hand).
	local drew = draw_cards(g, g.human_id, 1)
	switch_turn(g)
	return {
		ok = true,
		kind = "draw",
		drew = drew,
		turn_changed = true,
		message = "Drew a card — turn ends",
		actor = g.human_id,
	}
end

function M.player_pass(g)
	if not M.is_human_turn(g) then
		return { ok = false, message = "Not your turn" }
	end
	switch_turn(g)
	return { ok = true, kind = "pass", turn_changed = true, actor = g.human_id }
end

-- ── AI driver ────────────────────────────────────────────────────────────--
-- Performs ONE AI action and returns a summary. The board calls this on a timer
-- while it remains the AI's turn, so each step can be animated.
function M.ai_step(g)
	if not M.is_ai_turn(g) then
		return { ok = false, message = "Not AI turn" }
	end
	local hand = hand_of(g, g.ai_id)
	local decision = ai.decide(g.state, hand, g.has_drawn)

	if decision.kind == "play" then
		local card = hand[decision.index]
		local res = validate(g, g.ai_id, card)
		if not res.valid then
			-- Should not happen; fall back to drawing to stay safe.
			decision = { kind = "draw" }
		else
			return apply_play(g, g.ai_id, decision.index, res, decision.suit)
		end
	end

	if decision.kind == "draw" then
		local penalty = g.state.activePenaltyCount or 0
		if penalty > 0 then
			local drew = draw_cards(g, g.ai_id, penalty)
			g.state.activePenaltyCount = 0
			switch_turn(g)
			return { ok = true, kind = "draw", drew = drew, turn_changed = true, actor = g.ai_id }
		end
		-- Whot: drawing always ends the turn — the AI never re-decides to
		-- play the card it just drew.
		local drew = draw_cards(g, g.ai_id, 1)
		switch_turn(g)
		return { ok = true, kind = "draw", drew = drew, turn_changed = true, actor = g.ai_id }
	end

	-- pass
	switch_turn(g)
	return { ok = true, kind = "pass", turn_changed = true, actor = g.ai_id }
end

return M
