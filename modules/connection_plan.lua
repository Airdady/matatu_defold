-- modules/connection_plan.lua
-- THE ONE PLACE THAT DECIDES WHAT THE CONNECTION SHOULD DO NEXT.
--
-- THE MESS THIS REPLACES
--
-- "Being signed in" was a sequence that five different things had to perform
-- in the right order, and nobody owned it:
--
--   controller.script   identify_and_connect(user): identify() then connect()
--   websocket_manager   pending_identity, queued if the socket is not up yet
--   on_connected        sends the queued IDENTIFY
--   the watchdog        resends it three times, then gives up
--   schedule_reconnect  reopens the socket, on its own backoff
--
-- Each step is fine and the whole is not, because every one of them assumes
-- the step before it happened. When any assumption breaks there is no
-- component whose job is to notice.
--
-- The one that shipped: M.connect() no-ops while `is_connecting` is true, and
-- `is_connecting` is cleared ONLY by on_connected and on_disconnected. If the
-- socket attempt neither connects nor reports a failure — a hung TLS
-- handshake, an OEM silently dropping the socket, the app suspending
-- mid-connect — that flag stays true for the rest of the process. From then
-- on connect() is permanently a no-op, schedule_reconnect never runs (it only
-- fires from on_disconnected), and the queued IDENTIFY sits there. Meanwhile
-- the identify watchdog burns its three tries doing nothing, because its
-- resend is itself guarded on `socket_connected`.
--
-- That is the reported symptom exactly: POST /auth/firebase returns 200, the
-- app has every field it needs, and IDENTIFY is never sent. Most likely on a
-- FIRST login, because that is when a fresh socket is opened straight after a
-- token fetch and an HTTPS round trip, with the radio at its busiest.
--
-- THE REPLACEMENT
--
-- Stop sequencing. Record who we want to be, and let one reconciler run on a
-- timer until the world matches: connect if there is no socket, send IDENTIFY
-- if there is a socket but no identity, and force a hung attempt down so it
-- can be retried. It cannot deadlock, because it re-derives what to do from
-- observable state every tick instead of relying on an event that may never
-- arrive.
local M = {}

-- How long a connect attempt may sit in flight before we call it hung.
--
-- THIS ONE MUST BE LONGER THAN A REAL HANDSHAKE, and it is the only constant
-- here where being aggressive backfires completely.
--
-- It was 3.5s, on the reasoning that a handshake takes less than that. On a
-- congested cell it does not: five seconds of TCP+TLS is unremarkable. And the
-- failure is not "one slow connect" — it is permanent. Every attempt gets torn
-- down at 3.5s, the replacement takes just as long and is torn down too, and a
-- player on a slow link never gets online at all. That is measured, not
-- feared: tools/test_first_login_timing.lua's slow-handshake case goes from
-- "identified at 5s" to "never" at 3.5s.
--
-- It hid behind a second bug for a while. Abandoned attempts were not closed,
-- so the "hung" socket completed a moment later anyway and the app limped on
-- with two live connections. Closing them properly is what made the starvation
-- visible.
--
-- The extension is given timeout = 8000ms, so a connect that is genuinely
-- going to fail reports by then on its own. This is purely the backstop for
-- the case where NO event ever arrives, and 10s sits just above the
-- extension's own contract: late enough never to kill a handshake that was
-- going to resolve either way, early enough that a true hang costs seconds.
M.CONNECT_STALL_SECONDS = 10

-- How long to wait for an IDENTIFY reply before sending another.
--
-- Deliberately fast (2.5s) so unanswered IDENTIFY messages are retried immediately
-- instead of leaving the UI hanging.
M.IDENTIFY_RESEND_SECONDS = 2.5

