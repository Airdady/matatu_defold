-- SIGNING UP WITHOUT A PHONE, AND BEING SHOWN THE DOOR WHEN BLOCKED.
--
--   Run: lua tools/test_blocked_and_signup.lua
--
-- Three reports.
--
-- 1. A new player who skips phone linking is told "User ID required" when they
--    save a username and avatar. The refusal was HERE, on the handset, before
--    any request left it — and for that player there genuinely is no id,
--    because nothing on that path creates an account.
--
-- 2. A blocked account is reported on IDENTIFY and the app never read it. The
--    flag arrived on every sign-in and was ignored, so a suspended player
--    carried on as normal until they happened to touch an HTTP route the block
--    middleware guards.
--
-- 3. A blocked player must not be able to sign in again. The 403 fell into
--    handle_login_failure, which treats everything as transient — its own
--    comment said "the one answer that is not — DEVICE_UNKNOWN — never enters
--    this function" — so the app retried silently, forever, against a route
--    that was never going to say yes.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end

local api  = slurp("modules/api_service.lua")
local ctrl = slurp("main/controller.script")
local ws   = slurp("modules/websocket_manager.lua")

print("saving a profile no longer needs an account to already exist")
local fn = api:match("function M%.update_profile%(user_id, payload, cb%)(.-)\nend")
check_true("the function was found", fn ~= nil, "update_profile missing")
check_true("it no longer refuses on the handset",
    fn and not fn:find("User ID required"),
    "the client answered its own request with an error the player could not act on")
check_true("with no id it creates instead",
    fn and fn:find('request%("POST", "/auth/device/profile", payload, cb%)'),
    "no create path")
check_true("with an id it still updates",
    fn and fn:find('request%("PUT", "/users/" %.%. user_id, payload, cb%)'),
    "the existing path must be untouched")
check_true("and the device id is attached either way",
    fn and fn:find("payload%.deviceId = payload%.deviceId or M%.get_device_id%(%)"),
    "the account is addressed by it on create and backfilled on update")

print("")
print("and the app adopts the account the save just created")
local saver = ctrl:match('message_id == hash%("profile_save"%) then(.-)elseif message_id ==')
check_true("the handler was found", saver ~= nil, "profile_save missing")
check_true("it takes the id from the response",
    saver and saver:find("user%._id = merged%._id"),
    "identifying with the empty id opens a socket for nobody")
check_true("and re-points uid before identifying",
    saver and saver:find("uid = user%._id or uid"), "stale uid")
check_true("it keeps the token a new account comes back with",
    saver and saver:find("api%.set_auth_token, data%.token"),
    "the credential for everything afterwards")
-- Ordering: the id must be adopted BEFORE identify is called with it.
local adopt = saver and saver:find("uid = user%._id or uid")
local ident = saver and saver:find("ws%.identify%(uid")
check_true("the id is adopted before identify runs",
    adopt and ident and adopt < ident, "identify would use the empty id")

print("")
print("a blocked account is reported and acted on")
check_true("the socket reads isBlocked on identify",
    ws:find("if M%.current_user_data%.isBlocked == true then") ~= nil,
    "the flag arrived and nothing read it")
check_true("and says so",
    ws:find('emit%("account_blocked"') ~= nil, "no signal")
-- It must stop BEFORE the app is put back together around a blocked user.
local blk = ws:find("if M%.current_user_data%.isBlocked == true then")
local ok_emit = ws:find('emit%("identify_success"')
check_true("before identify_success puts them back in the app",
    blk and ok_emit and blk < ok_emit, "too late to matter")
check_true("and it returns rather than falling through",
    ws:match("isBlocked == true then(.-)\n    end"):find("return"),
    "must not continue into the game-state restore")

print("")
print("the app wipes itself and signs out")
local handler = ctrl:match('ws%.on%("account_blocked", function%(info%)(.-)end%)%)')
check_true("there is a handler", handler ~= nil, "nothing listens")
check_true("local session cleared", handler and handler:find("clear_session%(%)"), "session kept")
check_true("stored session cleared too",
    handler and handler:find("api%.clear_session"), "the file on disk survives a restart")
check_true("and it goes back to sign-in",
    handler and handler:find('show%(self, "auth"%)'), "left inside the app")
-- The device id is how the server recognises the handset. Clearing it would
-- hand a blocked player a fresh one, which is the opposite of the point.
check_true("the device id is deliberately NOT wiped",
    ctrl:find("Deliberately does NOT touch the device id") ~= nil,
    "wiping it would let a blocked player start over")

print("")
print("and cannot sign in again")
local dev = ctrl:match("handle_device_result = function%(self, result%)(.-)\n%-%- ")
    or ctrl:match("handle_device_result = function%(self, result%)(.-)local function")
check_true("the device result handler was found", dev ~= nil, "not found")
check_true("a blocked answer is intercepted",
    dev and dev:find('data%.error == "ACCOUNT_BLOCKED" or result%.status_code == 403'),
    "falls through to the transient retry")
check_true("and does not retry",
    dev and dev:find("cancel_silent_login_retry%(self%)"), "would hammer the route forever")
-- The interception has to come BEFORE the transient branch or it never runs.
local blocked_at = dev and dev:find('ACCOUNT_BLOCKED')
local transient_at = dev and dev:find("handle_login_failure%(self, result%.message")
check_true("intercepted before the transient branch",
    blocked_at and transient_at and blocked_at < transient_at,
    "order decides whether it runs at all")
check_true("and the stale comment about the only non-transient answer is fixed",
    ctrl:find("DEVICE_UNKNOWN and ACCOUNT_BLOCKED") ~= nil,
    "it named DEVICE_UNKNOWN as the only one, which is what let this through")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
