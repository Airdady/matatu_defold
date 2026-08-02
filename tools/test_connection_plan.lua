-- THE ONE PLACE THAT DECIDES WHAT THE CONNECTION SHOULD DO NEXT.
--
--   Run: lua tools/test_connection_plan.lua
--
-- THE MESS THIS REPLACES
--
-- "Being signed in" was a sequence five separate things had to perform in the
-- right order, and nobody owned it: controller.script called identify() then
-- connect(); websocket_manager queued the identity; on_connected sent it; a
-- watchdog resent it three times and then gave up; schedule_reconnect reopened
-- the socket on its own backoff. Each step is fine. The whole is not, because
-- every step assumes the one before it happened and no component's job is to
-- notice when one did not.
--
-- The one that shipped: M.connect() no-ops while `is_connecting` is true, and
-- that flag is cleared ONLY by on_connected and on_disconnected. A socket
-- attempt that neither connects nor reports a failure — a hung TLS handshake,
-- an OEM dropping it silently, the app suspending mid-connect — leaves it true
-- for the rest of the process. connect() is then permanently a no-op,
-- schedule_reconnect never runs (it fires only from on_disconnected), and the
-- queued IDENTIFY sits there for ever. The identify watchdog cannot rescue it
-- either: its resend is itself guarded on socket_connected.
--
-- Reported as: "POST /matatu/auth/firebase 200 OK, I can see all the data
-- populated in the app, and the identify never gets fired."

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local P = require("modules.connection_plan")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local ME = { _id = "u1" }

-- Sensible defaults; each test overrides only what it is about.
--
-- NONE rather than nil for "clear this field": `pairs` skips a key whose value
-- is nil, so `{ identity = nil }` would silently leave the default in place and
-- the test would assert nothing about the case it names.
local NONE = {}
local function plan(over)
    local s = {
        identity = ME, update_required = false,
        socket_connected = false, is_connecting = false, is_identified = false,
        connecting_for = 0, since_identify = 0,
    }
    for k, v in pairs(over or {}) do s[k] = (v ~= NONE) and v or nil end
    return P.next_action(s)
end

print("THE BUG: a socket that is up, with no identity on it")
-- The state that used to be able to last for ever. Whatever got us here — a
-- dropped frame, a server that answered down a branch which forgot to reply, a
-- connect that completed after the watchdog had given up — the answer is
-- always the same and always cheap: send it again.
check("connected, not identified, nothing sent recently",
    plan({ socket_connected = true, since_identify = 99 }), "identify")
check("...but not on every tick",
    plan({ socket_connected = true, since_identify = 0 }), "wait")
check("resend window", P.IDENTIFY_RESEND_SECONDS, 2.5)

print("")
print("THE DEADLOCK: a connect attempt that hangs")
-- is_connecting cleared only by two events, neither of which is coming.
-- Caught by elapsed time instead, because that is the one thing still
-- observable when events stop.
check("a fresh attempt is given room", plan({ is_connecting = true, connecting_for = 1 }), "wait")
check("still, right up to the line",
    plan({ is_connecting = true, connecting_for = P.CONNECT_STALL_SECONDS - 0.1 }), "wait")
check("past it, force it down",
    plan({ is_connecting = true, connecting_for = P.CONNECT_STALL_SECONDS }), "unstick")
check("and long past it", plan({ is_connecting = true, connecting_for = 600 }), "unstick")
check("stall window", P.CONNECT_STALL_SECONDS, 3.5)

print("")
print("The ordinary path")
check("no socket, nothing in flight: connect", plan({}), "connect")
check("identified: nothing to do", plan({ socket_connected = true, is_identified = true }), "idle")

print("")
print("A CACHED SESSION IS ENOUGH, ON ITS OWN")
-- The reported bug: "even when I have user in the cache the app is not firing
-- identify when I return."
--
-- The identity only existed in memory if some controller path had remembered
-- to call identify() — and there are several: boot, the Play Online tap, focus
-- regained, the identify_error recovery, the post-sign-in callback. Miss any
-- one and the app sits on CONNECTING with a perfectly good session on disk.
--
-- Sourcing it from the cache makes being signed in a property of the STATE
-- rather than of the path the app happened to take.
check("no identity in memory, one on disk: adopt it",
    plan({ identity = NONE, has_cached_identity = true }), "adopt")
