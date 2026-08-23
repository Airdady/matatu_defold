----------------------------------------------------------------------
-- test_championship_gate.lua
-- Headless check of the client-side championship membership gate in
-- modules/websocket_manager.lua, driven through the real websocket path with
-- tools/defold_sim.lua.
--
--   lua5.4 tools/test_championship_gate.lua        (run from repo root)
--
-- WHAT IS BEING PINNED
--
-- Reported: "all users are able to see tournament requests even when they are
-- not subscribed." The cause is on the server — every account is handed a
-- Global Championship progress row at sign-in so the tournament map has a
-- bracket to draw, and matchmaking read that placeholder as membership. Fixed
-- there (be_matatu handlers/tournaments/membership.ts), which is what protects
-- handsets running older builds.
--
-- This is the near side of the same rule. It earns its place because accepting
-- a championship invite COSTS the level's entry in real coins: a request that
-- should never have arrived must not be one tap away from taking somebody's
-- money. So the gate is checked from both directions here — a bystander is
-- never shown the invite, and an entrant always is.
--
-- Asserts:
--   A. a championship request to a player who has NOT joined is dropped
--   B. …and declined, so the requester's search is freed immediately
--   C. a championship request to a player who HAS joined comes through
--   D. an entrant part-way up the ladder with no `joined` flag comes through
--   E. an ordinary battle request is untouched — freelancing still works
----------------------------------------------------------------------

-- repo-root relative module resolution (matches Defold's require paths)
package.path = "./?.lua;" .. package.path

local SIM = dofile("tools/defold_sim.lua")
local ws = require("modules.websocket_manager")

local MY       = "p1"
local CHAMP_ID = "champ_1"
local BATTLE_ID = "battle_1"

local seven_levels = {}
for i = 1, 7 do seven_levels[i] = { name = "Level " .. i, coins = 0, points = 0 } end

-- The record the client holds for a tournament, as it arrives on IDENTIFY.
local function champ_entry(user_progress)
  return {
    _id = CHAMP_ID,
    name = "Global Championship",
    scope = "GLOBAL",
    levels = seven_levels,
    status = "active",
    joined = user_progress and user_progress.joined or false,
    userProgress = user_progress or { currentLevel = 1, levels = {}, opponentsPlayed = {}, joined = false },
  }
end

local function battle_entry()
  return {
    _id = BATTLE_ID,
    name = "Battle",
    scope = "STANDARD",
    levels = { { name = "Level 1", coins = 0, points = 0 } },
    status = "active",
    joined = false,
  }
end

-- The invite the server broadcasts for a tournament match.
local function game_request(request_id, tournament_id, scope, levels)
  return {
    type = "GAME_REQUEST",
    data = {
      requestId = request_id,
      sender = { _id = "p2", username = "Rival", avatar = 3 },
      tournament = {
        _id = tournament_id,
        name = "Whatever",
        stake = { amount = 100, charge = 20 },
        matchFormat = 3,
        scope = scope,
        levels = levels,
      },
      gameType = "TOURNAMENT",
      timestamp = 0,
      broadcastId = "b1",
    },
  }
end

local function identify_with(tournaments)
  SIM.server_send({
    type = "IDENTIFY",
    data = { _id = MY, username = "Me", balance = 5000, tournaments = tournaments },
  })
  SIM.pump(0.2)
end

local function declines_for(request_id)
  local n = 0
  for _, o in ipairs(SIM.outbound) do
    if o.type == "GAME_REQUEST_DECLINED" and o.data and o.data.requestId == request_id then
      n = n + 1
    end
  end
  return n
end

----------------------------------------------------------------------
-- harness
----------------------------------------------------------------------
local results = {}
local function check(label, cond, detail)
  results[#results + 1] = { label = label, ok = cond and true or false }
  print(string.format("%s  %s%s", cond and "PASS" or "FAIL", label,
    (detail and detail ~= "") and ("  [" .. detail .. "]") or ""))
end

SIM.add_recorder("controller")

-- Everything the guard protects sits behind this one event: the surfaces that
-- draw an invite (online.gui_script's inline banner, incoming.gui_script's
-- global overlay) are all driven by it, so counting it counts what the player
-- would have been shown.
local shown = {}
ws.on("game_request", function(_, _, request_id) shown[#shown + 1] = request_id end)

SIM.with_ctx("controller", function()
  ws.identify(MY, "Me", { amount = 5000, charge = 0 }, "UG")
  ws.connect()
end)
SIM.pump(0.5)

----------------------------------------------------------------------
-- A + B. the bystander: signed in, never entered
----------------------------------------------------------------------
identify_with({ champ_entry(), battle_entry() })

SIM.server_send(game_request("r1", CHAMP_ID, "GLOBAL", seven_levels))
SIM.pump(0.2)

check("A. championship invite is not shown to a player who never joined",
  #shown == 0, "shown=" .. #shown)
check("B. …and is declined, so the requester's search is freed",
  declines_for("r1") == 1)

----------------------------------------------------------------------
-- E. the battle, from the same not-joined state
----------------------------------------------------------------------
SIM.server_send(game_request("r2", BATTLE_ID, "STANDARD", { { name = "Level 1" } }))
SIM.pump(0.2)
check("E. an ordinary battle invite still comes through",
  #shown == 1 and shown[1] == "r2", "shown=" .. #shown)

----------------------------------------------------------------------
-- C. the entrant
----------------------------------------------------------------------
shown = {}
identify_with({
  champ_entry({ currentLevel = 1, levels = {}, opponentsPlayed = {}, joined = true }),
})
SIM.server_send(game_request("r3", CHAMP_ID, "GLOBAL", seven_levels))
SIM.pump(0.2)
check("C. championship invite reaches a player who joined",
  #shown == 1 and shown[1] == "r3", "shown=" .. #shown)

----------------------------------------------------------------------
-- D. the veteran, on a payload with no flag on it at all
----------------------------------------------------------------------
shown = {}
identify_with({
  -- No `joined` anywhere: an older server, or a row written before the field
  -- existed. This player is four rungs up the ladder and must not be cut off
  -- from their own championship by a guard meant for bystanders.
  {
    _id = CHAMP_ID,
    name = "Global Championship",
    scope = "GLOBAL",
    levels = seven_levels,
    status = "active",
    userProgress = { currentLevel = 4, levels = { { level = 1 }, { level = 2 } }, opponentsPlayed = { "x" } },
  },
})
SIM.server_send(game_request("r4", CHAMP_ID, "GLOBAL", seven_levels))
SIM.pump(0.2)
check("D. a player climbing the ladder still receives it, flag or no flag",
  #shown == 1 and shown[1] == "r4", "shown=" .. #shown)

----------------------------------------------------------------------
local failed = 0
for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end
print(string.format("\n%d/%d checks passed", #results - failed, #results))
os.exit(failed == 0 and 0 or 1)
