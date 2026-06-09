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

local connection = nil
local is_connecting = false
local is_manual_disconnect = false
local reconnect_attempts = 0
local current_reconnect_delay = config.INITIAL_RECONNECT_DELAY
local pending_identity = nil
local keep_alive_handle = nil
local reconnect_handle = nil

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
  if M.socket_connected then
    M.send_message("IDENTIFY", pending_identity)
  end
end

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

function M.send_emoji(emoji_content)
  M.send_message("EMOJI_MESSAGE", { gameId = M.active_game_id, emoji = emoji_content })
end

function M.update_stake(stake_data)
  if M.current_user_id == "" then return end
  M.current_user_data.stake = stake_data
  M.send_message("UPDATE_STAKE", { _id = M.current_user_id, stake = stake_data })
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
    -- latency bookkeeping
  elseif t == "AUTH_REQUIRED" then
    emit("auth_required", d.message or "Device not registered")
  elseif t == "IDENTIFY" then
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
      M.active_game_id = gs.id or d.gameId or ""
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
      M.active_game_id = gs.id or d.gameId or ""
      M.active_game_state = gs
      emit("game_request_accepted", gs)
    end
  elseif t == "START" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_id = gs.id or d.gameId or ""
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
      local processed = { _id = from_id, from = from_id, actions = actions, chosenSuit = gs.chosenSuit or "", gameState = gs }
      emit("game_move", processed, gs)
    else
      print("[PIPE-1] DROPPED — gs decoded empty")
    end
  elseif t == "TIMER_UPDATE" then
    emit("timer_update", d)
  elseif t == "PLAYER_READY" then
    emit("player_ready", d._id or "")
  elseif t == "PLAYER_DISCONNECTED" then
    emit("player_disconnected", d.reason or "Unknown", d.gracePeriod or 30)
  elseif t == "PLAYER_RECONNECTED" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
    emit("player_reconnected", gs)
  elseif t == "EMOJI_MESSAGE" then
    emit("emoji", d._id or "", d.emoji or "")
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
    emit("game_over", results)
  elseif t == "TRANSACTION_COMPLETED" then
    emit("transaction_completed", d)
  elseif t == "TRANSACTION_FAILED" then
    emit("transaction_failed", d.reason or "Failed")
  elseif t == "IDENTIFY_ERROR" then
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

local function start_keep_alive()
  stop_keep_alive()
  keep_alive_handle = timer.delay(config.KEEP_ALIVE_INTERVAL, true, function()
    if M.socket_connected and connection then
      websocket.send(connection, json_util.encode({ type = "CLIENT_PING", timestamp = os.time() }))
    end
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
  if pending_identity then M.send_message("IDENTIFY", pending_identity) end
end

local function on_disconnected(reason)
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
  if data.event == websocket.EVENT_CONNECTED then on_connected()
  elseif data.event == websocket.EVENT_DISCONNECTED then on_disconnected(data.message or "closed")
  elseif data.event == websocket.EVENT_ERROR then
    print("[WS] error: " .. tostring(data.message or (data.error and data.error.message)))
    emit("connection_error", data.message or "error")
    on_disconnected("error")
  elseif data.event == websocket.EVENT_MESSAGE then
    parse_message(data.message)
  end
end

function M.connect()
  if is_connecting or M.socket_connected then return end
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