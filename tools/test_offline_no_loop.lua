-- AN APP THAT IS OFFLINE MUST ALSO STOP TRYING TO CONNECT.
--
--   Run: lua tools/test_offline_no_loop.lua
--
-- Reported: after an account was unblocked, the app "makes multiple online
-- connection pings instead of doing ping and making user online once", and
-- "keeps connecting and disconnecting".
--
-- The refusal was answered in two places and driven from a third. connect()
-- refused while the latch was up, and on_disconnected() scheduled no retry —
-- but connection_plan, which is what actually DECIDES to connect, was never
-- told the latch existed. Its state table carried update_required and nothing
-- else, so every tick it went on returning "adopt_device", then "connect".
--
-- adopt_device calls identify(), and identify() restarts the reconciler
-- immediately rather than waiting for the next tick — so this did not even
-- cost one round per second. It spun, refused one call deeper each time, for
-- as long as the app was open. Before the latch reached connect() at all, the
-- same decisions opened real sockets: connect, get refused on IDENTIFY, clear
-- the session, disconnect, adopt the device id, connect again.
--
-- These run the planner rather than reading it.
package.path = "./?.lua;" .. package.path
local plan = require("modules.connection_plan")

local failures = 0
local function check(label, got, want, why)
    if got == want then
        print(string.format("  PASS %s (got %s)", label, tostring(got)))
    else
        failures = failures + 1
        print(string.format("  FAIL %s  <- got %s, want %s%s", label,
            tostring(got), tostring(want), why and ("  (" .. why .. ")") or ""))
    end
end

-- The state the app is left in the instant the server refuses the account:
-- clear_session has wiped the cached user and torn the socket down, and the
-- device id is deliberately kept.
local function refused(extra)
    local s = {
        identity = nil, socket_connected = false, is_connecting = false,
        is_identified = false, connecting_for = 0, since_identify = 1e9,
        has_cached_identity = false, reconnect_scheduled = false,
        has_device_identity = true, device_identity_refused = false,
        update_required = false, app_offline = true, app_offline_recheck = false,
    }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

print("")
print("A REFUSED ACCOUNT STOPS THE PLANNER, NOT JUST connect()")

check("nothing is attempted while the app is offline",
    plan.next_action(refused()), "idle",
    "adopt_device here is the loop: it identifies, which reconciles, which connects")

-- The exact shape of the bug: the field simply was not passed, so the planner
-- decided as though the app were healthy.
--
-- Written `false` rather than `nil` on purpose. Setting a key to nil in the
-- overrides table is invisible to pairs(), so the base `true` survived and
-- this "control" passed while proving nothing — which is precisely the thing
-- it exists to rule out. false and nil read identically to the planner.
check("and it is the flag doing it, not the rest of the state",
    plan.next_action(refused({ app_offline = false })), "adopt_device",
    "if this is idle for some other reason the test above proves nothing")

check("a socket that somehow survived is not re-identified either",
    plan.next_action(refused({ socket_connected = true, identity = { _id = "u1" } })), "idle",
    "re-sending IDENTIFY is the refusal asked for again on a live connection")

check("nor is a cached session adopted to try it with",
    plan.next_action(refused({ has_cached_identity = true })), "idle")

check("and a hung attempt is not unstuck into a fresh one",
    plan.next_action(refused({
        is_connecting = true, connecting_for = plan.CONNECT_STALL_SECONDS + 5,
    })), "idle",
    "unstick closes the socket and reconnects, which is the churn itself")

print("")
print("BUT IT IS A WINDOW, NOT A WALL")
-- The difference from update_required, and the reason this is not simply
-- "idle". A build the server has outgrown cannot become acceptable without a
-- new binary. A block is lifted server-side with nothing happening on the
-- phone — so an app that never asks again can never come back, which is the
-- other half of the report: the account WAS unblocked.

check("one attempt is allowed when the recheck window opens",
    plan.next_action(refused({ app_offline_recheck = true })), "adopt_device",
    "without this an unblocked account is offline forever")

check("and an update is still a wall, because that one cannot change",
    plan.next_action(refused({
        update_required = true, app_offline_recheck = true,
    })), "idle",
    "a refused build stays refused until the binary changes")

print("")
print("AND A HEALTHY APP IS UNTOUCHED")
check("still connects when nothing is refusing it",
    plan.next_action(refused({ app_offline = false, identity = { _id = "u1" } })), "connect")
check("still idles once identified",
    plan.next_action(refused({
        app_offline = false, identity = { _id = "u1" },
        socket_connected = true, is_identified = true,
    })), "idle")

-- ---------------------------------------------------------------------------
-- AND THE MANAGER HAS TO ACTUALLY TELL IT.
--
-- Everything above is inert if reconcile_step goes on building the state table
-- without these two fields — which is exactly what the bug was. The planner
-- was always capable of the right answer; it was never asked the question.
-- ---------------------------------------------------------------------------
print("")
print("THE STATE TABLE CARRIES THE FLAG")
local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local t = f:read("*a"); f:close(); return t
end
local ws = slurp("modules/websocket_manager.lua")
local step = ws:match("local function reconcile_step%(%)(.-)\n  end") or ""

local function check_true(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

check_true("reconcile_step passes app_offline",
    step:find("app_offline%s*=%s*M%.app_offline"),
    "the planner cannot act on a field it is never given")
check_true("and the recheck window with it",
    step:find("app_offline_recheck%s*=%s*M%.app_offline_recheck_due%(%)"),
    "without it the window never opens and an unblocked account stays offline")

print("")
print("THE PROBE IS SPENT WHEN IT IS TAKEN")
local conn = ws:match("function M%.connect%(%)(.-)\nend") or ""
check_true("connect() lets the probe through when due",
    conn:find("if not M%.app_offline_recheck_due%(%) then"),
    "a flat refusal here means the window can never be used")
check_true("and closes the window on the attempt, not on its answer",
    conn:find("app_offline_at = now_s%(%)"),
    "left open, the one probe is retried every tick — the loop again")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
