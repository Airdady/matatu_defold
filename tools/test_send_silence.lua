-- THE APP SENDS NOTHING, AND SAYS NOTHING ABOUT IT.
--
--   Run: lua tools/test_send_silence.lua
--
-- Reported as: while the connection badge is up nothing reaches the backend;
-- the backend itself is online and healthy; and pressing RETRY produces no
-- event there either.
--
-- Three separate holes, all in the same handful of lines, and all silent.
--
-- 1. send_message DROPPED IN SILENCE.
--
--        if not M.socket_connected or not connection then return false end
--
--    Every message sent while the socket is down vanished. No log, no queue,
--    no feedback — and send_move does not even read the return value. So "the
--    app sent nothing" was exactly true, with nothing anywhere saying so.
--
-- 2. send_message CLAIMED SUCCESS IT COULD NOT KNOW.
--
--        websocket.send(connection, ...)   -- unwrapped
--        return true
--
--    M.socket_connected is a flag, set by on_connected and cleared by
--    on_disconnected. A socket that dies without reporting it — the OS
--    reclaiming it, a network handover, the app backgrounded — leaves it true.
--    Sends then went to a dead socket and returned true. And a send on a
--    closed socket RAISES, so unwrapped it took down whatever frame called it.
--
-- 3. THE KEEP-ALIVE SENT THE SAME WAY, INSIDE A REPEATING TIMER.
--
--        websocket.send(connection, {type = "CLIENT_PING"})
--
--    When that raised it killed the keep-alive itself — and the ZOMBIE check
--    lives in the same callback, so the one thing that would have noticed the
--    dead socket died with it. The socket then sat "connected" for ever with
--    nothing going out and nothing coming back, and connect() no-ops while
--    M.socket_connected is true, so nothing reopened it. That is "the backend
--    looks healthy but the app is reconnecting and sending nothing".
--
-- 4. AND RETRY WAS SWALLOWED BY THE SAME FLAG. retry_connection cleared
--    is_connecting only once it was ten seconds stale, and never touched
--    socket_connected — which is the state somebody is pressing RETRY IN.
--
-- These drive the REAL modules/websocket_manager.lua against the simulator's
-- websocket extension, so what is asserted is what the socket actually saw.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
require("tools.defold_sim")
local SIM = _G.SIM
local ws = require("modules.websocket_manager")

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

local function outbound_types()
    local t = {}
    for _, o in ipairs(SIM.outbound) do t[#t + 1] = o.type end
    return table.concat(t, ",")
end
local function reset_outbound() SIM.outbound = {} end

-- Capture the drop reports the manager emits.
local dropped = {}
ws.on("message_dropped", function(msg_type, why)
    dropped[#dropped + 1] = { type = msg_type, why = why }
end)
local function reset_dropped() dropped = {} end

print("a send with no socket is refused OUT LOUD")
do
    reset_outbound(); reset_dropped()
    ws.socket_connected = false
    local sent = ws.send_message("GAME_REQUEST", { x = 1 })
    check("it reports failure to the caller", sent, false)
    check("nothing went on the wire", outbound_types(), "")
    -- The whole complaint: it used to happen in silence.
    check("and it said so", #dropped, 1)
    check_truthy("naming the message", dropped[1] and dropped[1].type == "GAME_REQUEST")
end

-- A REAL socket, opened through the manager, so the module-local `connection`
-- is genuinely set. Setting M.socket_connected by hand is not enough: the
-- first guard also tests `connection`, so a hand-set flag alone takes the
-- no-socket branch and never reaches the send at all — which is how an earlier
-- version of the block below passed while testing nothing.
local function open_real_socket()
    ws.socket_connected = false
    ws.connect()
    SIM.pump(0.3)
    assert(ws.socket_connected, "the simulated socket did not come up")
end

print("")
print("a send on a socket that has died is not reported as sent")
do
    open_real_socket()
    reset_outbound(); reset_dropped()
    -- The flag still says connected. The socket disagrees — which is what a
    -- stale flag over a reclaimed socket looks like from in here.
    local real_send = _G.websocket.send
    _G.websocket.send = function() error("closed") end

    local sent = ws.send_message("MOVE", { gameId = "g1" })
    _G.websocket.send = real_send

    check("the caller is told it failed", sent, false)
    check("and it is reported", #dropped, 1)
    check_truthy("with the reason, not just the fact",
        dropped[1] and tostring(dropped[1].why):match("closed") ~= nil)
    -- A raise IS a dead socket, whatever the flag said. Believing the flag is
    -- how the app went on "sending" into nothing for as long as it took the
    -- zombie watchdog to notice.
    check("the stale connected flag is taken down", ws.socket_connected, false)
    check("and the identity with it", ws.is_identified, false)
end

print("")
print("and the raise never escapes into the caller's frame")
do
    -- Unwrapped, this propagated into on_input / a timer callback and took the
    -- whole frame's script down with it.
    open_real_socket()
    local real_send = _G.websocket.send
    _G.websocket.send = function() error("closed") end
    local ok = pcall(ws.send_message, "MOVE", {})
    _G.websocket.send = real_send
    check("send_message returns rather than throwing", ok, true)
end

print("")
print("the keep-alive goes through the same guard rail")
do
    -- It was a bare websocket.send inside a REPEATING timer, so a raise killed
    -- the keep-alive — and the zombie check lives in that same callback, so
    -- the one thing that would have noticed died with it.
    local src = (function()
        local f = assert(io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
            .. "../modules/websocket_manager.lua"))
        local s = f:read("*a"); f:close()
        return (s:gsub("%-%-[^\n]*", ""))
    end)()
    check("no bare websocket.send is left anywhere",
        src:match("[^.]websocket%.send%(connection") ~= nil, false)
    check("the ping goes through send_message",
        src:match('M%.send_message%("CLIENT_PING"%)') ~= nil, true)
    check("and send_message is the only place that touches the socket",
        select(2, src:gsub("pcall%(websocket%.send", "")), 1)
end

print("")
print("RETRY discards whatever we are holding and opens a fresh socket")
do
    reset_outbound()
    -- The state somebody presses RETRY in: the flag insists we are connected.
    ws.socket_connected = true
    ws.is_identified = true
    SIM.ws_conn = nil

    ws.retry_connection()

    -- connect() no-ops on `is_connecting or socket_connected`, so without
    -- clearing them this call did absolutely nothing — which is exactly "I
    -- press RETRY and see no event at the backend".
    check_truthy("a connection was actually attempted", SIM.ws_conn ~= nil)
    check("and the stale flag is gone", ws.socket_connected, false)
end

print("")
print("and RETRY is not swallowed by a young in-flight attempt either")
do
    -- retry_connection used to clear is_connecting only once it was ten
    -- seconds stale. Inside that window the tap did nothing at all, and the
    -- player pressed it again.
    ws.socket_connected = false
    ws.connect()                     -- puts an attempt in flight
    SIM.ws_conn = nil                -- forget it, so a new one is detectable
    ws.retry_connection()
    check_truthy("a fresh attempt is made immediately", SIM.ws_conn ~= nil)
end

print("")
print("nothing above broke the ordinary case")
do
    reset_outbound(); reset_dropped()
    ws.socket_connected = true
    ws.is_identified = true
    local sent = ws.send_message("MOVE", { gameId = "g1" })
    check("a healthy send succeeds", sent, true)
    check("it reaches the socket", outbound_types(), "MOVE")
    check("and reports nothing dropped", #dropped, 0)
end

print("")
if failures == 0 then
    print("ALL PASSED")
else
    print(failures .. " FAILED")
    os.exit(1)
end
