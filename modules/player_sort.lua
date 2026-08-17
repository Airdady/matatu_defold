-- WHO IS WORTH SHOWING FIRST IN THE ONLINE LIST.
--
-- The list was in whatever order the server sent it, which meant the players a
-- person could actually play right now were scattered through it — and the ones
-- they definitely could not, because those players are already mid-game, were
-- just as likely to be at the top.
--
-- The order asked for, and the reasoning behind each rung:
--
--   1. MY STAKE        the tap that works. Someone sitting at the same stake I
--                      have selected can be challenged with no further steps.
--   2. OTHER STAKES    playable, but I have to change my stake first.
--   3. FREE            playable by anyone, always — but it wins nothing, so it
--                      is the last thing a paying player wants offered.
--   4. PLAYING         not playable at all. The row is not even tappable (see
--                      online_center: no challenge button on a playing row), so
--                      it belongs at the bottom whatever its stake.
--
-- AND THE THIRD RULE FALLS OUT OF THE FIRST TWO.
--
-- "When the player cannot afford any stake, show free players first, then other
-- stakes, then playing." That is the same ladder with my stake read as ZERO —
-- free becomes rung 1, everything paid becomes rung 2, and rung 3 empties
-- because free is no longer in it. So there is one ordering here rather than
-- two, and the broke case is a value rather than a branch: it is the case that
-- would otherwise be written twice and drift.
--
-- Pure and separate from online_center for the same reason reshuffle_queue is
-- separate from game_flow: that file needs the Defold engine to load, and
-- "which player should be at the top" is a claim worth being able to prove.

local M = {}

local function num(v)
    local n = tonumber(v)
    return (n and n > 0) and n or 0
end

--- The stake a row is offering, whichever kind of row it is.
--
-- A Battles row carries its own stake on `myBattle`; a Quick Play row carries
-- the player's selected stake on `stake`. Read the same way the renderer picks
-- what to PRINT on the row, so the list cannot be sorted by one number and
-- labelled with another.
function M.row_stake(pu)
    if type(pu) ~= "table" then return 0 end
    local mb = pu.myBattle
    if type(mb) == "table" then
        local s = (type(mb.stake) == "table") and num(mb.stake.amount) or 0
        if s > 0 then return s end
        return num(mb.stakeAmount)
    end
    return (type(pu.stake) == "table") and num(pu.stake.amount) or 0
end

--- Is this player mid-game, and therefore not challengeable?
--
-- Same test online_center uses to decide whether to attach a challenge button
-- at all. A row nobody can tap belongs at the bottom of the list.
function M.is_playing(pu)
    return type(pu) == "table" and pu.gameId ~= nil and pu.gameId ~= ""
end

--- Can this balance cover ANY paid stake on the ladder?
--
-- A stake costs amount + charge, which is the figure online.gui_script's
-- can_afford checks before letting a challenge go out — so a player who fails
-- this cannot start a paid game by any route, and sorting paid players to the
-- top would be sorting by what they cannot do.
--
-- Free tiers are skipped: everybody can afford those, so counting them would
-- make this always true and the rule would never fire.
function M.can_afford_any(balance, levels)
    local bal = tonumber(balance) or 0
    if type(levels) ~= "table" then return true end
    for _, lvl in ipairs(levels) do
        local amount = tonumber(lvl and lvl.amount) or 0
        if amount > 0 then
            local cost = amount + (tonumber(lvl.charge) or 0)
            if bal >= cost then return true end
        end
    end
    return false
end

--- The stake the list should be ordered AROUND.
--
-- Normally the one the player has selected. Zero when they cannot afford any
-- paid stake at all, which is what turns the ladder into "free first" without a
-- second ordering existing anywhere.
function M.pivot_stake(selected, balance, levels)
    if not M.can_afford_any(balance, levels) then return 0 end
    return num(type(selected) == "table" and selected.amount or selected)
end

--- Which rung a row sits on. Lower sorts first.
function M.rank(pu, pivot)
    if M.is_playing(pu) then return 4 end
    local s = M.row_stake(pu)
    if s == pivot then return 1 end
    if s > 0 then return 2 end
    return 3
end

--- Order a list of rows in place, and return it.
--
-- `opts = { selected_stake, balance, levels }`.
--
-- STABLE, which table.sort is not: rows that share a rung keep the order the
-- server sent them in, so whatever the server already sorts by — rank,
-- recency — survives inside each group instead of being scrambled differently
-- on every rebuild. The list is redrawn about once a second, and a list that
-- reshuffles under a moving thumb is worse than one in no order at all.
function M.sort(rows, opts)
    if type(rows) ~= "table" then return rows end
    opts = opts or {}
    local pivot = M.pivot_stake(opts.selected_stake, opts.balance, opts.levels)

    -- Decorate with the arrival index, sort, undecorate. The index cannot be
    -- looked up from the row itself: the Battles tab puts the SAME player table
    -- on the list more than once (one row per battle type it hosts), so keying
    -- anything by row identity collapses those two into one position.
    local decorated = {}
    for i, pu in ipairs(rows) do
        decorated[i] = { pu = pu, i = i, r = M.rank(pu, pivot) }
    end

    table.sort(decorated, function(a, b)
        if a.r ~= b.r then return a.r < b.r end
        return a.i < b.i
    end)

    for i, d in ipairs(decorated) do rows[i] = d.pu end
    return rows
end

return M
