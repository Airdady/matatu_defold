-- Regression test for the LOGIN WITH PHONE backup on the PLAY ONLINE tile.
--
--   Run: lua tools/test_phone_login_cta.lua
--
-- THE BUG
--
-- The button was shown on `not has_username`, where has_username came from
-- ws.current_user_data.username. That reads like "is this player signed in".
-- It is not.
--
-- controller.script populates current_user_data at boot from the cached
-- session (api.load_session) before a socket exists, let alone one the backend
-- has accepted. So a returning player carries a username from the cache no
-- matter what happens to their authentication afterwards — and the backup was
-- hidden by the very cache that proves nothing about their being signed in.
--
-- WHY THAT MATTERS MORE THAN IT SOUNDS
--
-- Silent sign-in retries quietly and open-endedly and deliberately never sets
-- auth_state to "error" any more, so there is no failure state on screen. A
-- player it can never satisfy — a stale Google credential, an account the
-- backend rejects, a device with no Play Services — sees a tile that says
-- PLAY NOW, taps it, and watches nothing happen. With the button hidden there
-- was no second route in and nothing to explain the first one.
--
-- This drives the REAL modules/lobby/auth_cta.lua, because the whole failure
-- was one predicate being asked the wrong question.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local AuthCta = require("modules.lobby.auth_cta")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local offer = AuthCta.should_offer_phone_login

print("A player who is genuinely online is not offered a second way in")
check("signed in and identified", offer({ username = "Ada" }, true), false)

print("")
print("THE BUG: a cached username with no accepted session")
-- current_user_data straight off api.load_session, before any socket. This is
-- what every returning player looks like at boot, and what a player whose
-- re-authentication never succeeds looks like forever.
check("cached username, never identified", offer({ username = "Ada" }, false), true)
check("cached username, identify pending", offer({ username = "Ada" }, nil), true)

print("")
print("A player with no account at all")
check("no user data", offer(nil, false), true)
check("empty user data", offer({}, false), true)
-- "" is TRUTHY in Lua. A signed-out payload carries exactly this, and testing
-- it rather than comparing it is how an empty username reads as a real one.
check("empty username string", offer({ username = "" }, false), true)
check("empty username, somehow identified", offer({ username = "" }, true), true)

print("")
print("Shapes that are not a username")
check("username is a number", offer({ username = 12345 }, true), true)
check("user data is not a table", offer("Ada", true), true)

print("")
print("A drop puts the backup back")
-- ws.is_identified is cleared in on_disconnected. A player sitting on the
-- lobby when the socket goes must be offered the route again, which is why
-- controller.script forwards "disconnected" to the lobby as well as to
-- "#online".
local user = { username = "Ada" }
check("before the drop", offer(user, true), false)
check("after the drop", offer(user, false), true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
