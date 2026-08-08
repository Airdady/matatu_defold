-- HOW LONG DOES IDENTIFY ACTUALLY TAKE AFTER A SUCCESSFUL SIGN-IN?
--
--   Run: lua tools/test_first_login_timing.lua
--
-- Reported, repeatedly: "firebase auth completes with success but identify
-- takes more than a minute to get fired, or doesn't fire at all."
--
-- Two rounds of reasoning about this produced two real fixes and did not
-- produce THIS one, so this drives the REAL modules/websocket_manager.lua
-- against a virtual clock and a scriptable socket, and measures the answer
-- instead of arguing about it.
--
-- What it models:
--   * timer.delay / timer.cancel, on a clock the test advances by hand
--   * websocket.connect, whose outcome each attempt is scripted
--   * the exact call the controller makes after a successful sign-in
--
-- What it measures: the virtual seconds between "the backend said yes" and
-- IDENTIFY reaching the wire.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

-- ── engine stubs ────────────────────────────────────────────────────────────
local NOW = 0
local timers = {}      -- id -> { at, interval, repeating, fn, cancelled }
local next_timer = 0

timer = {
    delay = function(seconds, repeating, fn)
        next_timer = next_timer + 1
        timers[next_timer] = {
            at = NOW + seconds, interval = seconds,
            repeating = repeating and true or false, fn = fn,
        }
        return next_timer
    end,
    cancel = function(h) if timers[h] then timers[h].cancelled = true end end,
}

socket = { gettime = function() return NOW end }

sys = {
    get_sys_info = function() return { system_name = "Android" } end,
    get_config_string = function() return "" end,
    get_config = function() return "" end,
    load = function() return {} end,
    save = function() return true end,
}

local ws_callback_fn
-- Scriptable socket. `outcomes` is consumed one entry per connect attempt:
--   "ok"      connects after `connect_latency`
--   "error"   reports EVENT_ERROR after `connect_latency`
--   "hang"    never reports anything at all
ws_callback_fn = nil
local outcomes, connect_latency = {}, 0.2
local attempt = 0
local connected_count = 0
local sent = {}        -- { at = seconds, type = "IDENTIFY" }

websocket = {
    EVENT_CONNECTED = "connected",
    EVENT_DISCONNECTED = "disconnected",
    EVENT_ERROR = "error",
    EVENT_MESSAGE = "message",
    connect = function(_url, _params, cb)
        attempt = attempt + 1
        ws_callback_fn = cb
        local outcome = outcomes[attempt] or "ok"
        local conn = { id = attempt }
        if outcome == "hang" then return conn end
        timer.delay(connect_latency, false, function()
            -- A socket the app has closed delivers nothing more. Modelled,
            -- because the whole point of closing an abandoned attempt is that
            -- it stops arriving late and giving the app a second live socket.
            if conn.closed then return end
            if outcome == "ok" then
                connected_count = connected_count + 1
                cb(nil, conn, { event = websocket.EVENT_CONNECTED })
            else
                cb(nil, conn, { event = websocket.EVENT_ERROR, message = "refused" })
            end
        end)
        return conn
    end,
    send = function(_conn, payload)
        local t = payload:match('"type"%s*:%s*"([^"]+)"')
        sent[#sent + 1] = {
            at = NOW, type = t, raw = payload,
            -- Pulled out of the JSON by hand rather than decoded: the harness
            -- has no json decoder, and these two fields are what the device
            -- path is actually about.
            deviceId = payload:match('"deviceId"%s*:%s*"([^"]*)"'),
            id = payload:match('"_id"%s*:%s*"([^"]*)"'),
        }
    end,
    disconnect = function(conn) if conn then conn.closed = true end end,
}

-- Advance the virtual clock, firing timers in order.
local function advance(seconds)
    local target = NOW + seconds
    while true do
        local soonest, id = nil, nil
        for h, t in pairs(timers) do
            if not t.cancelled and t.at <= target and (not soonest or t.at < soonest) then
                soonest, id = t.at, h
            end
        end
        if not id then break end
        local t = timers[id]
        NOW = t.at
        if t.repeating then t.at = NOW + t.interval else timers[id] = nil end
        t.fn()
    end
    NOW = target
