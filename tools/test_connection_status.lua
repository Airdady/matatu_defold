-- A SPINNER THAT PROMISES SOMETHING NOBODY IS DOING.
--
--   Run: lua tools/test_connection_status.lua
--
-- Reported as: a "RECONNECTING…" badge appears top-right, and while it is up
-- the app sends nothing to the backend at all — for a minute or more.
--
-- BOTH HALVES WERE TRUE, AND THEY WERE TRUE TOGETHER
--
-- The badge was driven by the raw `disconnected` event. on_disconnected emits
-- that BEFORE it decides whether it is going to reconnect:
--
--     emit("disconnected", reason)                     -- badge -> RECONNECTING
--     if is_manual_disconnect then return end           -- nothing scheduled
--     if M.update_required then return end              -- nothing, ever
--     if M.app_offline then return end                  -- nothing for 15 min
--     schedule_reconnect()
--
-- So in three separate cases the badge announced a reconnect that had already
-- been ruled out, and nothing on screen or in the code could tell those apart
-- from a real one:
--
--   * a manual teardown — until something else happens to call connect()
--   * update_required — terminal until the app is updated
--   * app_offline — silent for APP_OFFLINE_RECHECK_SECONDS, FIFTEEN MINUTES
--
-- The badge is not the bug on its own. The bug is that nothing owned the
-- answer to "what is this connection doing": next_action owned what to DO, and
-- the UI guessed separately from two events. connection_plan.status now
-- answers it from the same inputs, so the two cannot disagree.
--
-- The last block is the property that would have caught this on the day it was
-- written, and it is the reason this file exists rather than four spot checks.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local CP = require("modules.connection_plan")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

