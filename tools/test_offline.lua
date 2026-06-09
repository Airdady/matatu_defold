-- Smoke test: play many full offline games (human auto-plays greedily like the
-- AI) and assert every game terminates with a winner and no errors.
package.path = package.path .. ";./?.lua"

local game_logic = require("modules.game_logic")
local ai = require("modules.ai_player")
local rules = require("modules.card_rules")

math.randomseed(12345)

local function auto_human_turn(g)
	-- Mirror AI logic for the human seat so the sim can run unattended.
	local guard = 0
	while game_logic.is_human_turn(g) and not game_logic.is_over(g) do
		guard = guard + 1
		if guard > 200 then
			error("human turn did not terminate")
		end
		local hand = game_logic.get_state(g).players[g.human_id].hand
		local decision = ai.decide(game_logic.get_state(g), hand, g.has_drawn)
		local res
		if decision.kind == "play" then
			-- choose suit up front if needed by peeking
			res = game_logic.player_play(g, decision.index)
			if res.needs_suit_choice then
				local remaining = game_logic.get_state(g).players[g.human_id].hand
				game_logic.player_choose_suit(g, ai.best_suit_for_hand(remaining))
			end
		elseif decision.kind == "draw" then
			res = game_logic.player_draw(g)
			if res.auto_pass then
				game_logic.player_pass(g)
			end
		else
			res = game_logic.player_pass(g)
		end
		if not res.ok then
			error("human action failed: " .. tostring(res.message))
		end
		if res.continue_turn then
			-- keep going (skip card) — loop continues
		elseif res.turn_changed or res.needs_suit_choice then
			break
		end
	end
end

local function run_game()
	local g = game_logic.new({
		human_id = "you",
		ai_id = "bot",
		human_name = "You",
		ai_name = "Bot",
		rules = rules.RULES_JOKERS,
	})
	local turns = 0
	while not game_logic.is_over(g) do
		turns = turns + 1
		if turns > 5000 then
			error("game did not terminate (possible infinite loop)")
		end
		if game_logic.is_human_turn(g) then
			auto_human_turn(g)
		elseif game_logic.is_ai_turn(g) then
			local guard = 0
			while game_logic.is_ai_turn(g) and not game_logic.is_over(g) do
				guard = guard + 1
				if guard > 200 then
					error("AI turn did not terminate")
				end
				local r = game_logic.ai_step(g)
				if not r.ok then
					error("ai step failed: " .. tostring(r.message))
				end
				if r.turn_changed or r.game_over then
					break
				end
			end
		end
	end
	return g.state.winner, turns
end

local wins = { you = 0, bot = 0 }
local N = 500
for _ = 1, N do
	local winner = run_game()
	wins[winner] = (wins[winner] or 0) + 1
end

print(string.format("Ran %d full offline games with NO errors.", N))
print(string.format("  human(you) wins: %d", wins.you))
print(string.format("  ai(bot)   wins: %d", wins.bot))
assert(wins.you + wins.bot == N, "every game must have a winner")
print("PASS: offline engine + AI + rules are sound.")
