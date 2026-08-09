-- ONE STATE MACHINE FOR THE WHOLE CONNECTION.
--
-- WHY THIS EXISTS
--
-- Being online was sixteen booleans and four Defold timers, mutated from about
-- fifteen places across three files:
--
--   socket_connected  is_connecting  is_identified  is_manual_disconnect
--   reconnect_exhausted  update_required  app_offline  device_identity_refused
--   pending_identity  identify_tries  reconnect_attempts  identify_ok
--   reconnect_handle  identify_timer  keep_alive_handle  connecting_since
--
-- Every connection bug reported over this work had the same shape, and it was
-- never a hard problem in itself:
--
--   * two of them disagreed
--       - is_identified true with socket_connected false made the planner
--         return "idle" for ever, with nothing left to reopen anything
--       - reconnect_exhausted was set and the planner never read it, so it
--         reconnected once a second behind a dialog saying it had given up
--       - the UI decided "RECONNECTING" from a `disconnected` event that
--         on_disconnected emits BEFORE deciding not to reconnect
--   * or one of them got stuck with nothing that could clear it
--       - is_waiting_for_server_response gated every watchdog and had none
--       - a raise inside the keep-alive timer killed the timer, and with it
--         the zombie check that was the only thing watching that socket
--       - socket_connected stuck true made connect() and RETRY both no-ops
--   * or a recovery re-ran the identical action on the identical socket
--       - IDENTIFY unanswered -> re-send IDENTIFY on the same socket, ~25
--         times, then give up
--
-- None of those are subtle once you see them. They were invisible because no
-- single place knew what the connection was doing, so no single place could be
-- wrong in a way anybody could point at.
--
-- THE FOUR DECISIONS THIS MAKES
--
-- 1. ONE STATE VARIABLE. Not sixteen. Two flags cannot disagree if there is
--    only one. Everything the app reads (socket_connected, is_identified,
--    reconnect_exhausted, the UI status) is DERIVED from it, never stored
--    alongside it.
--
-- 2. NO TIMERS. Every timeout is seconds accumulated in `tick`. A Defold timer
--    can be cancelled, can die with the callback that raised inside it, and
--    can be left dangling by a code path that forgot it — and all three of
--    those happened here. A number that only ever goes up cannot.
--
-- 3. NO I/O. Transitions RETURN a list of effects — open_socket, close_socket,
--    send_identify — and the caller performs them. So the thing that decides
--    and the thing that acts cannot drift apart, and the whole machine is
--    testable by calling functions, with no engine, no sockets and no clock.
--
-- 4. THE MACHINE CONDEMNS THE SOCKET. An IDENTIFY that goes unanswered is not
--    a reason to send another IDENTIFY; it is evidence about the socket. There
--    is exactly one path from every failure — close, back off, open a new one —
--    and no call site can invent its own.
--
-- WHAT THIS IS NOT
--
-- It is not the message catalogue. Parsing, decryption, the game-state pipe,
-- tournaments, emoji, payments: none of that is here and none of it changed.
-- That half has not been the source of a single instability report, and
-- rewriting working code to make a diff look thorough is how you turn one
-- broken thing into five.
local M = {}

-- ── STATES ──────────────────────────────────────────────────────────────────
--
-- The whole connection, as seven values.
M.IDLE            = "idle"             -- nobody to be; no socket wanted
M.CONNECTING      = "connecting"       -- a socket attempt is in flight
M.IDENTIFYING     = "identifying"      -- socket open, IDENTIFY awaiting an answer
M.READY           = "ready"            -- identified; this is the goal
M.BACKOFF         = "backoff"          -- waiting before the next attempt
M.GIVEN_UP        = "given_up"         -- budget spent; only an explicit retry restarts
M.BLOCKED         = "blocked"          -- the server refuses this ACCOUNT
M.UPDATE_REQUIRED = "update_required"  -- the server refuses this BUILD

-- ── TUNING ──────────────────────────────────────────────────────────────────

--- A connect attempt that reports nothing at all by now is hung. Longer than a
--- real handshake on a congested cell (five seconds of TCP+TLS is
--- unremarkable) and just past the extension's own 8s timeout, so this only
--- ever catches the case where NO event arrives.
M.CONNECT_TIMEOUT = 10.0

--- How long to wait for an IDENTIFY reply before sending another.
M.IDENTIFY_TIMEOUT = 2.5

--- How many IDENTIFYs one socket is worth. After this the SOCKET is the
--- suspect, not the message — see decision 4 above.
M.IDENTIFY_TRIES = 3

--- Nothing inbound for this long means the link is dead however healthy it
--- claims to be. Must comfortably exceed the keep-alive interval.
M.SILENCE_TIMEOUT = 13.0

