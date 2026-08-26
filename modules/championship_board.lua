-- WHAT THE BOARD SHOWS DURING A GLOBAL CHAMPIONSHIP MATCH.
--
-- The championship is not played for the pot. A qualifier is played for a
-- place in the next round; the coins on the table are an entry, not a prize,
-- and putting a two-stake bundle beside the scoreboard for every one of seven
-- rounds says the opposite — it makes each rung look like a cash match and
-- makes the grand prize, the only money that is actually at stake, look like
-- one more of them.
--
-- So through the ladder the board carries the championship's NAME instead of
-- its money, and the coins are held back for the one match they mean
-- something in:
--
--   any level below the final   no pot, no coin flight at the end,
--                               a vertical CHAMPIONSHIP watermark
--   the final                   the GRAND PRIZE as the pot, on the finalist's
--                               own side of the board, and it may fly to the
--                               winner when the match ends
--
-- Everything that is NOT the global championship is untouched: an ordinary
-- match, a battle and a private cup all keep the stake pot they had.
--
-- WHOSE SIDE. Only the local player's level is knowable here — the tournament
-- list that carries `currentLevel` is this player's own, and no payload names
-- the opponent's rung. So the pot is placed on this player's side when THEY
-- are in the final, and otherwise not drawn at all. Guessing the opponent's
-- position from a level we were never sent would be worse than leaving it off.
local championship = require("modules.championship")

local M = {}

-- The local player's half of the board. The pot's resting X is the
-- scoreboard's column (coins.gui_script's POT_REST_X); this only moves it down
-- out of the centre onto the near side.
M.POT_X = 220
M.POT_Y_CENTRE = 360
M.POT_Y_MINE = 180

M.WATERMARK_TEXT = "CHAMPIONSHIP"

local function n(v) return tonumber(v) or 0 end

--- The player's own row for this tournament, out of the list IDENTIFY brings.
function M.entry(tournament_id, user_data)
    local id = tostring(tournament_id or "")
    if id == "" then return nil end
    local list = type(user_data) == "table" and user_data.tournaments or nil
    if type(list) ~= "table" then return nil end
    for _, t in ipairs(list) do
        if type(t) == "table" and tostring(t._id or t.tournamentId or "") == id then
            return t
        end
    end
    return nil
end

--- How many rungs this ladder has.
--
-- `levels` is the player's own per-level progress and is empty until they have
-- played one, so it cannot be counted on for the ladder's LENGTH.
-- `tournamentCount` is the tournament's own level count and is what the
-- server sends for exactly this (see getUserTournaments in cardUtils.ts);
-- levelNames is the same length and is the fallback.
function M.level_count(t)
    if type(t) ~= "table" then return 0 end
    local c = tonumber(t.tournamentCount)
    if c and c > 0 then return math.floor(c) end
    if type(t.levelNames) == "table" and #t.levelNames > 0 then return #t.levelNames end
    if type(t.levels) == "table" and #t.levels > 0 then return #t.levels end
    return 0
end

function M.current_level(t)
    if type(t) ~= "table" then return 0 end
    local up = type(t.userProgress) == "table" and t.userProgress or nil
    return n(up and up.currentLevel or t.currentLevel)
end

--- Is this player standing on the last rung?
--
-- `>=` rather than `==`: a ladder whose count we could not read answers 0, and
-- a player on level 3 of an unknown ladder must NOT be treated as a finalist.
-- So a zero count is refused outright before the comparison.
function M.at_final(t)
    local total = M.level_count(t)
    if total <= 0 then return false end
    return M.current_level(t) >= total
end

function M.grand_prize(t)
    if type(t) ~= "table" then return 0 end
    local gp = t.grandPrize
    if type(gp) == "table" then return n(gp.value or gp.amount) end
    return n(gp)
end

--- WHAT TO DRAW FOR THIS GAME. One answer, for the board and the game-over
--- screen both, so the two cannot disagree about whether coins are in play.
---
--- Returns:
---   championship  is this a rung of the global ladder at all
---   watermark     the vertical text to sit on the board, or nil
---   pot           nil, or { amount, x, y, grand }
---                 grand = true means it is the grand prize and may fly to
---                 the winner at the end; a stake pot does that anyway.
function M.plan(state, user_data)
    state = type(state) == "table" and state or {}
    local stake = type(state.stake) == "table" and n(state.stake.amount) or 0

    local tid = tostring(state.tournamentId or "")
    local entry = M.entry(tid, user_data)
    local is_champ = false
    if tid ~= "" then
        is_champ = championship.matches(entry or { _id = tid }, user_data)
    end

    if not is_champ then
        -- Unchanged: the stake pot, in the centre, for everything else. A
        -- zero-stake game (an AI trial, a free match) still gets nothing —
        -- a "0 coins" bundle sitting there all game says less than no bundle.
        return {
            championship = false,
            watermark = nil,
            pot = stake > 0
                and { amount = stake * 2, x = M.POT_X, y = M.POT_Y_CENTRE, grand = false }
                or nil,
        }
    end

    if not M.at_final(entry) then
        return { championship = true, watermark = M.WATERMARK_TEXT, pot = nil }
    end

    local prize = M.grand_prize(entry)
    if prize <= 0 then
        -- A final whose prize we cannot read. The watermark still stands; an
        -- invented figure about money would not.
        return { championship = true, watermark = M.WATERMARK_TEXT, pot = nil }
    end

    return {
        championship = true,
        watermark = M.WATERMARK_TEXT,
        pot = { amount = prize, x = M.POT_X, y = M.POT_Y_MINE, grand = true },
    }
end

--- May coins fly at the end of this match?
--
-- The same rule stated for the game-over screen: only the grand prize moves.
function M.coins_may_settle(plan)
    if type(plan) ~= "table" then return true end
    if not plan.championship then return true end
    return plan.pot ~= nil and plan.pot.grand == true
end

return M
