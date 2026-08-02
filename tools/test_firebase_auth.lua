-- What a failed sign-in MEANS.
--
--   Run: lua tools/test_firebase_auth.lua
--
-- THE PROBLEM THIS RULE EXISTS FOR
--
-- Three completely different situations arrive down one error channel, and the
-- old flow treated all of them the same way: retry, quietly, forever.
--
--   nothing is wrong   no Google account on the device, nothing cached yet, or
--                      the player closed the picker. Retrying behind their
--                      back accomplishes nothing — they have to be offered
--                      something to tap.
--   transient          network, or Play Services still warming up at cold
--                      start. Retrying is exactly right.
--   the BUILD is wrong an OAuth client that does not match, a config value
--                      that is missing. This fails for EVERY user of the
--                      build and no amount of retrying will fix it.
--
-- The third one is the one that cost real time. Silent retry never sets an
-- error state — deliberately, so a background failure does not shout at
-- players — so a misconfigured build presented as an app that says CONNECTING
-- and nothing else, on every device, with nothing in the logs but attempts.
--
-- This drives the REAL modules/firebase_auth.lua table, because the whole
-- failure was a mapping from a code to a decision.

-- Minimal stubs so the module loads outside the engine. It reads _G.firebaseauth
-- (absent here, which is the editor/desktop case) and uses timer.delay only on
-- the unavailable path.
timer = { delay = function(_, _, fn) fn() end }

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local fb = require("modules.firebase_auth")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local function classify(code) return fb.classify({ success = false, code = code }) end

print("a success is a success")
check("success flag wins", fb.classify({ success = true }), "success")
check("success with no code at all", fb.classify({ success = true, code = "" }), "success")

print("")
print("NOTHING IS WRONG — offer the button, do not retry behind their back")
-- Every one of these is the normal state of a device that has simply never
-- signed in. Retrying them silently is how a first-run player sits looking at
-- a lobby that will never come online.
check("no cached session yet", classify("no-silent-session"), "offer")
check("no Firebase session", classify("not-signed-in"), "offer")
check("player closed the picker", classify("google-12501"), "offer")
check("a picker is already open", classify("google-12502"), "offer")
check("sign-in required", classify("google-4"), "offer")

print("")
print("TRANSIENT — retry, this is what the backoff is for")
check("network error", classify("google-7"), "retry")
check("internal error", classify("google-8"), "retry")
check("interrupted", classify("google-14"), "retry")
check("token fetch failed", classify("token-fetch-failed"), "retry")

print("")
print("THE BUILD IS WRONG — retrying cannot fix this and must not be tried")
-- DEVELOPER_ERROR is the SHA-1 or the OAuth client not matching. It fails for
-- every single user of the build, identically, forever.
check("DEVELOPER_ERROR", classify("google-10"), "broken")
check("SIGN_IN_FAILED", classify("google-12500"), "broken")
-- requestIdToken given a client id Google will not issue for this app. The
-- sign-in "succeeds" and hands back nothing, which is the most confusing shape
-- of all because every log line says it worked.
check("no ID token returned", classify("no-id-token"), "broken")
check("extension never initialised", classify("not-initialised"), "broken")

print("")
print("An unrecognised code is treated as transient, NOT as broken")
-- The asymmetry is deliberate. Wrongly calling something "broken" strands a
-- player the app could have signed in a moment later; wrongly calling it
-- "retry" costs one retry.
check("unknown code", classify("something-new-from-google"), "retry")
check("empty code", classify(""), "retry")
check("nil result", fb.classify(nil), "retry")

print("")
print("Not available off-device")
-- The extension registers nothing outside Android, so this is the editor and
-- desktop case. It must answer rather than error, or the game cannot be run
-- outside a device build at all.
check("available is false", fb.available, false)
check("is_signed_in answers", fb.is_signed_in(), false)

local called
fb.login(function(r) called = r end)
check("login calls back", called ~= nil, true)
check("with a failure", called and called.success, false)
check("named, not blank", called and called.code, "not-available")
-- Callers read result.id_token straight out of this. A nil there would raise
-- inside the callback rather than at the point of the mistake.
check("id_token is a string", type(called and called.id_token), "string")

print("")
print("The FCM token path")
-- The bug this covers: getToken() is asynchronous and kicked off at extension
-- init, while IDENTIFY reads whatever is cached at the instant it fires. On a
-- cold start that is almost always nothing — boot, session restore and identify
-- all happen inside the window the fetch is still open — so IDENTIFY carried no
-- token, and nothing sent one afterwards because the arrival was cached in C++
-- where no Lua code could learn of it. The backend then held no token for that
-- install and the player silently received no push at all.
check("a listener can be registered", pcall(fb.on_fcm_token, function() end), true)
check("registering off-device does not error", pcall(fb.on_fcm_token, function() end), true)
check("fetch does not error off-device", pcall(fb.fetch_fcm_token), true)
-- Callers concatenate and compare this. A nil would raise at the call site
-- rather than at the mistake.
check("get returns a string when unavailable", type(fb.get_fcm_token()), "string")
check("and that string is empty, not 'nil'", fb.get_fcm_token(), "")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