--- Attempts before giving up and putting a RETRY in front of the player.
M.MAX_ATTEMPTS = 50

--- Backoff: 1s doubling by 1.5, capped. The cap is low while somebody is
--- waiting to get online and high when the app is merely idle — a player
--- staring at CONNECTING is not served by a thirty-second gap, and a server
--- that is down is not helped by every idle client knocking every second.
M.BACKOFF_BASE = 1.0
M.BACKOFF_FACTOR = 1.5
M.BACKOFF_CAP_WAITING = 8.0
M.BACKOFF_CAP_IDLE = 30.0
M.BACKOFF_JITTER = 0.2

--- How long a refused ACCOUNT is left alone before spending one probe.
M.BLOCKED_RECHECK = 15 * 60

-- ── CONSTRUCTION ────────────────────────────────────────────────────────────

--- `rand` is injectable so the backoff is deterministic under test. Nothing
--- else in here is non-deterministic, deliberately.
function M.new(opts)
    opts = opts or {}
    return {
        state = M.IDLE,
        -- What we want to be. nil means signed out.
        identity = nil,
        -- Seconds in the current state. The ONLY clock.
        elapsed = 0,
        -- IDENTIFYs sent on the CURRENT socket.
        identify_tries = 0,
        -- Consecutive failed attempts, for the backoff and the budget.
        attempts = 0,
        -- Seconds since anything at all arrived on the socket.
        since_rx = 0,
        -- How long the current backoff is meant to last.
        backoff_for = 0,
        -- Seconds since the account block went up.
        blocked_for = 0,
        -- True while the ONE attempt a blocked account is allowed is in
        -- flight, so its failure returns to silence instead of falling into
        -- the ordinary backoff.
        probing = false,
        rand = opts.rand or math.random,
    }
end

-- ── DERIVED VIEWS ───────────────────────────────────────────────────────────
--
-- Everything the rest of the app used to keep as its own boolean. Derived, so
-- it cannot be stale and cannot disagree with the state.

function M.socket_connected(fsm)
    return fsm.state == M.IDENTIFYING or fsm.state == M.READY
end

function M.is_identified(fsm)
    return fsm.state == M.READY
end

function M.has_given_up(fsm)
    return fsm.state == M.GIVEN_UP
end

--- Is an attempt or an exchange genuinely in flight right now? The spinner is
--- gated on this: an animated one not backed by an attempt is a lie, and it
--- was the whole of one report.
function M.is_working(fsm)
    return fsm.state == M.CONNECTING
        or fsm.state == M.IDENTIFYING
        or fsm.state == M.BACKOFF
end

--- What to tell the player. One string, from one state.
function M.status(fsm)
    local s = fsm.state
    if s == M.UPDATE_REQUIRED then return "update_required" end
    if s == M.BLOCKED then return "blocked" end
    if s == M.READY then return "online" end
    if s == M.IDLE then return "signed_out" end
    if s == M.GIVEN_UP then return "offline" end
    if s == M.BACKOFF then return "reconnecting" end
    return "connecting"   -- CONNECTING and IDENTIFYING
end

-- ── TRANSITIONS ─────────────────────────────────────────────────────────────

local function backoff_delay(fsm)
    local waiting = fsm.identity ~= nil
    local cap = waiting and M.BACKOFF_CAP_WAITING or M.BACKOFF_CAP_IDLE
    local raw = M.BACKOFF_BASE * (M.BACKOFF_FACTOR ^ math.max(0, fsm.attempts - 1))
    local delay = math.min(raw, cap)
    -- Jitter applied AFTER the clamp, so it also spreads the cap — which is
    -- exactly where every client is pinned to the same number and the spread
    -- matters most.
    return delay * (1 + (fsm.rand() * 2 - 1) * M.BACKOFF_JITTER)
end

