-- WHO IS SHOWN A CHAMPIONSHIP INVITE.
--
-- Reported more than once: everybody sees Global Championship game requests,
-- whether or not they are in the tournament. The fix is on the server — the
-- gate was sitting on handleGameRequest, which wsHandler never routes a
-- tournament request to, so it had never once run — and that is what protects
-- handsets already in the field.
--
-- This is the near side of the same rule. It earns its place for one reason:
-- accepting a championship invite costs the entry fee in real coins, so a
-- request that should never have arrived must not be one tap away from taking
-- somebody's money.
--
-- Two halves, both here:
--   1. the rule itself, in modules/championship.lua, under plain Lua
--   2. the socket path, through tools/defold_sim.lua, because a rule nothing
--      calls is exactly the failure being fixed on the server side
--
--   lua5.4 tools/test_championship_gate.lua        (run from repo root)
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;./?.lua;" .. package.path

local champ = require("modules.championship")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want)))
  end
end

local seven = { 1, 2, 3, 4, 5, 6, 7 }

-- The player's own list, as getUserTournaments builds it. `joined` is the
-- backend's own entryPaidAt.
local function user_data(joined, extra)
  local champ_entry = {
    _id = "champ-1", scope = "GLOBAL", name = "Global Championship",
    levels = seven, status = "active", joined = joined,
    userProgress = { currentLevel = 1, joined = joined },
  }
  for k, v in pairs(extra or {}) do champ_entry[k] = v end
  return { tournaments = { champ_entry, { _id = "battle-9", scope = "PRIVATE", levels = { 1 } } } }
end

-- The invite, in both shapes the server sends: the broadcast wraps the
-- tournament in `tournament`, the direct path puts a bare `tournamentId` on the
-- payload.
local broadcast = { requestId = "r1", gameType = "TOURNAMENT",
                    tournament = { _id = "champ-1", name = "Global Championship",
                                   stake = { amount = 450 }, matchFormat = 3 } }
local direct = { requestId = "r1", gameType = "TOURNAMENT", tournamentId = "champ-1" }
local battle = { requestId = "r2", gameType = "TOURNAMENT",
                 tournament = { _id = "battle-9", name = "Quick Battle", matchFormat = 3 } }

----------------------------------------------------------------------
-- 1. the rule
----------------------------------------------------------------------
print("── the rule ──")

check("a bystander's championship invite is dropped",
      champ.should_drop_request(broadcast, user_data(false)), true)
check("...in the bare-tournamentId shape too",
      champ.should_drop_request(direct, user_data(false)), true)
check("an entrant's is not",
      champ.should_drop_request(broadcast, user_data(true)), false)

-- Fails OPEN in every uncertain case. Swallowing invites a player wanted is a
-- worse bug than the one being fixed.
check("a battle invite is never dropped",
      champ.should_drop_request(battle, user_data(false)), false)
check("a tournament the player holds no record of is not dropped",
      champ.should_drop_request(
        { requestId = "r3", tournament = { _id = "somebody-elses-cup" } }, user_data(false)), false)
check("a request naming no tournament at all is not dropped",
      champ.should_drop_request({ requestId = "r4" }, user_data(false)), false)
check("with no user data at all, nothing is dropped",
      champ.should_drop_request(broadcast, nil), false)

-- An older backend sends no `joined` anywhere. Refusing on a field that is
-- simply absent would blank every championship invite on that build.
local legacy = { tournaments = { { _id = "champ-1", scope = "GLOBAL", levels = seven } } }
check("an absent joined flag means 'older server', not 'bystander'",
      champ.should_drop_request(broadcast, legacy), false)

-- entryPaidAt is the field `joined` is derived from; either is proof.
local paid_only = { tournaments = { { _id = "champ-1", scope = "GLOBAL", levels = seven,
                                      userProgress = { entryPaidAt = "2026-08-01T00:00:00Z" } } } }
check("entryPaidAt alone reads as joined",
      champ.should_drop_request(broadcast, paid_only), false)

-- The content-blind payload the deployed server still sends: no scope, no
-- levels. Recognised by id against the player's own list — the same reason
-- champ.matches exists.
check("a content-blind payload is still recognised by id",
      champ.should_drop_request(
        { requestId = "r5", tournament = { _id = "champ-1", name = "Season Ladder" } },
        user_data(false)), true)

check("joined() reads the top-level flag", champ.joined({ joined = true }), true)
check("joined() falls back to userProgress",
      champ.joined({ userProgress = { joined = true } }), true)
check("joined() is false for a record that says nothing", champ.joined({}), false)
check("joined() is false for no record at all", champ.joined(nil), false)

----------------------------------------------------------------------
-- 2. the socket path
----------------------------------------------------------------------
-- A rule nothing calls is precisely the failure this whole change is about, so
-- the guard is also driven through the real websocket manager.
print("\n── the socket path ──")

local SIM = dofile(here .. "/defold_sim.lua")
local ws = require("modules.websocket_manager")

SIM.add_recorder("controller")

-- Every surface that draws an invite — online.gui_script's inline banner,
-- incoming.gui_script's global overlay — is driven by this one event, so
-- counting it counts what the player would have been shown.
local shown = {}
ws.on("game_request", function(_, _, request_id) shown[#shown + 1] = request_id end)

SIM.with_ctx("controller", function()
  ws.identify("p1", "Me", { amount = 5000, charge = 0 }, "UG")
  ws.connect()
end)
SIM.pump(0.5)

local function identify_as(joined)
  SIM.server_send({ type = "IDENTIFY", data = {
    _id = "p1", username = "Me", balance = 5000, tournaments = user_data(joined).tournaments,
  } })
  SIM.pump(0.2)
end

local function send_request(payload)
  SIM.server_send({ type = "GAME_REQUEST", data = payload })
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

identify_as(false)
send_request(broadcast)
check("a bystander is never shown the invite", #shown, 0)
check("...and it is declined, freeing the requester's search", declines_for("r1"), 1)

send_request(battle)
check("an ordinary battle invite still comes through", shown[1], "r2")

shown = {}
identify_as(true)
send_request(broadcast)
check("an entrant is shown it", shown[1], "r1")

----------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
