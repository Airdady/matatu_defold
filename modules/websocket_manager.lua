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
local DC = require("modules.disconnect_events")

local M = {}

-- ── state ───────────────────────────────────────────────────────────────────
M.socket_connected = false
M.is_identified = false

-- Set once the server refuses this build as too old (UPDATE_REQUIRED, or a
-- 4426 close). Latching, deliberately: nothing short of updating the app can
-- clear it, so it also suppresses the reconnect loop.
M.update_required = false
M.online_users = {}
M.current_user_data = {}
M.current_user_id = ""
M.active_game_id = ""
M.active_game_state = {}

-- THE MOVE WE SENT AND HAVE NOT SEEN COME BACK.
--
-- Every server->client message that matters carries an ack (_ackId /
-- _replayId, answered with MISSED_MOVE_ACK), and moves/index.ts requeues
-- anything left unacked into missedMoves so a client that missed a move gets
-- it on the next reconnect. The client->server direction had NOTHING like
-- that: send_move called send_message and dropped its return value on the
-- floor, and send_message returns false without sending a byte whenever the
-- socket is down.
--
-- So a card played into a dead socket was simply gone. play_card had already
-- removed it from player_hand optimistically, the turn had already flipped to
-- the opponent locally — and the server never heard about any of it. On
-- reconnect, IDENTIFY brings the authoritative state where that card is still
-- in hand, sync_my_hand faithfully reconciles to it, and the card the player
-- watched land on the pile reappears in their hand. That is the reported
-- "the K I had placed came back from the pile to my hand".
--
-- Held here until the server's own echo of it arrives (or the state proves it
-- landed).
--
-- A LIST, NOT ONE SLOT. This used to hold a single move, on the reasoning
-- that a player has one turn and cannot move again until the first is
-- answered. That is not true of this game, for two separate reasons.
--
-- A TURN-KEEPING CARD. An 8 or a Jack leaves the turn with the player who
-- played it (rules.ts: SKIP_TURN), so a chain of them is several moves from
-- one player in a row.
--
-- AND THE STALL RECOVERY, which is the one that produced the report. When a
-- move is lost, the server's last state still says it is our turn — it never
-- heard the move that would have ended it. game.script's watchdog sees
-- is_player_turn() true with nothing in flight and releases `waiting`, which
-- is exactly what it is for: a board frozen on a dropped frame is worse than
-- a board that lets you play. So the hand re-opens and a second move goes out
-- while the first is still unanswered:
--
--   play K of diamonds  -> lost in a network glitch
--   board re-opens       -> the server still believes it is our turn
--   play 6 of diamonds  -> sent, and OVERWROTE the held K
--
-- Only the 6 was then adjudicated on reconnect. The K was dropped without
-- ever being resent, so the server's hand still contained it, sync_my_hand
-- faithfully put it back, and the player watched the card they had played
-- fly out of the deck and into their hand.
--
-- Oldest first, and resent in that order — a sequence of plays from one turn
-- only makes sense played in sequence.
M.pending_moves = {}

-- What the bubble's badge says, and the last page/message parked for the
-- listener to read back — a page of messages is far too big for msg.post's
-- fixed buffer, the same reason MOVE payloads are parked here. See the
-- INBOX_* branches in parse_message.
M.inbox_unread = 0
M.last_inbox_page = nil
M.last_inbox_message = nil
M.last_inbox_sent = nil

-- The oldest move still unanswered, or nil. Kept as a plain field because
-- "is anything of ours still in flight" is the question most callers have.
M.pending_move = nil

-- A turn cannot legitimately be an unbounded chain of unanswered moves. Well
-- past any real run of plays in one turn, and there so that a socket that is
-- down for a long time cannot grow this without limit.
local MAX_PENDING_MOVES = 8

-- Large payloads (full game state) cannot travel through msg.post: Defold
-- serializes message tables into a tiny fixed buffer and overflows on nested
-- arrays (e.g. the `rank` list with its `points` fields). So we park MOVE
-- payloads here in the shared Lua VM and only post a lightweight wake signal.
M.move_inbox = {}

-- ANNOUNCEMENTS TRAVEL THE SAME WAY, AND FOR THE SAME REASON.
--
-- The top-10 champions banner is one long string — twenty names, avatars and
-- prize figures, well over a kilobyte — and it was being handed to msg.post
-- verbatim. Defold overflowed on it every single time:
--
--   buffer (890 bytes) too small for table, exceeded at '...CHAMPIONS!...'
--
-- The listener threw, so the announcement was never queued, never shown and
-- never marked as viewed — which is why it arrived again on the next push and
-- threw again, several times a second, forever.
M.announcement_inbox = {}

M.last_game_over = {}
-- playerId -> the hand that player held at GAME_OVER, straight from the final
-- gameState. The end-of-round reveal's source of truth; see the GAME_OVER
-- branch in parse_message for why nothing else on the client can be trusted for
-- this once round continuations push the next state in early.
M.last_game_over_hands = {}
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

-- Keeps M.pending_move pointing at the oldest unanswered move.
local function sync_pending_alias()
  M.pending_move = M.pending_moves[1]
end