--- Move to `next`, resetting the per-state clock and emitting the effects the
--- caller must perform. Every transition in this file goes through here, so
--- there is exactly one place that can change the state.
local function go(fsm, next_state, effects)
    effects = effects or {}
    local changed = fsm.state ~= next_state
    fsm.state = next_state
    fsm.elapsed = 0
    if changed then
        effects[#effects + 1] = { "status", M.status(fsm) }
    end
    return effects
end

--- The one place that decides what to do when there is no usable socket.
--- Budget spent -> stop and put a RETRY in front of the player. Otherwise back
--- off. Nothing else in this file opens a socket.
local function retreat(fsm, effects)
    effects = effects or {}
    fsm.identify_tries = 0
    if fsm.identity == nil then
        return go(fsm, M.IDLE, effects)
    end

    -- A PROBE THAT FAILS GOES BACK TO BEING QUIET.
    --
    -- The recheck spends ONE attempt so an account whose block was lifted can
    -- discover that. Without this the probe's failure fell into the ordinary
    -- backoff and the app left the blocked state for good on its first try —
    -- turning "one request every fifteen minutes" into the reconnect loop the
    -- whole latch exists to prevent. Caught by the test asserting exactly one
    -- attempt per window; it counted five.
    if fsm.probing then
        fsm.probing = false
        fsm.blocked_for = 0
        fsm.attempts = 0
        return go(fsm, M.BLOCKED, effects)
    end

    fsm.attempts = fsm.attempts + 1
    if fsm.attempts > M.MAX_ATTEMPTS then
        effects[#effects + 1] = { "gave_up" }
        return go(fsm, M.GIVEN_UP, effects)
    end
    fsm.backoff_for = backoff_delay(fsm)
    return go(fsm, M.BACKOFF, effects)
end

--- Open a socket now. Only reachable from states that have none.
local function launch(fsm, effects)
    effects = effects or {}
    effects[#effects + 1] = { "open_socket" }
    fsm.since_rx = 0
    return go(fsm, M.CONNECTING, effects)
end

-- ── EVENTS ──────────────────────────────────────────────────────────────────
--
-- Each returns a list of effects. `{}` means "nothing to do", which is a
-- perfectly good answer and the commonest one.

--- Who we want to be. Passing nil signs out.
---
--- Calling this while already READY as the SAME identity is a no-op — the app
--- calls identify() from several places (boot, sign-in, resume, the recovery
--- path) and every one of them used to be able to fire a redundant IDENTIFY.
function M.set_identity(fsm, identity)
    if identity == nil then
        fsm.identity = nil
        fsm.attempts = 0
        return go(fsm, M.IDLE, { { "close_socket" } })
    end

    local same = fsm.identity ~= nil and fsm.identity == identity
    fsm.identity = identity

    if fsm.state == M.UPDATE_REQUIRED then return {} end
    -- A NEW identity is worth asking a server that refused the old one.
    if fsm.state == M.BLOCKED then
        if same then return {} end
        fsm.blocked_for = 0
        fsm.attempts = 0
        fsm.probing = false
        return launch(fsm)
    end
    if fsm.state == M.READY and same then return {} end

    fsm.attempts = 0
    if fsm.state == M.IDLE or fsm.state == M.GIVEN_UP or fsm.state == M.BACKOFF then
        return launch(fsm)
    end
    if fsm.state == M.IDENTIFYING then
        -- Socket is up and the identity changed: ask again, now.
        fsm.identify_tries = 1
        fsm.elapsed = 0
        return { { "send_identify" } }
    end
    if fsm.state == M.READY then
        fsm.identify_tries = 1
        return go(fsm, M.IDENTIFYING, { { "send_identify" } })
    end
    return {}   -- CONNECTING: it will be sent when the socket opens
end

function M.socket_open(fsm)
    if fsm.state ~= M.CONNECTING then
        -- A socket we already abandoned reporting in late. Closing it is the
        -- point: left open it goes on delivering events for a connection
        -- nobody is reading, and its eventual close would tear down the
        -- replacement.
        return { { "close_socket" } }
    end
    fsm.since_rx = 0
    fsm.identify_tries = 1
    return go(fsm, M.IDENTIFYING, { { "send_identify" } })
end

function M.socket_closed(fsm)
    if fsm.state == M.IDLE or fsm.state == M.BLOCKED
       or fsm.state == M.UPDATE_REQUIRED or fsm.state == M.GIVEN_UP then
        return {}
    end
    return retreat(fsm)
end

function M.identify_ok(fsm)
    if fsm.state ~= M.IDENTIFYING then return {} end
    -- The server accepting us is the one event that proves a block no longer
    -- applies, so the probe flag goes with it.
    fsm.probing = false
    fsm.attempts = 0
    fsm.identify_tries = 0
    fsm.since_rx = 0
    return go(fsm, M.READY)
end

--- The server said no to this identity. Not a network fault, so retrying the
--- same thing is pointless — the caller escalates (a fresh sign-in).
function M.identify_refused(fsm)
    fsm.identify_tries = 0
    return go(fsm, M.IDLE, { { "close_socket" }, { "identity_refused" } })
end

--- Anything arriving on the socket proves the link is alive.
function M.rx(fsm)
    fsm.since_rx = 0
    return {}
end

--- A send failed. Whatever any flag says, that is a dead socket.
function M.send_failed(fsm)
    if not M.socket_connected(fsm) then return {} end
    return retreat(fsm, { { "close_socket" } })
end

--- The player asked for it. A deliberate tap outranks whatever we are holding:
--- being asked to retry IS the evidence that it does not work.
function M.retry(fsm)
    if fsm.state == M.UPDATE_REQUIRED then return {} end
    fsm.attempts = 0
    fsm.identify_tries = 0
    if fsm.state == M.BLOCKED then
        -- Spend the probe now rather than making them wait out the window.
        -- Deliberate, so it is NOT flagged as a probe: a player who pressed
        -- RETRY has asked for the ordinary retry behaviour.
        fsm.blocked_for = 0
    end
    fsm.probing = false
    if fsm.identity == nil then return go(fsm, M.IDLE) end
    return launch(fsm, { { "close_socket" } })
end

function M.set_blocked(fsm, seconds_ago)
    fsm.blocked_for = tonumber(seconds_ago) or 0
    if fsm.state == M.BLOCKED then return {} end
    return go(fsm, M.BLOCKED, { { "close_socket" } })
end

function M.clear_blocked(fsm)
    if fsm.state ~= M.BLOCKED then return {} end
    fsm.blocked_for = 0
    fsm.probing = false
    fsm.attempts = 0
    if fsm.identity == nil then return go(fsm, M.IDLE) end
    return launch(fsm)
end

--- Terminal. Nothing but a new binary changes the answer, so this never
--- reopens a socket and never backs off.
function M.set_update_required(fsm)
    if fsm.state == M.UPDATE_REQUIRED then return {} end
    return go(fsm, M.UPDATE_REQUIRED, { { "close_socket" } })
end

-- ── THE CLOCK ───────────────────────────────────────────────────────────────

--- Every timeout in the connection, in one function, driven by elapsed time.
---
--- This replaces four Defold timers. A timer can be cancelled by a path that
--- forgets to clear its handle, can be killed by a raise inside its own
--- callback, and can outlive the state it was armed for. All three happened.
--- Seconds that only ever go up cannot do any of them.
function M.tick(fsm, dt)
    dt = tonumber(dt) or 0
    fsm.elapsed = fsm.elapsed + dt
    local s = fsm.state

    if s == M.CONNECTING then
        if fsm.elapsed >= M.CONNECT_TIMEOUT then
            -- No event either way. Force it down and try again rather than
            -- waiting on something that is not coming.
            return retreat(fsm, { { "close_socket" } })
        end
        return {}
    end

    if s == M.IDENTIFYING then
        fsm.since_rx = fsm.since_rx + dt
        if fsm.since_rx >= M.SILENCE_TIMEOUT then
            return retreat(fsm, { { "close_socket" } })
        end
        if fsm.elapsed >= M.IDENTIFY_TIMEOUT then
            if fsm.identify_tries < M.IDENTIFY_TRIES then
                fsm.identify_tries = fsm.identify_tries + 1
                fsm.elapsed = 0
                return { { "send_identify" } }
            end
            -- THE SOCKET IS THE SUSPECT NOW, NOT THE MESSAGE. Three sends
            -- ignored on a link that is otherwise answering is not something a
            -- fourth send fixes. Reported as ~25 IDENTIFYs into one socket.
            return retreat(fsm, { { "close_socket" }, { "identify_timeout" } })
        end
        return {}
    end

    if s == M.READY then
        fsm.since_rx = fsm.since_rx + dt
        if fsm.since_rx >= M.SILENCE_TIMEOUT then
            return retreat(fsm, { { "close_socket" } })
        end
        return {}
    end

    if s == M.BACKOFF then
        if fsm.elapsed >= fsm.backoff_for then return launch(fsm) end
        return {}
    end

    if s == M.BLOCKED then
        fsm.blocked_for = fsm.blocked_for + dt
        if fsm.blocked_for >= M.BLOCKED_RECHECK then
            -- One probe. The latch stays up; only the server accepting an
            -- identify takes it down.
            fsm.blocked_for = 0
            if fsm.identity ~= nil then
                fsm.probing = true
                return launch(fsm)
            end
        end
        return {}
    end

    -- IDLE, GIVEN_UP, UPDATE_REQUIRED: nothing is measured, because nothing
    -- is going to happen without an event from outside.
    return {}
end

--- A one-line description for the log. Every reported connection problem cost
--- time because the log said what happened without saying what the connection
--- thought it was doing.
function M.describe(fsm)
    return string.format(
        "%s (%.1fs, attempts=%d, identify=%d/%d, silent=%.1fs, identity=%s%s)",
        fsm.state, fsm.elapsed, fsm.attempts, fsm.identify_tries,
        M.IDENTIFY_TRIES, fsm.since_rx, tostring(fsm.identity ~= nil),
        fsm.probing and ", probing" or "")
end

return M
