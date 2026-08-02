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
-- The websocket extension timeout is capped, but in practice 3.5s is plenty of
-- time for TCP/TLS handshake before resetting and attempting a fresh socket.
M.CONNECT_STALL_SECONDS = 3.5

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
    if s.is_identified then return "idle" end

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

return M
