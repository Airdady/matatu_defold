-- TWO POINTS PER GAME. IT WAS THREE.
--
--   Run: lua tools/test_battle_points.lua
--
--   best of 3   9 -> 6      best of 9   27 -> 18
--   best of 5  15 -> 10     best of 11  33 -> 22
--   best of 7  21 -> 14     best of 13  39 -> 26
--
-- WHY THE CLIENT NEEDS ITS OWN CHECK. This ladder is written out in three
-- places and nothing links them: be_matatu's PRIZE_CONFIG, a second private
-- copy inside its playerRewards.ts, and BATTLE_TIERS_BY_GAME here. The two
-- server-side copies check each other (battlePoints.test.ts); this file is the
-- only thing standing between the third and a silent disagreement.
--
-- And a disagreement here is the worst-shaped one: the client SHOWS a number
-- and the server PAYS a different one, so nothing errors, nothing logs, and it
-- surfaces weeks later as a player insisting they were shorted.
--
-- Asserted as a RULE — points == 2 x games — so a format added later is
-- covered without anybody remembering to come back here.
package.path = "./?.lua;" .. package.path

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

-- Parsed out of the source rather than required: online_right.lua pulls in the
-- websocket manager and the rest of the lobby, and none of that is needed to
-- read a table of numbers.
local src = slurp("modules/online_right.lua")
local block = src:match("local BATTLE_TIERS_BY_GAME = (%b{})")

print("")
print("THE TABLE IS THERE AND WAS ACTUALLY READ")
check("BATTLE_TIERS_BY_GAME was found", block ~= nil,
    "a rename would make every assertion below a vacuous pass")

local rows = {}
if block then
    for games, charge, points in block:gmatch("games = (%d+), charge = (%d+),%s*points = (%d+)") do
        rows[#rows + 1] = { games = tonumber(games), charge = tonumber(charge), points = tonumber(points) }
    end
end
-- Three games x their formats. If this ever drops to a handful the pattern has
-- stopped matching and the file is not being checked any more.
check("and its rows were parsed (" .. #rows .. ")", #rows >= 9,
    "got " .. #rows .. " rows")

print("")
print("TWO POINTS PER GAME, EVERY ROW")
local bad = {}
for _, r in ipairs(rows) do
    if r.points ~= r.games * 2 then
        bad[#bad + 1] = string.format("best of %d pays %d", r.games, r.points)
    end
end
check("no row pays anything else", #bad == 0, table.concat(bad, ", "))

-- And the specific numbers, stated once so the intent is readable without
-- doing the arithmetic.
local by_games = {}
for _, r in ipairs(rows) do by_games[r.games] = r.points end
for games, want in pairs({ [3] = 6, [5] = 10, [7] = 14, [9] = 18 }) do
    check(string.format("best of %d pays %d", games, want),
        by_games[games] == want,
        "got " .. tostring(by_games[games]))
end

print("")
print("THE STAKE TIER DOES NOT CHANGE THE POINTS")
-- Points are a RANKING quantity earned by playing the format; the stake is
-- what decides the money. A best-of-3 at 500 and one at 2000 are the same
-- amount of playing, and the same in every game's currency.
local seen = {}
local inconsistent = {}
for _, r in ipairs(rows) do
    if seen[r.games] and seen[r.games] ~= r.points then
        inconsistent[#inconsistent + 1] =
            string.format("best of %d pays both %d and %d", r.games, seen[r.games], r.points)
    end
    seen[r.games] = r.points
end
check("one point value per format, across every tier and every game",
    #inconsistent == 0, table.concat(inconsistent, ", "))

print("")
print("AND NOTHING ELSE MOVED")
-- The edit was points-only, and the Kadi ladder has a `charge = 12` sitting
-- right beside a `points = 18`. A sweep over a table of numbers is exactly the
-- change that takes one column too many with it.
local charges = {}
for _, r in ipairs(rows) do charges[#charges + 1] = r.charge end
table.sort(charges)
check("the charges are still the ones that shipped",
    table.concat(charges, ",") == "4,4,4,7,7,9,12,40,40,40,65,65,75,75,75,90,115,125,125,175,225",
    "got " .. table.concat(charges, ","))

-- The stake ladder in config.lua is a DIFFERENT quantity — points per single
-- staked game, not per best-of — and was not in scope. Named here so nobody
-- reconciles the two by mistake.
local cfg = slurp("modules/config.lua")
check("the per-stake points ladder is untouched",
    cfg:find("points = 20, label = \"200\"") and cfg:find("points = 100, label = \"1000\""),
    "config.lua STAKE_LEVELS is per-stake, not per-format")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