end

-- api_service is pulled in lazily (through pcall) for the device id and the
-- FCM token. Stubbed here so the harness controls what the device reports.
local DEVICE_ID = "device-abcdef123456"
package.loaded["modules.api_service"] = {
    get_device_id = function() return DEVICE_ID end,
}

-- Reloaded per case rather than reset. websocket_manager keeps reconnect
-- counters, a pending reconnect handle and the identity in module locals with
-- no public way to clear them, so a case that ends mid-backoff would otherwise
-- hand its state to the next one.
local ws
local function fresh_module()
    package.loaded["modules.websocket_manager"] = nil
    ws = require("modules.websocket_manager")
end

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local USER = { _id = "u123", username = "Ada", balance = 500 }

-- Reset everything and replay the exact sequence controller.script performs
-- once the backend has accepted a sign-in.
local function sign_in(opts)
    opts = opts or {}
    -- next_timer is deliberately NOT reset: ids must stay unique across
    -- cases, or a cancel carried over from the previous one lands on an
    -- unrelated timer in the fresh table.
    NOW, timers, attempt, sent, connected_count = 0, {}, 0, {}, 0
    outcomes = opts.outcomes or {}
    connect_latency = opts.connect_latency or 0.2
    fresh_module()

    -- Boot: the identity provider is registered before anything else.
    ws.set_identity_provider(function() return opts.cached end)

    if not opts.boot_only then
        -- identify_and_connect(user), which is what the sign-in callback runs.
        ws.identify(USER._id, USER.username, { amount = 500, charge = 0 }, "UG")
        ws.connect()
    end
end

local function first_identify_at()
    for _, m in ipairs(sent) do
        if m.type == "IDENTIFY" then return m.at end
    end
    return nil
end

print("THE HAPPY PATH")
sign_in({})
advance(5)
check("IDENTIFY reaches the wire", first_identify_at() ~= nil, true)
check("within a second", (first_identify_at() or 99) <= 1, true)

print("")
print("THE REPORTED CASE: the socket refuses a few times first")
-- Nothing here is exotic. A phone that has just done a Firebase token fetch and
-- an HTTPS round trip is at its busiest, and the first socket attempts losing
-- is ordinary. schedule_reconnect backs off 1, 1.5, 2.25, 3.4, 5, 7.6, 11.4,
-- 17, 25.6 and then 30s a time — so a handful of failures puts the NEXT
-- attempt over a minute away, with the identity sitting queued the whole time.
sign_in({ outcomes = { "error", "error", "error", "error", "error", "error" } })
advance(90)
local t = first_identify_at()
print(string.format("      (IDENTIFY sent at %ss)", tostring(t and math.floor(t) or "never")))
check("it still happens", t ~= nil, true)
-- The promise: a player is never left in suspense for a minute by a few
-- failed connects. The reconciler retries on its own cadence rather than
-- waiting out an exponential backoff that was designed for an idle app.
-- The honest arithmetic with the waiting cap: 1 + 1.5 + 2.25 + 3 + 3 + 3, plus
-- six connect latencies = ~15s.
-- Not instant, because six consecutive failed connects is a genuinely bad
-- network — but seconds, not the half-minute the uncapped backoff reached.
check("and within 16 virtual seconds", (t or 999) <= 16, true)

print("")
print("THE MINUTE, EXACTLY")
-- schedule_reconnect backs off 1, 1.5, 2.25, 3.4, 5, 7.6, 11.4, 17, 25.6 and
-- then MAX_RECONNECT_DELAY (30s) a time. Nine losing attempts therefore put
-- the next one over a minute out, with the identity queued the whole while and
-- the player looking at CONNECTING. That is the report, arithmetic.
sign_in({ outcomes = { "error", "error", "error", "error", "error",
                       "error", "error", "error", "error" } })
