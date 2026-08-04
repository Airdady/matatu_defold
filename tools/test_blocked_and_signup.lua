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
-- Deliberately NOT the sign-in screen any more. It was, and that was wrong:
-- there is nothing to sign in with and nothing the player can do there, so it
-- was a dead end dressed as an action. They keep the app and the lobby says
-- the online half is unavailable.
check_true("and it leaves them in the lobby with the app",
    handler and handler:find('show%(self, "lobby"%)'), "thrown out to a login they cannot pass")
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

-- ── the wording, and what the player keeps ─────────────────────────────────
--
-- Asked for: say "App Offline" rather than "account blocked", and leave the
-- player with the app. The point is not euphemism — it is that the sentence
-- should describe a state of the app rather than pass judgement on a person,
-- and that everything not needing the server should keep working.
print("")
print("a refused account is told the app is offline")

check_true("neither path calls the player suspended",
    not ctrl:find("This account has been suspended"),
    "written for staff, reads as an accusation on a phone")
check_true("both say App Offline instead",
    select(2, ctrl:gsub('app_state%.blocked_reason = "App Offline"', '')) == 2,
    "the socket path and the sign-in path must agree")
check_true("and the server's own reason is not shown",
    not ctrl:find("app_state.blocked_reason = tostring(data.reason"),
    "it is staff wording; it stays in the logs")
check_true("but is still logged",
    ctrl:find('auth_debug%("account blocked %- going offline %(%%s%)", reason%)') ~= nil,
    "support needs to know why; the player does not need to be told")

print("")
print("and keeps the app")
-- Each app_offline block on its own, bounded by the `end` that closes it.
-- Lua's `.-` is lazy but unbounded, so a whole-file match happily reaches a
-- `show(self, "auth")` hundreds of lines away in an unrelated handler and
-- reports a failure that is not there.
local offline_blocks = {}
for blk in ctrl:gmatch('app_state%.app_offline = true(.-)\n    end') do
    offline_blocks[#offline_blocks + 1] = blk
end
check_true("both app-offline paths were found", #offline_blocks >= 2,
    "found " .. #offline_blocks)
local goes_to_auth = false
for _, blk in ipairs(offline_blocks) do
    if blk:find('show%(self, "auth"%)') then goes_to_auth = true end
end
check_true("they land on the lobby, not a sign-in screen", not goes_to_auth,
    "there is nothing to sign in with and nothing they can do there")
for _, blk in ipairs(offline_blocks) do
    check_true("and each one actually shows the lobby",
        blk:find('show%(self, "lobby"%)') ~= nil, "no destination")
end
check_true("the toast is informational, not an error",
    ctrl:find('toast"%)%.info%("App Offline') ~= nil, "an error toast reads as a fault")

print("")
print("the tile says so without inviting a retry")
local status = slurp("modules/lobby/online_status.lua")
local lobby  = slurp("main/lobby.gui_script")

check_true("there is a distinct app_offline state",
    status:find('if f%.app_offline then return "app_offline" end') ~= nil,
    "reusing 'offline' would render RETRY")
check_true("and it is terminal, deciding before everything else",
    (status:find("f%.app_offline") or math.huge) < (status:find("if f%.is_identified") or 0),
    "anything checked first could out-vote it")
check_true("the lobby passes the flag",
    lobby:find("app_offline%s*= app_state%.app_offline == true") ~= nil, "never reaches the tile")
check_true("the tile reads APP OFFLINE",
    lobby:find('cta_text = "APP OFFLINE"') ~= nil, "no label")
-- The BRANCH, comments stripped. The comment in that branch says "No RETRY
-- here", which a raw text search finds and reports as the very thing the
-- comment is promising does not happen.
local branch = lobby:match('if st == "app_offline" then(.-)elseif is_exhausted then') or ""
local branch_code = (branch:gsub("%-%-[^\n]*", ""))
check_true("the branch was found", branch ~= "", "pattern missed it")
check_true("and offers no RETRY, which could never succeed",
    not branch_code:find("RETRY"),
    "a button that invites the player to ask a question already answered")
check_true("while the genuine offline state still does offer one",
    lobby:match('elseif is_exhausted then(.-)elseif') and
        lobby:match('elseif is_exhausted then(.-)elseif'):find('cta_text = "RETRY"'),
    "a dropped connection IS worth retrying; this must not have removed that")
check_true("while saying the rest of the app still works",
    lobby:find("Everything else still works") ~= nil,
    "the player should know what they still have")

check_true("and a successful identify clears it",
    ctrl:find("app_state%.app_offline = false") ~= nil,
    "terminal until the server itself says otherwise, which an identify IS")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
