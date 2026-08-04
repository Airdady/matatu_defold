-- websocket_manager.lua
-- Real-time multiplayer client, ported from the Godot `WebSocketManager.gd`.
-- FIXED: MOVE event now reads actions/chosenSuit from the DECRYPTED gameState
--        (the backend nests them inside the encrypted blob, NOT on data top-level),
--        and derives the sender id from currentTurn so opponent moves animate.

local config = require("modules.config")
local conn_plan = require("modules.connection_plan")
local json_util = require("modules.json_util")
local util = require("modules.util")
local aes = require("modules.aes")

local M = {}

-- ── state ───────────────────────────────────────────────────────────────────
M.socket_connected = false
M.is_identified = false

-- Set once the server refuses this build as too old (UPDATE_REQUIRED, or a
-- 4426 close). Latching, deliberately: nothing short of updating the app can
-- clear it, so it also suppresses the reconnect loop.
M.update_required = false

-- Set once the server refuses this ACCOUNT. Suppresses reconnecting for the
-- same reason update_required does: the answer will be the same every time, so
-- retrying burns battery and radio to be told no again.
--
-- Restored from disk at boot (see api_service's offline flag), so a launch
-- after this costs no request at all — the app comes up offline knowing why,
-- rather than discovering it again.
--
-- NOT PERMANENT, and that is the difference from update_required. A build the
-- server has outgrown cannot become acceptable without a new binary. A block
-- can be lifted server-side with nothing happening on the phone — so an app
-- that latches this and never asks again can never come back, however long the
-- player waits or how often they reopen it. See APP_OFFLINE_RECHECK_SECONDS.
M.app_offline = false

-- When the latch went up, so the recheck window can be measured from it.
-- Seeded at boot from the timestamp in the cached flag, so the wait is counted
-- from the refusal itself rather than restarting at every launch — reopening
-- the app ten times in a minute costs no more requests than opening it once.
local app_offline_at = 0

-- How long the app stays quiet before spending ONE request to ask again.
--
-- Fifteen minutes, which is nothing next to how long a block lasts, and far
-- enough apart that it is not a reconnect loop by any reading: four requests
-- an hour against a server that answers each one in a few bytes. Set against
-- the alternative — never asking — where a player whose block was lifted an
-- hour ago is still staring at App Offline with nothing they can do about it.
local APP_OFFLINE_RECHECK_SECONDS = 15 * 60

-- The three accessors that read app_offline_at live further down, below
-- now_s(): a `local` introduced after a function body is not in scope inside
-- it, so written here they would resolve to a nil global and raise on the
-- first call. Same trap as SIGN_IN_CONNECT_GRACE further down.
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
-- Wall-clock of the moment `is_connecting` went true, and of the last IDENTIFY
-- put on the wire. The reconciler judges both by elapsed time rather than by
-- an event, because the bug it exists for is precisely an event that never
-- arrives.
local connecting_since = 0
local last_identify_sent = 0
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

--- Is the quiet period over? Exactly one attempt is allowed when it is.
function M.app_offline_recheck_due()
  if not M.app_offline then return false end
  return (now_s() - (app_offline_at or 0)) >= APP_OFFLINE_RECHECK_SECONDS
end

--- Raise the latch. `since` is when the refusal happened (an os.time()
--- stamp), so a flag restored from disk goes on counting from the refusal
--- itself instead of restarting the wait at every launch.
function M.set_app_offline(since)
  M.app_offline = true
  -- os.time() and now_s() can be different clocks, so an absolute stamp is
  -- turned into "how long ago" before being stored against the monotonic one.
  local ago = 0
  if type(since) == "number" and since > 0 then
    local elapsed = os.time() - since
    if elapsed > 0 then ago = elapsed end
  end
  app_offline_at = now_s() - ago
end

--- Drop it. The server accepting an identify is the one event that proves the
--- refusal no longer applies.
function M.clear_app_offline()
  M.app_offline = false
  app_offline_at = 0
end

local KEY_BYTES = util.hex_to_bytes(config.GAME_STATE_SECRET)

-- Close a socket attempt we are abandoning.
--
-- Declaring an attempt hung and opening a fresh one leaves the old one live:
-- `connection` is overwritten, but the socket underneath is not closed and the
-- extension goes on driving its callback. On a link slower than the stall
-- window that is not hypothetical — the abandoned handshake completes a moment
-- later, on_connected fires for it, and the app ends up with two sockets and
-- the server with two registrations for one player.
--
-- Best-effort by construction: the whole reason we are here is that this
-- socket is not behaving.
local function close_orphan_socket()
  if connection and websocket and websocket.disconnect then
    pcall(websocket.disconnect, connection)
  end
  connection = nil
end

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

-- Fallback-only heuristic for who made a move, used when the server message
-- doesn't carry an explicit `from` field. Assumes the backend always advances
-- `currentTurn` to the OTHER player after a move — true for Matatu, but NOT
-- for Whot's turn-retaining cards (Hold On / Suspension / General Market),
-- where the actor keeps the turn. Relying on this heuristic for those moves
-- silently misattributes the opponent's play as our own, so the actual
-- caller (parse_message's MOVE/RESHUFFLING handler) should always prefer an
-- explicit `from` field on the message when one is present.
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
  -- NO MOVE SURVIVES THE END OF ITS GAME.
  --
  -- Every move leaves the client through here, which makes this the one place
  -- the rule can actually be enforced. Up to now it was enforced at the input
  -- layer instead — on_input refuses taps once game_over is set — and that
  -- only covers moves the player starts by tapping. A move already staged when
  -- the result arrived, an AFK auto-play, a queued action draining after the
  -- fact and a retry all reach this function without going near on_input.
  --
  -- active_game_id is the authority: it is set from the game state the server
  -- pushes and cleared the moment GAME_OVER lands, so an empty one means there
  -- is no game to move in. A move naming a DIFFERENT game is refused too —
  -- that is a move from the round that just finished arriving after the next
  -- one has already started, which would otherwise be applied to the new game.
  if M.active_game_id == "" then
    print("[WS] MOVE dropped: the game is over")
    return false
  end
  if game_id and tostring(game_id) ~= "" and tostring(game_id) ~= tostring(M.active_game_id) then
    print(string.format("[WS] MOVE dropped: for game %s, but the live game is %s",
      tostring(game_id), tostring(M.active_game_id)))
    return false
  end

  local move_data = { gameId = game_id, from = from_id, to = to_id, cards = actions }
  if new_suit and new_suit ~= "" then
    move_data.newSuit = new_suit
  end
  if active_penalty_count and active_penalty_count > 0 then
    move_data.activePenaltyCount = active_penalty_count
  end
  M.send_message("MOVE", move_data)
end

-- IDENTIFY watchdog. The client used to send IDENTIFY and then simply wait:
-- if the reply never came (dropped frame, a rejected/stale user id answered
-- with a generic ERROR rather than IDENTIFY_ERROR, a socket that reports
-- "connected" a moment before it really is), is_identified stayed false and
-- the UI sat on CONNECTING forever with no way out. Resend a couple of
-- times, then surface it as an identify failure so the auth layer can
-- recover instead of hanging.
local IDENTIFY_TIMEOUT   = 2.5
local IDENTIFY_MAX_TRIES = 3
local identify_timer     = nil
local identify_tries     = 0

-- How old a connect attempt already in flight at SIGN-IN time must be before
-- the sign-in abandons it in favour of a fresh one.
--
-- Shorter than conn_plan.CONNECT_STALL_SECONDS, and deliberately so: that one
-- is the passive backstop for an app nobody is watching, while this fires on
-- an explicit, user-visible event carrying fresh proof that the network is up
-- (the HTTP sign-in that just returned against the same host). It fires once
-- per sign-in, never in a loop.
--
-- But NOT shorter than a real handshake. Below that it stops being a rescue
-- and becomes the starvation bug in miniature: a sign-in that lands during a
-- slow-but-working connect tears down the attempt that was about to succeed
-- and pays for a second one. Five seconds is the slow handshake that
-- test_first_login_timing.lua models; the pairing is asserted there.
--
-- So an attempt YOUNGER than this rides — it is still plausibly working, and
-- the 10s backstop has it either way. Only one that predates the sign-in by
-- more than a whole handshake is treated as dead, which is the ordinary shape
-- of a first login: boot opens a socket, then the player spends far longer
-- than this typing a number and waiting for a code.
--
-- Declared HERE, with the other identify timings, rather than beside the code
-- that reads it: M.identify() is defined earlier in this file, and a `local`
-- introduced after a function body is not in scope inside it — the read would
-- silently resolve to a nil global and raise on the comparison.
local SIGN_IN_CONNECT_GRACE = 5

local function cancel_identify_watchdog()
    if identify_timer then pcall(timer.cancel, identify_timer); identify_timer = nil end
end
M.cancel_identify_watchdog = cancel_identify_watchdog

-- The ONE place IDENTIFY goes on the wire, so last_identify_sent cannot drift
-- from reality. Three separate call sites used to send it, and the reconciler's
-- "have I sent one recently" question has to be answerable for all of them.
local function send_identify(why)
    if not pending_identity or not M.socket_connected then return false end
    last_identify_sent = now_s()
    print("[WS-DEBUG] sending IDENTIFY (" .. tostring(why) .. ")")
    return M.send_message("IDENTIFY", pending_identity)
end

local function arm_identify_watchdog()
    cancel_identify_watchdog()
    if not pending_identity or not M.socket_connected then return end
    identify_timer = timer.delay(IDENTIFY_TIMEOUT, false, function()
        identify_timer = nil
        if M.is_identified or not pending_identity then return end
        if not M.socket_connected then
            -- Socket was disconnected or is currently reconnecting;
            -- do not burn identify attempts while disconnected.
            return
        end
        if identify_tries < IDENTIFY_MAX_TRIES then
            identify_tries = identify_tries + 1
            -- %.1f, not %d. IDENTIFY_TIMEOUT is a fraction of a second now,
            -- and "%d" with a non-integer raises on Lua 5.3+ — inside the
            -- watchdog's own timer callback, which is the one thing that must
            -- not be able to die.
            print(string.format("[WS-DEBUG] IDENTIFY unanswered after %.1fs, resending (%d/%d)",
                IDENTIFY_TIMEOUT, identify_tries, IDENTIFY_MAX_TRIES))
            send_identify("watchdog")
            arm_identify_watchdog()
        else
            print("[WS-DEBUG] IDENTIFY never answered — reporting identify_error (timeout)")
            identify_tries = 0
            -- "timeout", and the distinction is the whole point. Nobody
            -- rejected this identity — the socket dropped, the server was slow,
            -- or it handled the reconnect down a branch that forgot to reply.
            -- The cached session is UNTESTED, not refused, and throwing it away
            -- here is what turned a network blip into a full re-authentication.
            emit("identify_error", "Could not sign you in. Retrying...", "timeout")
        end
    end)
end
M.arm_identify_watchdog = arm_identify_watchdog

-- The device id, which the app always has. Read lazily through pcall for the
-- same reason the FCM token is: api_service requires config, and requiring it
-- from here at load time is a cycle waiting to happen.
local function device_id()
  local id = ""
  pcall(function()
    local api = require("modules.api_service")
    if api and api.get_device_id then id = tostring(api.get_device_id() or "") end
  end)
  return id
end

-- A device id short enough to collide is not one. Some builds have returned
-- "" or "unknown" when theirs was unavailable, and sending THAT would ask the
-- server to match on a value every such device shares.
local function usable_device_id()
  local id = device_id()
  return #id >= 8 and id or ""
end
M.usable_device_id = usable_device_id

-- Latched when the server says it knows nothing about this device. Stops the
-- reconciler re-asking the same unanswerable question every few seconds; a
-- sign-in clears it by calling identify() with a real user id.
M.device_identity_refused = false

function M.identify(id, username, stake, country)
  id = tostring(id or "")
  M.current_user_id = id
  local fcm_token = ""
  pcall(function()
    local fbpush = require("modules.firebase_push")
    if fbpush and fbpush.get_fcm_token then
      fcm_token = fbpush.get_fcm_token()
    end
  end)

  -- A real user id clears the refusal: whatever the server did not recognise
  -- before, it is being given something different now.
  if id ~= "" then M.device_identity_refused = false end

  pending_identity = {
    _id = id,
    -- ALWAYS sent, even alongside a user id. It is what lets the server resume
    -- a returning player who has no cached session, and it keeps the stored
    -- deviceId fresh for the ones who do.
    deviceId = usable_device_id(),
    username = username,
    stake = stake or { amount = 0, charge = 0 },
    country = country or "",
    appVersion = config.APP_VERSION,
    fcmToken = (fcm_token and fcm_token ~= "") and fcm_token or nil,
  }
  print(string.format("[WS-DEBUG] identify() called: id=%s socket_connected=%s (%s)",
    tostring(id), tostring(M.socket_connected), M.socket_connected and "sending IDENTIFY now" or "queued for on_connected"))
  identify_tries = 0
  reconnect_attempts = 0
  M.reconnect_exhausted = false

  if M.socket_connected then
    send_identify("identify() called")
    arm_identify_watchdog()
  else
    -- A SIGN-IN IS EVIDENCE THE NETWORK WORKS.
    --
    -- Boot opens a socket before anybody has an identity, so by the time a
    -- sign-in completes there is usually an attempt already in flight. If that
    -- attempt has hung — no connect, no error, nothing — the sign-in used to
    -- inherit it and wait out the full CONNECT_STALL_SECONDS before anything
    -- else was tried. Ten seconds of nothing, after a login that had already
    -- succeeded. That is the "sometimes it works and sometimes it doesn't":
    -- whether login felt instant depended on whether the boot socket happened
    -- to connect.
    --
    -- We know more here than the reconciler does. The HTTP round trip that
    -- produced this user id just succeeded against the same host, seconds ago.
    -- An older socket attempt that still has not connected is not more
    -- trustworthy than that evidence, so it is abandoned and restarted.
    --
    -- A much shorter grace than the reconciler's, and it fires at most ONCE
    -- per sign-in rather than in a loop — so a genuinely slow handshake costs
    -- one restart here and is then governed by the 10s rule, instead of being
    -- torn down repeatedly.
    local in_flight_for = now_s() - (connecting_since or 0)
    local stale = is_connecting and in_flight_for >= SIGN_IN_CONNECT_GRACE
    if stale then
      print(string.format(
        "[WS] sign-in: abandoning a %.1fs connect that has reported nothing", in_flight_for))
      is_connecting = false
      close_orphan_socket()
    end
    if not is_connecting then
      M.connect()
    end
  end
  M.start_reconciler()
end

-- Clear the queued identity without disconnecting. Used when a session is
-- being torn down so the next auto-reconnect does NOT replay an old user id.
function M.reset_identity()
  cancel_identify_watchdog()
  pending_identity = nil
  identify_tries = 0
  M.current_user_id = ""
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

-- Ask the backend for a fresh "player above me / player below me" snapshot.
-- current_user_data.rank is otherwise only ever set once, at IDENTIFY, plus
-- a 2-row update for the two participants of a game that just ended — so a
-- bystander sitting in the online lobby never saw someone ELSE's points/
-- balance change (e.g. a new user joining and getting their signup bonus)
-- reflected in their own standings panel until they reconnected. The
-- RANK_UPDATE response updates current_user_data.rank in place and fires
-- "rank_update" so online_left.lua can re-render.
function M.request_rank()
  if M.current_user_id == "" then return end
  M.send_message("REQUEST_RANK", { _id = M.current_user_id })
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
  elseif t == "UPDATE_REQUIRED" then
    -- This build is below the server's minimum. Distinct from AUTH_REQUIRED:
    -- there is nothing wrong with the session, so the cached credentials must
    -- NOT be wiped — the player will still be signed in after they update.
    print("[WS] UPDATE_REQUIRED: " .. tostring(d.message))
    M.update_required = true
    emit("update_required", d)
  elseif t == "AUTH_REQUIRED" then
    print("[WS-DEBUG] AUTH_REQUIRED received: " .. tostring(d.message))
    M.is_identified = false
    emit("auth_required", d.message or "Device not registered")
  elseif t == "IDENTIFY" then
    print("[WS-DEBUG] IDENTIFY response received, marking is_identified=true")
    cancel_identify_watchdog()
    identify_tries = 0
    M.is_identified = true
    local user_payload = d
    if type(d.user) == "table" then
      user_payload = d.user
      if d._id then user_payload._id = d._id end
      if d.username then user_payload.username = d.username end
    end
    if type(M.current_user_data) ~= "table" then M.current_user_data = {} end
    if type(user_payload) == "table" then
      for k, v in pairs(user_payload) do M.current_user_data[k] = v end
    end
    if M.current_user_data._id then M.current_user_id = tostring(M.current_user_data._id) end


    -- BLOCKED. The server has been sending isBlocked on this payload all along
    -- and nothing read it, so a suspended account signed in and played exactly
    -- as before — the block only bit when it next hit an HTTP route guarded by
    -- checkBlockStatus.
    --
    -- Answered here and nowhere else: this is the first moment the app is told,
    -- and everything below (user_updated, identify_success, the game state
    -- restore) would otherwise put a blocked player back into the app before
    -- anyone could act on it.
    if M.current_user_data.isBlocked == true then
      local reason = tostring(M.current_user_data.blockReason or "")
      print("[WS] identify returned a refused account - going offline")
      M.is_identified = false
      local was_offline = M.app_offline
      -- Latched BEFORE the listeners run: one of them disconnects, and a
      -- disconnect schedules a reconnect unless this is already set.
      M.set_app_offline(os.time())
      -- The socket is refused, so it goes — here, not only via a listener that
      -- may not run. Left open it is a live connection carrying an identity
      -- the server will not accept, and the planner reads exactly that state
      -- as "re-send IDENTIFY", which is the refusal answered and re-asked for
      -- as long as the app is open.
      pcall(M.disconnect)
      -- Announced ONCE per latch. This path is re-entered every recheck
      -- window, and each emit clears the session, toasts and bounces the
      -- player back to the lobby — fine the first time, and a screen that
      -- resets itself out of nowhere every quarter of an hour after that.
      if not was_offline then
        emit("account_blocked", { reason = reason })
      end
      return
    end

    -- Identified WITHOUT having sent a user id: the server resolved us from
    -- the device id. The user it sent back is now the identity, and
    -- pending_identity has to carry it, or the next reconnect goes out
    -- device-only again and re-resolves something already known.
    if pending_identity and (pending_identity._id or "") == ""
       and (M.current_user_id or "") ~= "" then
      pending_identity._id = M.current_user_id
      pending_identity.username = M.current_user_data.username or pending_identity.username
      M.device_identity_refused = false
      print("[WS] device identify resolved to user " .. tostring(M.current_user_id))
      emit("identity_resolved_by_device", M.current_user_data)
    end

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
      -- Prefer the server's explicit `from` field (sent alongside the
      -- encrypted gameState) over the currentTurn-inequality heuristic —
      -- the heuristic breaks for Whot's turn-retaining special cards.
      local explicit_from = d.from
      local from_id = (explicit_from ~= nil and tostring(explicit_from) ~= "" and tostring(explicit_from))
        or derive_sender(gs)
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
  elseif t == "RANK_UPDATE" then
    -- Response to M.request_rank() — refresh the "player above/below me"
    -- standings snapshot in place, same shape as the rank IDENTIFY sends.
    if M.current_user_data then
      M.current_user_data.rank = (d and d.nearby) or {}
    end
    emit("rank_update", d or {})
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
  elseif t == "TEAM_CUP_EVENT" then
    -- Somebody joined the cup, or the owner started it. News about a cup this
    -- player is already IN, carrying no decision — so it surfaces as a toast
    -- and never as a banner. Not parked on M: a toast that has been shown is
    -- finished, and keeping the last one around only invites a screen to
    -- replay it on its next rebuild.
    emit("cup_event", d or {})
  elseif t == "TEAM_CUP_INVITE" then
    -- An invitation IS a decision, so this one gets the top banner. Arrives
    -- live when the invite is sent, and again for every un-acted-on invitation
    -- right after IDENTIFY (d.pending marks the replayed ones) — a push can be
    -- silenced or swiped away, so the replay is what actually guarantees the
    -- player sees it when they open the app.
    emit("cup_invite", d or {})
  elseif t == "TRANSACTION_COMPLETED" then
    emit("transaction_completed", d)
  elseif t == "TRANSACTION_FAILED" then
    emit("transaction_failed", d.reason or "Failed")
  elseif t == "IDENTIFY_UNKNOWN" then
    -- The server knows nothing about this device and we offered no user id.
    -- NOT a failure and NOT a rejection: there is no session to rebuild, this
    -- device has simply never signed in. Latched so the reconciler stops
    -- asking a question whose answer cannot change until somebody does.
    print("[WS] server does not recognise this device - a sign-in is needed")
    cancel_identify_watchdog()
    M.device_identity_refused = true
    -- The queued identity has to go as well as the flag. Left in place, the
    -- reconciler still sees an identity it has not registered and goes on
    -- re-sending it every few seconds — the latch only guards the branch that
    -- CREATES a device identity, not one already sitting there.
    M.reset_identity()
    emit("identify_unknown_device", d.message or "No account on this device yet")

  elseif t == "IDENTIFY_ERROR" then
    print("[WS-DEBUG] IDENTIFY_ERROR received: " .. tostring(d.message))
    cancel_identify_watchdog()
    M.is_identified = false
    -- "rejected": the server looked at this identity and refused it. This is
    -- the one that genuinely has to be rebuilt.
    emit("identify_error", d.message or "Authentication Failed", "rejected")
  elseif t == "ERROR" then
    -- handleIdentify answers an unknown/stale user id with a generic ERROR
    -- ("User not found"), not IDENTIFY_ERROR. Treated as a plain error it
    -- left is_identified false forever and the UI stuck on CONNECTING — and
    -- every later authenticated call kept using the same dead id, which is
    -- what surfaced as "Team owner not found". While un-identified, route it
    -- to the identify-failure path so the session can be rebuilt.
    if not M.is_identified and pending_identity then
      print("[WS-DEBUG] ERROR while un-identified, treating as identify failure: " .. tostring(d.message))
      cancel_identify_watchdog()
      -- Also a rejection: the server answered, and what it said was that this
      -- id is not one it knows.
      emit("identify_error", d.message or "Could not sign you in.", "rejected")
    else
      emit("error", d.message or "Error")
    end
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

-- The longest gap between reconnect attempts while a player is waiting to be
-- identified. config.MAX_RECONNECT_DELAY (30s) still applies once nobody is.
local WAITING_RECONNECT_MAX = 1.5

-- ...BUT NOT FOREVER.
--
-- A flat 1.5s ceiling is right for the case it was written for: a player
-- looking at CONNECTING while the server blips. It is wrong once it is clear
-- the server is not coming back in a moment, because it never escalates — it
-- retries every 1.5s for as long as the outage lasts, and every retry is a
-- fresh TLS handshake.
--
-- On the reported log that is exactly what happened: attempt after attempt at
-- 1.5s, each one answered with
--
--   SSLSocket mbedtls_ssl_handshake: -29312
--
-- which is MBEDTLS_ERR_SSL_CONN_EOF — the peer hung up DURING the handshake,
-- not a certificate or protocol fault. That is what a tunnel or proxy does
-- when it is shedding connections, so the retry rate was feeding the thing it
-- was retrying against.
--
-- So the ceiling escalates in three steps rather than staying flat, and the
-- steps are sized by what the player is actually experiencing:
--
--   1-6    1.5s   the blip the fast path exists for. A player who has just
--                 tapped is owed a retry NOW, and six of these is nine
--                 seconds — still well inside the promise that a handful of
--                 failed connects never costs them half a minute, which
--                 tools/test_first_login_timing.lua pins as arithmetic.
--
--   7-20   2.5s   the network is genuinely bad rather than briefly busy. Still
--                 seconds, still responsive, and already fewer handshakes.
--
--   21+    8s     nobody is being kept responsive any more — by here they have
--                 been waiting the best part of a minute and the fast retries
--                 have plainly not helped. This is where the reported log was
--                 (attempt 26), and it is the only band where the retry rate
--                 is doing harm rather than good. Five times fewer handshakes.
--
-- Note the ceilings only ever CAP the exponential backoff; they never hold a
-- retry back that the curve would have issued sooner.
local WAITING_FAST_ATTEMPTS  = 6
local WAITING_LATE_ATTEMPTS  = 20
local WAITING_RECONNECT_MID_MAX  = 2.5
local WAITING_RECONNECT_SLOW_MAX = 8

-- Spread the retries out.
--
-- Every client that drops off a restarting server comes back on the same
-- schedule, so they arrive together, and a server that just fell over gets its
-- whole population in one spike. A little noise per client turns that spike
-- into an arrival rate.
--
-- Deliberately small: it exists to break the lockstep, not to reshape the
-- timings above, which are held to real limits by the first-login test.
local RECONNECT_JITTER = 0.10

local schedule_reconnect -- forward decl

local function on_connected()
  print("[WS] connected")
  M.socket_connected = true
  M.reconnect_exhausted = false
  is_connecting = false
  reconnect_attempts = 0
  current_reconnect_delay = config.INITIAL_RECONNECT_DELAY
  start_keep_alive()
  emit("connected")
  print(string.format("[WS-DEBUG] on_connected: pending_identity=%s", tostring(pending_identity ~= nil)))
  if pending_identity then
    send_identify("socket opened")
    arm_identify_watchdog()
  end
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
  -- The server hung up because this build is below its minimum. Reconnecting
  -- would be refused identically every time, so the loop would just burn
  -- battery behind the update screen — and each retry re-runs the handshake
  -- that produced the refusal. This is terminal until the app is updated.
  if M.update_required then
    print("[WS] not reconnecting: update required")
    return
  end
  if M.app_offline then
    print("[WS] not reconnecting: app offline")
    return
  end
  schedule_reconnect()
end

schedule_reconnect = function()
  if reconnect_handle then return end
  reconnect_attempts = reconnect_attempts + 1
  if reconnect_attempts > config.MAX_RECONNECT_ATTEMPTS then
    print("[WS] max reconnect attempts reached")
    M.reconnect_exhausted = true
    emit("reconnect_failed")
    return
  end
  -- THE CAP DEPENDS ON WHETHER ANYBODY IS WAITING.
  --
  -- The 30s ceiling is right for an idle app whose socket dropped: nothing is
  -- on screen, and hammering a server that is already struggling helps nobody.
  --
  -- It is quite wrong for a player who has just signed in and is looking at
  -- CONNECTING. The backoff runs 1, 1.5, 2.25, 3.4, 5, 7.6, 11.4, 17, 25.6 and
  -- then 30 a time, so nine losing attempts put the next one over a minute
  -- out with the identity queued the whole while - which is exactly the
  -- "identify takes more than a minute" report, as arithmetic.
  --
  -- So while there is an identity waiting to be registered, the ceiling drops
  -- to a few seconds. It rises again the moment they are identified.
  local waiting = pending_identity ~= nil and not M.is_identified
  local ceiling
  if waiting then
    -- Fast while the outage still looks like a blip, then escalating. Without
    -- these steps it stayed at 1.5s for as long as the server was down.
    if reconnect_attempts <= WAITING_FAST_ATTEMPTS then
      ceiling = WAITING_RECONNECT_MAX
    elseif reconnect_attempts <= WAITING_LATE_ATTEMPTS then
      ceiling = WAITING_RECONNECT_MID_MAX
    else
      ceiling = WAITING_RECONNECT_SLOW_MAX
    end
  else
    ceiling = config.MAX_RECONNECT_DELAY
  end
  current_reconnect_delay = math.min(config.INITIAL_RECONNECT_DELAY * (config.RECONNECT_BACKOFF ^ (reconnect_attempts - 1)), ceiling)
  -- Jitter LAST, so it spreads the ceiling too — applied before the clamp it
  -- would be flattened away by it at exactly the point every client is pinned
  -- to the same value and the spread matters most.
  current_reconnect_delay = current_reconnect_delay * (1 + (math.random() * 2 - 1) * RECONNECT_JITTER)
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
  -- Every other caller of connect() (the "Play Online" tap, the reconnect
  -- timer, the lobby's auto-identify) goes through here, so refusing once is
  -- enough to stop all of them rather than guarding each one.
  if M.update_required then
    print("[WS] connect() refused: update required")
    return
  end
  -- Every route to a socket goes through connect(), so refusing here stops
  -- the reconnect timer, the lobby's auto-identify and the PLAY ONLINE tap
  -- alike, rather than each of them needing its own guard.
  --
  -- Except when the recheck window is open, which is the ONE attempt that
  -- lets an account whose block has been lifted find that out. The window is
  -- closed again here rather than on the answer: whether it succeeds or
  -- fails, this attempt has been spent, and leaving it open would turn the
  -- one probe into the loop this is here to prevent.
  if M.app_offline then
    if not M.app_offline_recheck_due() then
      print("[WS] connect() refused: app offline")
      return
    end
    print("[WS] app offline, but the recheck window is open - trying once")
    app_offline_at = now_s()
  end
  if is_connecting and (now_s() - (connecting_since or 0)) >= conn_plan.CONNECT_STALL_SECONDS then
    print("[WS] clearing stale is_connecting")
    is_connecting = false
    close_orphan_socket()
  end
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

  -- `b` is the Android versionCode, alongside the display version in `v`.
  -- The server gates on b when it has one (an integer needs no parsing) and
  -- falls back to v for builds older than the stamping change.
  local url = config.WS_URL .. "/?deviceId=" .. tostring(device_id)
      .. "&v=" .. config.APP_VERSION
      .. "&b=" .. tostring(config.APP_BUILD or 0)
  print("[WS] connecting to " .. url)
  is_connecting = true
  connecting_since = now_s()
  is_manual_disconnect = false

  local params = { timeout = 8000 }
  connection = websocket.connect(url, params, ws_callback)
end

-- A DELIBERATE retry, after the automatic ones have given up.
--
-- schedule_reconnect stops at MAX_RECONNECT_ATTEMPTS and sets
-- reconnect_exhausted, which is right: retrying forever behind a lobby that
-- says CONNECTING drains the battery and tells the player nothing. The lobby
-- then greys the online tiles and offers RETRY.
--
-- That button needs this. M.connect() on its own gets exactly ONE attempt —
-- reconnect_attempts is still over the maximum, so the first failure lands
-- straight back in the exhausted state — which makes a deliberate retry
-- weaker than the automatic ones it is standing in for. Somebody who has just
-- walked back into signal deserves the full budget, so the counter and the
-- backoff are reset first.
--
-- Safe to call at any time: connect() already no-ops while connecting or
-- connected, and refuses outright when an update is required.
function M.retry_connection()
  print("[WS] manual retry requested")
  reconnect_attempts = 0
  current_reconnect_delay = config.INITIAL_RECONNECT_DELAY
  M.reconnect_exhausted = false
  -- A pending timer would fire mid-attempt and be refused by connect()'s
  -- is_connecting guard, silently costing the player one of their retries.
  if reconnect_handle then
    pcall(timer.cancel, reconnect_handle)
    reconnect_handle = nil
  end
  -- A deliberate tap must not be swallowed by a stale in-flight flag. The
  -- reconciler would clear this itself, but only after the stall window, and
  -- somebody who just pressed RETRY is owed an attempt now.
  if is_connecting and (now_s() - (connecting_since or 0)) >= conn_plan.CONNECT_STALL_SECONDS then
    is_connecting = false
    connection = nil
  end
  M.connect()
  M.start_reconciler()
end

function M.disconnect()
  is_manual_disconnect = true
  -- Cleared here too. A disconnect requested WHILE an attempt is in flight
  -- otherwise leaves is_connecting true with no event coming to clear it, and
  -- the next connect() is a no-op until the reconciler's stall timer notices.
  is_connecting = false
  stop_keep_alive()
  cancel_identify_watchdog()
  pending_identity = nil      -- never replay a stale identity on the next connect
  identify_tries = 0
  if connection and websocket then websocket.disconnect(connection) end
  connection = nil
  M.socket_connected = false
  M.is_identified = false
end

-- ── THE RECONCILER ──────────────────────────────────────────────────────────
--
-- One loop whose whole job is to make the world match "we want to be signed in
-- as X". It replaces a sequence that five separate components had to perform
-- in the right order, each assuming the one before it had happened, with
-- nobody responsible for noticing when an assumption broke.
--
-- The failure that shipped: M.connect() no-ops while `is_connecting` is true,
-- and that flag is cleared ONLY by on_connected and on_disconnected. A socket
-- attempt that neither connects nor reports a failure — a hung TLS handshake,
-- an OEM dropping it silently, the app suspending mid-connect — leaves it true
-- for the rest of the process. connect() is then permanently a no-op,
-- schedule_reconnect never runs (it only fires from on_disconnected), and the
-- queued IDENTIFY sits there for ever. The identify watchdog cannot help: its
-- resend is itself guarded on socket_connected.
--
-- That is "Firebase returns 200, every field is populated, and IDENTIFY never
-- gets executed". Most likely on a FIRST login, because that is when a fresh
-- socket is opened straight after a token fetch and an HTTPS round trip.
--
-- This cannot deadlock the same way: it re-derives what to do from observable
-- state on every tick, so nothing depends on an event arriving.
local RECONCILE_INTERVAL = 1
local reconcile_handle = nil

-- Where a cached session comes from. Supplied by controller.script at boot so
-- this module does not have to require api_service (which requires config,
-- which is a cycle waiting to happen).
--
-- This is what makes "the app is open and there is a cached user" enough, on
-- its own, to get signed in. The identity used to exist only if some
-- controller path had remembered to call identify(), so whether IDENTIFY ever
-- fired depended on which route the app took through boot, resume, a failed
-- sign-in or a cleared flag. Now it is a property of the state.
local identity_provider = nil

function M.set_identity_provider(fn)
  identity_provider = fn
  M.start_reconciler()
end

local function adopt_cached_identity()
  if not identity_provider then return false end
  local ok, cached = pcall(identity_provider)
  if not ok or type(cached) ~= "table" then return false end
  local id = tostring(cached._id or cached.localId or "")
  if id == "" then return false end

  print("[WS] adopting cached session for " .. id .. " - identifying without a sign-in")
  if type(M.current_user_data) ~= "table" or (M.current_user_data._id or "") == "" then
    M.current_user_data = cached
  end
  M.identify(id, cached.username or "Player",
    { amount = tonumber(cached.balance) or 0, charge = 0 }, "UG")
  return true
end

local function has_cached_identity()
  if not identity_provider then return false end
  local ok, cached = pcall(identity_provider)
  return ok and type(cached) == "table" and tostring(cached._id or cached.localId or "") ~= ""
end

local function reconcile_step()
  local action = conn_plan.next_action({
    identity            = pending_identity,
    update_required     = M.update_required,
    -- WITHOUT THESE TWO THE PLANNER DRIVES A LOOP connect() ONLY REFUSES.
    --
    -- The latch was read at connect() and nowhere else, so every tick the
    -- planner still decided "adopt_device" and then "connect" — and
    -- adopt_device calls identify(), which restarts this loop on the spot
    -- rather than waiting for the next tick. It spun for as long as the app
    -- was open, refused one call deeper each time.
    app_offline         = M.app_offline,
    app_offline_recheck = M.app_offline_recheck_due(),
    socket_connected    = M.socket_connected,
    is_connecting       = is_connecting,
    is_identified       = M.is_identified,
    connecting_for      = now_s() - (connecting_since or 0),
    since_identify      = now_s() - (last_identify_sent or 0),
    has_cached_identity = has_cached_identity(),
    reconnect_scheduled = reconnect_handle ~= nil,
    has_device_identity = usable_device_id() ~= "",
    device_identity_refused = M.device_identity_refused,
  })

  if action == "adopt" then
    -- identify() sets pending_identity and kicks this loop again, so the next
    -- tick proceeds straight to connect/identify.
    adopt_cached_identity()

  elseif action == "adopt_device" then
    -- No user id anywhere, but the app knows its own device. Identify with
    -- that alone and let the server resolve who it belongs to; the reply
    -- carries the user back and the client caches it from there.
    print("[WS] no cached session - identifying by device id")
    M.identify("", "Player", { amount = 0, charge = 0 }, "UG")

  elseif action == "identify" then
    -- A socket with no identity on it. This is the state that used to be able
    -- to last for ever; re-sending costs one small frame.
    send_identify("reconciler")

  elseif action == "connect" then
    M.connect()

  elseif action == "unstick" then
    -- The attempt has hung past anything the extension's own 8s timeout could
    -- explain, and no event is coming to clear it. Force the flag down and let
    -- the next tick open a fresh one.
    print(string.format("[WS] connect attempt hung for %.0fs with no event - retrying",
      now_s() - (connecting_since or 0)))
    is_connecting = false
    close_orphan_socket()
    M.connect()
  end

  return action
end

-- RUN THE WHOLE WAY TO A STABLE STATE, NOW.
--
-- One action per tick meant a returning player with a session already on disk
-- waited two ticks before the socket was even opened: tick one adopted the
-- identity, tick two connected. Four seconds of CONNECTING for somebody the
-- app already knew everything about.
--
-- Each action changes the state the next decision reads, so a short loop walks
-- adopt -> connect (or adopt -> identify) in one pass and stops the moment
-- nothing more can usefully be done. Bounded because a planner bug must cost a
-- few wasted iterations, never a frozen app.
local function reconcile()
  for _ = 1, 4 do
    local action = reconcile_step()
    if action == "wait" or action == "idle" then return action end
  end
  return "wait"
end

-- Idempotent. Started the first time an identity is set and left running: the
-- ticks are almost all no-ops ("idle" or "wait"), and a loop that stops itself
-- is a loop that has to be restarted correctly by everything that might need
-- it — which is the class of bug this exists to remove.
function M.start_reconciler()
  -- When reconciling / resuming, if we are not connected and not identified,
  -- cancel any pending backoff delay so we attempt reconnection immediately.
  if not M.socket_connected and not M.is_identified then
    if reconnect_handle then
      pcall(timer.cancel, reconnect_handle)
      reconnect_handle = nil
    end
    reconnect_attempts = 0
  end

  if not reconcile_handle then
    reconcile_handle = timer.delay(RECONCILE_INTERVAL, true, function()
      local ok, err = pcall(reconcile)
      if not ok then print("[WS] reconciler error: " .. tostring(err)) end
    end)
  end
  -- And reconcile RIGHT NOW, every time, even when the timer was already
  -- running. This is what makes the common paths immediate rather than
  -- eventual: registering the identity provider at boot, and identify() being
  -- called after a sign-in, both land here and both should act on this frame
  -- instead of waiting up to RECONCILE_INTERVAL for a tick that will decide
  -- exactly the same thing.
  local ok, err = pcall(reconcile)
  if not ok then print("[WS] reconciler error: " .. tostring(err)) end
end

-- Test seam, and used by disconnect(): a repeating timer keeps the process
-- alive and would go on reconnecting a session that was deliberately ended.
function M.stop_reconciler()
  if reconcile_handle then pcall(timer.cancel, reconcile_handle); reconcile_handle = nil end
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