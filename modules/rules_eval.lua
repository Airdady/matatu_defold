----------------------------------------------------------------------
-- rules_eval.lua
-- The decision layer: given the current board + a candidate card, is the
-- move legal and what happens next. Also owns the cutting-card match test,
-- the authoritative server-state getters (penalty / suit), play-effect
-- sound selection, and hand scoring.
--
-- Wraps modules.card_rules; this module never touches sprites or layout.
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
-- Cutting Card Match Logic
----------------------------------------------------------------------
function M.is_cutting_match(self, rec)
    if not self.cutting_card then return false end
    if tonumber(rec.v) ~= 7 then return false end

    local cut = self.cutting_card
    local cv = tonumber(cut.v)

    if cv == 50 then
        local cut_red = (cut.s == "H" or cut.s == "D" or cut.s == "R")
        local rec_red = (rec.s == "H" or rec.s == "D")
        local cut_black = (cut.s == "S" or cut.s == "C" or cut.s == "B")
        local rec_black = (rec.s == "S" or rec.s == "C")

        if cut_red and rec_red then return true end
        if cut_black and rec_black then return true end
        return false
    else
        return rec.s == cut.s
    end
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

function M.get_active_suit(self)
    if self.online_mode and self.game_state and self.game_state.chosenSuit and self.game_state.chosenSuit ~= "" and self.game_state.chosenSuit ~= "null" then
        return tostring(self.game_state.chosenSuit)
    end
    return self.chosen_suit
end

----------------------------------------------------------------------
-- Rule evaluation
----------------------------------------------------------------------
function M.evaluate_play(self, rec, hand)
    local tp = M.top_played(self)
    local prev_rule = nil
    if tp then prev_rule = M.rules_card(tp) end
    local curr_rule = M.rules_card(rec)

    local penalty = M.get_active_penalty(self)
    local suit = M.get_active_suit(self)

    -- First move: nothing to match against, so anything is legal.
    if not prev_rule then
        local result = Rules.get_next_action(curr_rule, curr_rule, false, "", 0, 0, #hand == 1, Rules.RULES_JOKERS)
        if not result then result = {} end
        result.valid = true
        result.is_cut = M.is_cutting_match(self, rec)
        return result
    end

    -- Normal validation through the shared rule engine.
    -- The 7 (cutting card) is NOT wild: it must legally match by suit or value
    -- exactly like every other card before it can ever count as a cut.
    local result = Rules.get_next_action(
        prev_rule, curr_rule,
        penalty > 0,
        suit,
        penalty, 0,
        #hand == 1,
        Rules.RULES_JOKERS)

    if result == nil then
        result = { valid = false, type = Rules.NextActionType.INVALID_MOVE }
    end

    -- Only mark a cutting win when the move was otherwise legal.
    if result.valid and M.is_cutting_match(self, rec) then
        result.is_cut = true
    end

    return result
end

-- Validation is internal only; no visual tinting of cards. Kept as a hook so
-- callers (and online_handler) can fire it after any state change.
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
----------------------------------------------------------------------
function M.trigger_play_effects(self, rec)
    local v = tonumber(rec.v) or 1
    local snd = "SoundPlay"
    if v == 2 then snd = "SoundPlay20"
    elseif v == 3 then snd = "SoundPlay30"
    elseif v == 50 then snd = "SoundPlayJoker" end
    if M.is_cutting_match(self, rec) then snd = "SoundPlayCut" end
    self.play_sound(snd)
end

----------------------------------------------------------------------
-- Hand scoring
----------------------------------------------------------------------
function M.hand_score(hand)
    local total = 0
    for _, c in ipairs(hand) do
        local v = tonumber(c.v) or 10
        local pts = v
        if v == 1 then if c.s == "S" then pts = 60 else pts = 15 end
        elseif v == 2 then pts = 20
        elseif v == 3 then pts = 30
        elseif v == 50 then pts = 50
        elseif v == 15 then pts = 15 end
        total = total + pts
    end
    return total
end

return M
