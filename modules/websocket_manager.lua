-- websocket_manager.lua
-- Real-time multiplayer client, ported from the Godot `WebSocketManager.gd`.
-- FIXED: MOVE event now reads actions/chosenSuit from the DECRYPTED gameState
--        (the backend nests them inside the encrypted blob, NOT on data top-level),
--        and derives the sender id from currentTurn so opponent moves animate.

local config = require("modules.config")
local json_util = require("modules.json_util")
local util = require("modules.util")
local aes = require("modules.aes")

local M = {}

-- ── state ───────────────────────────────────────────────────────────────────
M.socket_connected = false
M.is_identified = false
M.online_users = {}
M.current_user_data = {}
M.current_user_id = ""
M.active_game_id = ""
M.active_game_state = {}

-- Large payloads (full game state) cannot travel through msg.post: Defold
-- serializes message tables into a tiny fixed buffer and overflows on nested
-- arrays (e.g. the `rank` list with its `points` fields). So we park MOVE
-- payloads here in the shared Lua VM and only post a lightweight wake signal.
M.move_inbox = {}
M.last_game_over = {}
M.last_season_complete = nil
M.current_season_status = nil
M.last_daily_bonus_status = nil
M.last_daily_bonus_claim = nil
M.current_savings_status = nil

local connection = nil
local is_connecting = false
local is_manual_disconnect = false
local reconnect_attempts = 0
local current_reconnect_delay = config.INITIAL_RECONNECT_DELAY
local pending_identity = nil
local keep_alive_handle = nil
local reconnect_handle = nil

-- Wall-clock (seconds) of the last inbound traffic on the socket. Used by the
-- zombie-connection watchdog. socket.gettime() is a Defold/luasocket global.
local function now_s()
  if socket and socket.gettime then return socket.gettime() end
  return os.time()
end
local last_rx_time = now_s()

local KEY_BYTES = util.hex_to_bytes(config.GAME_STATE_SECRET)

-- ── pub/sub ─────────────────────────────────────────────────────────────────
local listeners = {} -- event -> { id -> fn }
local next_listener_id = 0

function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  next_listener_id = next_listener_id + 1
  local id = next_listener_id
  listeners[event][id] = fn
  return { event = event, id = id }
end

function M.off(token)
  if token and listeners[token.event] then
    listeners[token.event][token.id] = nil
  end
end

local function emit(event, ...)
  local group = listeners[event]
  if not group then return end
  for _, fn in pairs(group) do
    local ok, err = pcall(fn, ...)
    if not ok then
      print("[WS] listener error on '" .. event .. "': " .. tostring(err))
    end
  end
end
M.emit = emit

-- ── game state decryption ───────────────────────────────────────────────────
local function decrypt_game_state(b64)
  local raw = util.base64_to_bytes(b64)
  if #raw < 17 then return {} end
  local iv, ct = {}, {}
  for i = 1, 16 do iv[i] = raw[i] end
  for i = 17, #raw do ct[#ct + 1] = raw[i] end
  local pt = aes.decrypt_cbc(KEY_BYTES, iv, ct)
  local str = util.bytes_to_string(pt)
  return json_util.decode(str) or {}
end

function M.extract_game_state(data)
  if type(data) ~= "table" then return {} end
  local raw = data.gameState
  if raw == nil then return {} end
  if type(raw) == "table" then return raw end
  if type(raw) == "string" then return decrypt_game_state(raw) end
  return {}
end

-- Derive who made the move. The backend advances `currentTurn` to the OTHER
-- player after a move, so the actor is whoever is NOT currentTurn.
-- On the opponent's client this resolves to the real opponent (animate).
-- On the sender's client (reshuffle echo) it resolves to self (state-sync only).
local function derive_sender(gs)
  if type(gs) ~= "table" or type(gs.players) ~= "table" then return "" end
  local turn = gs.currentTurn
  for k, p in pairs(gs.players) do
    local pid = (type(p) == "table" and (p._id or p.id)) or k
    if pid and pid ~= turn then return pid end
  end
  return ""
end

-- ── sending ─────────────────────────────────────────────────────────────────
function M.send_message(msg_type, data)
  if not M.socket_connected or not connection then return false end
  local payload = { type = msg_type, data = data or {}, timestamp = os.time() }
  websocket.send(connection, json_util.encode(payload))
  return true
end

