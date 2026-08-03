-- DEVICE-FIRST SIGN-IN, WITH THE PHONE NUMBER AS THE THING THAT SURVIVES.
--
--   Run: lua tools/test_device_auth.lua
--
-- THE SHAPE
--
--   launch ─▶ cached session?  ── yes ─▶ IDENTIFY with the user id
--               │ no
--               ▼
--             POST /auth/device { deviceId }
--               ├─ 200            signed in. One request. No provider.
--               ├─ 404 DEVICE_UNKNOWN   we do not know this handset
--               └─ anything else  transient — back off and retry
--                    │
--                    ▼ (on DEVICE_UNKNOWN)
--             phone number ─▶ POST /auth/phone, which REMAPS deviceId
--
-- WHY THE PHONE STEP IS NOT OPTIONAL
--
-- A device id does not survive a new handset. Without a second identity, a
-- player who buys a phone has simply lost their account and their balance, and
-- nothing on screen would say so. The phone number is the identity that
-- crosses handsets, and /auth/phone writes the NEW deviceId onto the account as
-- it signs them in — so it is both the recovery and the re-binding.
--
-- WHY DEVICE_UNKNOWN IS NOT A FAILURE
--
-- It is the ordinary state on a first run and the expected state on a new
-- phone. Feeding it into the retry ladder would spend requests on a question
-- that cannot change its answer, while the player watches CONNECTING. It is
-- also why the client keys on the server's `code` rather than on the status:
-- a dead network reports status 0, and reading that as "no account here" would
-- send a returning player to a phone-number screen they do not need.
--
-- Source-level, because controller.script and api_service.lua cannot be
-- required into a plain Lua process.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local function read(rel)
    local f = io.open(ROOT .. rel)
    if not f then return nil end
    local s = f:read("a"); f:close(); return s
end

