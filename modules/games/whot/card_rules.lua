--------------------------------------------------------------------
-- card_rules.lua  (WHOT build)
--
-- This file used to hold the Matatu rules. On the Whot branch it IS the
-- Whot rule engine — a pure-Lua port of whot_rules.lua / WhotRules.gd.
-- Pure logic, no engine dependencies, so it drives the offline AI, the
-- local game engine and client-side move validation before sending online.
--
-- A "card" is a plain table { v = <int>, s = <shape> }.
--
-- Back-compat: a handful of call sites (game_flow, tournament4,
-- offline_handler) still reference the old Matatu API surface
-- (RULES_JOKERS, NextActionType.CHOOSE_SUIT, is_master_card, ...). Those
-- names are kept here as harmless aliases that map onto Whot behaviour so
-- nothing nil-errors while the online/tournament board is migrated.
--------------------------------------------------------------------

local M = {}

-- === SHAPE CONSTANTS (replace Matatu suits) ===
M.SHAPE_CIRCLE   = "C"
M.SHAPE_TRIANGLE = "T"
M.SHAPE_CROSS    = "X"
M.SHAPE_SQUARE   = "S"
M.SHAPE_STAR     = "R"
M.SHAPE_WHOT     = "W" -- the Whot wildcard shape

M.SHAPES = { "C", "T", "X", "S", "R" }

-- === RULE SETS (legacy aliases — Whot has a single rule set) ===
M.RULES_CLASSIC = "CLASSIC"
M.RULES_JOKERS  = "JOKERS"

-- === NEXT-ACTION ENUM (numeric, mirrors the Godot enum order) ===
M.NextActionType = {
    INVALID_MOVE     = 0,
    PLAY_CARD        = 1,
    CHOOSE_SHAPE     = 2,
    SKIP_TURN        = 3,
    END_TURN         = 4,
    REDUCE_PENALTY   = 5,
    TRANSFER_PENALTY = 6,
    HOLD_ON          = 7, -- Card 1: player plays again
    GENERAL_MARKET   = 8, -- Card 14: all opponents draw
}
-- Legacy alias: old code compares against CHOOSE_SUIT; Whot's equivalent is
-- CHOOSE_SHAPE, so point it at the same value.
M.NextActionType.CHOOSE_SUIT = M.NextActionType.CHOOSE_SHAPE

-- === WHOT VALUES ===
M.VALUES = {
    HOLD_ON        = 1,
    PICK_TWO       = 2,
    PICK_THREE     = 5,
    SUSPENSION     = 8,
    GENERAL_MARKET = 14,
    WHOT           = 20,
}

--------------------------------------------------------------------
-- Card helpers
--------------------------------------------------------------------

function M.create_card(value, shape)
    return { v = math.floor(tonumber(value) or 0), s = tostring(shape) }
end

local function shape_name(s)
    if s == "C" then return "Circle"
    elseif s == "T" then return "Triangle"
    elseif s == "X" then return "Cross"
    elseif s == "S" then return "Square"
    elseif s == "R" then return "Star"
    elseif s == "W" then return "Whot"
    end
    return "Unknown"
end
M.shape_name = shape_name

function M.card_to_string(card)
    if card == nil then return "<none>" end
    if card.v == M.VALUES.WHOT then return "Whot! (20)" end
    return string.format("%d of %s", card.v, shape_name(card.s))
end

--------------------------------------------------------------------
-- Utility predicates
--------------------------------------------------------------------

function M.is_whot(card)
    return card.v == M.VALUES.WHOT or card.s == M.SHAPE_WHOT
end

function M.is_penalty_card(card)
    return card.v == M.VALUES.PICK_TWO or card.v == M.VALUES.PICK_THREE
end

function M.get_card_penalty_value(card)
    if card.v == M.VALUES.PICK_TWO then return 2 end
    if card.v == M.VALUES.PICK_THREE then return 3 end
    return 0
end

-- selected_shape: a chosen shape forced by a previously played Whot ("" = none)
function M.is_basic_match(card, prev_card, selected_shape)
    selected_shape = selected_shape or ""
    if M.is_whot(card) then
        return true -- Whot can be played on anything
    end
    if selected_shape ~= "" then
        return card.s == selected_shape
    end
    return (card.v == prev_card.v or card.s == prev_card.s)
end

--------------------------------------------------------------------
-- Legacy Matatu predicates kept as harmless no-ops/aliases
--------------------------------------------------------------------
function M.is_classic(_) return false end
function M.is_joker(_) return false end           -- Whot has no jokers
function M.is_ace(_) return false end             -- no aces in Whot
function M.is_master_card(_, _) return false end  -- no master card in Whot
M.MASTER_CARD = { v = -1, s = "" }                -- never matches a real card

--------------------------------------------------------------------
-- Card effects
--------------------------------------------------------------------

