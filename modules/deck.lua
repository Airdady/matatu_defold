--- deck.lua  (WHOT build)
-- Builds and shuffles the standard Whot deck.
-- Card = { v = value, s = shape }.  Shapes: C/T/X/S/R + W (Whot wildcard).
-- Mirrors the composition in whot_defold card_defs.build_deck / Game.gd.

local M = {}

--- Returns a fresh, ordered Whot deck.
function M.build()
	local cards = {}
	local function add(values, shape)
		for _, v in ipairs(values) do
			cards[#cards + 1] = { v = v, s = shape }
		end
	end
	add({ 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14 }, "C") -- Circles
	add({ 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14 }, "T") -- Triangles
	add({ 1, 2, 3, 5, 7, 10, 11, 13, 14 },           "S") -- Squares
	add({ 1, 2, 3, 5, 7, 10, 11, 13, 14 },           "X") -- Crosses
	add({ 1, 2, 3, 4, 5, 7, 8 },                     "R") -- Stars
	for _ = 1, 5 do cards[#cards + 1] = { v = 20, s = "W" } end -- Whots
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
