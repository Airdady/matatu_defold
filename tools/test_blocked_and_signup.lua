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
-- THREE sites, not two: the socket path, the sign-in path, and the boot
-- restore that reads the latch back off disk. Asserted as "at least the two
-- decision paths, and every one of them says the same thing" rather than as an
-- exact count, which would fail the moment a fourth legitimate site appeared.
local offline_wordings = select(2, ctrl:gsub('app_state%.blocked_reason = "App Offline"', ''))
check_true("every path says App Offline", offline_wordings >= 3,
    "found " .. offline_wordings .. "; the socket path, the sign-in path and the boot restore must agree")
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
-- Only the two paths that DECIDE the app is offline route anywhere. The boot
-- restore also sets the flag but is inside init(), where there is no screen to
-- move to and nothing has been shown yet — requiring a destination there would
-- be asking for a navigation that makes no sense.
local routed = 0
for _, blk in ipairs(offline_blocks) do
    if blk:find('show%(self, "lobby"%)') then routed = routed + 1 end
end
check_true("the two decision paths both land on the lobby", routed >= 2,
    "routed " .. routed .. " of " .. #offline_blocks)
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

-- ── persistent, and silent ─────────────────────────────────────────────────
--
-- Asked for: show offline persistently, stop calling the backend to reconnect,
-- and keep the state in the local cache.
--
-- The point is that a refusal is a permanent answer. Retrying it is a loop
-- that burns battery and radio to be told the same thing, and holding it only
-- in memory means every cold start rediscovers it — a device sign-in, a 403
-- and a socket attempt, on every launch, forever.
print("")
print("the offline state is latched, not rediscovered")

check_true("the socket latches it",
    ws:find("M%.app_offline = false") ~= nil and ws:find("M%.app_offline = true") ~= nil,
    "no latch")
check_true("connect() is refused while it is set",
    ws:match("function M%.connect%(%)(.-)\nend"):find("if M%.app_offline then"),
    "every route to a socket goes through connect; refusing there stops them all")
check_true("and no reconnect is scheduled",
    ws:find('print%("%[WS%] not reconnecting: app offline"%)') ~= nil,
    "the reconnect loop would ask again on a timer")

-- Latched BEFORE the listeners run: one of them disconnects, and a disconnect
-- schedules a reconnect unless the flag is already set.
local blk_at = ws:find("M%.app_offline = true")
local emit_at = ws:find('emit%("account_blocked"')
check_true("latched before the listeners can disconnect",
    blk_at and emit_at and blk_at < emit_at,
    "a disconnect during the emit would schedule a reconnect")

print("")
print("and it survives a restart, from the local cache")
check_true("there is a file for it, separate from the session",
    api:find('local OFFLINE_FILE = sys%.get_save_file%("matatu_gdt", "offline%.json"%)') ~= nil,
    "the session is cleared when going offline; this has to outlive that")
for _, fn in ipairs({ "set_app_offline", "clear_app_offline", "is_app_offline" }) do
    check_true("api." .. fn, api:find("function M%." .. fn) ~= nil, "missing")
end
-- Bounded by the RESTORE BLOCK itself. A lazy match from init() to the first
-- comment line stops before the code it is looking for — the block is
-- introduced by a comment.
local init_head = ctrl:match("function init%(self%)(.-)auth_debug%(\"boot: app is offline")
check_true("boot reads it before anything connects",
    init_head ~= nil and init_head:find("api%.is_app_offline%(%)") ~= nil,
    "read after a connect attempt is a read that saved nothing")
-- And that it really is at the TOP of init, not merely somewhere in it.
--
-- Counted in STATEMENTS, not characters. A character budget measures the
-- comments as well as the code, so explaining the block better moved it
-- "later" and failed a test about where it runs — which is a test measuring
-- prose. Blank and comment-only lines are dropped and what is left is code
-- that would run before the restore.
local before = 0
for line in (init_head or ""):gmatch("[^\n]+") do
    local t = line:match("^%s*(.-)%s*$")
    if t ~= "" and not t:match("^%-%-") then before = before + 1 end
end
check_true("and does so first thing",
    init_head ~= nil and before <= 6,
    tostring(before) .. " statements run before the offline latch is restored")
check_true("and mirrors it onto the socket manager",
    ctrl:find("ws%.set_app_offline%(") ~= nil, "the latch has to reach the thing that reconnects")
-- Through the SETTER, with the stamp the refusal was written with. A bare
-- assignment leaves the recheck window starting at zero — permanently due —
-- so the one probe becomes an attempt on every reconciler tick, which is the
-- loop this whole section exists to stop.
check_true("counting the wait from the refusal, not from this launch",
    ctrl:find("ws%.set_app_offline%(api%.app_offline_since%(%)%)") ~= nil,
    "restarting the window at every launch costs a request per cold start")
check_true("and nothing assigns the latch behind the setter's back",
    ctrl:find("ws%.app_offline = ") == nil,
    "a bare assignment skips the window and reads as due-now")

print("")
print("no sign-in is even attempted")
local dev = ctrl:match("local function try_device_login%(self%)(.-)\n    cancel_silent_login_retry")
check_true("device login returns early when offline",
    dev and dev:find("if app_state%.app_offline and not ws%.app_offline_recheck_due"),
    "every route into signing in comes through this function")
check_true("but not while the recheck window is open",
    dev and dev:find("app_offline_recheck_due"),
    "clear_session wiped the cached session, so the socket path alone cannot probe")
check_true("and cancels the retry ladder on the way out",
    dev and dev:find("cancel_silent_login_retry%(self%)"),
    "a retry left on the clock fires into this same early return, and is still armed later")
check_true("and clears the in-flight flag on the way out",
    dev and dev:find("self%._silent_login_inflight = false"),
    "left set, PLAY ONLINE would be permanently swallowed as a duplicate tap")

print("")
print("only the server can undo it")
check_true("a successful identify clears the cache too",
    ctrl:find("api%.clear_app_offline") ~= nil,
    "otherwise an unblocked account stays offline forever")
local ident = ctrl:match('ws%.on%("identify_success", function%(%)(.-)end%)%)')
check_true("and clears the socket latch with it",
    ident and ident:find("ws%.clear_app_offline%(%)"), "half-cleared is still offline")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