function M.send_move(game_id, from_id, to_id, actions, new_suit, active_penalty_count)
  local move_data = { gameId = game_id, from = from_id, to = to_id, cards = actions }
  if new_suit and new_suit ~= "" then
    move_data.newSuit = new_suit
  end
  if active_penalty_count and active_penalty_count > 0 then
    move_data.activePenaltyCount = active_penalty_count
  end
  M.send_message("MOVE", move_data)
end

function M.identify(id, username, stake, country)
  M.current_user_id = id
  pending_identity = {
    _id = id,
    username = username,
    stake = stake or { amount = 0, charge = 0 },
    country = country or "",
    appVersion = config.APP_VERSION,
  }
  print(string.format("[WS-DEBUG] identify() called: id=%s socket_connected=%s (%s)",
    tostring(id), tostring(M.socket_connected), M.socket_connected and "sending IDENTIFY now" or "queued for on_connected"))
  if M.socket_connected then
    M.send_message("IDENTIFY", pending_identity)
  end
end

-- FIXED: extra_data logic appends payload keys matching the Godot structure (e.g. tournamentId)
function M.send_game_request(opponent, stake, extra_data)
  local payload = {
    opponent = opponent,
    user = { _id = M.current_user_id, username = M.current_user_data.username or "" },
    stake = stake,
  }
  if type(extra_data) == "table" then
    for k, v in pairs(extra_data) do payload[k] = v end
  end
  M.send_message("GAME_REQUEST", payload)
end

function M.accept_game_request(request_id)
  M.send_message("GAME_REQUEST_ACCEPTED", { requestId = request_id })
end

function M.decline_game_request(request_id)
  M.send_message("GAME_REQUEST_DECLINED", { requestId = request_id })
end

-- Ack that the player has viewed the Season Results screen (sent when they
-- close the Half-Week Season Complete modal).
function M.send_season_results_viewed(season_id)
  M.send_message("SEASON_RESULTS_VIEWED", { seasonId = season_id })
end

-- Player pressed the claim/accept button on the daily bonus dialog.
function M.claim_daily_bonus()
  M.send_message("CLAIM_DAILY_BONUS", {})
end

-- Player chose to exchange `amount` coins from their balance into Savings now
-- (the "Exchange to Savings now" stepper in the savings Add dialog).
function M.exchange_to_savings(amount)
  M.send_message("EXCHANGE_TO_SAVINGS", { amount = amount })
end

