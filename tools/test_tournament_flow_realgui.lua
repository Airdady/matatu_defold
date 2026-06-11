----------------------------------------------------------------------
-- test_tournament_flow_realgui.lua
-- Same replay as test_tournament_flow.lua but with the REAL gui_scripts
-- (game.gui_script / gameover.gui_script / suit_select.gui_script) mounted,
-- a gui.* stub, and — crucially — Defold's hard message-size limit enforced
-- on msg.post (the engine rejects script messages whose serialized payload
-- exceeds ~2KB; the codebase already documents this for MOVE payloads).
----------------------------------------------------------------------

package.path = "./?.lua;" .. package.path

package.preload["modules.api_service"] = function()
  return {
    get_device_id = function() return "sim-device" end,
    set_auth_token = function() end, save_session = function() end,
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
-- emoji popover is gui-heavy and orthogonal to the flow under test
package.preload["modules.emoji_popover"] = function()
  return {
    init = function() end, close = function() end, reset = function() end,
    on_message = function() end, on_input = function() return false end,
  }
end

local SIM = dofile("tools/defold_sim.lua")
local json_util = require("modules.json_util")
local ws = require("modules.websocket_manager")

----------------------------------------------------------------------
-- Defold message-size limit on msg.post payloads
----------------------------------------------------------------------
local MESSAGE_LIMIT = 2048
local oversized = {}
local orig_post = msg.post
msg.post = function(target, message_id, message)
  if message ~= nil then
    local encoded = json_util.encode(message) or ""
    if #encoded > MESSAGE_LIMIT then
      oversized[#oversized + 1] = string.format(
        "[%6.2fs] ctx=%s -> %s '%s' (%d bytes)",
        SIM.clock, tostring(SIM.current_ctx), tostring(target), tostring(message_id), #encoded)
      error(string.format("Message too large for %s (%d bytes > %d)",
        tostring(message_id), #encoded, MESSAGE_LIMIT))
    end
  end
  return orig_post(target, message_id, message)
end

----------------------------------------------------------------------
-- gui.* stub
----------------------------------------------------------------------
local gui_node_n = 0
local function new_node(kind, pos, size_or_text)
  gui_node_n = gui_node_n + 1
  return {
    __node = true, kind = kind, id = gui_node_n,
    pos = pos or vmath.vector3(0, 0, 0),
    size = (kind ~= "text") and (size_or_text or vmath.vector3(0, 0, 0)) or nil,
    text = (kind == "text") and tostring(size_or_text or "") or nil,
    enabled = true, color = vmath.vector4(1, 1, 1, 1),
    scale = vmath.vector3(1, 1, 1), parent = nil, children = {},
  }
end

_G.gui = {
  PIVOT_CENTER = "C", PIVOT_W = "W", PIVOT_E = "E", PIVOT_N = "N", PIVOT_S = "S",
  PIVOT_NW = "NW", PIVOT_NE = "NE", PIVOT_SW = "SW", PIVOT_SE = "SE",
  ANCHOR_LEFT = "AL", ANCHOR_RIGHT = "AR", ANCHOR_TOP = "AT", ANCHOR_BOTTOM = "AB", ANCHOR_NONE = "AN",
  ADJUST_FIT = 1, ADJUST_STRETCH = 2, ADJUST_ZOOM = 3,
  CLIPPING_MODE_STENCIL = 1, CLIPPING_MODE_NONE = 0,
  EASING_INQUAD = 8, EASING_OUTBOUNCE = 9,
  EASING_OUTSINE = 1, EASING_INSINE = 2, EASING_OUTBACK = 3, EASING_OUTCUBIC = 4,
  EASING_INOUTSINE = 5, EASING_LINEAR = 6, EASING_OUTQUAD = 7,
  PLAYBACK_ONCE_FORWARD = 1, PLAYBACK_LOOP_PINGPONG = 2, PLAYBACK_ONCE_PINGPONG = 3,

  new_box_node = function(pos, size) return new_node("box", pos, size) end,
  new_text_node = function(pos, text) return new_node("text", pos, text) end,
  new_pie_node = function(pos, size) return new_node("pie", pos, size) end,

  set_parent = function(n, p) n.parent = p; if p then p.children[#p.children + 1] = n end end,
  set_position = function(n, p) n.pos = p end,
  get_position = function(n) return n.pos end,
  set_size = function(n, s) n.size = s end,
  set_color = function(n, c) n.color = c end,
  get_color = function(n) return n.color end,
  set_text = function(n, t) n.text = tostring(t) end,
  get_text = function(n) return n.text end,
  set_enabled = function(n, e) n.enabled = e and true or false end,
  is_enabled = function(n) return n.enabled end,
  set_scale = function(n, s) n.scale = s end,
  set_pivot = function() end, set_xanchor = function() end, set_yanchor = function() end,
  set_adjust_mode = function() end, set_rotation = function() end,
  set_font = function() end, set_shadow = function() end, set_outline = function() end,
  set_tracking = function() end, set_render_order = function() end,
  set_fill_angle = function() end, set_perimeter_vertices = function() end,
  set_texture = function() end, play_flipbook = function() end, new_texture = function() return true end,
  pick_node = function() return false end,
  set_clipping_mode = function() end,
  animate = function(n, prop, to, easing, dur, delay, cb, playback)
    if type(delay) == "function" then cb = delay; delay = 0 end
    if cb then timer.delay((dur or 0) + (delay or 0), false, function() cb(nil, n) end) end
  end,
  cancel_animation = function() end,
  delete_node = function() end,
  get_node = function() return new_node("box") end,
  set_flipbook = function() end,
}

----------------------------------------------------------------------
-- components: real logic scripts + REAL gui scripts
----------------------------------------------------------------------
for _, id in ipairs({ "lobby", "auth", "profile", "online", "themes", "payments", "tournaments" }) do
  SIM.add_recorder(id)
end
SIM.load_script_component("controller", "main/controller.script")
SIM.load_script_component("game_logic", "main/game.script")
SIM.load_script_component("game", "main/game.gui_script")
SIM.load_script_component("gameover", "main/gameover.gui_script")
SIM.load_script_component("suit_select", "main/suit_select.gui_script")
SIM.init_component("controller")
SIM.init_component("game_logic")
SIM.init_component("game")
SIM.init_component("gameover")
SIM.init_component("suit_select")
SIM.pump(0.2)

----------------------------------------------------------------------
-- backend payloads (same as test_tournament_flow.lua)
----------------------------------------------------------------------
local MY, OPP, TOUR = "p1", "ai9", "tour_77"

local function mk_deck(n)
  local d = {}
  local suits = { "H", "S", "D", "C" }
  for i = 1, n do d[#d + 1] = { v = (i % 13) + 1, s = suits[(i % 4) + 1] } end
  return d
end

-- activeTheme shaped like a real populated theme doc — this is what travels
-- inside players[*] on the wire.
local THEME = {
  _id = "theme_basic_red", name = "Red Basic", price = 0,
  cardBack = "red_basic", table_bg = "table_bg_red",
  preview = "https://cdn.example.com/themes/red_basic/preview.png",
}

local function mk_state(gid, my_score, opp_score, status, level)
  return {
    gameId = gid,
    players = {
      [MY] = {
        id = MY, _id = MY, username = "Me", avatar = 1, balance = 5000,
        winRate = 62, gamesPlayed = 124,
        ready = false, isAI = false, status = "WAITING",
        stake = { amount = 1000, charge = 100 }, activeTheme = THEME,
        hand = { {v=4,s="H"}, {v=5,s="S"}, {v=7,s="D"}, {v=10,s="C"},
                 {v=11,s="H"}, {v=12,s="S"}, {v=13,s="D"} },
      },
      [OPP] = {
        id = OPP, _id = OPP, username = "RoboKato", avatar = 2, balance = 99999,
        winRate = 48, gamesPlayed = 300,
        ready = true, isAI = true, status = "WAITING",
        stake = { amount = 1000, charge = 100 }, activeTheme = THEME,
        hand = { {v=2,s="H"}, {v=3,s="S"}, {v=6,s="D"}, {v=8,s="C"},
                 {v=9,s="H"}, {v=4,s="S"}, {v=5,s="D"} },
      },
    },
    status = status or "ACTIVE",
    userId = MY, currentTurn = MY,
    gameType = "TOURNAMENT", tournamentId = TOUR,
    isTournamentContinuation = (my_score + opp_score) > 0,
    matchFormat = 3,
    tournamentScore = {
      currentLevel = level or 1, totalLevels = 7, matchFormat = 3,
      scores = { [MY] = my_score, [OPP] = opp_score },
    },
    cuttingCard = { v = 7, s = "H" },
    headToHead = {
      scores = { [MY] = 3, [OPP] = 2 },
      totalGames = 5,
      lastGames = {},
      form = { [MY] = { "W", "L", "W", "W", "L" }, [OPP] = { "L", "W", "L", "L", "W" } },
      ratings = { [MY] = { winRate = 62, gamesPlayed = 124 }, [OPP] = { winRate = 48, gamesPlayed = 300 } },
    },
    deck = mk_deck(30),
    playedCards = {},
    stake = { amount = 1000, charge = 100, points = 100 },
    activePenaltyCount = 0, isBattle = false, actions = {}, rules = "JOKERS",
    ready = {}, activeTheme = THEME,
  }
end

local results = {}
local function check(label, cond, detail)
  results[#results + 1] = { label = label, ok = cond and true or false }
  print(string.format("%s  %s%s", cond and "PASS" or "FAIL", label,
    (detail and detail ~= "") and ("  [" .. detail .. "]") or ""))
end

local function outbound_of(t)
  local out = {}
  for _, o in ipairs(SIM.outbound) do if o.type == t then out[#out + 1] = o end end
  return out
end

local function hud(self_field)
  return SIM.components.game.self[self_field]
end

----------------------------------------------------------------------
-- replay
----------------------------------------------------------------------
SIM.with_ctx("controller", function()
  ws.identify(MY, "Me", { amount = 5000, charge = 0 }, "UG")
  ws.connect()
end)
SIM.pump(0.5)
SIM.server_send({ type = "IDENTIFY", data = { _id = MY, username = "Me", balance = 5000 } })
SIM.pump(0.5)

print("\n══ GAME 1: GAME_REQUEST_ACCEPTED ══")
SIM.server_send({ type = "GAME_REQUEST_ACCEPTED",
                  data = { gameState = mk_state("g1", 0, 0, "ACTIVE") } })
SIM.pump(12.0)

check("A1: PLAYER_READY sent for g1",
  (function()
    for _, o in ipairs(outbound_of("PLAYER_READY")) do
      if o.data and o.data.gameId == "g1" then return true end
    end
    return false
  end)())

check("A2: series scoreboard visible with flip clocks at 0-0",
  hud("sb_title") ~= nil and hud("sb_title").enabled == true
  and hud("p_flipper") and hud("p_flipper").val == "00"
  and hud("o_flipper") and hud("o_flipper").val == "00",
  "title=" .. tostring(hud("sb_title") and hud("sb_title").text))

local chip = hud("stake_chip")
check("A3: stake chip clear of the HUD column (x >= 190)",
  not (chip and chip.enabled and chip.pos.x < 190),
  chip and string.format("chip enabled=%s x=%s", tostring(chip.enabled), tostring(chip.pos.x)) or "no chip")

check("A4: head-to-head strip shows all-time 3-2 and 5 form badges",
  hud("h2h_alltime_lbl") and hud("h2h_alltime_lbl").enabled == true
  and hud("h2h_alltime_lbl").text == "H2H 3-2"
  and hud("h2h_badges")[1].bg.enabled and hud("h2h_badges")[1].lbl.text == "W"
  and hud("h2h_badges")[2].lbl.text == "L"
  and hud("h2h_badges")[5].bg.enabled,
  tostring(hud("h2h_alltime_lbl") and hud("h2h_alltime_lbl").text))

check("A5: win-rate rating chips set from player data",
  hud("p_rating") and hud("p_rating").bg.enabled and hud("p_rating").lbl.text == "WR 62%"
  and hud("o_rating") and hud("o_rating").bg.enabled and hud("o_rating").lbl.text == "WR 48%",
  string.format("p=%s o=%s", tostring(hud("p_rating") and hud("p_rating").lbl.text),
    tostring(hud("o_rating") and hud("o_rating").lbl.text)))

print("\n══ GAME 1: START ══")
local started = mk_state("g1", 0, 0, "STARTED")
started.turnExpiresAt = (socket.gettime() + 30) * 1000
SIM.server_send({ type = "START",
                  data = { gameId = "g1", currentTurn = MY,
                           turnExpiresAt = started.turnExpiresAt, gameState = started } })
SIM.pump(2.0)

print("\n══ GAME 1: GAME_OVER (1-0, match continues) ══")
local over = mk_state("g1", 0, 0, "GAME_OVER")
over.gameOverState = {
  winner = MY, loser = OPP, reason = "ALL_CARDS_PLAYED",
  stake = { amount = 1000, charge = 100, points = 100 },
  gameType = "TOURNAMENT",
  tournamentData = {
    id = TOUR, name = "Global Championship",
    levels = {
      { name = "Qualifier", coins = 1000, points = 1 },
      { name = "Round of 64", coins = 2000, points = 2 },
      { name = "Round of 32", coins = 4000, points = 3 },
      { name = "Round of 16", coins = 8000, points = 4 },
      { name = "Quarter Finals", coins = 16000, points = 5 },
      { name = "Semi Finals", coins = 32000, points = 6 },
      { name = "Finals", coins = 64000, points = 8 },
    },
    grandPrize = { value = 64000, points = 8 },
  },
  rewards = { [MY] = 0, [OPP] = 0 },
  currentScores = { [MY] = 1, [OPP] = 0 },
  currentRound = 2, requiredWins = 2,
  isMatchComplete = false, tournamentCompleted = false,
  isNoShowScenario = false,
  balances = { [MY] = 5900, [OPP] = 98899 },
  headToHead = {
    scores = { [MY] = 4, [OPP] = 2 },
    totalGames = 6,
    lastGames = {},
    form = { [MY] = { "W", "W", "L", "W", "W" }, [OPP] = { "L", "L", "W", "L", "L" } },
    ratings = {},
  },
}
SIM.server_send({ type = "GAME_OVER", data = { gameState = over } })
SIM.pump(4.0)

check("E1: balance updated there and then on game over",
  hud("p_balance") and hud("p_balance").text == "Bal: 5900"
  and (require("modules.websocket_manager").current_user_data.balance == 5900),
  tostring(hud("p_balance") and hud("p_balance").text))

check("E2: series score flips to 1-0 and H2H refreshes to 4-2 at game over",
  hud("p_flipper") and hud("p_flipper").val == "01"
  and hud("o_flipper") and hud("o_flipper").val == "00"
  and hud("h2h_alltime_lbl") and hud("h2h_alltime_lbl").text == "H2H 4-2",
  string.format("p=%s o=%s h2h=%s", tostring(hud("p_flipper") and hud("p_flipper").val),
    tostring(hud("o_flipper") and hud("o_flipper").val),
    tostring(hud("h2h_alltime_lbl") and hud("h2h_alltime_lbl").text)))

local go_gui = SIM.components.gameover.self
check("B1: game-over modal visible after tournament round",
  go_gui.n_content ~= nil and go_gui.n_content.enabled == true,
  "title=" .. tostring(go_gui.n_title and go_gui.n_title.text))

print("\n══ GAME 2: GAME_REQUEST_ACCEPTED (auto-accept continuation) ══")
local g2 = mk_state("g2", 1, 0, "ACTIVE")
g2.headToHead.scores = { [MY] = 4, [OPP] = 2 }
g2.headToHead.totalGames = 6
g2.headToHead.form = { [MY] = { "W", "W", "L", "W", "W" }, [OPP] = { "L", "L", "W", "L", "L" } }
SIM.server_send({ type = "GAME_REQUEST_ACCEPTED", data = { gameState = g2 } })
SIM.pump(12.0)

check("B2: PLAYER_READY sent for g2 (round 2 initialised)",
  (function()
    for _, o in ipairs(outbound_of("PLAYER_READY")) do
      if o.data and o.data.gameId == "g2" then return true end
    end
    return false
  end)())

check("B3: game-over modal dismissed for round 2",
  go_gui.n_content ~= nil and go_gui.n_content.enabled == false)

check("C1: scoreboard still visible across the round transition",
  hud("sb_title") ~= nil and hud("sb_title").enabled == true
  and hud("h2h_alltime_lbl") and hud("h2h_alltime_lbl").enabled == true)
check("C2: flip clocks read 1-0",
  hud("p_flipper") and hud("p_flipper").val == "01" and hud("o_flipper").val == "00",
  string.format("p=%s o=%s", tostring(hud("p_flipper") and hud("p_flipper").val),
    tostring(hud("o_flipper") and hud("o_flipper").val)))

print("\n══ GAME 2: START ══")
local s2 = mk_state("g2", 1, 0, "STARTED")
s2.turnExpiresAt = (socket.gettime() + 30) * 1000
SIM.server_send({ type = "START",
                  data = { gameId = "g2", currentTurn = MY,
                           turnExpiresAt = s2.turnExpiresAt, gameState = s2 } })
SIM.pump(2.0)

check("B4: duplicate START for the live game did NOT re-deal (de-dupe)",
  SIM.components.game_logic.self.online_game_id == "g2")

----------------------------------------------------------------------
-- round 2 lost -> 1-1, then ROUND 3 DELIVERED VIA `START` WITH A NEW ID
-- (recovery/alternate path: previously this was dropped entirely — the
-- controller skipped it on the game screen and the board's own listener
-- posted to "#" which resolves to #controller in the ws-callback context)
----------------------------------------------------------------------
print("\n══ GAME 2: GAME_OVER (1-1, match continues) ══")
local over2 = mk_state("g2", 1, 0, "GAME_OVER")
over2.headToHead = nil -- move-style states may omit it; the strip must persist
over2.gameOverState = {
  winner = OPP, loser = MY, reason = "ALL_CARDS_PLAYED",
  stake = { amount = 1000, charge = 100, points = 100 },
  gameType = "TOURNAMENT",
  tournamentData = over.gameOverState.tournamentData,
  rewards = { [MY] = 0, [OPP] = 0 },
  currentScores = { [MY] = 1, [OPP] = 1 },
  currentRound = 3, requiredWins = 2,
  isMatchComplete = false, tournamentCompleted = false,
  isNoShowScenario = false,
}
SIM.server_send({ type = "GAME_OVER", data = { gameState = over2 } })
SIM.pump(4.0)

print("\n══ GAME 3: delivered via START with a new id (g3) ══")
local s3 = mk_state("g3", 1, 1, "STARTED")
s3.turnExpiresAt = (socket.gettime() + 30) * 1000
SIM.server_send({ type = "START",
                  data = { gameId = "g3", currentTurn = MY,
                           turnExpiresAt = s3.turnExpiresAt, gameState = s3 } })
SIM.pump(8.0)

check("D1: START-delivered round re-initialised the board (was dropped before)",
  SIM.components.game_logic.self.online_game_id == "g3",
  "online_game_id=" .. tostring(SIM.components.game_logic.self.online_game_id))
check("D2: flip clocks read 1-1 after START-delivered round",
  hud("p_flipper") and hud("p_flipper").val == "01" and hud("o_flipper") and hud("o_flipper").val == "01",
  string.format("p=%s o=%s", tostring(hud("p_flipper") and hud("p_flipper").val),
    tostring(hud("o_flipper") and hud("o_flipper").val)))
check("D3: scoreboard still visible and chip still aside",
  hud("sb_title") and hud("sb_title").enabled == true
  and (not (hud("stake_chip") and hud("stake_chip").enabled) or hud("stake_chip").pos.x >= 190))

----------------------------------------------------------------------
-- HEAD_TO_HEAD response routing (sender-side dialog data)
----------------------------------------------------------------------
print("\n══ HEAD_TO_HEAD response ══")
SIM.server_send({ type = "HEAD_TO_HEAD", data = { opponentId = OPP, headToHead = {
  scores = { [MY] = 4, [OPP] = 3 }, totalGames = 7, lastGames = {},
  form = { [MY] = { "L", "W", "W", "L", "W" }, [OPP] = { "W", "L", "L", "W", "L" } },
  ratings = { [OPP] = { winRate = 48, gamesPlayed = 301 } },
} } })
SIM.pump(0.5)
check("F1: HEAD_TO_HEAD parked on ws module and forwarded to the lobby",
  (function()
    local wsm = require("modules.websocket_manager")
    if type(wsm.last_head_to_head) ~= "table" then return false end
    if tostring(wsm.last_head_to_head.opponentId) ~= OPP then return false end
    for _, r in ipairs(SIM.components.online.received) do
      if r.mid == hash("ws_head_to_head") then return true end
    end
    return false
  end)())

----------------------------------------------------------------------
-- summary
----------------------------------------------------------------------
print("\n──────── summary ────────")
local fails = 0
for _, r in ipairs(results) do
  if not r.ok then fails = fails + 1 end
  print(string.format("%s  %s", r.ok and "PASS" or "FAIL", r.label))
end

print("\n──────── OVERSIZED msg.post payloads (engine would reject) ────────")
if #oversized == 0 then print("(none)") end
for _, l in ipairs(oversized) do print(l) end

print("\n──────── outbound ws ────────")
for _, o in ipairs(SIM.outbound) do
  local extra = ""
  if o.type == "PLAYER_READY" and o.data then extra = " gameId=" .. tostring(o.data.gameId) end
  print(string.format("[%6.2fs] %s%s", o.t, tostring(o.type), extra))
end

os.exit(fails == 0 and 0 or 1)
