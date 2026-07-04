----------------------------------------------------------------------
-- rules_eval.lua  (WHOT build)
-- The decision layer: given the current board + a candidate card, is the
-- move legal and what happens next. Wraps modules.card_rules (now the Whot
-- engine); never touches sprites or layout.
--
-- The public function names are unchanged from the Matatu build so the board
-- controller (game.script / game_flow.lua / tournament4.lua) keeps working.
-- Whot has no "cutting card" and no per-suit penalty stacking, so the cutting
-- helpers are reduced to no-ops and the chosen-suit getter now returns the
-- chosen *shape*.
----------------------------------------------------------------------
local Rules = require "modules.card_rules"
local Defs  = require "modules.card_defs"

local M = {}

----------------------------------------------------------------------
-- Small accessors
----------------------------------------------------------------------
function M.rules_card(rec)
    if not rec or not rec.v or not rec.s then return nil end
    return Rules.create_card(tonumber(rec.v), tostring(rec.s))
end

function M.top_played(self) return self.played_cards[#self.played_cards] end

----------------------------------------------------------------------
-- Cutting Card Match Logic — Whot has no cutting card.
----------------------------------------------------------------------
function M.is_cutting_match(_self, _rec)
    return false
end

----------------------------------------------------------------------
-- Server State Getters (authoritative when online)
----------------------------------------------------------------------
function M.get_active_penalty(self)
    if self.online_mode and self.game_state and self.game_state.activePenaltyCount ~= nil then
        return tonumber(self.game_state.activePenaltyCount) or 0
    end
    return self.active_penalty
end

-- Returns the forced shape after a Whot card. Reads server state when online;
-- the server may report it as chosenShape or (legacy) chosenSuit.
function M.get_active_suit(self)
    if self.online_mode and self.game_state then
        local gs = self.game_state
        local s = gs.chosenShape or gs.chosenSuit
        if s and s ~= "" and s ~= "null" then return tostring(s) end
    end
    return self.chosen_suit or self.chosen_shape or ""
end
M.get_active_shape = M.get_active_suit

----------------------------------------------------------------------
-- Rule evaluation
----------------------------------------------------------------------
function M.evaluate_play(self, rec, hand)
    local tp = M.top_played(self)
    local prev_rule = nil
    if tp then prev_rule = M.rules_card(tp) end
    local curr_rule = M.rules_card(rec)

    local penalty = M.get_active_penalty(self)
    local shape = M.get_active_suit(self)

    -- First move: nothing to match against, so anything is legal.
    if not prev_rule then
        local result = Rules.get_next_action(curr_rule, curr_rule, false, "", 0, 0, #hand == 1)
        if not result then result = {} end
        result.valid = true
        return result
    end

    local result = Rules.get_next_action(
        prev_rule, curr_rule,
        penalty > 0,
        shape,
        penalty, 0,
        #hand == 1)

    if result == nil then
        result = { valid = false, type = Rules.NextActionType.INVALID_MOVE }
    end

    return result
end

-- Validation is internal only; kept as a hook for callers/online_handler.
function M.pre_validate_hand(self)
end

function M.has_playable(self, hand)
    if #self.played_cards == 0 then return true end
    for _, c in ipairs(hand) do
        if M.evaluate_play(self, c, hand).valid then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Play-effect sound selection
--   Reuses the existing Matatu sound atlas names. Whot Pick Two -> the
--   "2 penalty" sting, Pick Three -> the "3 penalty" sting, everything
--   else -> the normal play sound.
----------------------------------------------------------------------
function M.trigger_play_effects(self, rec, is_last)
    local v = tonumber(rec.v) or 0
    local snd = "SoundPlay"
    if v == 2 then snd = "SoundPlay20"
    elseif v == 5 then snd = "SoundPlay30" end

    -- The last card ends the round: it lands with the normal play sound.
    if is_last then snd = "SoundPlay" end

    self.play_sound(snd)
end

----------------------------------------------------------------------
-- Hand scoring (Whot: Whot = 20, otherwise the card's face value)
----------------------------------------------------------------------
function M.hand_score(hand)
    local total = 0
    for _, c in ipairs(hand) do
        local v = tonumber(c.v) or 0
        if v == 20 or c.s == "W" then total = total + 20
        else total = total + v end
    end
    return total
end

return M