advance(180)
local tm = first_identify_at()
print(string.format("      (IDENTIFY sent at %ss)", tostring(tm and math.floor(tm) or "never")))
check("nobody waits a minute", (tm or 999) < 60, true)
-- The actual promise. A player is owed a retry every few seconds while they
-- are staring at CONNECTING, not every thirty.
-- Nine consecutive failures is a broken network, and this does not pretend
-- otherwise. What it promises is that the WAIT is proportional to the
-- failures rather than to an exponential curve designed for an idle app.
check("in fact under 30s", (tm or 999) <= 30, true)

print("")
print("THE HANG: a connect that never reports anything")
-- is_connecting is cleared only by on_connected and on_disconnected. A socket
-- attempt that reports neither leaves it true for ever, and connect() no-ops
-- from then on.
sign_in({ outcomes = { "hang", "ok" } })
advance(40)
local th = first_identify_at()
print(string.format("      (IDENTIFY sent at %ss)", tostring(th and math.floor(th) or "never")))
check("recovered", th ~= nil, true)
check("within the stall window plus a retry", (th or 999) <= 20, true)

print("")
print("BOOT WITH A CACHED SESSION AND NOBODY CALLING IDENTIFY")
-- The other half of the report: "even when I have user in the cache the app is
-- not firing identify when I return". Nothing calls identify() here at all —
-- the reconciler has to find the session by itself.
sign_in({ boot_only = true, cached = USER })
advance(10)
local tb = first_identify_at()
print(string.format("      (IDENTIFY sent at %ss)", tostring(tb and math.floor(tb) or "never")))
check("adopted from cache and sent", tb ~= nil, true)
check("promptly", (tb or 999) <= 8, true)

print("")
print("RETURNING: the app comes back with everything already in hand")
-- The reported case in its own words: "when I return as a returning user make
-- sure the identify is fired instantly since we have user data to use for
-- identify in cache."
--
-- Backgrounding drops the socket, so on resume there is no connection and no
-- registration — but the user id has been known all along. There is nothing to
-- look up, nothing to ask Firebase, and nothing to wait for.

-- (a) resume with the identity still in memory: the socket went, the identity
--     did not. This is the ordinary suspend/resume.
sign_in({ boot_only = true, cached = USER })
advance(3)                          -- boot, identify, connect, get registered
ws.is_identified = true
local dropped_at = NOW
ws.socket_connected = false          -- backgrounded: the socket goes
ws.is_identified = false
sent = {}
ws.start_reconciler()                -- what the focus handler triggers
advance(1)
local tr = first_identify_at()
print(string.format("      (IDENTIFY re-sent %ss after coming back)",
    tostring(tr and math.floor(tr - dropped_at) or "never")))
check("re-identified on return", tr ~= nil, true)
-- "Instantly" means on the frame the app came back, not on the reconciler's
-- next tick. What buys that is start_reconciler() reconciling ON CALL rather
-- than only arming a timer — disable that and this goes to "never".
check("instantly, not on the next tick", (tr or 999) - dropped_at <= 0.5, true)

-- (b) resume after the identity was dropped too, with only the cache left.
--     Adopting has to lead straight on to connecting rather than stopping for
--     a tick in between.
sign_in({ boot_only = true, cached = USER })
advance(3)
ws.is_identified = true
ws.socket_connected = false
ws.is_identified = false
ws.reset_identity()                  -- nothing left but the cached session
local dropped2 = NOW
sent = {}
ws.start_reconciler()
advance(1)
local tr2 = first_identify_at()
print(string.format("      (IDENTIFY re-sent %ss after coming back)",
    tostring(tr2 and math.floor(tr2 - dropped2) or "never")))
check("adopted from cache and re-identified", tr2 ~= nil, true)
-- NOTE on what this does and does not pin. It stays green even with the
-- reconciler reduced to one action per call, because adopt goes through
-- identify(), which re-enters start_reconciler and so continues the chain
-- itself. The bounded loop in reconcile() is therefore belt-and-braces for
-- actions that have no such re-entry, not the thing making this case fast.
check("adopting leads straight on to connecting", (tr2 or 999) - dropped2 <= 0.5, true)