check("adopt even with a socket already up",
    plan({ identity = NONE, has_cached_identity = true, socket_connected = true }), "adopt")
check("adopt even mid-connect",
    plan({ identity = NONE, has_cached_identity = true, is_connecting = true }), "adopt")
-- An identity already in memory is the live one; the cache must not replace it.
check("an in-memory identity is NOT re-adopted",
    plan({ has_cached_identity = true }), "connect")
-- A refused build still trumps everything.
check("but not when the build is refused",
    plan({ identity = NONE, has_cached_identity = true, update_required = true }), "idle")

print("")
print("NO CACHE EITHER: THE DEVICE ID IS STILL AN IDENTITY")
-- The last hole, and why CONNECTING could stick for a returning player: with
-- no cached session the client had NOTHING to send, so it sent nothing. The
-- device id is generated on first run, is already on the User document and
-- does not expire — for a returning player it identifies them exactly as well
-- as their user id does.
check("nothing in memory, nothing cached, but a device: identify by it",
    plan({ identity = NONE, has_device_identity = true }), "adopt_device")
-- Order matters. A cached session names the account; the device only implies
-- it, and on a shared or reinstalled handset those can differ.
check("a cached session is preferred over the device",
    plan({ identity = NONE, has_cached_identity = true, has_device_identity = true }), "adopt")
check("once the server says it does not know this device, stop asking",
    plan({ identity = NONE, has_device_identity = true, device_identity_refused = true }), "idle")
-- The refusal must not silence a real session that turns up afterwards.
check("a refusal does not block a cached session",
    plan({ identity = NONE, has_cached_identity = true,
           has_device_identity = true, device_identity_refused = true }), "adopt")
check("nor a refused build",
    plan({ identity = NONE, has_device_identity = true, update_required = true }), "idle")

print("")
print("Nothing is wanted without an identity")
-- A signed-out app holds no socket open. This is also what makes the loop safe
-- to leave running for the life of the process: with no identity every tick is
-- a no-op.
check("no identity, no cache, no device", plan({ identity = NONE }), "idle")
check("no identity even with a socket up",
    plan({ identity = NONE, socket_connected = true }), "idle")
check("no identity, mid-connect", plan({ identity = NONE, is_connecting = true }), "idle")

print("")
print("A refused BUILD is terminal")
-- Every reconnect re-runs the handshake that produced the refusal, so the loop
-- would only burn battery behind the update screen.
check("update required, disconnected", plan({ update_required = true }), "idle")
check("update required, connected",
    plan({ update_required = true, socket_connected = true }), "idle")
check("update required outranks a hung attempt",
    plan({ update_required = true, is_connecting = true, connecting_for = 600 }), "idle")

print("")
print("Precedence between the checks")
-- These orderings are the ones that would silently undo the fix if they moved.
check("identified beats a stale identify timer",
    plan({ socket_connected = true, is_identified = true, since_identify = 999 }), "idle")
-- A socket that reports connected while the flag is still up: send, do not sit
-- waiting for the attempt to "finish".
check("connected wins over is_connecting",
    plan({ socket_connected = true, is_connecting = true, since_identify = 99 }), "identify")

print("")
print("Nothing here can raise")
-- It runs on a timer for the life of the process. An error in it stops the
-- only thing that can recover a stuck connection.
check("no state at all", P.next_action(nil), "idle")
check("empty state", P.next_action({}), "idle")
check("missing timings are treated as stale, not as fresh",
    P.next_action({ identity = ME, socket_connected = true }), "identify")
check("non-numeric connecting_for",
    plan({ is_connecting = true, connecting_for = "ages" }), "wait")
check("non-numeric since_identify",
    plan({ socket_connected = true, since_identify = "ages" }), "identify")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