-- A signed-in player whose socket is up and identified: the resting state.
local function online(over)
    local s = {
        identity = { _id = "u1" },
        has_cached_identity = true,
        has_device_identity = true,
        socket_connected = true,
        is_identified = true,
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

print("the states that used to lie")
do
    -- The exact three. Each one leaves on_disconnected without scheduling
    -- anything, and each one used to render as RECONNECTING….
    check("a refused build says so",
        CP.status(online({ socket_connected = false, is_identified = false,
                           update_required = true })),
        "update_required")

    check("a blocked account says so",
        CP.status(online({ socket_connected = false, is_identified = false,
                           app_offline = true })),
        "blocked")

    check("and exhausted retries offer the retry, not a spinner",
        CP.status(online({ socket_connected = false, is_identified = false,
                           reconnect_exhausted = true })),
        "offline")
end

print("")
print("and the states that are genuinely in flight still say so")
do
    check("a retry on the clock is reconnecting",
        CP.status(online({ socket_connected = false, is_identified = false,
                           reconnect_scheduled = true })),
        "reconnecting")

    check("an attempt in flight is connecting",
        CP.status(online({ socket_connected = false, is_identified = false,
                           is_connecting = true })),
        "connecting")

    -- A socket that is UP but not identified is a different problem from one
    -- that dropped — the link works and the server has not answered — and
    -- saying "reconnecting" sent everyone looking at the wrong half.
    check("a socket awaiting IDENTIFY is connecting, not reconnecting",
        CP.status(online({ is_identified = false })),
        "connecting")

    -- Nothing in flight, nothing scheduled, but somebody to be: the
    -- reconciler is about to open a socket. Not a resting state, and not a
    -- failure to report either.
    check("and a gap before the reconciler ticks is connecting",
        CP.status(online({ socket_connected = false, is_identified = false })),
        "connecting")
end

print("")
print("nothing is reported when nothing is wanted")
do
    check("identified is online", CP.status(online()), "online")
    check("signed out is signed out", CP.status({}), "signed_out")
    check("and a device the server has disowned is too",
        CP.status({ has_device_identity = true, device_identity_refused = true }),
        "signed_out")
    check("but a device it has NOT disowned is worth connecting for",
        CP.status({ has_device_identity = true }), "connecting")
    check("and so is a session on disk",
        CP.status({ has_cached_identity = true }), "connecting")
end

print("")
print("precedence matches next_action's, because they answer one question")
do
    -- If these two disagreed about which rule wins, the spinner would drift
    -- out of step with the loop again — differently, but just as invisibly.
    local s = online({ socket_connected = false, is_identified = false,
                       update_required = true, app_offline = true,
                       reconnect_exhausted = true, reconnect_scheduled = true })
    check("a refused build outranks everything", CP.status(s), "update_required")
    s.update_required = false
    check("then a blocked account", CP.status(s), "blocked")
    s.app_offline = false
    check("then exhausted retries", CP.status(s), "offline")
end

print("")
print("the spinner only animates for states that are actually trying")
do
    check("connecting animates", CP.status_is_active("connecting"), true)
    check("reconnecting animates", CP.status_is_active("reconnecting"), true)
    check("offline does not", CP.status_is_active("offline"), false)
    check("blocked does not", CP.status_is_active("blocked"), false)
    check("update_required does not", CP.status_is_active("update_required"), false)
    check("online does not", CP.status_is_active("online"), false)
end

print("")
print("THE PROPERTY: a spinner is a promise that something is in flight")
do
    -- Every combination of the flags that matter, checked against the planner
    -- itself. Wherever next_action decides to do NOTHING, status must not
    -- claim a reconnect is happening — that equivalence is the whole bug,
    -- stated once, instead of four examples of it.
    local flags = {
        "update_required", "app_offline", "socket_connected", "is_connecting",
        "is_identified", "reconnect_scheduled", "reconnect_exhausted",
        "has_cached_identity", "has_device_identity", "device_identity_refused",
    }
    local n = #flags
    local checked, bad = 0, {}
    for mask = 0, (2 ^ n) - 1 do
        local s = {}
        for i = 1, n do
            if math.floor(mask / (2 ^ (i - 1))) % 2 == 1 then s[flags[i]] = true end
        end
        -- Both with and without an identity in memory.
        for _, ident in ipairs({ false, true }) do
            s.identity = ident and { _id = "u1" } or nil
            local action = CP.next_action(s)
            local status = CP.status(s)
            checked = checked + 1
            if action == "idle" and status == "reconnecting" then
                bad[#bad + 1] = string.format("mask=%d identity=%s", mask, tostring(ident))
            end
            -- And the converse: if the planner IS about to act, the UI must
            -- not be telling the player it has given up.
            if (action == "connect" or action == "identify" or action == "unstick")
               and (status == "offline" or status == "signed_out") then
                bad[#bad + 1] = string.format("gave-up-but-acting mask=%d identity=%s",
                    mask, tostring(ident))
            end
        end
    end
    check("every combination was examined", checked, 2048)
    check("and none of them promises a reconnect nobody is doing", #bad, 0)
    if #bad > 0 then
        for i = 1, math.min(5, #bad) do print("      " .. bad[i]) end
    end
end

print("")
print("and the app is wired to the resolved status, not the raw events")
do
    local here = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
    local function read(rel)
        local f = assert(io.open(here .. "../" .. rel, "r"))
        local s = f:read("*a"); f:close()
        -- Comments stripped: both files explain this change at length and
        -- QUOTE the code being asserted absent.
        return (s:gsub("%-%-[^\n]*", ""))
    end
    local net = read("main/network.gui_script")
    local wsm = read("modules/websocket_manager.lua")

    check("the badge subscribes to connection_status",
        net:match('ws%.on%("connection_status"') ~= nil, true)
    check("and no longer guesses from `disconnected`",
        net:match('ws%.on%("disconnected"') ~= nil, false)
    check("nor from `connection_error`",
        net:match('ws%.on%("connection_error"') ~= nil, false)

    -- A screen can be built long after the connection settled into whatever
    -- it is doing; without this it shows nothing until the next change.
    check("and it reads the status once at build time",
        net:match("apply_status%(ws%.connection_status%(%)%)") ~= nil, true)

    check("the manager publishes it", wsm:match("emit%(\"connection_status\"") ~= nil, true)
    -- Published from on_disconnected specifically, which is where the three
    -- silent early returns live — and BEFORE them, by position.
    --
    -- The first version of this only asked whether "publish_status" appeared
    -- anywhere in the function. It does: there is a second call after
    -- schedule_reconnect. So the check passed with the important one deleted,
    -- which is the same class of mistake as the bug it is guarding —
    -- something that looks like a check and is not one. Positions, not
    -- presence.
    local dis = wsm:match("on_disconnected = function.-\nend")
    check("on_disconnected exists", dis ~= nil, true)
    if dis then
        local first_publish = dis:find("publish_status%(%)")
        local first_return = dis:find("if is_manual_disconnect then")
        check("it publishes before the manual-teardown return",
            first_publish ~= nil and first_return ~= nil and first_publish < first_return, true)
        check("and before the update_required return",
            first_publish ~= nil and first_publish < (dis:find("M%.update_required") or 0), true)
        check("and before the app_offline return",
            first_publish ~= nil and first_publish < (dis:find("M%.app_offline") or 0), true)
    end
    check("and the reconciler publishes as a backstop",
        wsm:match("local function reconcile%(%).-publish_status") ~= nil, true)

    -- Only announce real changes: emitting every second would make the log
    -- useless for exactly the problem it is meant to explain.
    check("and only when the status actually changed",
        wsm:match("if status == last_published_status then return end") ~= nil, true)
end

print("")
if failures == 0 then
    print("ALL PASSED")
else
    print(failures .. " FAILED")
    os.exit(1)
end