-- Assert against CODE. Every file here explains itself at length and those
-- explanations name the very things being asserted absent.
local function code_of(src) return (src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")) end

local controller = code_of(read("main/controller.script"))
local api        = code_of(read("modules/api_service.lua"))
local project    = read("game.project")

print("PLAY SERVICES IS GONE")
check("no gpgs extension dependency", project:find("extension%-gpgs"), nil)
check("no [gpgs] config section", project:find("%[gpgs%]"), nil)
check("the controller calls nothing on gpgs", controller:find("gpgs%."), nil)
check("no /auth/google call is left in the client", api:find("/auth/google", 1, true), nil)
check("and no gpgs_login", api:find("function M.gpgs_login", 1, true), nil)

print("")
print("DEVICE SIGN-IN IS THE WAY IN")
check("api.device_login exists", api:find("function M.device_login", 1, true) ~= nil, true)
check("it posts to /auth/device", api:find("/auth/device", 1, true) ~= nil, true)
check("it sends the device id", api:find("deviceId = M.get_device_id()", 1, true) ~= nil, true)
-- Push rides along on whichever call establishes the session.
check("and carries the FCM token", api:find("fcmToken", 1, true) ~= nil, true)
check("the controller signs in with it",
    controller:find("api.device_login(", 1, true) ~= nil, true)
check("boot uses it when there is no cached session",
    controller:find("try_device_login(self)", 1, true) ~= nil, true)

print("")
print("A CACHED SESSION STILL SHORT-CIRCUITS IT")
-- The fastest launch of all makes no HTTP request at all: the reconciler
-- adopts the session from disk and IDENTIFYs straight away.
check("the identity provider is still registered at boot",
    controller:find("ws.set_identity_provider", 1, true) ~= nil, true)

print("")
print("DEVICE_UNKNOWN IS NOT A FAILURE")
check("there is a named predicate for it",
    api:find("function M.is_device_unknown", 1, true) ~= nil, true)
check("the controller asks it",
    controller:find("api.is_device_unknown(result)", 1, true) ~= nil, true)
-- The distinction that matters: keyed on the server's code, not the status.
-- A dead network is status 0 and must NOT read as "no account on this device".
check("it is keyed on the server's code", api:find('"DEVICE_UNKNOWN"', 1, true) ~= nil, true)
check("not on a bare 404", api:find("status_code == 404", 1, true), nil)
-- It must not enter the retry ladder: no number of requests invents an account.
local handler = controller:match("handle_device_result = function.-\nend\n") or ""
check("found the handler", #handler > 0, true)
local unknown_at = handler:find("is_device_unknown", 1, true)
local retry_at   = handler:find("handle_login_failure", 1, true)
check("the unknown branch is checked BEFORE the retry ladder",
    (unknown_at or math.huge) < (retry_at or 0), true)
check("and it returns rather than falling through",
    handler:sub(unknown_at or 1, retry_at or #handler):find("return", 1, true) ~= nil, true)
check("it asks for the phone number",
    handler:sub(unknown_at or 1, retry_at or #handler):find('show(self, "profile")', 1, true) ~= nil, true)

print("")
print("A TRANSIENT FAILURE STILL RETRIES")
check("the ladder is still wired", controller:find("handle_login_failure", 1, true) ~= nil, true)
check("with a backoff", controller:find("silent_login_delay", 1, true) ~= nil, true)
-- The rungs that only ever existed for Play Games' consent problem are gone;
-- a device id has no consent to grant, so nothing can need them.
check("no forced credential refresh rung", controller:find("force_fresh_gpgs_session", 1, true), nil)
check("no interactive sign-in rung", controller:find("_interactive_login_done", 1, true), nil)

print("")
print("THE PHONE NUMBER IS THE IDENTITY THAT CROSSES HANDSETS")
check("phone sign-in is still there", api:find("function M.phone_login", 1, true) ~= nil, true)
check("it posts to /auth/phone", api:find("/auth/phone", 1, true) ~= nil, true)
check("and sends the CURRENT device id, so the backend can remap it",
    api:find("payload.deviceId = payload.deviceId or M.get_device_id()", 1, true) ~= nil, true)
check("the controller handles a phone sign-in",
    controller:find('hash("phone_login")', 1, true) ~= nil, true)

print("")
print("A BROKEN IDENTIFY DOES NOT COST THE PLAYER THEIR DEVICE")
-- clear_session runs on auth_required/identify_error, which includes causes as
-- mundane as a dropped connection. Clearing the device id there would turn a
-- network hiccup into a demand for a phone number.
local clear_fn = controller:match("local function clear_session%(%).-\nend\n") or ""
check("found clear_session", #clear_fn > 0, true)
check("it does not clear the device id", clear_fn:find("device", 1, true), nil)
check("it does re-sign-in automatically",
    controller:find("try_device_login", 1, true) ~= nil, true)

print("")
print("THE PHONE SCREEN APPEARS FOR ONE REASON ONLY")
-- Reported: it turned up after a perfectly successful launch. It was a
-- MANDATORY completion step — profile_complete required a phone number, and
-- route_after_auth re-evaluates that on every login and every reconnect, so
-- any account without one was sent to the number screen however it signed in.
--
-- That made sense when the phone number was the migration path off pre-Google
-- accounts. It does not now: sign-in IS the device id, so a player whose
-- handset was recognised is signed in, and asking them for a credential the
-- app did not need to let them in has nothing to explain itself with.
--
-- The number still matters — it is the identity that survives a new handset,
-- and losing it means losing the account when the phone changes. So it stays
-- offered on the profile screen and remains the entire answer to
-- DEVICE_UNKNOWN. It just no longer interrupts.
local app_state = code_of(read("modules/app_state.lua"))
local profile_fn = app_state:match("function M%.profile_complete%(user%).-\nend\n") or ""
check("found profile_complete", #profile_fn > 0, true)
check("it does NOT require a phone number", profile_fn:find("phone_complete", 1, true), nil)
check("it still requires an avatar", profile_fn:find("avatar", 1, true) ~= nil, true)
check("and a username", profile_fn:find("username_complete", 1, true) ~= nil, true)
-- Still available where it belongs: the profile screen decides whether to show
-- the step, rather than the router deciding whether to force it.
check("phone_complete still exists for the screen to ask",
    app_state:find("function M.phone_complete", 1, true) ~= nil, true)
local profile_gui = code_of(read("main/profile.gui_script"))
check("and the profile screen is what asks it",
    profile_gui:find("app_state.phone_complete(u)", 1, true) ~= nil, true)

-- The one path that DOES lead there, and it is the only one.
check("DEVICE_UNKNOWN is what opens it",
    handler:sub(unknown_at or 1, retry_at or #handler):find('show(self, "profile")', 1, true) ~= nil, true)
-- ...and once there, the button has to actually work. With no session there is
-- nothing to LINK a number to: the endpoint requires a Bearer token the player
-- does not have yet, so the one route back into an account after changing
-- handsets answered 401.
check("the phone step signs in when there is no session",
    controller:find("if not is_logged_in() then", 1, true) ~= nil, true)
check("by routing to phone_login, not link_phone",
    controller:find('msg.post("#controller", "phone_login", { phoneNumber = phone })', 1, true) ~= nil, true)

print("")
print("THE PLAYER'S THEME IS ACTUALLY PUT ON")
-- sync_theme_from_user reads user.themes and returns at its first line without
-- one. That list lived under DataScope.THEME on the backend, which nothing
-- fetches at sign-in, so the call was a no-op on every path for as long as it
-- existed and an owned, active theme was never applied. The list is in the base
-- IDENTIFY payload now; these are the two places that have to read it.
--
-- IDENTIFY is the one moment every route has in common: a cached-session boot
-- never calls device_login at all, and api.save_session stores no theme, so the
-- IDENTIFY reply is the FIRST place the app can learn which theme is active.
local id_ok = controller:match('ws%.on%("identify_success".-\n    end%)%)') or ""
check("found the identify_success handler", #id_ok > 0, true)
check("it applies the theme", id_ok:find("sync_theme_from_user", 1, true) ~= nil, true)
-- And the device sign-in, which routes itself rather than going through
-- route_after_auth and so does not inherit that call.
check("so does the device sign-in",
    handler:find("app_state.sync_theme_from_user(user)", 1, true) ~= nil, true)
-- The session cache carries no theme, which is why IDENTIFY has to.
local api_raw = read("modules/api_service.lua") or ""
local save_fn = api_raw:match("function M%.save_session%(user%).-\nend\n") or ""
check("the saved session has no theme in it", save_fn:find("theme", 1, true), nil)

print("")
print("FIREBASE AUTH IS GONE FROM THE EXTENSION TOO")
-- Not just unused from Lua — removed. The native extension still exposed
-- login/silent_login/refresh_token/logout/is_signed_in, and an entry point
-- that exists is an entry point that can be called.
local java   = read("firebaseauth/src/FirebaseAuthDefold.java") or ""
local cpp    = read("firebaseauth/src/firebaseauth.cpp") or ""
-- Comments stripped, for the same reason the Lua sources are: the gradle file
-- explains which dependencies were removed and why, naming both of them, and
-- the raw text therefore "contains" exactly what is being asserted absent.
local gradle_raw = read("firebaseauth/manifests/android/build.gradle") or ""
local gradle = (gradle_raw:gsub("//[^\n]*", ""))

check("no GoogleSignIn in the Java", java:find("GoogleSignIn", 1, true), nil)
check("no FirebaseAuth in the Java", java:find("FirebaseAuth%."), nil)
check("no sign-in intent", java:find("RC_SIGN_IN", 1, true), nil)
check("no activity-result handling", java:find("onActivityResult", 1, true), nil)
check("no auth callbacks into native", java:find("onAuthSuccess", 1, true), nil)

check("the Lua module offers no login", cpp:find('{"login"', 1, true), nil)
check("no silent_login", cpp:find('{"silent_login"', 1, true), nil)
check("no refresh_token", cpp:find('{"refresh_token"', 1, true), nil)
check("no logout", cpp:find('{"logout"', 1, true), nil)
check("no is_signed_in", cpp:find('{"is_signed_in"', 1, true), nil)

check("firebase-auth is not a dependency", gradle:find("firebase%-auth"), nil)
check("play-services-auth is not a dependency", gradle:find("play%-services%-auth"), nil)
check("web_client_id is gone from the config", project:find("web_client_id", 1, true), nil)

print("")
print("PUSH IS UNAFFECTED")
-- Everything the notification path needs, still there. This is the half that
-- CANNOT go: FCM is Firebase, and nothing else in the build initialises it.
check("firebase-messaging is still a dependency", gradle:find("firebase%-messaging") ~= nil, true)
check("FirebaseApp is still initialised", java:find("FirebaseApp.initializeApp", 1, true) ~= nil, true)
check("the token is still fetched natively", java:find("FirebaseMessaging.getInstance", 1, true) ~= nil, true)
check("notification channels are still created",
    java:find("ensureNotificationChannels", 1, true) ~= nil, true)
check("the foreground check the messaging service asks for is still there",
    java:find("isAppInForeground", 1, true) ~= nil, true)
for _, fn in ipairs({ "is_available", "get_fcm_token", "fetch_fcm_token",
                      "set_fcm_listener", "consume_pending_action" }) do
    check("the Lua module still offers " .. fn, cpp:find('{"' .. fn .. '"', 1, true) ~= nil, true)
end
check("the push module is still required",
    controller:find("modules.firebase_push", 1, true) ~= nil, true)
check("the token is still fetched", controller:find("fbpush.fetch_fcm_token", 1, true) ~= nil, true)
check("rotations are still heard", controller:find("fbpush.on_fcm_token", 1, true) ~= nil, true)
check("[firebase] is still configured for messaging", project:find("%[firebase%]") ~= nil, true)

print("")
print("game.project STILL PARSES")
-- It has no comment syntax; only [section] headers and key = value lines.
local bad = 0
for line in (project .. "\n"):gmatch("([^\n]*)\n") do
    local t = line:match("^%s*(.-)%s*$")
    if t ~= "" and not t:match("^%[[%w_]+%]$") and not t:match("^[%w_#]+%s*=") then
        bad = bad + 1
        print("        " .. t)
    end
end
check("every line is a header or a key = value", bad, 0)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
