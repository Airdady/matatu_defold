-- card_defs.lua  (WHOT build)
-- Card identity + atlas-frame helpers for the sprite-based game board.
--
-- Frame/animation names match /assets/cards/cards.atlas, which on the Whot
-- branch references the Whot art. Each card image is named "<v><s>"
-- e.g. "1C", "10T", "20W"; the deck back is "BACK_DEFAULT".

local deck = require("modules.deck")

local M = {}

M.BACK_FRAME = "BACK_DEFAULT"

-- Whot has a single deck art set (no per-theme card backs).
function M.back_frame()
	return M.BACK_FRAME
end

local function shape_name(s)
	if s == "C" then return "Circles"
	elseif s == "T" then return "Triangles"
	elseif s == "S" then return "Squares"
	elseif s == "X" then return "Crosses"
	elseif s == "R" then return "Stars"
	elseif s == "W" then return "Whot"
	end
	return tostring(s)
end

-- Build a fresh, unshuffled Whot deck: { {v=,s=}, ... }
function M.build_deck()
	return deck.build()
end

-- Atlas animation/frame name for a card record { v=, s= }, e.g. "20W".
function M.frame_name(card)
	return tostring(card.v) .. tostring(card.s)
end

-- Human-readable card name, e.g. "10 of Circles", "Whot! (20)".
function M.card_name(card)
	local v = tonumber(card.v) or 0
	if v == 20 or card.s == "W" then return "Whot! (20)" end
	return tostring(v) .. " of " .. shape_name(card.s)
end

-- Shape display name for the chosen-shape badge (legacy name: suit_name).
function M.shape_name(s)
	return shape_name(s)
end
M.suit_name = M.shape_name

return M
