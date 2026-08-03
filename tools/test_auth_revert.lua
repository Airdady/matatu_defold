-- SIGN-IN IS GOOGLE PLAY GAMES AGAIN, AND PUSH SURVIVED THE REVERT.
--
--   Run: lua tools/test_auth_revert.lua
--
-- THE TRAP THIS GUARDS
--
-- Firebase Auth and Firebase Cloud Messaging shipped in the same native
-- extension, and the entanglement is not cosmetic:
--
--   * FirebaseAuthDefold.java is what calls FirebaseApp.initializeApp(). Defold
--     does not apply the Google Services Gradle plugin, so google-services.json
--     never becomes the string resources that would normally do it — nothing
--     else in the build initialises Firebase at all.
--   * That same init fetches the FCM registration token and creates the
--     notification channels.
--   * modules/firebase_auth.lua carried get_fcm_token, on_fcm_token and
--     consume_pending_action right alongside the sign-in calls.
--
-- So "delete Firebase" and "keep notifications" cannot both be taken
-- literally. What was actually done: the sign-in PATH is gone and unreachable
-- from Lua, while the extension stays and stays initialised, purely as the push
-- transport. These assertions state that split so it cannot quietly close back
-- up — in either direction. A Firebase sign-in creeping back in fails here, and
-- so does push being ripped out along with the auth.
--
-- Source-level, because the files involved are Defold scripts that cannot be
-- required into a plain Lua process (gui.*, msg.*, the extension globals).

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