print("")
print("A SLOW BUT WORKING HANDSHAKE IS NOT KILLED FOR BEING SLOW")
-- CONNECT_STALL_SECONDS decides when an in-flight attempt is declared hung.
-- Set it below what a real handshake takes on a bad link and the app tears
-- down connections that were about to succeed, over and over, and a player on
-- rural 3G never gets online at all — the opposite of the bug it exists for.
--
-- Five seconds of TCP+TLS is unremarkable on a congested cell.
sign_in({ connect_latency = 5 })
-- 12s, not 30: past the 10s stall window and the 5s handshake, but short of
-- the zombie watchdog at 13s. A reconnect it triggers is legitimate, and
-- counting it would make the single-socket assertion below meaningless.
advance(12)
local tslow = first_identify_at()
print(string.format("      (IDENTIFY sent at %ss, stall window is %ss)",
    tostring(tslow and math.floor(tslow) or "never"),
    tostring(require("modules.connection_plan").CONNECT_STALL_SECONDS)))
check("a slow link still gets identified", tslow ~= nil, true)
-- Generous: what matters is that it converges rather than churning for ever.
check("without churning indefinitely", (tslow or 999) <= 12, true)
-- And with ONE socket, not two. Abandoning an attempt without closing it left
-- the old handshake to complete a moment later and fire on_connected for a
-- socket the app had already replaced — two live connections, and the server
-- holding two registrations for one player.
check("and with a single live socket", connected_count, 1)

print("")
print("NO CACHE AT ALL: IDENTIFY BY DEVICE ID")
-- The remaining hole, and the reason CONNECTING could stick for a returning
-- player: with no cached session the client had NOTHING to send, so it sent
-- nothing. A fresh install over an old one, a cleared cache, or a session
-- wiped by a transient failure all land here — and the device id, which the
-- app has always had, identifies the player perfectly well.
sign_in({ boot_only = true, cached = nil })
advance(1)
local td = first_identify_at()
print(string.format("      (IDENTIFY sent at %ss)", tostring(td and math.floor(td) or "never")))
check("it identifies anyway", td ~= nil, true)
check("instantly", (td or 999) <= 0.5, true)

local function last_identify_payload()
    for i = #sent, 1, -1 do
        if sent[i].type == "IDENTIFY" then return sent[i] end
    end
end
check("carrying the device id", (last_identify_payload() or {}).deviceId, DEVICE_ID)
check("and no user id, because there is none", (last_identify_payload() or {}).id, "")

print("")
print("...and it stops asking once the server says it does not know us")
-- The answer cannot change until somebody signs in, so re-asking every few
-- seconds is just noise on a device that has genuinely never had an account.
-- Fed through the real socket callback rather than a test-only export, so it
-- travels the same path a server message actually does.
ws_callback_fn(nil, {}, {
    event = websocket.EVENT_MESSAGE,
    message = '{"type":"IDENTIFY_UNKNOWN","data":{"message":"nope"}}',
})
local before = #sent
advance(30)
local extra = 0
for i = before + 1, #sent do
    if sent[i].type == "IDENTIFY" then extra = extra + 1 end
end
check("no further device identifies", extra, 0)

print("")
print("FIRST LOGIN, NO CACHE: THE EXACT SEQUENCE THE APP RUNS")
-- Reported as "the current login is unpredictable, at times it works and at
-- times it doesn't". This replays what boot actually does on a device with no
-- cached session:
--
--   1. controller.script calls ws.connect() straight away, so the socket is
--      already handshaking before anybody has an identity
--   2. the reconciler finds no cache and identifies by DEVICE id
--   3. seconds later POST /auth/firebase returns and identify_and_connect runs
--      with the real user id
--
-- Every one of those can land while the previous is still in flight, which is
-- exactly the shape that produces "sometimes".
local attempts_at_sign_in = 0
local function first_login_no_cache(firebase_at, opts)
    opts = opts or {}
    sign_in({ boot_only = true, cached = nil,
              outcomes = opts.outcomes, connect_latency = opts.connect_latency })
    ws.connect()                       -- boot connects with no identity yet
    advance(firebase_at)
    sent = {}                          -- only count what the sign-in produces
    attempts_at_sign_in = attempt
    -- identify_and_connect(user), verbatim.
    ws.identify(USER._id, USER.username, { amount = 500, charge = 0 }, "UG")
    ws.connect()
    advance(opts.settle or 6)
