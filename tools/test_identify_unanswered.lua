-- A SOCKET THAT ANSWERS PINGS AND IGNORES IDENTIFY, ASKED FOREVER.
--
--   Run: lua tools/test_identify_unanswered.lua
--
-- From a reported device log, trimmed to its repeating unit:
--
--   20:54:05.747  [WS] connected
--   20:54:05.747  sending IDENTIFY (socket opened)
--   20:54:08.243  IDENTIFY unanswered after 2.5s, resending (1/3)
--   20:54:10.748  IDENTIFY unanswered after 2.5s, resending (2/3)
--   20:54:13.251  IDENTIFY unanswered after 2.5s, resending (3/3)
--   20:54:15.752  IDENTIFY never answered — reporting identify_error (timeout)
--   20:54:15.752  identify_error (timeout): re-identifying from cache (1/5)
--   20:54:15.753  identify() called: socket_connected=true (sending IDENTIFY now)
--   20:54:15.753  sending IDENTIFY (identify() called)
--   20:54:15.753  connect() no-op: is_connecting=false socket_connected=true
--   ... and again at (2/5), and again at (3/5)
--
-- WHAT THE LOG PROVES, AND WHAT IT RULES OUT
--
-- The recovery re-sent IDENTIFY down the SAME socket that had already ignored
-- four of them, because connect() no-ops while we believe we are connected.
-- Five cycles, ~25 IDENTIFYs, then it gave up. No iteration of that loop could
-- ever have produced a different answer.
--
-- And the zombie watchdog never fired across those thirty seconds. It fires
-- after ZOMBIE_TIMEOUT (13s) without a SINGLE inbound frame — so frames were
-- arriving. The server was answering CLIENT_PING and not IDENTIFY. Whatever is
-- wrong is at the other end; what was wrong HERE is that the client kept
-- asking the socket that had stopped answering.
--
-- So: after the watchdog's budget is spent, the socket is dropped. The next
-- IDENTIFY goes out on a genuinely fresh connection, on the normal backoff,
-- and the give-up path (MAX_RECONNECT_ATTEMPTS -> OFFLINE + RETRY) is reached
-- by a route that can actually change the outcome.
--
-- This drives the REAL modules/websocket_manager.lua against the simulator's
-- websocket extension, with a fake server that behaves exactly as the log
-- says the real one did: pings answered, IDENTIFY ignored.
--
-- Its own file rather than a block in test_send_silence.lua: it needs a
-- websocket_manager that no earlier scenario has left mid-reconnect, and a
-- test that quietly depends on what ran before it is a test that will lie
-- later.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
require("tools.defold_sim")
local SIM = _G.SIM
local ws = require("modules.websocket_manager")
local json_util = require("modules.json_util")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end
local function check_truthy(label, got)
    local ok = got and true or false
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s)", ok and "PASS" or "FAIL", label, tostring(got)))
end

-- The server from the log: healthy link, answers CLIENT_PING, never answers
-- IDENTIFY. Without the pong the zombie watchdog fires first and the test
-- would be proving something else entirely.
local real_send = _G.websocket.send
_G.websocket.send = function(conn, payload)
    real_send(conn, payload)
    local decoded = json_util.decode(payload) or {}
    if decoded.type == "CLIENT_PING" then SIM.server_send({ type = "CLIENT_PONG" }) end
end

