----------------------------------------------------------------------
-- test_tournament_flow.lua
-- Headless replay of the ONLINE TOURNAMENT sequence against the real
-- controller.script + game.script + modules, using tools/defold_sim.lua.
--
--   lua5.4 tools/test_tournament_flow.lua        (run from repo root)
--
-- Sequence mirrored from be_matatu:
--   IDENTIFY -> GAME_REQUEST_ACCEPTED(g1 ACTIVE) -> START(g1 STARTED)
--   -> MOVE (opponent) -> GAME_OVER (round, isMatchComplete=false)
--   -> GAME_REQUEST_ACCEPTED(g2 ACTIVE, auto-accepted continuation)
--   -> START(g2 STARTED)
--
-- Asserts:
--   A. scoreboard shown on the HUD for game 1 (tournament fields present)
--   B. board re-initialises for game 2 (screen_enter + PLAYER_READY g2)
--   C. scoreboard persists/updates (1-0) across the round transition
----------------------------------------------------------------------

-- repo-root relative module resolution (matches Defold's require paths)
package.path = "./?.lua;" .. package.path

-- api_service stub (controller requires it; only these entry points matter)
package.preload["modules.api_service"] = function()
  return {
    get_device_id = function() return "sim-device" end,
    set_auth_token = function() end,
    save_session = function() end,
    load_session = function() return nil end,
    device_login = function(cb) cb({ success = false }) end,
    send_otp = function(_, _, cb) cb({ success = false }) end,
    verify_otp = function(_, _, cb) cb({ success = false }) end,
    update_profile = function(_, _, cb) cb({ success = false }) end,
    purchase_theme = function(_, _, cb) cb({ success = false }) end,
    switch_theme = function(_, _, cb) cb({ success = false }) end,
    send_transaction = function(_, cb) cb({ success = false }) end,
  }
end

local SIM = dofile("tools/defold_sim.lua")
local ws = require("modules.websocket_manager")

-- GUI siblings as recorders; logic scripts are the real files.
for _, id in ipairs({ "lobby", "auth", "profile", "online", "themes",
                      "payments", "tournaments", "game", "suit_select", "gameover" }) do
  SIM.add_recorder(id)
end
SIM.load_script_component("controller", "main/controller.script")
SIM.load_script_component("game_logic", "main/game.script")
SIM.init_component("controller")
SIM.init_component("game_logic")
SIM.pump(0.2)

----------------------------------------------------------------------
-- backend-shaped payload builders (mirroring be_matatu initializeDeck)
----------------------------------------------------------------------
local MY, OPP, TOUR = "p1", "ai9", "tour_77"

local function mk_deck(n)
  local d = {}
  local suits = { "H", "S", "D", "C" }
  for i = 1, n do d[#d + 1] = { v = (i % 13) + 1, s = suits[(i % 4) + 1] } end
  return d
end

local function mk_state(gid, my_score, opp_score, status, level)
  return {
    gameId = gid,
    players = {
      [MY] = {
        id = MY, _id = MY, username = "Me", avatar = 1, balance = 5000,
        ready = false, isAI = false, status = "WAITING",
        stake = { amount = 1000, charge = 100 },
        hand = { {v=4,s="H"}, {v=5,s="S"}, {v=7,s="D"}, {v=10,s="C"},
                 {v=11,s="H"}, {v=12,s="S"}, {v=13,s="D"} },
      },
      [OPP] = {
        id = OPP, _id = OPP, username = "RoboKato", avatar = 2, balance = 99999,
        ready = true, isAI = true, status = "WAITING",
        stake = { amount = 1000, charge = 100 },
        hand = { {v=2,s="H"}, {v=3,s="S"}, {v=6,s="D"}, {v=8,s="C"},
                 {v=9,s="H"}, {v=4,s="S"}, {v=5,s="D"} },
      },
    },
    status = status or "ACTIVE",
    userId = MY,
    currentTurn = MY,
    gameType = "TOURNAMENT",
    tournamentId = TOUR,
    isTournamentContinuation = (my_score + opp_score) > 0,
    matchFormat = 3,
    tournamentScore = {
      currentLevel = level or 1, totalLevels = 7, matchFormat = 3,
      scores = { [MY] = my_score, [OPP] = opp_score },
    },
    cuttingCard = { v = 7, s = "H" },
    deck = mk_deck(30),
    playedCards = {},
    chosenSuit = nil,        -- JSON null decodes to absent
    currentCard = nil,
    stake = { amount = 1000, charge = 100, points = 100 },
    activePenaltyCount = 0,
    isBattle = false,
    actions = {},
    rules = "JOKERS",
    ready = {},
  }
end

local function hud_msgs(name)
  local out = {}
  for _, r in ipairs(SIM.components.game.received) do
    if r.mid == hash(name) then out[#out + 1] = r end
  end
  return out
end

local function outbound_of(t)
  local out = {}
  for _, o in ipairs(SIM.outbound) do if o.type == t then out[#out + 1] = o end end
  return out
end

local results = {}
local function check(label, cond, detail)
  results[#results + 1] = { label = label, ok = cond and true or false, detail = detail or "" }
  print(string.format("%s  %s%s", cond and "PASS" or "FAIL", label,
    (detail and detail ~= "") and ("  [" .. detail .. "]") or ""))
end

----------------------------------------------------------------------
-- 1. connect + identify (as controller does)
----------------------------------------------------------------------
SIM.with_ctx("controller", function()
  ws.identify(MY, "Me", { amount = 5000, charge = 0 }, "UG")
  ws.connect()
end)
SIM.pump(0.5)
SIM.server_send({ type = "IDENTIFY", data = { _id = MY, username = "Me", balance = 5000 } })
SIM.pump(0.5)

----------------------------------------------------------------------
-- 2. tournament game 1 arrives (auto-accepted request)
----------------------------------------------------------------------
print("\n══ GAME 1: GAME_REQUEST_ACCEPTED (ACTIVE) ══")
SIM.server_send({ type = "GAME_REQUEST_ACCEPTED",
                  data = { gameState = mk_state("g1", 0, 0, "ACTIVE") } })
SIM.pump(12.0)

local sb = hud_msgs("update_scoreboard")
local sb_show = nil
for _, r in ipairs(sb) do if r.msg.show then sb_show = r end end
check("A1: game 1 board initialised (PLAYER_READY sent for g1)",
  (function()
    for _, o in ipairs(outbound_of("PLAYER_READY")) do
      if o.data and o.data.gameId == "g1" then return true end
    end
    return false
  end)())
check("A2: scoreboard SHOWN on HUD for tournament game 1",
  sb_show ~= nil,
  sb_show and string.format("p=%s o=%s best_of=%s stage=%s",
    tostring(sb_show.msg.p_score), tostring(sb_show.msg.o_score),
    tostring(sb_show.msg.best_of), tostring(sb_show.msg.stage)) or "no update_scoreboard{show=true} received")

----------------------------------------------------------------------
-- 3. server confirms start
----------------------------------------------------------------------
print("\n══ GAME 1: START (STARTED) ══")
local started = mk_state("g1", 0, 0, "STARTED")
started.turnExpiresAt = (socket.gettime() + 30) * 1000
SIM.server_send({ type = "START",
                  data = { gameId = "g1", currentTurn = MY,
                           turnExpiresAt = started.turnExpiresAt,
                           gameState = started } })
SIM.pump(2.0)

----------------------------------------------------------------------
-- 4. opponent move (state keeps tournament fields, as the live object does)
----------------------------------------------------------------------
print("\n══ GAME 1: MOVE (opponent plays) ══")
local mv = mk_state("g1", 0, 0, "STARTED")
mv.actions = { { type = "PLAY", v = 2, s = "H" } }
mv.currentTurn = MY
mv.turnExpiresAt = (socket.gettime() + 30) * 1000
mv.playedCards = { { v = 2, s = "H" } }
mv.currentCard = { v = 2, s = "H" }
table.remove(mv.players[OPP].hand, 1)
SIM.server_send({ type = "MOVE", data = { gameState = mv } })
SIM.pump(4.0)

----------------------------------------------------------------------
-- 5. round ends — match continues (1-0)
----------------------------------------------------------------------
print("\n══ GAME 1: GAME_OVER (round won 1-0, match continues) ══")
local over = mk_state("g1", 0, 0, "GAME_OVER")
over.gameOverState = {
  winner = MY, loser = OPP, reason = "ALL_CARDS_PLAYED",
  stake = { amount = 1000, charge = 100, points = 100 },
  gameType = "TOURNAMENT",
  tournamentData = { id = TOUR, name = "Global", levels = {}, grandPrize = { value = 64000 } },
  rewards = { [MY] = 0, [OPP] = 0 },
  currentScores = { [MY] = 1, [OPP] = 0 },
  currentRound = 2, requiredWins = 2,
  isMatchComplete = false, tournamentCompleted = false,
}
SIM.server_send({ type = "GAME_OVER", data = { gameState = over } })
SIM.pump(4.0)

check("B1: HUD received the round-story interstitial (modal suppressed)",
  (function()
    for _, r in ipairs(SIM.components.game.received) do
      if r.mid == hash("round_story") then return true end
    end
    return false
  end)() and (function()
    for _, r in ipairs(SIM.components.gameover.received) do
      if r.mid == hash("game_over") then return false end
    end
    return true
  end)())

-- the recorder HUD can't ack the story; do it like the real gui would
SIM.with_ctx("game", function()
  msg.post("/controller#game_logic", "round_story_done")
end)
SIM.pump(0.5)

----------------------------------------------------------------------
-- 6. next round auto-accepted by backend → GAME_REQUEST_ACCEPTED (g2)
----------------------------------------------------------------------
print("\n══ GAME 2: GAME_REQUEST_ACCEPTED (auto-accept continuation) ══")
local n_screen_enters_before = 0
-- (count via trace of PLAYER_READY for g2 below instead)
SIM.server_send({ type = "GAME_REQUEST_ACCEPTED",
                  data = { gameState = mk_state("g2", 1, 0, "ACTIVE") } })
SIM.pump(12.0)

check("B2: board re-initialised for round 2 (PLAYER_READY sent for g2)",
  (function()
    for _, o in ipairs(outbound_of("PLAYER_READY")) do
      if o.data and o.data.gameId == "g2" then return true end
    end
    return false
  end)())

local sb2 = hud_msgs("update_scoreboard")
local last_show = nil
for _, r in ipairs(sb2) do if r.msg.show then last_show = r end end
check("C1: scoreboard persists across rounds and reads 1-0",
  last_show ~= nil and tonumber(last_show.msg.p_score) == 1 and tonumber(last_show.msg.o_score) == 0,
  last_show and string.format("p=%s o=%s", tostring(last_show.msg.p_score), tostring(last_show.msg.o_score)) or "none")

----------------------------------------------------------------------
-- 7. START for g2
----------------------------------------------------------------------
print("\n══ GAME 2: START ══")
local s2 = mk_state("g2", 1, 0, "STARTED")
s2.turnExpiresAt = (socket.gettime() + 30) * 1000
SIM.server_send({ type = "START",
                  data = { gameId = "g2", currentTurn = MY,
                           turnExpiresAt = s2.turnExpiresAt, gameState = s2 } })
SIM.pump(2.0)

----------------------------------------------------------------------
-- summary + trace tail
----------------------------------------------------------------------
print("\n──────── summary ────────")
local fails = 0
for _, r in ipairs(results) do
  if not r.ok then fails = fails + 1 end
  print(string.format("%s  %s", r.ok and "PASS" or "FAIL", r.label))
end

print("\n──────── HUD scoreboard messages ────────")
for _, r in ipairs(hud_msgs("update_scoreboard")) do
  print(string.format("[%6.2fs] show=%s p=%s o=%s best_of=%s stage=%s",
    r.t, tostring(r.msg.show), tostring(r.msg.p_score), tostring(r.msg.o_score),
    tostring(r.msg.best_of), tostring(r.msg.stage)))
end

print("\n──────── outbound ws ────────")
for _, o in ipairs(SIM.outbound) do
  local extra = ""
  if o.type == "PLAYER_READY" and o.data then extra = " gameId=" .. tostring(o.data.gameId) end
  print(string.format("[%6.2fs] %s%s", o.t, tostring(o.type), extra))
end

if os.getenv("TRACE") then
  print("\n──────── full trace ────────")
  for _, l in ipairs(SIM.trace) do print(l) end
end

os.exit(fails == 0 and 0 or 1)
