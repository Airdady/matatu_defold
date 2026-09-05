-- WHO IS AT THE TOP OF THE ONLINE LIST.
--
--   Run: lua5.4 tools/test_player_sort.lua
--
-- Three keys, in this order:
--
--   1. SKILL     my own tier first, then the neighbouring tier, then further
--                out. A viewer with no known tier ties every row on this, and
--                the whole order collapses to key 2 — which is what the three
--                stake cases below are, and why they are unchanged.
--
--   2. ACTIVITY  within a tier:
--
--        stake 200 selected   200s first, then other stakes, then free, then
--                             those already playing
--        stake 500 selected   500s first, then other stakes, then free, then
--                             playing
--        cannot afford any    free first, then other stakes, then playing
--
-- The third is the same ladder read around a pivot of ZERO, which is why there
-- is one ordering in modules/player_sort.lua rather than two: the broke case is
-- a value, not a branch, and a branch is what would have drifted.
--
--   3. FREE      and this one sits ABOVE the tier, not inside it. A free game
--                wins nothing, so for a player who has chosen a stake it is
--                not a worse match but a different activity, and it belongs
--                under everybody they could play for coins however well
--                matched. Free was already last WITHIN a tier (key 2 puts it
--                on rung 3), but a well-matched free row still outranked a
--                paid row one tier out, so free players surfaced wherever the
--                tiers happened to fall.
--
--                Off for the broke case above, where free is the only game
--                there is — the pivot says so, so this needs no branch either.
--
-- Runs under plain Lua with no simulator — player_sort requires nothing,
-- deliberately, so "which player should be at the top" can be proven without
-- booting a screen.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local ps = require("modules.player_sort")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

-- Matatu's ladder. The cheapest paid rung costs 200 + 20.
local LEVELS = {
  { amount = 0,    charge = 0,   label = "Free" },
  { amount = 200,  charge = 20,  label = "200" },
  { amount = 500,  charge = 50,  label = "500" },
  { amount = 1000, charge = 100, label = "1000" },
  { amount = 2000, charge = 100, label = "2000" },
}

local function p(name, amount, playing)
  return { _id = name, username = name, stake = { amount = amount },
           gameId = playing and "g1" or nil }
end