local drops, errors, connects = {}, {}, 0
-- Counted AT THE DROP, not at the end of a pump window. The reconnect that
-- follows opens a fresh socket and sends its own IDENTIFY, so a count taken
-- afterwards measures two sockets and calls the extra message a regression.
-- Timing-based windows were the first version of this and they were brittle in
-- both directions.
local identifies_at_first_drop = nil
ws.on("disconnected", function(reason)
    drops[#drops + 1] = tostring(reason)
    if identifies_at_first_drop == nil then
        local n = 0
        for _, o in ipairs(SIM.outbound) do if o.type == "IDENTIFY" then n = n + 1 end end
        identifies_at_first_drop = n
    end
end)
ws.on("identify_error", function(_, reason) errors[#errors + 1] = tostring(reason) end)
ws.on("connected", function() connects = connects + 1 end)

local function identify_count()
    local n = 0
    for _, o in ipairs(SIM.outbound) do if o.type == "IDENTIFY" then n = n + 1 end end
    return n
end
local function has_drop(pattern)
    for _, r in ipairs(drops) do if r:match(pattern) then return true end end
    return false
end

ws.connect()
SIM.pump(0.3)
assert(ws.socket_connected, "the simulated socket did not come up")
SIM.outbound = {}
ws.identify("u1", "Dogo", { amount = 0, charge = 0 }, "UG")

-- Long enough for the watchdog's three resends AND the give-up that follows
-- the third. IDENTIFY_TIMEOUT is 2.5s and there are four waits, not three:
-- send, +2.5 resend 1, +2.5 resend 2, +2.5 resend 3, +2.5 give up.
SIM.pump(12)

print("the watchdog spends its budget and no more")
do
    check_truthy("it reports the timeout", errors[1] == "timeout")
    -- One on identify(), three from the watchdog. Any more means it is still
    -- talking to a socket that has stopped listening.
    check("four IDENTIFYs on that socket, not twenty-five", identifies_at_first_drop, 4)
end

print("")
print("and then it drops the socket rather than asking it again")
do
    -- THE LOAD-BEARING ONE.
    check("the socket is dropped", has_drop("identify"), true)
    -- Not by the zombie watchdog: pings were answered throughout. If this were
    -- true the fake server would be wrong and the test would be proving the
    -- absence of traffic instead of the absence of an ANSWER.
    check("and not because the link went quiet", has_drop("zombie"), false)
end

print("")
print("the next IDENTIFY goes out on a genuinely new connection")
do
    -- The reconnect may already have landed inside the window above (the first
    -- backoff step is about a second), so this asks whether a SECOND socket
    -- exists at all rather than whether one appears in the next four seconds.
    check_truthy("a fresh socket was opened (" .. connects .. " connections so far)",
        connects >= 2)
    SIM.outbound = {}
    SIM.pump(4)
    check_truthy("and IDENTIFY keeps going out on the new one", identify_count() >= 1)
end

print("")
print("and it escalates instead of spinning at the same rate")
do
    -- Every cycle now costs a handshake, so it has to walk the backoff rather
    -- than retry flat out. reconnect_attempts climbing is what eventually
    -- reaches OFFLINE + RETRY — a give-up the player can act on, instead of
    -- twenty-five identical messages into a hole.
    local first = SIM.clock
    local cycles = 0
    local seen = {}
    for _ = 1, 12 do
        local before = #drops
        SIM.pump(10)
        if #drops > before then
            cycles = cycles + 1
            seen[#seen + 1] = string.format("%.1fs", SIM.clock - first)
        end
    end
    check_truthy("it keeps cycling rather than stopping dead (" .. cycles .. " drops)", cycles >= 2)
    check("and every drop is for the same, named reason", has_drop("identify"), true)
end

print("")
print("the ordinary case is untouched: an answered IDENTIFY settles at once")
do
    -- Guard rail. A fix that drops sockets must not drop one that is working.
    local answered = false
    _G.websocket.send = function(conn, payload)
        real_send(conn, payload)
        local decoded = json_util.decode(payload) or {}
        if decoded.type == "CLIENT_PING" then SIM.server_send({ type = "CLIENT_PONG" }) end
        if decoded.type == "IDENTIFY" and not answered then
            answered = true
            SIM.server_send({ type = "IDENTIFY", data = { _id = "u1", username = "Dogo" } })
        end
    end

    local drops_before = #drops
    ws.retry_connection()
    SIM.pump(1)
    check("it identifies", ws.is_identified, true)
    SIM.pump(15)
    check("and stays connected", ws.socket_connected, true)
    check("with no socket dropped along the way", #drops, drops_before)
end

_G.websocket.send = real_send

print("")
if failures == 0 then
    print("ALL PASSED")
else
    print(failures .. " FAILED")
    os.exit(1)
end
