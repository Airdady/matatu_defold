-- =============================================================================
-- game_mode.lua  —  the single build-time switch for which game this build is.
--
-- Set M.GAME to "MATATU", "WHOT" or "KADI" before building. Everything that is
-- game-specific and cleanly switchable derives from here:
--   * backend endpoint path   (config.lua -> /matatu | /whot | /kadi)
--   * in-app branding/titles   (lobby, tutorial, bot name)
--   * per-game how-to / special-card copy
--
-- The backend (be_matatu) already runs a matching rule engine per path
-- (src/matatu, src/whot, src/kadi) and selects it from the URL path, so simply
-- pointing the client at /whot makes the server validate Whot moves.
--
-- The game *logic and art* switch here too: modules/card_rules.lua, deck.lua,
-- card_defs.lua, ai_player.lua, rules_eval.lua and game_logic.lua are thin
-- dispatchers over modules/games/<game>/, and main/card.script assigns the
-- matching card atlas (classic Matatu sheets + themes, or cards_whot.atlas).
-- KADI currently plays with the standard deck + the Matatu client engine —
-- its own special-card rules are not ported client-side yet (the backend
-- /kadi engine is authoritative for online play).
-- =============================================================================

local M = {}

-- >>> CHANGE THIS ONE LINE TO RE-TARGET THE WHOLE BUILD <<<
M.GAME = "WHOT"          -- "MATATU" | "WHOT" | "KADI"

-- Per-game definitions.
--
-- country/currency_code/currency_symbol/phone_country_code/phone_placeholder
-- mirror be_matatu's COUNTRY_CONFIG (src/common/constants/gameConfig.ts) —
-- Matatu=Uganda/UGX (existing, unchanged), Whot=Nigeria/NGN, Kadi=Kenya/KES.
-- These drive display only (currency labels, phone-field placeholder); the
-- real-money online stake AMOUNTS are intentionally NOT switched here yet —
-- see WHOT_PORT_NOTES.md for why (the backend's stake tables are hardcoded
-- UGX-only in several money-settlement files and would need a coordinated
-- fix first, to avoid corrupting a Whot/Kadi player's real stake).
local DEFS = {
    MATATU = {
        path    = "matatu",
        brand   = "Matatu",
        title   = "MATATU",
        tagline = "East Africa's favourite card game.",
        country            = "Uganda",
        currency_code       = "UGX",
        currency_symbol     = "UGX",
        phone_country_code  = "256",
        phone_placeholder   = "07XX XXX XXX",
        default_stake_amount = 200,
        how_to  = {
            "On your turn, play a card matching the",
            "top card's SUIT or NUMBER.",
            "No match?  Tap the deck to DRAW.",
        },
        specials = {
            "8 / J    skip the opponent (play again)",
            "2 / 3    opponent draws a penalty",
            "Ace      choose the next suit",
            "Joker    pass on a 5-card penalty",
            "Ace of Spades  cancels any penalty",
            "7    the cutting card can end a round",
        },
    },
    WHOT = {
        path    = "whot",
        brand   = "Whot",
        title   = "WHOT",
        tagline = "Africa's favourite shapes card game.",
        country            = "Nigeria",
        currency_code       = "NGN",
        currency_symbol     = "\226\130\166", -- ₦
        phone_country_code  = "234",
        phone_placeholder   = "0801 234 5678",
        default_stake_amount = 100,
        how_to  = {
            "On your turn, play a card matching the",
            "top card's SHAPE or NUMBER.",
            "No match?  Tap the deck to DRAW.",
        },
        specials = {
            "1    Hold On — you play again",
            "2    Pick Two — next player draws 2",
            "5    Pick Three — next player draws 3",
            "8    Suspension — next player is skipped",
            "14   General Market — everyone else draws 1",
            "20   Whot — choose the next shape",
        },
    },
    KADI = {
        path    = "kadi",
        brand   = "Kadi",
        title   = "KADI",
        tagline = "The classic Kadi card game.",
        country            = "Kenya",
        currency_code       = "KES",
        currency_symbol     = "KSh",
        phone_country_code  = "254",
        phone_placeholder   = "07XX XXX XXX",
        default_stake_amount = 10,
        how_to  = {
            "On your turn, play a card matching the",
            "top card's SUIT or NUMBER.",
            "No match?  Tap the deck to DRAW.",
        },
        specials = {
            "Question cards ask for an answer",
            "Jump / Kickback change the turn order",
            "Penalty cards make the next player draw",
        },
    },
}

function M.def()
    return DEFS[M.GAME] or DEFS.MATATU
end

local d = M.def()
M.PATH    = d.path        -- backend URL segment
M.BRAND   = d.brand       -- "Whot"  (mixed case, for sentences)
M.TITLE   = d.title       -- "WHOT"  (upper, for the big lobby title)
M.TAGLINE = d.tagline
M.BOT     = d.brand .. " Bot"

M.COUNTRY             = d.country
M.CURRENCY_CODE        = d.currency_code
M.CURRENCY_SYMBOL      = d.currency_symbol
M.PHONE_COUNTRY_CODE   = d.phone_country_code
M.PHONE_PLACEHOLDER    = d.phone_placeholder
M.DEFAULT_STAKE_AMOUNT = d.default_stake_amount

-- Convenience predicates
function M.is_whot()   return M.GAME == "WHOT"   end
function M.is_matatu() return M.GAME == "MATATU" end
function M.is_kadi()   return M.GAME == "KADI"   end

return M
