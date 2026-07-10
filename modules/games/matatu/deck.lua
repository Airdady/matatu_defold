--- deck.lua
-- Builds and shuffles the 54-card Matatu deck.
-- Card = { v = value, s = suit }.  Ace=15, Jack=11, Queen=12, King=13.

local M = {}

local SUITS = { "H", "D", "S", "C" }
-- Ace(15) first, then 2..13
local VALUES = { 15, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }

--- Returns a fresh, ordered 54-card deck (52 standard + 2 jokers).
function M.build()
	local cards = {}
	for _, s in ipairs(SUITS) do
		for _, v in ipairs(VALUES) do
			cards[#cards + 1] = { v = v, s = s }
		end
	end
	-- Jokers
	cards[#cards + 1] = { v = 50, s = "R" }
	cards[#cards + 1] = { v = 50, s = "B" }
	return cards
end

--- In-place Fisher-Yates shuffle.
function M.shuffle(cards)
	for i = #cards, 2, -1 do
		local j = math.random(i)
		cards[i], cards[j] = cards[j], cards[i]
	end
	return cards
end

--- Convenience: a freshly shuffled deck.
function M.new_shuffled()
	return M.shuffle(M.build())
end

return M
