-- WHO IS WORTH SHOWING FIRST IN THE ONLINE LIST.
--
-- The list was in whatever order the server sent it, which meant the players a
-- person could actually play right now were scattered through it — and the ones
-- they definitely could not, because those players are already mid-game, were
-- just as likely to be at the top.
--
-- A ROW NOBODY CAN TAP IS NOT A CANDIDATE. IT GOES LAST.
--
--   0. PLAYING            already mid-game. online_center attaches no
--                         challenge button to these rows, so nothing about
--                         them — not their tier, not their stake — can make
--                         them worth being above someone you could actually
--                         play. Below everybody, whatever else is true.
--
-- THE BACKEND IS THE AUTHORITY ON THIS, and has been: broadcastOnlineUsers'
-- comparator opens with `busyA - busyB`, before rank, before anything. This
-- side has to AGREE with it rather than re-decide it — the client sorts the
-- list it is handed, so it is the last writer, and a client that put playing
-- rows anywhere else would silently overrule a rule the server had already
-- applied correctly. That is exactly what happened when the tier gap was
-- hoisted above it and a well-matched player mid-game floated to the top.
--
-- SKILL FIRST. ACTIVITY SECOND. Among everyone who is actually playable:
--
--   1. HOW WELL MATCHED   players of my own SKILL TIER first, then the
--                         immediate neighbouring tier, then further out — the
--                         same ladder the rank badge already draws on the row
--                         (BEGINNER, PRO, MASTER, GRANDMASTER), so what a
--                         player sees and what the list sorts by are one fact.
--
--   2. WHAT THEY ARE DOING, within a tier:
--
--        MY STAKE      the tap that works. Someone sitting at the same stake I
--                      have selected can be challenged with no further steps.
--        OTHER STAKES  playable, but I have to change my stake first.
--        FREE          playable by anyone, always — but it wins nothing, so it
--                      is the last thing a paying player wants offered.
--        PLAYING       not playable at all. The row is not even tappable (see
--                      online_center: no challenge button on a playing row), so
--                      it goes last within its tier.
--
-- THESE TWO USED TO BE THE OTHER WAY ROUND, and the change is deliberate.
-- Activity was the rung and skill was only the tiebreak inside it, so the top
-- of the list was whoever happened to be sitting at my stake — at any tier at
-- all. A BEGINNER's first screen could be four GRANDMASTERS, which is a
-- matchmaking answer nobody asked for and the fastest way to lose a new
-- player.
--
-- The swap applies only WITHIN the playable set. A mid-game player was never
-- meant to rise with it, and briefly did; rung 0 above is what holds them
-- down.
--
-- The tier is SENT, not computed here. broadcastOnlineUsers attaches
-- `skillTier` to every row (be_matatu's services/playerTier.ts), because "my
-- own tier first" is viewer-relative and that list is built once for
-- everybody — so the ordering has to happen on this side, and the fact has to
-- come from that one.
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

--- Is this player mid-game — or seated at a party table — and therefore not
--- challengeable?
--
-- Same test online_center uses to decide whether to attach a challenge button
-- at all. A row nobody can tap belongs at the bottom of the list.
--
-- `inParty` is the second reason and arrived later. The server refuses every
-- request to a seated player and retires the ones already in flight
-- (retireRequestsForSeat in be_matatu's party.ts), so they are exactly as
-- unreachable as somebody mid-game — but the row read as available, and the
-- only way to find that out was to tap CHALLENGE and be told no.
function M.is_playing(pu)
    if type(pu) ~= "table" then return false end
    if pu.inParty then return true end
    return pu.gameId ~= nil and pu.gameId ~= ""
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
-- THE SKILL LADDER, weakest to strongest. Index is ladder position, which is
-- what makes "one tier away" a subtraction. Mirrors be_matatu's SKILL_TIERS
-- and modules/rank_badge.lua's own bands — if this changes, all three change.
M.TIERS = { "BEGINNER", "PRO", "MASTER", "GRANDMASTER" }

local TIER_INDEX = {}
for i, t in ipairs(M.TIERS) do TIER_INDEX[t] = i end

-- The floor was AMATEUR before the rename, and the tier arrives from the
-- SERVER — so a client on the new build can still be handed the old word by a
-- server that has not been deployed yet, or by an account the boot migration
-- has not swept. Unknown tiers sort to the back of their rung, which would put
-- every such player behind everybody for as long as the two ends disagree.
-- One line here costs nothing and makes the rollout order not matter.
TIER_INDEX.AMATEUR = TIER_INDEX.BEGINNER

--- Where a row's tier sits on the ladder, or nil when it has none.
--
-- nil rather than a default: a server that does not send skillTier yet, or an
-- AI row that has no record, must not be treated as BEGINNER and dragged to one
-- end of every rung. Unknown sorts LAST within its rung and nothing else
-- changes — which is exactly how this behaved before the field existed.
function M.tier_index(pu)
    if type(pu) ~= "table" then return nil end
    local t = pu.skillTier or pu.skill_tier
    if type(t) ~= "string" then return nil end
    return TIER_INDEX[t:upper()]
end

--- How far a row is from `mine` on the ladder. Lower is a better match.
--
-- Returns a number ABOVE any real distance when either side is unknown, so an
-- unplaceable row falls to the back of its rung rather than to the front.
function M.tier_gap(pu, mine)
    local theirs = M.tier_index(pu)
    if not theirs or not mine then return #M.TIERS end
    return math.abs(theirs - mine)
end

--- What this row is DOING. Lower sorts first, within a tier.
--
-- Unchanged from when this was the primary key — the four values already say
-- "an active stake, then free, then playing", with the stake I have selected
-- ahead of the rest of the active ones.
function M.rank(pu, pivot)
    if M.is_playing(pu) then return 4 end
    local s = M.row_stake(pu)
    if s == pivot then return 1 end
    if s > 0 then return 2 end
    return 3
end

--- Order a list of rows in place, and return it.
--
-- `opts = { selected_stake, balance, levels, my_tier }`.
--
-- `my_tier` is the VIEWER's own skillTier. Omit it and the tier tiebreak is
-- skipped entirely and the order is exactly what it was before — which is what
-- a client talking to a server that does not send the field yet will get.
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
    local mine = TIER_INDEX[tostring(opts.my_tier or ""):upper()]

    local decorated = {}
    for i, pu in ipairs(rows) do
        decorated[i] = {
            pu = pu, i = i,
            -- Sorted on before anything else. Kept as its own key rather than
            -- folded into the rung because the rung is compared AFTER the tier
            -- gap, and a playing row must not be reachable by a good tier
            -- match.
            b = M.is_playing(pu) and 1 or 0,
            r = M.rank(pu, pivot),
            -- 0 when the viewer's tier is unknown, so every row ties on it and
            -- the arrival index decides — the old behaviour, exactly.
            g = mine and M.tier_gap(pu, mine) or 0,
        }
    end

    -- Playing last, unconditionally. Then, among the playable, tier gap before
    -- activity. With `g` at 0 for everybody — which is what an unknown viewer
    -- tier gives — the order collapses back to what it was before the tier key
    -- existed, so a client talking to a server that does not send skillTier
    -- yet is unaffected.
    table.sort(decorated, function(a, b)
        if a.b ~= b.b then return a.b < b.b end
        if a.g ~= b.g then return a.g < b.g end
        if a.r ~= b.r then return a.r < b.r end
        return a.i < b.i
    end)

    for i, d in ipairs(decorated) do rows[i] = d.pu end
    return rows
end

return M
