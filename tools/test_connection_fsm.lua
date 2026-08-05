-- THE CONNECTION, AS ONE STATE MACHINE.
--
--   Run: lua tools/test_connection_fsm.lua
--
-- The last section is the point of this file: every connection bug reported
-- over this work, replayed against the new machine. Each of them was possible
-- because being online was sixteen booleans and four Defold timers that no
-- single component owned. None of them is possible against one state variable,
-- one clock and no I/O — and that claim is worth nothing unless it is checked,
-- so it is checked, by name.
--
-- No engine, no sockets, no simulator, no wall clock. Effects are returned and
-- inspected, which is the whole reason the machine returns them instead of
-- performing them.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local FSM = require("modules.connection_fsm")

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

-- Deterministic backoff: no jitter under test.
local function new(identity)
    local f = FSM.new({ rand = function() return 0.5 end })
    if identity then FSM.set_identity(f, identity) end
    return f
end

local function names(effects)
    local out = {}
    for _, e in ipairs(effects or {}) do out[#out + 1] = e[1] end
    return table.concat(out, ",")
end
local function has(effects, name)
    for _, e in ipairs(effects or {}) do if e[1] == name then return true end end
    return false
end

--- Run the clock in small steps, collecting every effect. Returns them flat.
local function run(fsm, seconds, step)
    step = step or 0.1
    local all = {}
    local t = 0
    while t < seconds - 1e-9 do
        for _, e in ipairs(FSM.tick(fsm, step)) do all[#all + 1] = e end
        t = t + step
    end
    return all
end
local function count(effects, name)
    local n = 0
    for _, e in ipairs(effects or {}) do if e[1] == name then n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------------------
print("the happy path is three transitions and nothing else")
do
    local f = FSM.new({ rand = function() return 0.5 end })
    check("a signed-out app wants no socket", f.state, FSM.IDLE)
    check("and says so", FSM.status(f), "signed_out")

    local e = FSM.set_identity(f, "u1")
    check("an identity opens one", has(e, "open_socket"), true)
    check("state", f.state, FSM.CONNECTING)

    e = FSM.socket_open(f)
    check("the socket asks who we are", has(e, "send_identify"), true)
    check("state", f.state, FSM.IDENTIFYING)
    check("the socket counts as connected", FSM.socket_connected(f), true)
    check("but not identified yet", FSM.is_identified(f), false)

    e = FSM.identify_ok(f)
    check("and the answer settles it", f.state, FSM.READY)
    check("status", FSM.status(f), "online")
    check("nothing further is asked for", has(e, "send_identify"), false)
end

print("")
print("re-identifying as the same player does nothing at all")
do
    -- identify() is called from boot, sign-in, resume and the recovery path.
    -- Every one of them used to be able to fire a redundant IDENTIFY.
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    check("no effects", names(FSM.set_identity(f, "u1")), "")
    check("and still online", f.state, FSM.READY)
end

print("")
print("a different player re-identifies on the socket we already have")
do
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    local e = FSM.set_identity(f, "u2")
    check("it asks again", has(e, "send_identify"), true)
    check("without throwing the socket away", has(e, "close_socket"), false)
    check("state", f.state, FSM.IDENTIFYING)
end

-- ---------------------------------------------------------------------------
print("")
print("every failure leads to the same place: close, back off, reopen")
do
    local f = new("u1")
    FSM.socket_open(f)
    local e = FSM.socket_closed(f)
    check("a closed socket backs off", f.state, FSM.BACKOFF)
    check("status", FSM.status(f), "reconnecting")

    -- And the backoff actually ends in a new socket rather than sitting there.
    local all = run(f, 5)
    check("which opens a new one", has(all, "open_socket"), true)
    check("state", f.state, FSM.CONNECTING)
end

print("")
print("a connect that reports nothing is not waited on for ever")
do
    local f = new("u1")
    check("state", f.state, FSM.CONNECTING)
    local all = run(f, FSM.CONNECT_TIMEOUT + 0.5)
    check("the hung attempt is closed", has(all, "close_socket"), true)
    check_truthy("and it moved on", f.state == FSM.BACKOFF or f.state == FSM.CONNECTING)
end

print("")
print("a send that fails is a dead socket, whatever anything else says")
do
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    check("we believe we are online", FSM.socket_connected(f), true)
    local e = FSM.send_failed(f)
    check("a failed send closes it", has(e, "close_socket"), true)
    check("and backs off", f.state, FSM.BACKOFF)
    check("so socket_connected stops lying", FSM.socket_connected(f), false)
end

print("")
print("silence kills a socket that claims to be fine")
do
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    local all = run(f, FSM.SILENCE_TIMEOUT + 1)
    check("the quiet link is closed", has(all, "close_socket"), true)
    check("and retried", f.state ~= FSM.READY, true)
end

print("")
print("but traffic keeps it alive indefinitely")
do
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    for _ = 1, 600 do          -- sixty seconds
        FSM.tick(f, 0.1)
        FSM.rx(f)              -- a pong, a move, anything
    end
    check("still online after a minute of traffic", f.state, FSM.READY)
end

-- ---------------------------------------------------------------------------
print("")
print("an unanswered IDENTIFY costs the SOCKET, not another IDENTIFY")
do
    -- The reported log: ~25 IDENTIFYs down one socket across five recovery
    -- cycles, because the recovery re-sent on the socket that was ignoring
    -- them and connect() no-oped while socket_connected was true.
    local f = new("u1")
    FSM.socket_open(f)
    local all = {}
    for _ = 1, 200 do
        for _, e in ipairs(FSM.tick(f, 0.1)) do all[#all + 1] = e end
        FSM.rx(f)   -- the link is HEALTHY: pings are being answered
        if f.state ~= FSM.IDENTIFYING then break end
    end
    -- One on open + two resends = three sends, then the socket is condemned.
    check("it resends up to the budget", count(all, "send_identify"), FSM.IDENTIFY_TRIES - 1)
    check("then closes the socket", has(all, "close_socket"), true)
    check("and says why", has(all, "identify_timeout"), true)
    check("and backs off rather than asking again", f.state, FSM.BACKOFF)
end

print("")
print("and a refusal is escalated, not retried")
do
    -- Nobody rejected a network; the server rejected this identity. Backing
    -- off would just ask the same question again.
    local f = new("u1")
    FSM.socket_open(f)
    local e = FSM.identify_refused(f)
    check("the socket goes", has(e, "close_socket"), true)
    check("the caller is told to rebuild the session", has(e, "identity_refused"), true)
    check("and nothing retries on its own", f.state, FSM.IDLE)
end

-- ---------------------------------------------------------------------------
print("")
print("the budget is honoured, and RETRY is what restarts it")
do
    local f = new("u1")
    local gave_up = false
    -- Effects from BOTH halves. An earlier version scanned only the explicit
    -- socket_closed and missed the give-up entirely, because the connect
    -- timeout inside run() is what produced it — so it failed a machine that
    -- was doing exactly the right thing.
    local function scan(effects)
        for _, e in ipairs(effects or {}) do
            if e[1] == "gave_up" then gave_up = true end
        end
    end
    for _ = 1, FSM.MAX_ATTEMPTS + 5 do
        if f.state == FSM.CONNECTING then scan(FSM.socket_closed(f)) end
        scan(run(f, 40))   -- past any backoff
        if f.state == FSM.GIVEN_UP then break end
    end
    check("it eventually gives up", f.state, FSM.GIVEN_UP)
    check("and announces it once", gave_up, true)
    check("status offers the retry", FSM.status(f), "offline")

    -- THE BUG THIS REPLACES: the planner never read the give-up flag and went
    -- on connecting once a second behind a dialog saying it had stopped.
    local quiet = run(f, 120)
    check("and then does NOTHING on its own", names(quiet), "")

    local e = FSM.retry(f)
    check("until asked", has(e, "open_socket"), true)
    check("state", f.state, FSM.CONNECTING)
end

print("")
print("RETRY outranks whatever we are holding")
do
    -- Reported: pressing RETRY produced no event at the backend, because
    -- connect() no-ops on `is_connecting or socket_connected` and the retry
    -- path cleared neither.
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    local e = FSM.retry(f)
    check("the held socket is discarded", has(e, "close_socket"), true)
    check("and a new one opened", has(e, "open_socket"), true)
    check("state", f.state, FSM.CONNECTING)

    -- And from mid-handshake, which the ten-second staleness rule used to
    -- swallow completely.
    local g = new("u1")
    check("mid-handshake", g.state, FSM.CONNECTING)
    check("a retry still opens a fresh one", has(FSM.retry(g), "open_socket"), true)
end

-- ---------------------------------------------------------------------------
print("")
print("a refused BUILD is terminal and never pretends otherwise")
do
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    local e = FSM.set_update_required(f)
    check("the socket is dropped", has(e, "close_socket"), true)
    check("status says what it is", FSM.status(f), "update_required")
    check("nothing is attempted, ever", names(run(f, 600)), "")
    check("not even on request", names(FSM.retry(f)), "")
    check("nor on a fresh identity", names(FSM.set_identity(f, "u9")), "")
end

print("")
print("a refused ACCOUNT goes quiet, then spends exactly one probe")
do
    local f = new("u1")
    FSM.socket_open(f)
    local e = FSM.set_blocked(f, 0)
    check("the socket is dropped", has(e, "close_socket"), true)
    check("status says what it is", FSM.status(f), "blocked")

    -- The reported case: fifteen minutes of an animated RECONNECTING badge
    -- with nothing happening behind it. Quiet is right; the spinner was not.
    check("nothing happens meanwhile", names(run(f, FSM.BLOCKED_RECHECK - 60)), "")
    check("and it is not dressed up as a reconnect", FSM.status(f), "blocked")

    local later = run(f, 120)
    check("then one attempt", count(later, "open_socket"), 1)

    -- AND THE PROBE FAILING RETURNS IT TO SILENCE. Without this the failed
    -- probe fell into the ordinary backoff and the app left the blocked state
    -- for good on its first try — turning one request every fifteen minutes
    -- into the reconnect loop the latch exists to prevent. This is what
    -- counted five attempts instead of one.
    FSM.socket_closed(f)
    check("a failed probe goes back to quiet", f.state, FSM.BLOCKED)
    check("and stays quiet", names(run(f, FSM.BLOCKED_RECHECK - 60)), "")
end

print("")
print("and a new identity is worth asking a server that refused the old one")
do
    local f = new("u1")
    FSM.set_blocked(f, 0)
    check("the same one is not", names(FSM.set_identity(f, "u1")), "")
    check("a different one is", has(FSM.set_identity(f, "u2"), "open_socket"), true)
end

-- ---------------------------------------------------------------------------
print("")
print("signing out stops everything")
do
    local f = new("u1")
    FSM.socket_open(f); FSM.identify_ok(f)
    local e = FSM.set_identity(f, nil)
    check("the socket is closed", has(e, "close_socket"), true)
    check("state", f.state, FSM.IDLE)
    check("status", FSM.status(f), "signed_out")
    check("and nothing reconnects behind our back", names(run(f, 300)), "")
end

print("")
print("a socket that arrives after we gave up on it is closed, not adopted")
do
    -- Abandoned sockets left open go on delivering events for a connection
    -- nobody is reading, and their eventual close tears down the replacement.
    local f = new("u1")
    run(f, FSM.CONNECT_TIMEOUT + 0.5)     -- declared hung, now in backoff
    local e = FSM.socket_open(f)          -- the old one finally reports in
    check("it is closed", has(e, "close_socket"), true)
    check("and does not become our connection", f.state ~= FSM.IDENTIFYING, true)
end

-- ---------------------------------------------------------------------------
print("")
print("THE PROPERTIES THAT MAKE THE OLD BUGS UNREACHABLE")
do
    -- 1. socket_connected and is_identified cannot disagree, because neither
    --    is stored. `is_identified true, socket_connected false` made the old
    --    planner return "idle" for ever with nothing left to reopen anything.
    local bad = 0
    for _, s in ipairs({ FSM.IDLE, FSM.CONNECTING, FSM.IDENTIFYING, FSM.READY,
                         FSM.BACKOFF, FSM.GIVEN_UP, FSM.BLOCKED, FSM.UPDATE_REQUIRED }) do
        local f = FSM.new()
        f.state = s
        if FSM.is_identified(f) and not FSM.socket_connected(f) then bad = bad + 1 end
    end
    check("identified without a socket is not representable", bad, 0)

    -- 2. The spinner is never shown for a state that is doing nothing. This is
    --    the fifteen-minute badge, stated as a rule over every state.
    bad = 0
    for _, s in ipairs({ FSM.IDLE, FSM.CONNECTING, FSM.IDENTIFYING, FSM.READY,
                         FSM.BACKOFF, FSM.GIVEN_UP, FSM.BLOCKED, FSM.UPDATE_REQUIRED }) do
        local f = FSM.new()
        f.state = s
        local spinning = FSM.status(f) == "reconnecting" or FSM.status(f) == "connecting"
        if spinning ~= FSM.is_working(f) then bad = bad + 1 end
    end
    check("a spinner means exactly 'something is in flight'", bad, 0)

    -- 3. From ANY state, a run of the clock with no events never wedges: it
    --    either reaches a resting state or keeps opening sockets. The old
    --    layer had four separate ways to stop for ever with an identity
    --    waiting.
    local stuck = {}
    for _, s in ipairs({ FSM.CONNECTING, FSM.IDENTIFYING, FSM.READY, FSM.BACKOFF }) do
        local f = new("u1")
        f.state = s
        f.elapsed = 0
        local all = run(f, 300)
        -- Either it is trying, or it has deliberately stopped with a reason
        -- the player can act on.
        local resting = f.state == FSM.GIVEN_UP or f.state == FSM.IDLE
        if not resting and not has(all, "open_socket") then stuck[#stuck + 1] = s end
    end
    check("no state stalls with an identity waiting", #stuck, 0)
    if #stuck > 0 then print("      stuck: " .. table.concat(stuck, ",")) end

    -- 4. Every effect the machine can emit is one the driver knows how to
    --    perform. A typo'd effect name is a silent no-op otherwise — which is
    --    precisely the class of failure this whole design is meant to remove.
    local known = {
        open_socket = true, close_socket = true, send_identify = true,
        status = true, gave_up = true, identify_timeout = true,
        identity_refused = true,
    }
    local seen, unknown = {}, {}
    local function sweep(effects)
        for _, e in ipairs(effects or {}) do
            seen[e[1]] = true
            if not known[e[1]] then unknown[#unknown + 1] = e[1] end
        end
    end
    -- Including the budget being spent, or `gave_up` is reported unreachable
    -- when it is simply not reached by fifty-attempt-free paths.
    do
        local f = new("u1")
        f.state = FSM.CONNECTING
        f.attempts = FSM.MAX_ATTEMPTS
        sweep(FSM.socket_closed(f))
    end
    for _, s in ipairs({ FSM.IDLE, FSM.CONNECTING, FSM.IDENTIFYING, FSM.READY,
                         FSM.BACKOFF, FSM.GIVEN_UP, FSM.BLOCKED, FSM.UPDATE_REQUIRED }) do
        local f = new("u1"); f.state = s
        sweep(FSM.socket_open(f));      f.state = s
        sweep(FSM.socket_closed(f));    f.state = s
        sweep(FSM.identify_ok(f));      f.state = s
        sweep(FSM.identify_refused(f)); f.state = s
        sweep(FSM.send_failed(f));      f.state = s
        sweep(FSM.retry(f));            f.state = s
        sweep(FSM.set_blocked(f, 0));   f.state = s
        sweep(FSM.clear_blocked(f));    f.state = s
        sweep(FSM.set_update_required(f)); f.state = s
        sweep(FSM.set_identity(f, "u2"));  f.state = s
        sweep(FSM.set_identity(f, nil));   f.state = s
        sweep(run(f, 60))
    end
    check("no effect is emitted that the driver cannot perform", #unknown, 0)
    if #unknown > 0 then print("      unknown: " .. table.concat(unknown, ",")) end
    -- And the reverse: an effect nothing can ever emit is dead weight in the
    -- driver, and reads as a capability that does not exist.
    local unreachable = {}
    for name in pairs(known) do if not seen[name] then unreachable[#unreachable + 1] = name end end
    table.sort(unreachable)
    check("and none the machine can never emit", #unreachable, 0)
    if #unreachable > 0 then print("      unreachable: " .. table.concat(unreachable, ",")) end
end

print("")
if failures == 0 then
    print("ALL PASSED")
else
    print(failures .. " FAILED")
    os.exit(1)
end