function M.send_move(game_id, from_id, to_id, actions, new_suit, active_penalty_count)
  local move_data = { gameId = game_id, from = from_id, to = to_id, cards = actions }
  if new_suit and new_suit ~= "" then
    move_data.newSuit = new_suit
  end
  if active_penalty_count and active_penalty_count > 0 then
    move_data.activePenaltyCount = active_penalty_count
  end

  -- Recorded BEFORE the send, and kept regardless of whether it succeeded.
  -- A send that returns false never reached the wire; a send that returns
  -- true still might not have (a connection that has gone dark without a
  -- close looks identical to a healthy one until the ping watchdog notices,
  -- which is the same reason the server acks its own live sends). Neither
  -- case is distinguishable from here, so both are held and adjudicated
  -- later against the server's own state — see resend_pending_move_if_lost.
  local held = {
    game_id = game_id,
    from_id = from_id,
    data = move_data,
    -- Just the PLAY cards: these are what the server's copy of our hand is
    -- checked against to decide whether this move ever landed. A DRAW has no
    -- such fingerprint (the drawn card is chosen by the server), so a
    -- draw-only move is judged on the turn alone.
    plays = (function()
      local out = {}
      for _, a in ipairs(actions or {}) do
        if a.type == "PLAY" then
          out[#out + 1] = { v = tonumber(a.v), s = tostring(a.s or "") }
        end
      end
      return out
    end)(),
    sent_ok = false,
    at = now_s(),
  }

  M.pending_moves[#M.pending_moves + 1] = held
  while #M.pending_moves > MAX_PENDING_MOVES do
    local dropped = table.remove(M.pending_moves, 1)
    print(string.format(
      "[WS] holding more than %d unanswered moves — dropping the oldest (%d play(s))",
      MAX_PENDING_MOVES, #(dropped.plays or {})))
  end
  sync_pending_alias()

  held.sent_ok = M.send_message("MOVE", move_data) and true or false
  if not held.sent_ok then
    print("[WS] MOVE not sent — socket down. Held for resend on reconnect.")
  end
  return held.sent_ok
end

-- The move came back from the server (or became moot). Stop holding it.
local function clear_pending_move(why)
  if #M.pending_moves > 0 then
    print(string.format("[WS] %d pending move(s) cleared: %s",
      #M.pending_moves, tostring(why)))
    M.pending_moves = {}
    sync_pending_alias()
  end
end
M.clear_pending_move = clear_pending_move

-- Which of the held moves have demonstrably landed, judged against a state
-- the server sent us? Used on the echo of our own move, where one move being
-- confirmed says nothing about the others still in flight behind it.
--
-- A move has landed when the cards it played are no longer in the server's
-- copy of our hand. Nothing is resent from here: a live echo is not the
-- moment to retry anything, only to stop holding what is already done.
local function retire_landed_moves(gs)
  if #M.pending_moves == 0 then return end
  local me = tostring(M.current_user_id or "")
  local hand = me ~= "" and ((gs or {}).players or {})[me]
  hand = type(hand) == "table" and hand.hand or nil
  if type(hand) ~= "table" then
    -- No hand to judge against. The echo still confirms the OLDEST move —
    -- the server answers in the order it was sent — so retire just that one.
    table.remove(M.pending_moves, 1)
    sync_pending_alias()
    return
  end

  local in_hand = function(pc)
    for _, hc in ipairs(hand) do
      if tonumber(hc.v) == pc.v and tostring(hc.s) == pc.s then return true end
    end
    return false
  end

  local kept = {}
  for _, pm in ipairs(M.pending_moves) do
    local still = 0
    for _, pc in ipairs(pm.plays) do
      if in_hand(pc) then still = still + 1 end
    end
    -- Every card still in hand means this one has NOT been applied yet.
    -- A draw-only move has no fingerprint, so it is left held for the
    -- reconnect adjudication to judge on the turn.
    if #pm.plays > 0 and still == #pm.plays then kept[#kept + 1] = pm end
  end
  if #kept ~= #M.pending_moves then
    print(string.format("[WS] %d of %d held move(s) confirmed by the echo",
      #M.pending_moves - #kept, #M.pending_moves))
  end
  M.pending_moves = kept
  sync_pending_alias()
end
M.retire_landed_moves = retire_landed_moves

-- DID THE MOVE WE ARE HOLDING EVER REACH THE SERVER?
--
-- Asked against the authoritative state that arrives with IDENTIFY on
-- reconnect, so this is not a guess — it reads the server's own copy of the
-- board and answers from it:
--
--   * not our turn any more  -> the move landed (the server advanced the
--     turn), or the turn moved on without us. Either way, resending would be
--     refused (handleMove attributes by currentTurn and answers a mismatched
--     sender with NOT_YOUR_TURN) and there is nothing to recover.
--   * still our turn AND every card we played is still in the server's copy
--     of our hand -> the server never saw it. Resend.
--   * still our turn but the cards are gone from our hand -> it landed and
--     the turn is ours again (a Whot hold-on, a penalty stack). Nothing to do.
--
-- The resend is safe even if this judgement is somehow wrong: validateMove
-- rejects a card that is not in hand, and a sender who is not currentTurn is
-- ignored with NOT_YOUR_TURN rather than applied. The server cannot be made
-- to play the same card twice by this.
local function resend_pending_move_if_lost(gs)
  if #M.pending_moves == 0 then return end
  if type(gs) ~= "table" or next(gs) == nil then return end
  local pm = M.pending_moves[1]

  -- A different game entirely — the held move belongs to a board that is no
  -- longer in front of us.
  local gid = tostring(gs.gameId or gs.id or "")
  if gid ~= "" and tostring(pm.game_id or "") ~= "" and gid ~= tostring(pm.game_id) then
    clear_pending_move("state is for a different game")
    return
  end

  local me = tostring(pm.from_id or M.current_user_id or "")
  if me == "" then return end

  if tostring(gs.currentTurn or "") ~= me then
    clear_pending_move("server has moved the turn on — the move landed or is moot")
    return
  end

  -- Still our turn. Are the cards we played still sitting in our hand?
  local hand = ((gs.players or {})[me] or {}).hand
  if type(hand) ~= "table" then
    clear_pending_move("no authoritative hand to judge against")
    return
  end

  local in_hand = function(pc)
    for _, hc in ipairs(hand) do
      if tonumber(hc.v) == pc.v and tostring(hc.s) == pc.s then return true end
    end
    return false
  end

  -- EACH HELD MOVE IS JUDGED SEPARATELY, OLDEST FIRST.
  --
  -- A turn can leave several unanswered — a skip chain, or the stall recovery
  -- re-opening the board over a lost move — and they are not all in the same
  -- state: the K may have been lost while the 6 behind it landed, or the other
  -- way round. Judging only the newest, which is all a single slot could do,
  -- silently discarded the rest.
  --
  -- Resent in the order they were played, because a chain only makes sense
  -- that way, and the socket preserves that order.
  local kept = {}
  for _, held in ipairs(M.pending_moves) do
    local still = 0
    for _, pc in ipairs(held.plays) do
      if in_hand(pc) then still = still + 1 end
    end
    if #held.plays == 0 or still == #held.plays then
      print(string.format(
        "[WS] resending the move the server never got (%d play(s), sent_ok=%s)",
        #held.plays, tostring(held.sent_ok)))
      M.send_message("MOVE", held.data)
      held.at = now_s()
      emit("pending_move_resent", held)
      kept[#kept + 1] = held
    else
      print("[WS] held move dropped: cards are no longer in hand — it landed")
    end
  end
  M.pending_moves = kept
  sync_pending_alias()
end
M.resend_pending_move_if_lost = resend_pending_move_if_lost

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
    if not pending_identity or not M.socket_connected then
        -- TEMP DEBUG — remove once the version-gate regression is found.
        -- Confirms/denies "identify is never even attempted" as opposed to
        -- "it's attempted but refused/lost": if this line prints, the client
        -- never got as far as putting IDENTIFY on the wire at all.
        print(string.format(
            "[WS-DEBUG] send_identify(%s) SKIPPED — pending_identity=%s socket_connected=%s",
            tostring(why), tostring(pending_identity ~= nil), tostring(M.socket_connected)))
        return false
    end
    last_identify_sent = now_s()
    -- TEMP DEBUG — the exact version-gate fields this IDENTIFY carries, so a
    -- refusal is traceable to what THIS client actually sent rather than
    -- guessed at from the server's side alone.
    print(string.format(
        "[WS-DEBUG] sending IDENTIFY (%s) appVersion=%s appBuild=%s appPackage=%s update_required=%s",
        tostring(why), tostring(pending_identity.appVersion), tostring(pending_identity.appBuild),
        tostring(pending_identity.appPackage), tostring(M.update_required)))
    return M.send_message("IDENTIFY", pending_identity)
end

local function arm_identify_watchdog()
    cancel_identify_watchdog()
    if not pending_identity then return end
    identify_timer = timer.delay(IDENTIFY_TIMEOUT, false, function()
        identify_timer = nil
        if M.is_identified or not pending_identity then return end
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
    -- Alongside appVersion so the server's version gate always has the real
    -- Android versionCode too, not just the display name — it already gets
    -- this at connect time via the socket URL's `b` param, but IDENTIFY is
    -- what actually gets stored on the account (see handleIdentify.ts), and
    -- the two are sent at different moments.
    appBuild = config.APP_BUILD or 0,
    -- Which of matatu's two shipped packages this is — see the `pkg` param
    -- on the connect URL above for why this has to be the package name and
    -- not something guessed from appVersion.
    appPackage = config.APP_PACKAGE or "",
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
    arm_identify_watchdog()
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

-- ── MESSAGE CENTRE ───────────────────────────────────────────────────────────
--
-- The chat bubble. Support moved off email: the player writes here, an
-- operator answers in the dashboard, and the reply arrives over this socket or
-- as a push if they are not connected.
--
-- The same inbox carries bonus notices and announcements, so there is ONE
-- badge and one place to look. It is also the missed-message store — every
-- message is a row on the server before any delivery is attempted — so
-- anything that arrives while the app is closed is simply read on the next
-- fetch. Nothing is queued on this side.

--- The player wrote to support.
function M.send_inbox_message(body)
  M.send_message("INBOX_SEND", { body = tostring(body or "") })
end

--- Open the inbox, or page back through it.
--
-- `before` is the timestamp of the OLDEST message already held, not an offset:
-- an offset shifts underneath a message arriving mid-scroll and silently skips
-- or repeats one.
function M.fetch_inbox(before, limit)
  M.send_message("INBOX_FETCH", { before = before, limit = limit })
end

--- The player has seen these. Ids optional — omitted means everything.
function M.mark_inbox_read(ids)
  M.send_message("INBOX_READ", { ids = ids })
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

-- ── PARTY: a table of two to four, opened for twenty seconds ────────────────
--
-- Three pieces of state, and they answer different questions:
--
--   M.current_party      the table WE are sitting at, or nil. Set by
--                        PARTY_ROSTER, cleared by CANCELLED/STARTING.
--   M.available_parties  the open tables we could join, pushed by the server
--                        whenever OUR view of them changes (PARTY_AVAILABLE).
--                        Already filtered per player and sorted soonest-first,
--                        so the client renders it as given rather than
--                        deciding eligibility itself — the server is the only
--                        side that knows every balance in the lobby.
--   M.last_party_error   the most recent refusal, for the screen to show.
--
-- current_party is deliberately NOT derived from available_parties: a table we
-- are seated at stops being "available" to us the moment we sit down, and
-- deriving one from the other would empty our own roster as we joined it.
M.current_party = nil
M.available_parties = {}
M.last_party_error = nil
M.last_party_result = nil

function M.party_create(entry, mode, score_cap)
  if M.current_user_id == "" then return end
  M.send_message("PARTY_CREATE", {
    entry = tonumber(entry),
    mode = tostring(mode or "NORMAL"),
    scoreCap = tonumber(score_cap),
  })
end

function M.party_join(party_id)
  if M.current_user_id == "" or not party_id then return end
  M.send_message("PARTY_JOIN", { partyId = tostring(party_id) })
end

function M.party_leave(party_id)
  -- The id is optional on the wire: the server falls back to whichever table
  -- this player is seated at, which is what a LEAVE button has to hand.
  local id = party_id or (M.current_party and M.current_party.partyId)
  M.send_message("PARTY_LEAVE", { partyId = id and tostring(id) or nil })
end

-- Ask for the open-table list now, for a screen that has just opened. The
-- server answers this one unconditionally; the pushes it sends unprompted are
-- de-duplicated against what we were last shown, so a screen re-opening on an
-- unchanged lobby would otherwise get nothing.
function M.party_list()
  if M.current_user_id == "" then return end
  M.send_message("PARTY_LIST", {})
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

  -- CONFIRM RECEIPT — of a reconnect catch-up OR an ordinary LIVE move.
  --
  -- be_matatu tags a message `_replayId` when it's a reconnect catch-up
  -- (handleIdentify.ts's pendingMissedMoveReplays — see the RESHUFFLING/MOVE
  -- branch below, which skips the action-replay pipeline for these) and
  -- `_ackId` when it's an ordinary live send the server wants confirmed
  -- (moves/index.ts's pendingLiveMoveAcks — sent because readyState OPEN and
  -- a successful ws.send() are not proof the other end actually got it; a
  -- connection that went dark without an explicit close looks identical to
  -- a healthy one until the ping/pong watchdog notices, several seconds
  -- later). Both get the exact same ack — the server checks the id against
  -- whichever of its two registries is holding it — the only difference is
  -- what the CLIENT does with the rest of the message: a live move still
  -- runs its normal animation below, a catch-up does not.
  --
  -- DO NOT REMOVE THIS WITHOUT REMOVING THE SERVER SIDE FIRST. moves/index.ts
  -- registers every live send in pendingLiveMoveAcks and, after
  -- LIVE_MOVE_ACK_TIMEOUT_MS with no ack, requeues that move into missedMoves
  -- — so a client that stops acking has every move it successfully received
  -- re-delivered on its next reconnect, while the server logs "no
  -- MISSED_MOVE_ACK ... queued into missedMoves" for moves that arrived fine.
  local ack_id = (d._replayId and d._replayId ~= "" and d._replayId)
    or (d._ackId and d._ackId ~= "" and d._ackId)
  if ack_id then
    M.send_message("MISSED_MOVE_ACK", { replayId = ack_id })
  end

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
    for k, v in pairs(user_payload) do M.current_user_data[k] = v end
    if M.current_user_data._id then M.current_user_id = M.current_user_data._id end

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
      -- BEFORE the board rebuilds off this state. If our last move never
      -- reached the server, this is the one moment we can still tell — the
      -- state in hand is authoritative and the move is still held. Resending
      -- here means the correction arrives as a normal MOVE the board plays,
      -- rather than the player watching their own card reappear in their hand.
      resend_pending_move_if_lost(gs)
      emit("game_request_accepted", gs)
    else
      -- Identified with no game in progress: whatever we were holding belongs
      -- to a game that is over.
      clear_pending_move("identified with no active game")
      emit("identify_success", M.current_user_data, d)
    end
  elseif t == "ONLINE_USERS" then
    handle_online_users(d)
  elseif t == "PUBLIC_ANNOUNCEMENTS" then
    emit("announcements", d)
  elseif t == "GAME_REQUEST" then
    -- NO DROP HERE ANY MORE.
    --
    -- This used to swallow a championship invite aimed at somebody who had not
    -- joined, back when the server refused to send them at all and one slipping
    -- through meant something had gone wrong.
    --
    -- That is no longer the rule. Championship invites go to every eligible
    -- player deliberately — a ladder nobody may be invited to fills up very
    -- slowly — and an invite to somebody not yet in is the ONE that matters
    -- most: it is how they join. The strip offers them JOIN, with the one-off
    -- fee on it and the grand prize beside it, and accepting enters them.
    -- Dropping it here would silently delete the entire recruiting path.
    M.last_game_request = { user = d.user or {}, stake = d.stake or {}, requestId = d.requestId or "", raw = d }
    emit("game_request", d.user or {}, d.stake or {}, d.requestId or "", d)
  elseif t == "GAME_SEARCH_STARTED" then
    -- HOW LONG THE SEARCH ACTUALLY RUNS — the server's number, not ours.
    --
    -- The search dialog counted down a hardcoded ten seconds and failed itself
    -- at zero. The real window is twelve seconds for a championship ladder and
    -- eight for a battle or a chamber (be_matatu's settleAfterMs), so on a
    -- ladder the dialog gave up two seconds BEFORE the server picked an
    -- opponent — and told the player nobody was available while a match was
    -- being made for them.
    --
    -- The last seconds of the window are a grace for answers already in
    -- flight, which is why zero on the ring means "choosing", not "nobody
    -- came": the decision lands after it.
    M.last_search_window = {
      settle_ms = tonumber(d.settleInMs) or 0,
      grace_ms  = tonumber(d.graceMs) or 0,
      invited   = tonumber(d.invited) or 0,
      at        = socket.gettime(),
    }
    emit("search_window", M.last_search_window)
  elseif t == "GAME_REQUEST_ROSTER" then
    -- WHO HAS JOINED THE SEARCH SO FAR.
    --
    -- Pushed to the requester as each invitee accepts, so the dialog can show
    -- the shortlist filling up instead of a spinner that says nothing until a
    -- board appears. `chosenId` is null on every push but the last: FINDING
    -- somebody is not CHOOSING them, and naming the first arrival as the
    -- opponent would be the first-to-tap rule again, just drawn rather than
    -- enforced.
    local accepted = {}
    for _, a in ipairs((type(d) == "table" and d.accepted) or {}) do
      accepted[#accepted + 1] = {
        userId    = tostring(a.userId or ""),
        username  = tostring(a.username or "Player"),
        avatar    = tonumber(a.avatar) or 1,
        skillTier = a.skillTier and tostring(a.skillTier) or nil,
      }
    end
    M.last_search_roster = {
      accepted     = accepted,
      count        = tonumber(d.count) or #accepted,
      remaining_ms = tonumber(d.remainingMs) or 0,
      chosen_id    = (d.chosenId ~= nil and tostring(d.chosenId) ~= "") and tostring(d.chosenId) or nil,
    }
    emit("search_roster", M.last_search_roster)
  elseif t == "GAME_REQUEST_CANCELLED" then
    emit("game_request_cancelled", d.requestId or d.id or "")
  elseif t == "GAME_REQUEST_DECLINED" then
    -- `message` FIRST, `reason` ONLY AS A FALLBACK.
    --
    -- The backend sends both on this message and they are different things:
    -- `reason` is a machine token it branches on and logs ("NO_OPPONENT"),
    -- `message` is the sentence written for a player. Reading `reason` put the
    -- token itself on the search dialog.
    --
    -- `revoked` is passed on too. It marks the withdrawal of an invitation
    -- sent TO US by somebody else's broadcast, which is a completely different
    -- event from our own request being declined — see controller.script.
    emit(
      "game_request_declined",
      d.message or d.reason or "Declined",
      d.requestId or "",
      d.revoked == true
    )
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

      -- A RECONNECT CATCH-UP (d._replayId set — see handleIdentify.ts) IS
      -- PLAYED, not discarded.
      --
      -- It used to be dropped here on the reasoning that IDENTIFY has already
      -- rebuilt the board to the post-move state, so replaying the actions
      -- would double-apply them. The board did end up correct — and the player
      -- came back to a game that had silently changed under them, with no idea
      -- what the opponent had done. That is the whole reason the server queues
      -- these at all; handleIdentify.ts says so directly: the IDENTIFY resync
      -- "does not treat that passive resync the same way it treats a live MOVE
      -- — no card-play animation".
      --
      -- Replaying is safe because of two properties that hold specifically for
      -- these messages:
      --
      --   * missedMoves.set() REPLACES rather than appends, so a catch-up
      --     carries the most recent missed move only. Its gameState is
      --     therefore the CURRENT state, not a historical one — applying it
      --     cannot rewind the board the way a chronological replay would.
      --   * finalize_state_sync converges rather than deltas. sync_deck_size,
      --     stamp_deck, stamp_ai_hand and sync_my_hand all reconcile TO the
      --     carried state, so an action that was already applied is corrected
      --     rather than compounded.
      --
      -- The one thing that does not self-correct is the discard pile, which
      -- nothing reconciles — the animated card lands on a pile that already
      -- has it. handle_single_move trims it for replays; see `isReplay` there.
      local actions = gs.actions or {}
      -- Prefer the server's explicit `from` field (sent alongside the
      -- encrypted gameState) over the currentTurn-inequality heuristic —
      -- the heuristic breaks for Whot's turn-retaining special cards.
      local explicit_from = d.from
      local from_id = (explicit_from ~= nil and tostring(explicit_from) ~= "" and tostring(explicit_from))
        or derive_sender(gs)
      local is_replay = (d._replayId ~= nil and d._replayId ~= "")
      print(string.format("[PIPE-1] decoded from=%s actions=%d turn=%s suit=%s replay=%s",
        tostring(from_id), #actions, tostring(gs.currentTurn), tostring(gs.chosenSuit),
        tostring(is_replay)))
      pprint("[PIPE-1] gs.actions:", actions)
      -- OUR OWN MOVE, COME BACK TO US. That echo is the only confirmation the
      -- server ever sends that it applied what we sent. Anything else the
      -- server says about our move (a RESYNC, a NOT_YOUR_TURN, the round
      -- ending) is an answer too, and clears everything held, below.
      --
      -- Retires only what this echo actually PROVES, rather than everything.
      -- Several of our moves can be in flight at once, and one of them being
      -- applied says nothing about the ones behind it — the
      -- echoed state names which cards have left our hand, so that is what
      -- decides.
      if from_id ~= "" and tostring(from_id) == tostring(M.current_user_id) then
        retire_landed_moves(gs)
      end

      local processed = {
        _id = from_id, from = from_id, actions = actions,
        chosenSuit = gs.chosenSuit or "", gameState = gs,
        isReplay = is_replay,
      }
      emit("game_move", processed, gs)
    else
      print("[PIPE-1] DROPPED — gs decoded empty")
    end
  elseif t == "INBOX_UNREAD" then
    M.inbox_unread = tonumber(d.unread) or 0
    emit("inbox_unread", M.inbox_unread)
  elseif t == "INBOX_HISTORY" then
    M.last_inbox_page = {
      messages = d.messages or {},
      nextBefore = d.nextBefore,
      isFirstPage = d.isFirstPage == true,
    }
    M.inbox_unread = tonumber(d.unread) or M.inbox_unread or 0
    emit("inbox_history", M.last_inbox_page)
  elseif t == "INBOX_MESSAGE" then
    M.last_inbox_message = d.message
    M.inbox_unread = tonumber(d.unread) or ((M.inbox_unread or 0) + 1)
    emit("inbox_message", d.message, M.inbox_unread)
  elseif t == "INBOX_SENT" then
    -- The player's OWN message, echoed. Their line appears in the thread only
    -- once the server has it, which is what makes the bubble honest about
    -- whether support has actually received anything.
    M.last_inbox_sent = d
    emit("inbox_sent", d)
  elseif t == "TIMER_UPDATE" then
    -- THE SENDER'S CONFIRMATION, AND THE ONLY ONE THEY GET.
    --
    -- An ordinary move is echoed as a MOVE to the OPPONENT. The player who
    -- made it is answered with this and nothing else — turn, clock, penalty
    -- count — because they already animated it locally (moves/index.ts, the
    -- `else if (isOnline)` sender branch). It is sent to the mover alone and
    -- nowhere else, in all three games.
    --
    -- So it is the acknowledgement, and nothing was treating it as one. The
    -- held copy was retired by the MOVE echo, which for an ordinary move never
    -- comes back to us: only an AI-covered move, a reshuffle and a deck-drift
    -- resync are echoed to their own sender. Every ordinary move therefore sat
    -- in the held list until a refusal, the round ending or a reconnect
    -- cleared it — so the list filled with moves that had plainly landed, and
    -- past the cap the OLDEST was dropped, which is the one entry that might
    -- still have been genuinely unanswered.
    --
    -- The oldest is retired, not a matched one: this carries no hand to
    -- identify a move by, and the server answers in the order it was sent.
    if #M.pending_moves > 0
      and (d.from == nil or tostring(d.from) == tostring(M.current_user_id)) then
      table.remove(M.pending_moves, 1)
      M.pending_move = M.pending_moves[1]
    end
    emit("timer_update", d)
  elseif t == "PLAYER_READY" then
    emit("player_ready", d._id or "")
  elseif t == "PLAYER_DISCONNECTED" then
    -- Both the envelope and the payload go to DC, which reads whichever shape
    -- the deployed server actually sent and converts the grace DEADLINE into
    -- the seconds remaining. See modules/disconnect_events.lua.
    emit("player_disconnected", DC.parse_disconnect(d, message, now_s()))
  elseif t == "PLAYER_RECONNECTED" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
    local rc = DC.parse_reconnect(d, message)
    emit("player_reconnected", { player_id = rc.player_id, state = gs })
  elseif t == "EMOJI_MESSAGE" then
    emit("emoji", d._id or d.from or "", d.emoji or d.name or "", d.sound or "")
  elseif t == "GAME_STATE_SYNC" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
  elseif t == "NOT_YOUR_TURN" then
    -- The server declined to attribute a move to us because it is not our
    -- turn. Whatever we were holding is answered — resending it would be
    -- declined the same way, forever.
    clear_pending_move("server says it is not our turn")
    emit("not_your_turn", { game_id = tostring(d.gameId or ""),
                            current_turn = tostring(d.currentTurn or "") })
  elseif t == "RESYNC" then
    -- The backend rejected our move: our board drifted. Park the
    -- authoritative state and let the board rebuild itself.
    --
    -- The held move is dropped rather than retried: a RESYNC IS the server's
    -- answer to it, and it was a refusal. Retrying a move the server has
    -- already refused would refuse identically every time.
    clear_pending_move("server refused the move with a RESYNC")
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_state = gs
      emit("resync", { reason = tostring(d.reason or "") })
    end
  elseif t == "ROUND_COMPLETE" then
    -- The round this move belonged to is finished; there is nothing left for
    -- it to land on.
    clear_pending_move("round complete")
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then M.active_game_state = gs end
    emit("round_complete", gs)
  elseif t == "GAME_OVER" then
    clear_pending_move("game over")
    M.active_game_id = ""
    local results = {}
    local final_state = {}
    if type(d.gameState) == "table" and type(d.gameState.gameOverState) == "table" then
      final_state = d.gameState
      results = d.gameState.gameOverState
    elseif type(d.gameOverState) == "table" then
      results = d.gameOverState
    else
      -- Last resort: try to decrypt the gameState blob and pull gameOverState out.
      local gs = M.extract_game_state(d)
      final_state = gs
      if type(gs.gameOverState) == "table" then results = gs.gameOverState
      elseif next(gs) ~= nil then results = gs end
    end
    M.last_game_over = results

    -- THE HANDS AS THEY WERE WHEN THE GAME ENDED, kept apart from everything
    -- else on the message.
    --
    -- GAME_OVER carries the whole final gameState, hands included — it is the
    -- only authoritative account of what the opponent was actually holding —
    -- and all of it except gameOverState used to be thrown away here. The
    -- reveal at the end of a round then had to go looking, and its last resort
    -- was M.active_game_state.
    --
    -- That is wrong precisely when it matters. The server now sets the next
    -- round up before it broadcasts GAME_OVER, so by the time the reveal runs,
    -- active_game_state has routinely already been REPLACED by the NEXT round's
    -- state — a fresh deal, different cards, possibly a different number of
    -- them. The opponent's hand was flipped face-up showing cards from a round
    -- that had not been played yet, or (when the next state had no hand to read)
    -- showing the raw placeholders the face-down cards were spawned with. Both
    -- read to the player as "those are not the cards they had", and both only
    -- happen in the modes that continue: knockouts and tournaments.
    --
    -- Copied out card by card rather than kept by reference so this survives
    -- the next state overwriting anything, and stays small enough to be safe to
    -- hold: it is only ever read back directly, never posted.
    local final_hands = {}
    if type(final_state.players) == "table" then
      for pid, p in pairs(final_state.players) do
        if type(p) == "table" and type(p.hand) == "table" then
          local hand = {}
          for i, c in ipairs(p.hand) do
            if type(c) == "table" then hand[i] = { v = c.v, s = c.s } end
          end
          final_hands[tostring(pid)] = hand
        end
      end
    end
    M.last_game_over_hands = final_hands
    -- The backend settles wallets before sending GAME_OVER and ships the
    -- post-game balances in gameOverState.balances — apply ours immediately
    -- so every screen shows the updated balance there and then (the IDENTIFY
    -- refresh is fire-and-forget behind a nearby-rank aggregation, and is
    -- suppressed outright for tournament round-continues).
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
    -- Our own W/L form after this game, keyed by user id in
    -- gameOverState.recentForm (endGame.ts's formByPlayer). Applied here for
    -- the same reason as balance and rank: the lobby's "YOUR CURRENT FORM"
    -- panel draws straight off current_user_data, so without this it keeps
    -- showing the form from before the game until some later identify happens
    -- to refresh it.
    --
    -- A missing or non-table entry leaves the cached form alone rather than
    -- replacing it with an empty one — the backend omits the key for games it
    -- never settled (no-shows, failed saves), and blanking the panel on those
    -- would be worse than showing a form that is one game stale.
    if type(results.recentForm) == "table" then
      local mine = results.recentForm[tostring(M.current_user_id)]
      if type(mine) == "table" then
        M.current_user_data.recentForm = mine
        user_touched = true
      end
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
    -- The server has ALREADY reset points and credited coinsEarned/
    -- savingCoinsEarned into this player's account by the time this message
    -- arrives (completeSeason's own bulkWrite, be_matatu side) — but nothing
    -- here ever told current_user_data, which is what every screen OTHER
    -- than the results dialog itself reads (the BAL/PTS/SAVINGS panel in
    -- online_right.lua, in particular). The results dialog showed the right
    -- numbers because it reads straight off `d`; everywhere else kept
    -- showing the pre-reset totals until the next full reconnect, which for
    -- a session that stays open across the boundary could be hours away —
    -- indistinguishable, from the player's seat, from "points never clear".
    --
    -- Mirrors the server's own update exactly: points is a $set (so this is
    -- an assignment, not an add — rewardPointsEarned IS the new total, 0
    -- unless a mission or rank bonus paid points alongside it), balance and
    -- savingCoins are $inc (so these add the earned amount, same as the
    -- dialog's own "+N" figures already do).
    if M.current_user_data then
      M.current_user_data.points = d.rewardPointsEarned or 0
      M.current_user_data.balance = (M.current_user_data.balance or 0) + (d.coinsEarned or 0)
      M.current_user_data.savingCoins = (M.current_user_data.savingCoins or 0) + (d.savingCoinsEarned or 0)
    end
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
  -- ── PARTY ────────────────────────────────────────────────────────────────
  -- The open-table list, already filtered to what THIS player can join and
  -- sorted soonest-to-close first. Replaced wholesale rather than merged: an
  -- empty list is a real message and is how a table that filled, expired or
  -- was called off leaves the lobby. Merging would leave dead tables on screen
  -- that tap through to a refusal.
  elseif t == "PARTY_AVAILABLE" then
    local list = {}
    if type(d) == "table" and type(d.parties) == "table" then
      for i, p in ipairs(d.parties) do list[i] = p end
    end
    M.available_parties = list
    emit("party_available", list)

  -- Our own table changed: somebody sat down or stood up. partyView sends the
  -- seats in join order, so a screen diffing two rosters can tell WHICH chair
  -- just filled and animate only that one.
  elseif t == "PARTY_ROSTER" then
    if type(d) == "table" then
      M.current_party = d
      M.last_party_error = nil

      -- SEATS, AS A SEARCH ROSTER — so a party fills the same dialog a
      -- tournament does.
      --
      -- The two are the same thing from the player's side: you opened
      -- something, and you are watching people arrive one by one. Tournaments
      -- already have a dialog for exactly that, with the arrival animation and
      -- the per-player sound, driven off GAME_REQUEST_ROSTER's `accepted`
      -- list. Rather than draw a second one, party seats are translated into
      -- the same shape and the same dialog is fed.
      --
      -- OUR OWN SEAT IS DROPPED. The tournament roster is everybody who
      -- accepted the requester's invite — it never contains the requester. A
      -- party's seats DO include the host, so leaving it in would animate the
      -- player into their own waiting room.
      local accepted = {}
      for _, seat in ipairs(type(d.seats) == "table" and d.seats or {}) do
        local sid = tostring(seat.userId or "")
        if sid ~= "" and sid ~= tostring(M.current_user_id) then
          accepted[#accepted + 1] = {
            userId    = sid,
            username  = tostring(seat.username or "Player"),
            avatar    = tonumber(seat.avatar) or 1,
            skillTier = seat.skillTier and tostring(seat.skillTier) or nil,
          }
        end
      end
      local closes = tonumber(d.closesAt) or 0
      M.last_search_roster = {
        accepted     = accepted,
        count        = #accepted,
        remaining_ms = closes > 0 and math.max(0, closes - (socket.gettime() * 1000)) or 0,
        -- No chosen_id, ever. A party takes everybody who sat down; there is
        -- nobody to single out, and naming one would draw a decision the mode
        -- does not make.
        chosen_id    = nil,
      }
      emit("search_roster", M.last_search_roster)
      emit("party_roster", d)
    end

  -- The table is dealing. Carries the game state exactly as an ordinary match
  -- does, so this hands off to the same board.
  elseif t == "PARTY_STARTING" then
    M.current_party = nil
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_id = gs.gameId or gs.id or d.gameId or ""
      M.active_game_state = gs
      emit("party_starting", d)
      -- Deliberately the SAME event an ordinary match start emits. Everything
      -- that routes to the board, clears the lobby and starts the clock is
      -- already listening for it, and a party is a game like any other once
      -- the cards are out.
      emit("game_start", gs)
    else
      -- No state means the deal failed after the table was told it was
      -- starting. Say nothing about a game; the CANCELLED that follows carries
      -- the refund.
      emit("party_starting", d)
    end

  -- The table was called off, or we left it. `refunded` is what actually went
  -- back — zero when the entry stays with the table, which is the case when a
  -- player leaves a seat they held.
  elseif t == "PARTY_CANCELLED" then
    M.current_party = nil
    if type(d) == "table" then emit("party_cancelled", d) end

  -- A refusal we have to show: the table filled, we cannot afford it, we are
  -- already seated. Every one of these is something the player has to be TOLD
  -- — a tap that appears to do nothing is the worst answer a full table can
  -- give.
  elseif t == "PARTY_ERROR" then
    M.last_party_error = d
    emit("party_error", d or {})

  -- One seat dropped out mid-hand and the table plays on. A duel would be
  -- over; this is not, so the board keeps running and just loses a player.
  elseif t == "PARTY_PLAYER_OUT" then
    if type(d) == "table" then
      if M.active_game_state and type(M.active_game_state.players) == "table" then
        local p = M.active_game_state.players[tostring(d.playerId or "")]
        if type(p) == "table" then p.eliminated = true end
      end
      if d.currentTurn and M.active_game_state then
        M.active_game_state.currentTurn = d.currentTurn
      end
      emit("party_player_out", d)
    end

  -- A capped party scored a hand and dealt the next one. NOT a game over: the
  -- board keeps running, with fresh cards and updated running totals. Handled
  -- as a state replacement so the seats, the counts and whoever just went out
  -- on the cap all redraw from one message.
  elseif t == "PARTY_NEXT_HAND" then
    local gs = M.extract_game_state(d)
    if next(gs) ~= nil then
      M.active_game_id = gs.gameId or gs.id or d.gameId or ""
      M.active_game_state = gs
      -- Carries the state, so the board re-deals through its ordinary start
      -- path (online_handler listens for this) rather than through game_move,
      -- which describes a card being played and cannot express a fresh hand.
      emit("party_next_hand", d, gs)
    end

  -- The table finished. Carries the whole finishing order and the pot rather
  -- than a winner and a loser — see partyPlacements.ts on the server.
  elseif t == "PARTY_GAME_OVER" then
    M.last_party_result = d
    M.active_game_id = ""
    M.active_game_state = nil
    if type(d) == "table" then
      -- Our own new form, applied straight away for the same reason the
      -- two-player GAME_OVER does it: the lobby form panel reads
      -- current_user_data and would otherwise sit stale until an identify.
      for _, place in ipairs(type(d.placements) == "table" and d.placements or {}) do
        if tostring(place.playerId or "") == tostring(M.current_user_id) then
          local form = M.current_user_data.recentForm
          if type(form) ~= "table" then form = {} end
          table.insert(form, 1, place.won and "W" or "L")
          while #form > 5 do table.remove(form) end
          M.current_user_data.recentForm = form
          emit("user_updated", M.current_user_data)
          break
        end
      end
      emit("party_game_over", d)
    end

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
  local ceiling = waiting and WAITING_RECONNECT_MAX or config.MAX_RECONNECT_DELAY
  current_reconnect_delay = math.min(config.INITIAL_RECONNECT_DELAY * (config.RECONNECT_BACKOFF ^ (reconnect_attempts - 1)), ceiling)
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
  -- falls back to v for builds older than the stamping change. `pkg` is
  -- which of matatu's two shipped packages this is (com.matatu.champ vs
  -- com.matatu.nap) — needed because a version NUMBER alone doesn't
  -- reliably say which package sent it (see appVersion.ts's
  -- resolveMatatuVariant); dots are safe unescaped in a query string.
  local url = config.WS_URL .. "/?deviceId=" .. tostring(device_id)
      .. "&v=" .. config.APP_VERSION
      .. "&b=" .. tostring(config.APP_BUILD or 0)
      .. "&pkg=" .. tostring(config.APP_PACKAGE or "")
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

function M.queue_announcements(list)
  if type(list) ~= "table" then return end
  for _, item in ipairs(list) do
    M.announcement_inbox[#M.announcement_inbox + 1] = item
  end
end

function M.take_announcements()
  local out = M.announcement_inbox
  M.announcement_inbox = {}
  return out
end

return M