end

local function identify_with_user_id()
    for _, m in ipairs(sent) do
        if m.type == "IDENTIFY" and m.id == USER._id then return m.at end
    end
end

-- (a) Firebase lands AFTER the socket is already open and device-identified.
first_login_no_cache(2)
local ta = identify_with_user_id()
print(string.format("      (socket already open: user IDENTIFY at +%ss)",
    tostring(ta and string.format("%.1f", ta - 2) or "never")))
check("the real user id is sent", ta ~= nil, true)
check("instantly", (ta and ta - 2 or 99) <= 0.5, true)

-- (b) Firebase lands WHILE the socket is still handshaking. The awkward one:
--     identify() cannot send yet, so it has to be queued and flushed on open.
first_login_no_cache(0.1, { connect_latency = 3 })
local tb = identify_with_user_id()
print(string.format("      (mid-handshake: user IDENTIFY at +%ss)",
    tostring(tb and string.format("%.1f", tb - 0.1) or "never")))
check("still sent once the socket opens", tb ~= nil, true)

-- (c) Firebase lands while the boot connect is HUNG and no event is coming —
--     the ordinary shape of a first login, where the socket was opened at boot
--     and the player then spent real seconds typing a number and waiting for a
--     code. The sign-in inherited that dead socket and sat on it until the 10s
--     backstop noticed, which is the "sometimes it works" being reported: it
--     depended entirely on whether the boot socket happened to come up.
first_login_no_cache(8, { outcomes = { "hang", "ok" } })
local tc = identify_with_user_id()
print(string.format("      (boot connect hung for 8s: user IDENTIFY at +%ss)",
    tostring(tc and string.format("%.1f", tc - 8) or "never")))
check("the hung attempt does not swallow the sign-in", tc ~= nil, true)
check("and the sign-in does not wait out the 10s backstop for it",
    (tc and tc - 8 or 99) <= 1, true)
check("it opened a fresh socket rather than reusing the dead one",
    attempt > attempts_at_sign_in, true)

-- (d) THE OTHER SIDE OF THE SAME NUMBER, and the reason it is not smaller.
--     A slow link is indistinguishable from a hung one except by how long it
--     has had. A sign-in landing 1s into a 5s handshake must NOT tear it down:
--     doing so throws away the attempt that was about to succeed and buys a
--     second full handshake. That is the starvation bug that CONNECT_STALL
--     already had once, and a grace below a real handshake reintroduces it.
first_login_no_cache(1, { connect_latency = 5, settle = 10 })
local td = identify_with_user_id()
print(string.format("      (sign-in 1s into a 5s handshake: user IDENTIFY at +%ss)",
    tostring(td and string.format("%.1f", td - 1) or "never")))
check("the working handshake is left alone", attempt, attempts_at_sign_in)
check("and it identifies as soon as that socket opens",
    (td and td - 1 or 99) <= 4.5, true)

-- (e) A hang that is still YOUNG at sign-in cannot be told apart from (d), so
--     it rides — and the passive backstop is what catches it. Stated as a
--     bound rather than left to be assumed: this is the worst case the design
--     accepts, and naming it is what stops it quietly growing.
first_login_no_cache(1, { outcomes = { "hang", "ok" }, settle = 20 })
local te = identify_with_user_id()
print(string.format("      (sign-in 1s into a hang: user IDENTIFY at +%ss)",
    tostring(te and string.format("%.1f", te - 1) or "never")))
check("it still gets there", te ~= nil, true)
check("bounded by the 10s backstop, not unbounded", (te and te - 1 or 99) <= 10, true)

print("")
print("NO DEVICE ID EITHER MEANS NO SOCKET")
-- The only case left where holding a socket open buys nothing.
DEVICE_ID = ""
sign_in({ boot_only = true, cached = nil })
advance(20)
check("nothing is sent", first_identify_at(), nil)
check("and no socket is opened", attempt, 0)
DEVICE_ID = "device-abcdef123456"

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
