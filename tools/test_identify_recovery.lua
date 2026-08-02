-- WHAT TO DO WHEN IDENTIFY DOES NOT SUCCEED.
--
--   Run: lua tools/test_identify_recovery.lua
--
-- THE PROBLEM THIS RULE EXISTS FOR
--
-- A cached session is a permanent thing. The user id was resolved once, by a
-- Google sign-in on this device, and it does not expire — boot already uses it
-- directly, sending IDENTIFY without going anywhere near Firebase.
--
-- Every failure path then threw it away. The identify_error handler ran
-- clear_session() as its very first statement, wiping the saved session and
-- the auth token, and rebuilt the whole identity through a Firebase silent
-- login: a token fetch, an HTTP round trip and a fresh backend match, to
-- re-derive a user id the app already had written down and had just been
-- using.
--
-- And it fired on the wrong thing. identify_error comes from three places and
-- only two are about the identity being wrong:
--
--   timeout    the client's own watchdog, after IDENTIFY went unanswered three
--              times. Nobody rejected anything — the socket dropped, the
--              server was slow, or (as actually shipped) it handled the
--              reconnect down a branch that forgot to reply.
--   rejected   the server said IDENTIFY_ERROR, or answered a stale id with
--              "User not found".
--
-- Treating the first as the second meant a network blip cost a full
-- re-authentication — and on a device that could not reach Firebase at that
-- moment, it cost the session outright. The player was signed out by a hiccup.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local R = require("modules.identify_recovery")

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local HAVE_CACHE, NO_CACHE = true, false

print("A TIMEOUT KEEPS THE SESSION")
-- The whole point. Nobody refused this identity, so it is re-sent, not
-- rebuilt.
check("first timeout re-identifies", R.plan("timeout", 0, HAVE_CACHE), "reidentify")
check("and does not clear the cache", R.clears_cache(R.plan("timeout", 0, HAVE_CACHE)), false)
check("still re-identifying at the last of the budget",
    R.plan("timeout", R.MAX_REIDENTIFY - 1, HAVE_CACHE), "reidentify")

print("")
print("A REJECTION REBUILDS, IMMEDIATELY")
-- The server looked at this identity and refused it. Re-sending the same id
-- would be refused identically, for ever.
check("rejected goes straight to re-auth", R.plan("rejected", 0, HAVE_CACHE), "reauth")
check("and that one DOES clear the cache", R.clears_cache(R.plan("rejected", 0, HAVE_CACHE)), true)
check("no amount of budget saves a rejected identity",
    R.plan("rejected", 0, HAVE_CACHE), "reauth")

print("")
print("THE BUDGET IS FINITE")
-- Re-identifying for ever against a server that will never answer is its own
-- kind of stuck. Fifteen unanswered IDENTIFYs (the watchdog tries three times
-- before we are called once) is enough to conclude the identity is the
-- problem after all.
check("past the budget, rebuild", R.plan("timeout", R.MAX_REIDENTIFY, HAVE_CACHE), "reauth")
check("and well past it", R.plan("timeout", 99, HAVE_CACHE), "reauth")
-- Asserted as a number because it IS the promise: how long a flaky connection
-- can keep a signed-in player signed in.
check("budget", R.MAX_REIDENTIFY, 5)

print("")
print("NO CACHE MEANS THERE IS NOTHING TO RE-SEND")
-- A first-run device, or one whose session was already cleared. There is no
-- user id to identify AS, so the only route is a real sign-in.
check("timeout with no cache", R.plan("timeout", 0, NO_CACHE), "reauth")
check("rejected with no cache", R.plan("rejected", 0, NO_CACHE), "reauth")

print("")
print("AN UNKNOWN REASON IS TREATED AS A TIMEOUT")
-- The asymmetry is deliberate, and it is the direction the old code got wrong.
-- Wrongly re-identifying costs ONE small socket message against an id we
-- already hold. Wrongly re-authenticating costs a Firebase round trip and, if
-- the device is offline, the session.
check("nil reason", R.plan(nil, 0, HAVE_CACHE), "reidentify")
check("empty reason", R.plan("", 0, HAVE_CACHE), "reidentify")
check("something new", R.plan("server-had-a-moment", 0, HAVE_CACHE), "reidentify")
check("classify defaults to timeout", R.classify(nil), "timeout")
check("classify only names one rejection", R.classify("rejected"), "rejected")

print("")
print("Nothing here can raise")
-- It runs inside a socket callback, on the path a returning player takes.
check("nil attempts", R.plan("timeout", nil, HAVE_CACHE), "reidentify")
check("non-numeric attempts", R.plan("timeout", "lots", HAVE_CACHE), "reidentify")
check("clears_cache on nonsense", R.clears_cache("something-else"), false)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