function M.get_card_effect(card, _is_penalty_active)
    if M.is_whot(card) then
        return {
            type = M.NextActionType.CHOOSE_SHAPE,
            allow_shape_choice = true,
            allow_suit_choice  = true, -- legacy mirror
            message = "Whot played - Choose a shape",
        }
    end

    local v = card.v
    if v == M.VALUES.HOLD_ON then
        return { type = M.NextActionType.HOLD_ON, message = "Hold On - You play again!" }
    elseif v == M.VALUES.PICK_TWO then
        return { type = M.NextActionType.TRANSFER_PENALTY, penalty_cards = 2,
                 message = "Pick Two - Next player draws 2 cards" }
    elseif v == M.VALUES.PICK_THREE then
        return { type = M.NextActionType.TRANSFER_PENALTY, penalty_cards = 3,
                 message = "Pick Three - Next player draws 3 cards" }
    elseif v == M.VALUES.SUSPENSION then
        return { type = M.NextActionType.SKIP_TURN, skip_turns = 1,
                 message = "Suspension - Next player skips their turn" }
    elseif v == M.VALUES.GENERAL_MARKET then
        return { type = M.NextActionType.GENERAL_MARKET, draw_cards = 1,
                 message = "General Market - All opponents draw 1 card" }
    end

    return { type = M.NextActionType.END_TURN, message = "Turn ends normally" }
end

--------------------------------------------------------------------
-- Penalty calculation
--   In Whot, penalties don't stack/reduce by suit like Matatu: a matching
--   Pick card simply overrides and transfers the new penalty onward.
--------------------------------------------------------------------

function M.calculate_penalty_action(played_card, prev_card, current_penalty)
    local played_penalty = M.get_card_penalty_value(played_card)

    if played_card.v == prev_card.v then
        return {
            type = M.NextActionType.TRANSFER_PENALTY,
            next_player_penalty_count = played_penalty,
            current_penalty_count = 0,
            message = string.format("Penalty transferred (%d cards)", played_penalty),
        }
    end

    return {
        type = M.NextActionType.INVALID_MOVE,
        next_player_penalty_count = 0,
        current_penalty_count = current_penalty,
        message = "Cannot defend penalty with this card.",
    }
end

--------------------------------------------------------------------
-- Main validation entry point
--
-- Returns a "NextActionResult" table:
--   { valid, type, next_player_penalty_count, current_penalty_count,
--     message, allow_shape_choice, allow_suit_choice, penalty_cards,
--     skip_turns, draw_cards }
--
-- Trailing legacy args (is_last_card, rules) are accepted and ignored so the
-- old Matatu call signature keeps working unchanged.
--------------------------------------------------------------------

local function new_result(partial)
    local r = {
        valid = true,
        type = M.NextActionType.END_TURN,
        next_player_penalty_count = 0,
        current_penalty_count = 0,
        message = "",
        allow_shape_choice = false,
        allow_suit_choice = false,
        penalty_cards = 0,
        skip_turns = 0,
        draw_cards = 0,
    }
    if partial then
        for k, val in pairs(partial) do r[k] = val end
    end
    return r
end

function M.get_next_action(prev_card, played_card, is_penalty_active,
                           selected_shape, current_penalty_count,
                           next_player_penalty_count, is_last_card, _rules)
    is_penalty_active         = is_penalty_active or false
    selected_shape            = selected_shape or ""
    current_penalty_count     = current_penalty_count or 0
    next_player_penalty_count = next_player_penalty_count or 0

    local function create_invalid(msg)
        return new_result({
            valid = false,
            type = M.NextActionType.INVALID_MOVE,
            next_player_penalty_count = next_player_penalty_count,
            current_penalty_count = current_penalty_count,
            message = msg,
        })
    end

    -- First move / empty board
    if prev_card == nil then
        local effect = M.get_card_effect(played_card, is_penalty_active)
        effect.next_player_penalty_count = effect.penalty_cards or 0
        return new_result(effect)
    end

    -- Active penalty (someone played a Pick card on us)
    if is_penalty_active and current_penalty_count > 0 then
        if M.is_penalty_card(played_card) and played_card.v == prev_card.v then
            return new_result(
                M.calculate_penalty_action(played_card, prev_card, current_penalty_count))
        end
        return create_invalid(string.format(
            "Must play a matching Pick card to defend, or draw %d cards.",
            current_penalty_count))
    end

    -- Basic move validation
    if not M.is_basic_match(played_card, prev_card, selected_shape) then
        return create_invalid("Cannot play " .. M.card_to_string(played_card))
    end

    -- Regular play
    local effect = M.get_card_effect(played_card, is_penalty_active)
    effect.next_player_penalty_count = effect.penalty_cards or 0
    effect.current_penalty_count = 0
    return new_result(effect)
end

return M