-- Player saved their auto-charge-per-game preference (the "Auto-charge per
-- game" toggle in the savings Add dialog). `amount` must be one of 2/5/10/25
-- when `enabled` is true.
function M.set_savings_auto_charge(enabled, amount)
  M.send_message("SET_SAVINGS_AUTO_CHARGE", { enabled = enabled, amount = amount })
end

function M.send_emoji(name, sound, to)
  M.send_message("EMOJI_MESSAGE", {
    gameId = M.active_game_id,
    to = to or "",
    name = name,
    sound = sound or "",
    emoji = name, -- back-compat field
  })
end

function M.update_stake(stake_data)
  if M.current_user_id == "" then return end
  M.current_user_data.stake = stake_data
  M.send_message("UPDATE_STAKE", { _id = M.current_user_id, stake = stake_data })
end

-- Ask the backend for the head-to-head stats vs a specific opponent
-- (all-time scores, last-5 form, win-rate ratings). The HEAD_TO_HEAD
-- response lands on M.last_head_to_head and fires the "head_to_head" event.
function M.request_head_to_head(opponent_id)
  if not opponent_id or opponent_id == "" then return end
  M.send_message("GET_HEAD_TO_HEAD", {
    _id = M.current_user_id,
    opponentId = tostring(opponent_id),
  })
end

-- ── message parsing ─────────────────────────────────────────────────────────
local function handle_online_users(msg_data)
  local users = {}
  if type(msg_data) == "table" then
    if #msg_data > 0 then users = msg_data
    elseif msg_data.users then users = msg_data.users
    elseif msg_data.onlineUsers then users = msg_data.onlineUsers end
  end
  M.online_users = users
  emit("online_users", users)
end

local function parse_message(json_string)
  local message = json_util.decode(json_string)
  if type(message) ~= "table" then return end
  local t = message.type or ""
  local d = message.data or {}

  emit("message", t, d)

  if t == "PING" then
    M.send_message("PONG", {})
  elseif t == "CLIENT_PONG" or t == "PONG" then
    -- Real-time network quality (Godot parity): RTT of our own keep-alive
    -- ping. Shown locally on OUR badge and reported to the server so the
    -- opponent's client can show it live on theirs.
    if M._ping_sent_at and M._ping_sent_at > 0 then
      local latency = math.floor((now_s() - M._ping_sent_at) * 1000)
      M._ping_sent_at = 0
      emit("network_quality", { user_id = M.current_user_id, latency_ms = latency })
      if M.active_game_id ~= "" then
        M.send_message("NETWORK_QUALITY", { latency = latency, gameId = M.active_game_id })
      end
    end
  elseif t == "NETWORK_QUALITY" then
    -- The opponent's reported latency, relayed by the server.
    local uid = tostring(d.userId or "")
    if uid ~= "" then
      emit("network_quality", { user_id = uid, latency_ms = tonumber(d.latency) or 0 })
    end
  elseif t == "AUTH_REQUIRED" then
    print("[WS-DEBUG] AUTH_REQUIRED received: " .. tostring(d.message))
    M.is_identified = false
    emit("auth_required", d.message or "Device not registered")
  elseif t == "IDENTIFY" then
    print("[WS-DEBUG] IDENTIFY response received, marking is_identified=true")
    M.is_identified = true
    local user_payload = d
    if type(d.user) == "table" then
      user_payload = d.user
      if d._id then user_payload._id = d._id end
      if d.username then user_payload.username = d.username end
    end
    for k, v in pairs(user_payload) do M.current_user_data[k] = v end
    if M.current_user_data._id then M.current_user_id = M.current_user_data._id end
    emit("user_updated", M.current_user_data)

    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_id = gs.gameId or gs.id or d.gameId or ""
      M.active_game_state = gs
      emit("game_request_accepted", gs)
    else
      emit("identify_success", M.current_user_data, d)
    end
  elseif t == "ONLINE_USERS" then
    handle_online_users(d)
  elseif t == "PUBLIC_ANNOUNCEMENTS" then
    emit("announcements", d)
  elseif t == "GAME_REQUEST" then
    M.last_game_request = { user = d.user or {}, stake = d.stake or {}, requestId = d.requestId or "", raw = d }
    emit("game_request", d.user or {}, d.stake or {}, d.requestId or "", d)
  elseif t == "GAME_REQUEST_CANCELLED" then
    emit("game_request_cancelled", d.requestId or d.id or "")
  elseif t == "GAME_REQUEST_DECLINED" then
    emit("game_request_declined", d.reason or "Declined", d.requestId or "")
  elseif t == "GAME_REQUEST_ACCEPTED" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_id = gs.gameId or gs.id or d.gameId or ""
      M.active_game_state = gs
      emit("game_request_accepted", gs)
    end
  elseif t == "START" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_id = gs.gameId or gs.id or d.gameId or ""
      M.active_game_state = gs
      emit("game_start", gs)
    end
  elseif t == "MOVE" or t == "RESHUFFLING" then
    local gs = M.extract_game_state(d)
    print("[PIPE-1] parse_message type=" .. t .. " gs_keys=" .. tostring(next(gs) ~= nil))
    if next(gs) ~= nil then
      M.active_game_state = gs
      local actions = gs.actions or {}
      local from_id = derive_sender(gs)
      print(string.format("[PIPE-1] decoded from=%s actions=%d turn=%s suit=%s",
        tostring(from_id), #actions, tostring(gs.currentTurn), tostring(gs.chosenSuit)))
      pprint("[PIPE-1] gs.actions:", actions)
      local processed = { _id = from_id, from = from_id, actions = actions, chosenSuit = gs.chosenSuit or "", gameState = gs, aiOnBehalf = (d.aiOnBehalf == true) }
      emit("game_move", processed, gs)
    else
      print("[PIPE-1] DROPPED — gs decoded empty")
    end
  elseif t == "TIMER_UPDATE" then
    emit("timer_update", d)
  elseif t == "PLAYER_READY" then
    emit("player_ready", d._id or "")
  elseif t == "PLAYER_DISCONNECTED" then
    emit("player_disconnected", {
      reason = d.reason or "Unknown",
      grace = tonumber(d.gracePeriod) or 30,
      player_id = tostring(d._id or d.playerId or d.userId or ""),
    })
  elseif t == "PLAYER_RECONNECTED" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
    emit("player_reconnected", {
      player_id = tostring(d._id or d.playerId or d.userId or ""),
      state = gs,
    })
  elseif t == "EMOJI_MESSAGE" then
    emit("emoji", d._id or d.from or "", d.emoji or d.name or "", d.sound or "")
  elseif t == "AI_PLAYED_ON_YOUR_BEHALF" then
    -- The backend AI covered this player's seat: either a one-shot move after
    -- a turn timeout (mode=SINGLE_MOVE, capped per game) or a full takeover
    -- while they were offline (mode=TAKEOVER, delivered on reconnect).
    emit("ai_played_for_you", {
      mode = tostring(d.mode or "SINGLE_MOVE"),
      moves = tonumber(d.aiMovesUsed or d.aiMovesPlayed) or 0,
      max = tonumber(d.aiMovesMax) or 3,
      message = tostring(d.message or ""),
    })
  elseif t == "GAME_STATE_SYNC" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
  elseif t == "RESYNC" then
    -- The backend rejected our move: our board drifted. Park the
    -- authoritative state and let the board rebuild itself.
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_state = gs
      emit("resync", { reason = tostring(d.reason or "") })
    end
  elseif t == "ROUND_COMPLETE" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
    emit("round_complete", gs)
  elseif t == "GAME_OVER" then
    M.active_game_id = ""
    local results = {}
    if type(d.gameState) == "table" and type(d.gameState.gameOverState) == "table" then
      results = d.gameState.gameOverState
    elseif type(d.gameOverState) == "table" then
      results = d.gameOverState
    else
      -- Last resort: try to decrypt the gameState blob and pull gameOverState out.
      local gs = M.extract_game_state(d)
      if type(gs.gameOverState) == "table" then results = gs.gameOverState
      elseif next(gs) ~= nil then results = gs end
    end
    M.last_game_over = results
    -- The backend settles wallets before sending GAME_OVER and ships the
    -- post-game balances in gameOverState.balances — apply ours immediately
    -- so every screen shows the updated balance there and then (the IDENTIFY
    -- refresh is suppressed for zero-stake games and tournament round-continues).
    local user_touched = false
    if type(results.balances) == "table" then
      local bal = tonumber(results.balances[M.current_user_id])
      if bal ~= nil then
        M.current_user_data.balance = bal
        user_touched = true
      end
    end
    -- The backend also computes a fresh, match-relative rank/points slice for
    -- the two players who just played (endGame.ts's `freshRank`), specifically
    -- so the online lobby's STANDINGS panel can reflect the result right away.
    -- Without applying it here, ws.current_user_data.rank keeps whatever was
    -- last fetched before the game started, so the left panel never updates
    -- "live" when a game completes even though the user_updated event fires.
    if type(results.rank) == "table" and #results.rank > 0 then
      M.current_user_data.rank = results.rank
      user_touched = true
    end
    if user_touched then
      emit("user_updated", M.current_user_data)
    end
    emit("game_over", results)
    -- Once a game is FINALLY over (i.e. NOT a continuing tournament/battle round)
    -- drop the cached active game. Otherwise the finished state lingers and the
    -- controller resurrects the old board on the next identify/route — the "game
    -- board comes back with the previous state" bug.
    local gt = tostring(results.gameType or "")
    local round_continues =
        (gt == "TOURNAMENT" or gt == "BATTLE" or gt == "ELIMINATION")
        and not (results.isMatchComplete or results.tournamentCompleted
                 or results.tournamentEndedByTimeout or results.isNoShowScenario)
    if not round_continues then
      M.active_game_state = {}
    end
  elseif t == "TOURNAMENT_NO_OPPONENTS_FOUND" or t == "TOURNAMENT_REQUESTS_CANCELLED" then
    emit("tournament_no_opponents", d)
  elseif t == "HEAD_TO_HEAD" then
    -- All-time scores + last-5 form vs a specific opponent (response to
    -- GET_HEAD_TO_HEAD). Parked here — the nested stats table is too big to
    -- ride through msg.post — and read back by the online lobby.
    M.last_head_to_head = d or {}
    emit("head_to_head", d or {})
  elseif t == "SEASON_COMPLETE" then
    -- Half-Week Season wrap-up: final rank, rewards, badges/missions, and the
    -- full leaderboard. Parked here (too big to ride through msg.post) and
    -- read back by the global season_results overlay.
    M.last_season_complete = d
    -- The server sends a fresh SEASON_STATUS for the new season right after
    -- this, but clear the stale one now as a safety net — otherwise, if that
    -- follow-up message is ever lost, the countdown UI would stay frozen
    -- showing the just-closed season's (now past) endDate forever instead of
    -- just hiding until the next SEASON_STATUS arrives.
    M.current_season_status = nil
    emit("season_complete", d)
  elseif t == "SEASON_STATUS" then
    -- Pushed right after IDENTIFY so the client can drive an accurate
    -- countdown instead of guessing the Mon/Wed-noon/Sat boundary locally.
    M.current_season_status = d
    emit("season_status", d)
  elseif t == "DAILY_BONUS_STATUS" then
    -- Pushed right after IDENTIFY, same moment SEASON_STATUS arrives. Parked
    -- here and read back by the global daily_bonus overlay.
    M.last_daily_bonus_status = d
    emit("daily_bonus_status", d)
  elseif t == "DAILY_BONUS_CLAIMED" then
    -- Server's reply to a CLAIM_DAILY_BONUS attempt.
    M.last_daily_bonus_claim = d
    emit("daily_bonus_claimed", d)
  elseif t == "SAVINGS_STATUS" then
    -- Pushed right after IDENTIFY, same moment SEASON_STATUS/DAILY_BONUS_STATUS
    -- already arrive. Parked here and read back by the savings Add dialog.
    M.current_savings_status = d
    emit("savings_status", d)
  elseif t == "SAVINGS_EXCHANGE_RESULT" then
    -- Server's reply to an EXCHANGE_TO_SAVINGS attempt.
    M.last_savings_exchange = d
    emit("savings_exchange_result", d)
    if d.success then
      if M.current_user_data then
        M.current_user_data.balance = d.newBalance
        M.current_user_data.savingCoins = d.newSavingCoins
      end
      if M.current_savings_status then M.current_savings_status.savingCoins = d.newSavingCoins end
    end
  elseif t == "SAVINGS_SETTINGS_UPDATED" then
    -- Server's reply to a SET_SAVINGS_AUTO_CHARGE attempt.
    M.last_savings_settings = d
    emit("savings_settings_updated", d)
    if d.success and M.current_savings_status then
      M.current_savings_status.autoCharge = { enabled = d.enabled, amount = d.amount }
    end
  elseif t == "TRANSACTION_COMPLETED" then
    emit("transaction_completed", d)
  elseif t == "TRANSACTION_FAILED" then
    emit("transaction_failed", d.reason or "Failed")
  elseif t == "IDENTIFY_ERROR" then
    print("[WS-DEBUG] IDENTIFY_ERROR received: " .. tostring(d.message))
    M.is_identified = false
    emit("identify_error", d.message or "Authentication Failed")
  elseif t == "ERROR" then
    emit("error", d.message or "Error")
  else
    -- Diagnostic: if the opponent move ever stops arriving, this line tells you
    -- the backend is using a `type` string this client doesn't handle yet.
    print("[WS] UNHANDLED message type: '" .. tostring(t) .. "'")
  end
end

-- ── connection lifecycle ──────────────────────────────────────────────────--
local function stop_keep_alive()
  if keep_alive_handle then timer.cancel(keep_alive_handle); keep_alive_handle = nil end
end

local on_disconnected -- forward decl

-- A socket reported as "connected" but with no inbound traffic for ZOMBIE_TIMEOUT
-- seconds is a dead-but-open (zombie) link. Tear it down and let the normal
-- reconnect/backoff path bring us back, instead of hanging forever.
local function handle_zombie()
  print("[WS] zombie connection detected (no traffic for " ..
    tostring(config.ZOMBIE_TIMEOUT) .. "s) — forcing reconnect")
  emit("connection_error", "zombie")
  if connection and websocket then pcall(websocket.disconnect, connection) end
  on_disconnected("zombie")
end

local function start_keep_alive()
  stop_keep_alive()
  last_rx_time = now_s()
  keep_alive_handle = timer.delay(config.KEEP_ALIVE_INTERVAL, true, function()
    if not (M.socket_connected and connection) then return end
    -- Watchdog: if nothing has come back since the last ping cycles, the link
    -- is a zombie. Check BEFORE sending so a truly dead socket can't keep
    -- resetting our notion of "alive" just by queuing more outbound pings.
    if (now_s() - last_rx_time) > config.ZOMBIE_TIMEOUT then
      handle_zombie()
      return
    end
    M._ping_sent_at = now_s()
    websocket.send(connection, json_util.encode({ type = "CLIENT_PING", timestamp = os.time() }))
  end)
end

local schedule_reconnect -- forward decl

local function on_connected()
  print("[WS] connected")
  M.socket_connected = true
  is_connecting = false
  reconnect_attempts = 0
  current_reconnect_delay = config.INITIAL_RECONNECT_DELAY
  start_keep_alive()
  emit("connected")
  print(string.format("[WS-DEBUG] on_connected: pending_identity=%s", tostring(pending_identity ~= nil)))
  if pending_identity then M.send_message("IDENTIFY", pending_identity) end
end

on_disconnected = function(reason)
  print("[WS] disconnected: " .. tostring(reason))
  M.socket_connected = false
  is_connecting = false
  M.is_identified = false
  stop_keep_alive()
  connection = nil
  emit("disconnected", reason)
  if is_manual_disconnect then
    is_manual_disconnect = false
    return
  end
  schedule_reconnect()
end

schedule_reconnect = function()
  if reconnect_handle then return end
  reconnect_attempts = reconnect_attempts + 1
  if reconnect_attempts > config.MAX_RECONNECT_ATTEMPTS then
    print("[WS] max reconnect attempts reached")
    emit("reconnect_failed")
    return
  end
  current_reconnect_delay = math.min(config.INITIAL_RECONNECT_DELAY * (config.RECONNECT_BACKOFF ^ (reconnect_attempts - 1)), config.MAX_RECONNECT_DELAY)
  print(string.format("[WS] reconnecting in %.1fs (attempt %d)", current_reconnect_delay, reconnect_attempts))
  reconnect_handle = timer.delay(current_reconnect_delay, false, function()
    reconnect_handle = nil
    M.connect()
  end)
end

local function ws_callback(_, conn, data)
  if data.event == websocket.EVENT_CONNECTED then
    last_rx_time = now_s()
    on_connected()
  elseif data.event == websocket.EVENT_DISCONNECTED then on_disconnected(data.message or "closed")
  elseif data.event == websocket.EVENT_ERROR then
    print("[WS] error: " .. tostring(data.message or (data.error and data.error.message)))
    emit("connection_error", data.message or "error")
    on_disconnected("error")
  elseif data.event == websocket.EVENT_MESSAGE then
    -- Any inbound frame proves the link is alive; feed the zombie watchdog.
    last_rx_time = now_s()
    parse_message(data.message)
  end
end

function M.connect()
  if is_connecting or M.socket_connected then
    print(string.format("[WS-DEBUG] connect() no-op: is_connecting=%s socket_connected=%s",
      tostring(is_connecting), tostring(M.socket_connected)))
    return
  end
  if not websocket then
    print("[WS] ERROR: extension-websocket not installed. Add it to game.project dependencies.")
    emit("connection_error", "websocket extension missing")
    return
  end

  local device_id = ""
  local ok_api, api = pcall(require, "modules.api_service")
  if ok_api then device_id = api.get_device_id() end

  local url = config.WS_URL .. "/?deviceId=" .. tostring(device_id) .. "&v=" .. config.APP_VERSION
  print("[WS] connecting to " .. url)
  is_connecting = true
  is_manual_disconnect = false

  local params = { timeout = 8000 }
  connection = websocket.connect(url, params, ws_callback)
end

function M.disconnect()
  is_manual_disconnect = true
  stop_keep_alive()
  if connection and websocket then websocket.disconnect(connection) end
  connection = nil
  M.socket_connected = false
  M.is_identified = false
end

function M.get_active_game() return M.active_game_state end
function M.get_online_users() return M.online_users end
function M.get_current_user_id() return M.current_user_id end

-- Ask the backend to (re)broadcast the online-players list right now,
-- instead of passively waiting on whatever the last push happened to be.
-- The server's own broadcast is debounced ~1s and purely event-driven (new
-- login, game end, disconnect, etc.) — a first-time solo player has no other
-- event to trigger a second broadcast, so without this, entering the online
-- screen slightly before that debounced window closes could leave the list
-- looking permanently empty for the rest of the session.
function M.request_online_users()
  M.send_message("ONLINE_USERS", {})
end

-- Move inbox: parked here (shared VM) instead of being passed through msg.post.
function M.queue_move(move, state)
  local m = move or {}
  print(string.format("[PIPE-2] queue_move from=%s actions=%d  inbox_now=%d",
    tostring(m._id or m.from), tostring(m.actions and #m.actions or 0), #M.move_inbox + 1))
  table.insert(M.move_inbox, { move = move, state = state })
end

function M.take_moves()
  local out = M.move_inbox
  M.move_inbox = {}
  return out
end

return M