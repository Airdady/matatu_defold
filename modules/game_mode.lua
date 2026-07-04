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
-- NOTE on the game *logic*: this particular build ships the WHOT rule set,
-- deck and card art (see card_rules.lua / deck.lua / card_defs.lua / the cards
-- atlas). MATATU and KADI switch the endpoints + branding here; to also switch
-- the offline rules/deck/art you drop in their variant modules behind the same
-- M.GAME check (Matatu's live on `main`; Kadi's client game is not built yet).
-- =============================================================================

local M = {}

-- >>> CHANGE THIS ONE LINE TO RE-TARGET THE WHOLE BUILD <<<
M.GAME = "WHOT"          -- "MATATU" | "WHOT" | "KADI"

-- Per-game definitions.
local DEFS = {
    MATATU = {
        path    = "matatu",
        brand   = "Matatu",
        title   = "MATATU",
        tagline = "East Africa's favourite card game.",
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

-- Convenience predicates
function M.is_whot()   return M.GAME == "WHOT"   end
function M.is_matatu() return M.GAME == "MATATU" end
function M.is_kadi()   return M.GAME == "KADI"   end

return M
