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

-- Scriptable socket. `outcomes` is consumed one entry per connect attempt:
--   "ok"      connects after `connect_latency`
--   "error"   reports EVENT_ERROR after `connect_latency`
--   "hang"    never reports anything at all
local ws_callback_fn = nil
local outcomes, connect_latency = {}, 0.2
local attempt = 0
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
            if outcome == "ok" then
                cb(nil, conn, { event = websocket.EVENT_CONNECTED })
            else
                cb(nil, conn, { event = websocket.EVENT_ERROR, message = "refused" })
            end
        end)
        return conn
    end,
    send = function(_conn, payload)
        local t = payload:match('"type"%s*:%s*"([^"]+)"')
        sent[#sent + 1] = { at = NOW, type = t }
    end,
    disconnect = function() end,
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
    NOW, timers, attempt, sent = 0, {}, 0, {}
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
print("NO SESSION MEANS NO SOCKET")
sign_in({ boot_only = true, cached = nil })
advance(20)
check("nothing is sent", first_identify_at(), nil)
check("and no socket is opened", attempt, 0)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