local function names(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.username end
  return table.concat(out, ",")
end

-- One of everything, in an order that is wrong for every case below.
local function lobby()
  return {
    p("playing200", 200, true),
    p("free_a", 0),
    p("k1000", 1000),
    p("s200_a", 200),
    p("playing_free", 0, true),
    p("s500_a", 500),
    p("free_b", 0),
    p("s200_b", 200),
  }
end

----------------------------------------------------------------------
print("── stake 200 selected ──")
----------------------------------------------------------------------
local rows = lobby()
ps.sort(rows, { selected_stake = { amount = 200 }, balance = 5000, levels = LEVELS })
check("200s, then other stakes, then free, then playing",
      names(rows),
      "s200_a,s200_b,k1000,s500_a,free_a,free_b,playing200,playing_free")

----------------------------------------------------------------------
print("\n── stake 500 selected ──")
----------------------------------------------------------------------
rows = lobby()
ps.sort(rows, { selected_stake = { amount = 500 }, balance = 5000, levels = LEVELS })
check("500s first, and 200s drop into the other-stakes group",
      names(rows),
      "s500_a,k1000,s200_a,s200_b,free_a,free_b,playing200,playing_free")

----------------------------------------------------------------------
print("\n── cannot afford any stake ──")
----------------------------------------------------------------------
-- 199 cannot cover 200 + 20, the cheapest paid rung. The selected stake is
-- still 500 — what the player picked is not what they can pay for.
rows = lobby()
ps.sort(rows, { selected_stake = { amount = 500 }, balance = 199, levels = LEVELS })
check("free first, then other stakes, then playing",
      names(rows),
      "free_a,free_b,k1000,s200_a,s500_a,s200_b,playing200,playing_free")

check("199 cannot afford anything", ps.can_afford_any(199, LEVELS), false)
check("...220 exactly can, at the bottom rung", ps.can_afford_any(220, LEVELS), true)
check("...219 cannot — the charge counts", ps.can_afford_any(219, LEVELS), false)
check("a free tier is not something to afford", ps.can_afford_any(0, LEVELS), false)
check("...and with no ladder at all we do not claim poverty",
      ps.can_afford_any(0, nil), true)

check("the pivot falls to zero when broke", ps.pivot_stake({ amount = 500 }, 10, LEVELS), 0)
check("...and is the selection when not", ps.pivot_stake({ amount = 500 }, 5000, LEVELS), 500)
check("a bare number is accepted as a selection", ps.pivot_stake(200, 5000, LEVELS), 200)

----------------------------------------------------------------------
print("\n── the rungs themselves ──")
----------------------------------------------------------------------
check("my stake is rung 1", ps.rank(p("x", 200), 200), 1)
check("another stake is rung 2", ps.rank(p("x", 500), 200), 2)
check("free is rung 3", ps.rank(p("x", 0), 200), 3)
check("playing is rung 4 whatever its stake", ps.rank(p("x", 200, true), 200), 4)
check("...even free and playing", ps.rank(p("x", 0, true), 200), 4)

-- With the pivot at zero, free IS my stake — so it takes rung 1 and rung 3
-- empties. That is the whole reason the broke case needs no branch.
check("at pivot zero, free is rung 1", ps.rank(p("x", 0), 0), 1)
check("...and everything paid is rung 2", ps.rank(p("x", 200), 0), 2)

----------------------------------------------------------------------
print("\n── it does not scramble what it does not order ──")
----------------------------------------------------------------------
-- The list is redrawn about once a second. A sort that reorders equals
-- differently each time is a list that jumps under a moving thumb, so rows
-- sharing a rung keep the order the server sent them in.
rows = {}
for i = 1, 12 do rows[#rows+1] = p("same" .. i, 200) end
ps.sort(rows, { selected_stake = { amount = 200 }, balance = 5000, levels = LEVELS })
local stable = true
for i = 1, 12 do if rows[i].username ~= ("same" .. i) then stable = false end end
check("equal rows keep their arrival order", stable, true)

-- The Battles tab puts the SAME player table on the list more than once, one
-- row per battle type they host. Anything keyed by row identity collapses
-- those into one position.
local shared = { _id = "host", username = "host", stake = { amount = 0 } }
local a = { _id = "host", username = "hostA", myBattle = { stake = { amount = 500 } } }
local b = { _id = "host", username = "hostB", myBattle = { stake = { amount = 500 } } }
rows = { a, b, p("s200", 200) }
ps.sort(rows, { selected_stake = { amount = 500 }, balance = 5000, levels = LEVELS })
check("duplicate hosts both survive the sort", names(rows), "hostA,hostB,s200")
check("...and the shared table is untouched", shared.username, "host")

----------------------------------------------------------------------
print("\n── reading a row's stake ──")
----------------------------------------------------------------------
check("a quick-play row reads its own stake", ps.row_stake(p("x", 200)), 200)
check("a battles row reads the BATTLE's stake",
      ps.row_stake({ myBattle = { stake = { amount = 1000 } } }), 1000)
check("...falling back to the flat spelling",
      ps.row_stake({ myBattle = { stakeAmount = 300 } }), 300)
check("a missing stake is free, not nil", ps.row_stake({}), 0)
check("and junk does not throw", ps.row_stake(nil), 0)

check("playing is read the same way the row renderer reads it",
      ps.is_playing({ gameId = "g1" }), true)
check("...an empty id is not playing", ps.is_playing({ gameId = "" }), false)
check("...nor is a missing one", ps.is_playing({}), false)

----------------------------------------------------------------------
print("\n── nothing to sort ──")
----------------------------------------------------------------------
check("an empty list is fine", #ps.sort({}, {}), 0)
check("no options at all is fine", #ps.sort({ p("x", 200) }, nil), 1)
check("a non-list is returned untouched", ps.sort(nil, {}), nil)

----------------------------------------------------------------------
-- WITHIN A RUNG, THE CLOSEST TIER FIRST
----------------------------------------------------------------------
-- The tier is a TIEBREAK, never an override: being able to play someone at
-- all beats playing someone well matched. Everything below shares one rung so
-- the tier is the only thing left to decide, except where the rung is checked
-- against it explicitly.
local function trow(name, tier, stake, playing)
  return { username = name, skillTier = tier,
           stake = { amount = stake or 200 },
           -- is_playing reads gameId, the same field online_center checks
           -- before it attaches a challenge button.
           gameId = playing and "g1" or nil }
end
local function tnames(rows)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = r.username end
  return table.concat(out, ",")
end

local topts = { selected_stake = 200, balance = 10000,
                levels = { { amount = 0 }, { amount = 200 } }, my_tier = "PRO" }

check("my own tier comes first",
  tnames(ps.sort({ trow("gm", "GRANDMASTER"), trow("pro", "PRO") }, topts)), "pro,gm")

-- PRO(0), then BEGINNER and MASTER both one step away — arrival order decides
-- between them — then GRANDMASTER at two.
check("then the immediate neighbour, in either direction",
  tnames(ps.sort({
    trow("gm", "GRANDMASTER"), trow("am", "BEGINNER"),
    trow("ma", "MASTER"), trow("pro", "PRO"),
  }, topts)), "pro,am,ma,gm")

check("a row with no tier falls to the BACK of its rung, not the front",
  tnames(ps.sort({ trow("none", nil), trow("pro", "PRO") }, topts)), "pro,none")

-- SKILL OUTRANKS ACTIVITY. These two used to assert the opposite, and the
-- swap is the point: activity as the rung meant the top of the list was
-- whoever happened to be at my stake, at any tier at all — a BEGINNER's first
-- screen could be four GRANDMASTERS.
check("a matching tier beats a matching stake",
  tnames(ps.sort({ trow("pro_other", "PRO", 500), trow("am_mine", "BEGINNER", 200) }, topts)),
  "pro_other,am_mine")

check("and it beats a free playable stranger too",
  tnames(ps.sort({ trow("am_free", "BEGINNER", 0), trow("pro_paid", "PRO", 500) }, topts)),
  "pro_paid,am_free")

-- BUT THE SWAP APPLIES ONLY WITHIN THE PLAYABLE SET. A row nobody can tap —
-- online_center attaches no challenge button to a playing row — cannot be
-- lifted by a good tier match. The backend says the same thing first
-- (broadcastOnlineUsers opens its comparator with busyA - busyB); this side
-- agrees with it rather than re-deciding it.
check("a perfect tier match who is mid-game still sits below a playable stranger",
  tnames(ps.sort({ trow("pro_busy", "PRO", 200, true), trow("am_free", "BEGINNER", 200) }, topts)),
  "am_free,pro_busy")

check("and no stake makes a playing row playable either",
  tnames(ps.sort({ trow("pro_mine", "PRO", 200, true), trow("am_free", "BEGINNER", 0) }, topts)),
  "am_free,pro_mine")

-- WITHIN A TIER, THE ACTIVITY ORDER IS THE ONE ASKED FOR: an active stake
-- (mine ahead of the rest), then free, then playing.
check("inside one tier: my stake, other stakes, free, playing",
  tnames(ps.sort({
    trow("p_playing", "PRO", 200, true), trow("p_free", "PRO", 0),
    trow("p_other", "PRO", 500),         trow("p_mine", "PRO", 200),
  }, topts)), "p_mine,p_other,p_free,p_playing")

-- The paid rows come first in tier order, then the free ones in tier order,
-- then playing. pro_free used to lead this list on its perfect tier match;
-- it now sits under the BEGINNER who is actually playing for coins.
check("and that order repeats in the next tier out, with every playing row under both",
  tnames(ps.sort({
    trow("am_mine", "BEGINNER", 200), trow("pro_playing", "PRO", 200, true),
    trow("am_free", "BEGINNER", 0),   trow("pro_free", "PRO", 0),
  }, topts)), "am_mine,pro_free,am_free,pro_playing")

----------------------------------------------------------------------
print("\n── free players go to the bottom, whatever their tier ──")
----------------------------------------------------------------------
-- A free game wins nothing, so it is not a worse MATCH — it is a different
-- activity, and it belongs under everybody the viewer could play for coins.
check("a perfect tier match on free sits under a paid stranger",
  tnames(ps.sort({ trow("pro_free", "PRO", 0), trow("gm_paid", "GRANDMASTER", 500) }, topts)),
  "gm_paid,pro_free")

check("...and under a paid row at the far end of the ladder",
  tnames(ps.sort({ trow("pro_free", "PRO", 0), trow("am_paid", "BEGINNER", 1000) }, topts)),
  "am_paid,pro_free")

check("every free row sinks, not just the well-matched one",
  tnames(ps.sort({
    trow("pro_free", "PRO", 0),  trow("gm_paid", "GRANDMASTER", 500),
    trow("am_free", "BEGINNER", 0), trow("pro_paid", "PRO", 200),
  }, topts)), "pro_paid,gm_paid,pro_free,am_free")

check("...and the tier still orders them among themselves",
  tnames(ps.sort({
    trow("gm_free", "GRANDMASTER", 0), trow("pro_free", "PRO", 0),
    trow("ma_free", "MASTER", 0),
  }, topts)), "pro_free,ma_free,gm_free")

-- BUT NEVER BELOW A ROW NOBODY CAN TAP. Free is still a game that can be
-- started; a player mid-game is not.
check("free still beats playing", 
  tnames(ps.sort({ trow("pro_busy", "PRO", 200, true), trow("am_free", "BEGINNER", 0) }, topts)),
  "am_free,pro_busy")

-- AND NOT AT ALL WHEN FREE IS THE ONLY GAME THERE IS. The pivot is zero for a
-- player who cannot afford any paid stake, and sinking free rows there would
-- bury every game they can start.
local broke = { selected_stake = 200, balance = 0,
                levels = { { amount = 0 }, { amount = 200, charge = 20 } }, my_tier = "PRO" }
-- Same tier on both sides, because skill outranks activity and always has —
-- what is being shown here is that free is not pushed DOWN, which is the only
-- thing this rule changes.
check("a player who can afford nothing still gets free first",
  tnames(ps.sort({ trow("pro_paid", "PRO", 200), trow("pro_free", "PRO", 0) }, broke)),
  "pro_free,pro_paid")
check("the rule is off entirely at a zero pivot",
  ps.is_free_row(trow("x", "PRO", 0), 0), false)
check("...and on for a player with a stake to play for",
  ps.is_free_row(trow("x", "PRO", 0), 200), true)
check("a paid row is never a free row", ps.is_free_row(trow("x", "PRO", 500), 200), false)

-- The whole rule in one list: everybody playable, in tier-then-activity
-- order, and then every playing row after them regardless of tier or stake.
check("playing rows form the tail, whatever their tier and stake",
  tnames(ps.sort({
    trow("gm_busy", "GRANDMASTER", 200, true), trow("pro_busy", "PRO", 200, true),
    trow("am_free", "BEGINNER", 0),            trow("pro_mine", "PRO", 200),
  }, topts)), "pro_mine,am_free,pro_busy,gm_busy")

-- A SERVER THAT DOES NOT SEND THE FIELD MUST CHANGE NOTHING. This is the old
-- behaviour exactly, and it is what an un-deployed backend gets.
local no_tier = { selected_stake = 200, balance = 10000,
                  levels = { { amount = 0 }, { amount = 200 } } }
check("without my_tier the order is arrival order",
  tnames(ps.sort({ trow("b", "GRANDMASTER"), trow("a", "PRO") }, no_tier)), "b,a")

check("an unknown tier name reads as no index", ps.tier_index(trow("x", "WIZARD")), nil)
check("distance is symmetric across the ladder",
  ps.tier_gap(trow("x", "BEGINNER"), 4), ps.tier_gap(trow("y", "GRANDMASTER"), 1))

----------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