--- What the connection should do right now.
--
-- @param s  observable state:
--    identity          who we want to be (nil when signed out)
--    update_required   the build is refused; nothing is worth trying
--    app_offline       the ACCOUNT is refused; nothing is worth trying yet
--    app_offline_recheck  the recheck window is open: allow ONE attempt, so a
--                      block that has since been lifted can be discovered
--    socket_connected  the socket is up
--    is_connecting     an attempt is in flight
--    is_identified     the server has accepted us
--    connecting_for    seconds the current attempt has been in flight
--    since_identify    seconds since IDENTIFY was last sent
--    has_cached_identity  a saved session exists on disk
--    reconnect_scheduled  a retry is already on the clock
--    has_device_identity  the app has a usable device id
--    device_identity_refused  the server has said it does not know this device
-- @return "idle"    nothing is wanted
--         "adopt"   no identity in memory, but one is cached: load it
--         "adopt_device" nothing cached either: identify by device id
--         "connect" open the socket
--         "identify" send IDENTIFY
--         "unstick" the attempt has hung: force it down, then reconnect
--         "wait"    something is legitimately in flight
function M.next_action(s)
    s = s or {}

    -- FIRST, because it outranks everything including adopting a session.
    -- Every reconnect re-runs the handshake that produced the refusal, so the
    -- loop would only burn battery behind the update screen — and adopting a
    -- cached identity to do it with is worse, not better.
    if s.update_required then return "idle" end

    -- SAME RANK, DIFFERENT DURATION: the server refuses this ACCOUNT.
    --
    -- connect() refuses while the latch is up, but refusing there is not
    -- enough on its own — this planner is what DRIVES connecting, and while it
    -- knew nothing about the latch it went on deciding "adopt_device", then
    -- "connect", every single tick. Each decision called identify(), which
    -- restarts this loop immediately rather than waiting for the next tick, so
    -- it did not even cost one second per round: it was a spin, refused one
    -- call deeper every time, for as long as the app was open.
    --
    -- Unlike update_required this is NOT permanent, and that difference is the
    -- whole reason it is a window rather than an "idle". A build the server has
    -- outgrown cannot become acceptable without a new binary, so there is
    -- nothing to re-ask. A block can be lifted server-side with nothing
    -- happening on the phone at all — and if the app never asks again, an
    -- account that was unblocked can never come back, no matter how long the
    -- player waits or how often they reopen it.
    --
    -- So: silence, then exactly one attempt when the window comes round.
    -- app_offline_recheck is what says the window is open (see
    -- websocket_manager's APP_OFFLINE_RECHECK_SECONDS).
    if s.app_offline and not s.app_offline_recheck then return "idle" end

    -- Nobody to be YET, but a session on disk. Adopt it.
    --
    -- This is what makes "the app is open and there is a cached user" enough,
    -- on its own, to get signed in. Previously the identity only existed if
    -- some controller path had remembered to call identify() — so whether
    -- IDENTIFY ever fired depended on which route the app happened to take
    -- through boot, resume, a failed sign-in or a cleared flag. Sourcing it
    -- from the cache here makes it a property of the state instead of of the
    -- path.
    if not s.identity then
        if s.has_cached_identity then return "adopt" end
        -- NOTHING CACHED, BUT THE APP STILL KNOWS ITS OWN DEVICE.
        --
        -- The device id is generated on first run, is already stored on the
        -- User document, and does not expire — so for a returning player it
        -- identifies them exactly as well as their user id does. Sending it is
        -- what makes a cold, cacheless open work at all: a fresh install after
        -- a reinstall, a cleared cache, or a session wiped by a transient
        -- failure used to leave the client with NOTHING to send, so it sent
        -- nothing and the player sat on CONNECTING for ever.
        --
        -- Once the server has said it does not know this device, stop asking.
        -- The answer will not change until somebody signs in, and a sign-in
        -- clears the flag by identifying with a real user id.
        if s.has_device_identity and not s.device_identity_refused then
            return "adopt_device"
        end
        -- Nobody to be. A signed-out app holds no socket open.
        return "idle"
    end

    -- Done. This is the state the whole module exists to reach.
    --
    -- BOTH HALVES, and the socket half is not decoration. is_identified means
    -- "the server accepted us", which is a statement about a SOCKET — and a
    -- stale true with no socket under it made this return "idle" for ever,
    -- with nothing left to reopen the connection. on_disconnected clears both
    -- together today, so this is a guard rather than a live bug; it is here
    -- because a planner that can call itself finished while disconnected is
    -- one edit away from being one.
    if s.is_identified and s.socket_connected then return "idle" end

    -- THE RETRY BUDGET IS SPENT, AND THAT IS A DECISION, NOT AN ACCIDENT.
    --
    -- schedule_reconnect stops at MAX_RECONNECT_ATTEMPTS, sets
    -- reconnect_exhausted and emits reconnect_failed; the lobby greys its
    -- online tiles and the network dialog offers RETRY. Every one of those
    -- says the app has stopped trying.
    --
    -- This planner never read the flag, so it went on returning "connect"
    -- every tick — one attempt a second, for ever, behind a dialog telling the
    -- player nothing was happening and inviting them to press a button that
    -- would do what was already being done. The budget existed and nothing
    -- honoured it.
    --
    -- retry_connection() clears the flag, so RETRY is what starts it again.
    if s.reconnect_exhausted and not s.is_connecting and not s.socket_connected then
        return "idle"
    end

    if s.socket_connected then
        -- A socket with no identity on it is the case that used to be able to
        -- last for ever. Re-sending costs one small frame.
        if (tonumber(s.since_identify) or math.huge) >= M.IDENTIFY_RESEND_SECONDS then
            return "identify"
        end
        return "wait"
    end

    if s.is_connecting then
        -- The deadlock, caught by elapsed time rather than by an event that
        -- may never come.
        if (tonumber(s.connecting_for) or 0) >= M.CONNECT_STALL_SECONDS then
            return "unstick"
        end
        return "wait"
    end

    -- A retry is already on the clock. Connecting anyway would make this a
    -- SECOND retry loop running beside schedule_reconnect's, which is how a
    -- struggling server gets hit every two seconds by every client at once.
    -- The backoff is capped instead (see schedule_reconnect), so waiting here
    -- costs a player seconds, not the half-minute it used to.
    if s.reconnect_scheduled then return "wait" end

    return "connect"
end

-- ---------------------------------------------------------------------------
-- WHAT THE PLAYER SHOULD BE TOLD, DERIVED FROM THE SAME STATE.
--
-- Reported: a "RECONNECTING…" badge appears, and while it is up the app sends
-- nothing to the backend at all — for a minute or more.
--
-- Both halves were true, and they were true TOGETHER because the badge was
-- driven by the raw `disconnected` event, which on_disconnected emits BEFORE
-- deciding whether it is going to reconnect:
--
--     emit("disconnected", reason)          -- badge -> RECONNECTING
--     if is_manual_disconnect then return end          -- nothing scheduled
--     if M.update_required then return end             -- nothing, ever
--     if M.app_offline then return end                 -- nothing for 15 min
--     schedule_reconnect()
--
-- So in three separate cases the badge announced a reconnect that had already
-- been decided against. The longest is the account block, whose recheck window
-- is APP_OFFLINE_RECHECK_SECONDS — fifteen minutes of a spinner promising
-- something that is not happening, which is exactly "it takes very long and no
-- socket events are exchanged".
--
-- The badge is not the bug on its own; the bug is that nothing owned the
-- answer to "what is this connection doing". next_action above owns what to
-- DO. This owns what to SAY, from the same inputs, so the two cannot disagree.
--
-- The invariant worth stating outright, and it is tested: whenever next_action
-- says "idle" and we are not online, this must NOT say "reconnecting". A
-- spinner is a promise that something is in flight.

--- What to tell the player about the connection.
--
-- @return "online"          identified; nothing to show
--         "connecting"      a socket or an IDENTIFY is genuinely in flight
--         "reconnecting"    dropped, and a retry is on the clock
--         "offline"         retries exhausted; RETRY is the only way forward
--         "update_required" terminal until the app is updated
--         "blocked"         the account is refused; we re-ask on a long timer
--         "signed_out"      nobody to be, so no socket is wanted
function M.status(s)
    s = s or {}

    -- Same order of precedence as next_action, deliberately: these two answer
    -- the same question and disagreeing about which rule wins is how the
    -- spinner got out of step with the loop in the first place.
    if s.update_required then return "update_required" end
    if s.app_offline then return "blocked" end

    if s.socket_connected and s.is_identified then return "online" end

    -- Nobody to be. A signed-out app holds no socket, so there is nothing to
    -- report as broken.
    if not s.identity and not s.has_cached_identity
       and (not s.has_device_identity or s.device_identity_refused) then
        return "signed_out"
    end

    -- A LIVE SOCKET BEATS A STALE GIVE-UP FLAG.
    --
    -- reconnect_exhausted is cleared by on_connected, so a socket that is up
    -- while it is still set is a momentary overlap — but reading the flag
    -- first meant answering "offline" about a link that was working and an
    -- IDENTIFY that was in flight. Checked after, it can only ever describe
    -- what it actually means: no socket, and nothing being done about it.
    --
    -- A socket with no identity on it is not "reconnecting" either. The link
    -- is up and we are waiting on the server, which is a different thing to
    -- say and a different thing to go and look at.
    if s.socket_connected then return "connecting" end
    if s.is_connecting then return "connecting" end

    -- The automatic retries have given up. This is the one state with an
    -- action attached, so it must not be dressed up as a spinner.
    if s.reconnect_exhausted then return "offline" end

    if s.reconnect_scheduled then return "reconnecting" end

    -- No socket, nothing in flight, nothing on the clock — but we do have
    -- somebody to be, so the reconciler is about to open one. Not a resting
    -- state, and not a failure either.
    return "connecting"
end

--- Does this status mean the app is trying to reach the server right now?
--- The spinner is gated on this: an animated one that is not backed by an
--- attempt is the thing being fixed.
function M.status_is_active(status)
    return status == "connecting" or status == "reconnecting"
end

return M