-- ASSERT AGAINST CODE, NOT PROSE.
--
-- Every file here explains itself at length, and those explanations name the
-- very things being asserted absent — "/auth/firebase", "silent_login". Two of
-- these checks passed their negative control on the strength of a comment
-- alone before this existed, which is a test that cannot fail for the reason
-- it was written.
local function code_of(src)
    return (src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

local controller = code_of(read("main/controller.script"))
local api        = code_of(read("modules/api_service.lua"))
local auth_gui   = code_of(read("main/auth.gui_script"))
local project    = read("game.project")   -- ini; its comments start with ';'

print("THE SIGN-IN PATH IS GONE FROM LUA")
check("the firebase_auth module no longer exists", read("modules/firebase_auth.lua"), nil)
check("nothing requires it", controller:find("modules.firebase_auth", 1, true), nil)
check("nor does api_service", api:find("modules.firebase_auth", 1, true), nil)
-- The wire call. This is the one that decides which backend route a sign-in
-- actually hits, so it is the one that matters most.
check("no /auth/firebase call is left", api:find("/auth/firebase", 1, true), nil)
check("sign-in posts to /auth/google", api:find("/auth/google", 1, true) ~= nil, true)
check("through gpgs_login", api:find("function M.gpgs_login", 1, true) ~= nil, true)
check("and firebase_login is gone", api:find("function M.firebase_login", 1, true), nil)

print("")
print("PLAY GAMES IS WIRED BACK UP")
check("the extension dependency is declared",
    project:find("extension%-gpgs") ~= nil, true)
check("and its config section is back", project:find("%[gpgs%]") ~= nil, true)
-- One callback for the whole extension, registered once. Missing this is the
-- failure with no symptom: sign-in is requested, Google answers, and the answer
-- goes nowhere — the app simply waits for ever.
-- Matched as a CALL. A plain substring search passes against
-- `gpgs.set_callback_DISABLED(...)`, which is exactly the shape a regression
-- takes, and this assertion sat green through that negative control.
check("the single GPGS callback is registered",
    controller:find("gpgs%.set_callback%s*%(") ~= nil, true)
check("it routes into gpgs_callback",
    controller:find("gpgs_callback(self, mid, m)", 1, true) ~= nil, true)
check("silent sign-in calls the extension",
    controller:find("gpgs.silent_login()", 1, true) ~= nil, true)
check("interactive sign-in calls the extension",
    controller:find("gpgs.login()", 1, true) ~= nil, true)
-- The empty-auth-code branch. Play Games can sign a player in perfectly and
-- hand back nothing usable; the Firebase callback had no equivalent because
-- Firebase cannot do it, so reverting without this loses a real failure mode.
check("the empty auth code is still handled",
    controller:find("missing_auth_code", 1, true) ~= nil, true)

print("")
print("THE AUTH SCREEN IS SILENT-ONLY AGAIN")
-- The picker button was added FOR Firebase, where the account picker is the
-- ordinary way in. Under Play Games it is a last resort the escalation ladder
-- already opens by itself.
check("no SIGN IN WITH GOOGLE button", auth_gui:find("SIGN IN WITH GOOGLE", 1, true), nil)
check("no google_signin action", auth_gui:find("google_signin", 1, true), nil)
check("and the controller no longer handles one",
    controller:find('hash("google_signin")', 1, true), nil)
check("the screen names Play Games again",
    auth_gui:find("GOOGLE PLAY GAMES", 1, true) ~= nil, true)
check("TRY AGAIN is still reachable",
    auth_gui:find("retry_silent_login", 1, true) ~= nil, true)

print("")
print("PUSH IS UNTOUCHED")
local push = read("modules/firebase_push.lua")
check("the push module exists", push ~= nil, true)
push = push or ""
for _, fn in ipairs({ "get_fcm_token", "fetch_fcm_token", "on_fcm_token", "consume_pending_action" }) do
    check("it still provides " .. fn, push:find("function M." .. fn, 1, true) ~= nil, true)
end
-- ...and does NOT provide a way back to Firebase sign-in. The native extension
-- still exposes the sign-in calls; not re-exporting them is what makes the
-- revert real rather than merely unused.
--
local push_code = code_of(push)
check("but no silent_login", push_code:find("silent_login", 1, true), nil)
check("no login", push_code:find("function M.login", 1, true), nil)
check("no refresh_token", push_code:find("refresh_token", 1, true), nil)
check("and no failure classifier", push_code:find("function M.classify", 1, true), nil)

check("the controller still fetches the token",
    controller:find("fbpush.fetch_fcm_token", 1, true) ~= nil, true)
check("still listens for rotations",
    controller:find("fbpush.on_fcm_token", 1, true) ~= nil, true)
check("and still reads the notification button",
    controller:find("fbpush.consume_pending_action", 1, true) ~= nil, true)

print("")
print("THE EXTENSION ITSELF STAYS — IT IS WHAT INITIALISES FIREBASE")
-- Deleting these is the tempting version of this revert and the one that
-- silently kills notifications: no FirebaseApp, no token, no channels.
check("the Java init is still there",
    read("firebaseauth/src/FirebaseAuthDefold.java") ~= nil, true)
check("the messaging service is still there",
    read("firebaseauth/src/MatatuFirebaseMessagingService.java") ~= nil, true)
check("the action receiver is still there",
    read("firebaseauth/src/NotificationActionReceiver.java") ~= nil, true)
local gradle = read("firebaseauth/manifests/android/build.gradle") or ""
check("firebase-messaging is still a dependency",
    gradle:find("firebase%-messaging") ~= nil, true)
local manifest = read("firebaseauth/manifests/android/AndroidManifest.xml") or ""
check("the messaging service is still registered",
    manifest:find("MatatuFirebaseMessagingService", 1, true) ~= nil, true)
check("and the notification permission is still requested",
    manifest:find("POST_NOTIFICATIONS", 1, true) ~= nil, true)
-- The values FirebaseOptions is built from. Blank any of these and the
-- extension refuses to initialise, which takes messaging down with it.
check("the [firebase] section is kept for messaging",
    project:find("%[firebase%]") ~= nil, true)
check("with a real api_key", project:find("api_key = AIza") ~= nil, true)
check("and a real app_id", project:find("app_id = 1:") ~= nil, true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
