-- card_defs.lua
-- Card identity + atlas-frame helpers for the sprite-based game board.
-- Frame names match /assets/cards/cards.atlas: "card_<v><s>" and "card_back".
-- This build is Matatu-only (no Kadi deck).

local deck = require("modules.deck")

local M = {}

M.BACK_FRAME = "card_back"

local VALUE_NAMES = {
	[2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7",
	[8] = "8", [9] = "9", [10] = "10", [11] = "Jack", [12] = "Queen",
	[13] = "King", [15] = "Ace", [50] = "Joker",
}

local SUIT_NAMES = {
	H = "Hearts", D = "Diamonds", S = "Spades", C = "Clubs",
	R = "Red", B = "Black",
}

-- Build a fresh, unshuffled Matatu deck: { {v=,s=}, ... }
function M.build_deck()
	return deck.build()
end

-- Atlas animation/frame name for a card record { v=, s= }.
function M.frame_name(card)
	return "card_" .. tostring(card.v) .. tostring(card.s)
end

-- Human-readable card name, e.g. "Ace of Spades", "Joker".
function M.card_name(card)
	local v = tonumber(card.v) or 0
	if v == 50 then return "Joker" end
	local vn = VALUE_NAMES[v] or tostring(v)
	local sn = SUIT_NAMES[card.s] or tostring(card.s)
	return vn .. " of " .. sn
end

-- Suit display name for the chosen-suit badge.
function M.suit_name(s)
	return SUIT_NAMES[s] or tostring(s)
end

return M
