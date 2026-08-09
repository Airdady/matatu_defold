-- A NUMBER THAT WORKED, ON A SCREEN THAT WOULD NOT LEAVE.
--
--   Run: lua tools/test_phone_signin_routes.lua
--
-- Reported: the phone number is accepted and the app should move on to the
-- username and avatar step, but it stays on the number pad.
--
-- It was one boolean. Both sign-in paths tested `data.token`:
--
--   device   if not (result.success and data.token) then ...fail
--   phone    if result.success and data.token then ...succeed
--
-- and the server does not always issue one. It returns `token: null` on
-- purpose when JWT_SECRET is not configured, so that a missing secret cannot
-- cost somebody their account (signAppToken, be_matatu auth.routes.ts). Every
-- one of those successful sign-ins was therefore read as a failure:
--
--   * device — "Could not sign in on this device", so a returning player was
--     sent to the phone screen with an account already waiting for them
--   * phone  — the account signed in behind the screen, and the screen showed
--     an error and stayed exactly where it was
--
-- These RUN the decision, which is why it was moved into its own module: it
-- lived inside a network callback where nothing could reach it, and the two
-- callers had already drifted into two different answers.
package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path
local AR = require("modules.auth_result")

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

-- What the server actually sends. `token = nil` is the deployment in the
-- report; a string token is the ordinary one.
local function reply(over)
    over = over or {}
    return {
        success = (over.success ~= false),
        data = {
            token = over.token,
            isNewUser = over.isNewUser,
            user = over.user ~= nil and over.user or {
                _id = "6512ab34cd56ef7890123456",
                username = over.username,
                avatar = over.avatar,
                phoneNumber = "0700111222",
                balance = 500,
            },
        },
    }
end

print("")
print("A SIGN-IN IS AN ACCOUNT, NOT A TOKEN")

check("no token, but an account: signed in",
    AR.signed_in(reply({ token = nil })) == true,
    "this is the exact response that stranded the player on the number pad")
check("a token as well: still signed in",
    AR.signed_in(reply({ token = "jwt.abc.123" })) == true)
check("an empty-string token is the same as none",
    AR.signed_in(reply({ token = "" })) == true)

check("a failed request is not a sign-in",
    AR.signed_in(reply({ success = false })) == false)
check("and neither is a success with no account",
    AR.signed_in(reply({ user = {} })) == false,
    "there is nobody to identify as, no balance and no bracket to route to")
check("nor one with a blank id",
    AR.signed_in(reply({ user = { _id = "" } })) == false)
check("nor one with no user object at all",
    AR.signed_in({ success = true, data = {} }) == false)

check("nothing at all does not throw",
    AR.signed_in(nil) == false and AR.signed_in("nope") == false
        and AR.account_id(nil) == "")

print("")
print("THE ID IS WHAT COMES BACK")
check("_id", AR.account_id(reply()) == "6512ab34cd56ef7890123456")
check("localId is accepted too — the older paths named it that",
    AR.account_id(reply({ user = { localId = "legacy-id-1" } })) == "legacy-id-1")
check("and _id wins when both are there",
    AR.account_id(reply({ user = { _id = "a", localId = "b" } })) == "a")

print("")
print("AND THE TOKEN IS READ SEPARATELY, AS THE OPTIONAL THING IT IS")
check("a token is returned when there is one",
    AR.token(reply({ token = "jwt.abc.123" })) == "jwt.abc.123")
check("and \"\" when there is not, so callers need no type check",
    AR.token(reply({ token = nil })) == ""
        and AR.token(reply({ token = "" })) == ""
        and AR.token(nil) == "")
check("a non-string token is not a token",
    AR.token({ success = true, data = { token = 12345 } }) == "")

-- ---------------------------------------------------------------------------
print("")
print("BOTH CALL SITES ASK THE SAME QUESTION NOW")

local ctrl = slurp("main/controller.script")
-- Comments stripped: this file explains the old condition at length, and a
-- check that its explanation counts as a violation punishes documenting it.
local code = ctrl:gsub("%-%-[^\n]*", "")

check("nothing gates a sign-in on the token any more",
    not code:find("result%.success and data%.token")
        and not code:find("success and data%.token"),
    "this is the condition that was rejecting good sign-ins")
check("the device path uses the shared decision",
    code:find("if not auth_result%.signed_in%(result%) then"))
check("and so does the phone path",
    code:find("if auth_result%.signed_in%(result%) then"))
check("the module is required",
    code:find('local auth_result = require%("modules%.auth_result"%)'))
check("and a token is still stored when one arrives",
    code:find("auth_result%.token%(result%)"),
    "the four routes behind verifyToken still need it")

-- ---------------------------------------------------------------------------
print("")
print("AND THE SCREEN LEAVES WHEN IT SHOULD")
--
-- The other half of "it stays on the phone input". Even with the sign-in
-- accepted, the profile screen decides its own step from the account data —
-- so the number has to be ON that account by the time it looks.
-- app_state builds colour constants at load time, which is all vmath is
-- needed for here. The predicates under test touch none of it.
_G.vmath = _G.vmath or {
    vector3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end,
    vector4 = function(a, b, c, d) return { x = a, y = b, z = c, w = d } end,
}
local app_state = require("modules.app_state")

local signed_in_user = {
    _id = "6512ab34cd56ef7890123456",
    phoneNumber = "0700111222",
    avatar = 0,          -- not chosen yet
    username = nil,      -- not chosen yet
}
check("the phone step is satisfied once the number is on the account",
    app_state.phone_complete(signed_in_user) == true,
    "decide_step reads exactly this, and a false here pins the screen in place")
check("and the profile step is NOT, so there is somewhere to go",
    app_state.profile_complete(signed_in_user) == false,
    "if this were true the player would be sent past the avatar picker")

check("an account with no number does keep the phone step",
    app_state.phone_complete({ _id = "x" }) == false,
    "the step is mandatory and state-driven; that part was never the bug")

-- ---------------------------------------------------------------------------
print("")
print("THE NUMBER IS NEVER DEMANDED — IT IS OFFERED")
--
-- Reported, in order:
--   "user with device id exists and is missing username and avatar — just
--    take him to that screen"
--   "in case no device id is found attached to the device, skip the phone
--    number screen"
--
-- Which together say: the keypad is not a gate. It was one, and it forced
-- itself on two different players — somebody the device had already
-- identified who only needed a name, and somebody the device did NOT know,
-- whose account /auth/device/profile can create from a username, an avatar
-- and the device id with no number involved at all.
local GameMode = require("modules.game_mode")

check("a handset nobody recognises is NOT asked for a number",
    app_state.phone_step_required({}) == false,
    "the very first thing a new player does must not be a credential they may not have")
check("nor is a session with no id",
    app_state.phone_step_required({ username = "Ada" }) == false)
check("nor an account the device identified",
    app_state.phone_step_required({ _id = "6512ab34cd56ef7890123456", avatar = 0 }) == false,
    "they need the avatar picker, not the number pad")
check("nor one that already has a number",
    app_state.phone_step_required({ _id = "abc", phoneNumber = "0700111222" }) == false)
check("nobody at all, in fact",
    app_state.phone_step_required(nil) == false
        and app_state.phone_step_required("nope") == false
        and app_state.phone_step_required({ _id = "" }) == false)

-- The predicate that still answers honestly, and is what the screen uses to
-- decide whether to OFFER the step rather than force it.
if GameMode.is_matatu() then
    check("phone_complete still tells the truth",
        app_state.phone_complete({ _id = "x" }) == false
            and app_state.phone_complete({ _id = "x", phoneNumber = "0700111222" }) == true,
        "the offer depends on it; only the gate is gone")
end

-- ---------------------------------------------------------------------------
print("")
print("BUT THE ROUTE BACK INTO AN OLD ACCOUNT SURVIVES")
--
-- The player this could have cost is specific: somebody returning on a new
-- handset, or after a reinstall, whose device id has rerolled. Nothing on the
-- profile screen identifies them, so picking a name there would mint a SECOND
-- account and leave the one with their balance unreachable — with nothing on
-- screen to say so. Removing a gate must not remove the door.
local prof_code = slurp("main/profile.gui_script"):gsub("%-%-[^\n]*", "")

check("the profile step offers a sign-in for a returning player",
    prof_code:find('id = "phone_login_open"'),
    "without it, skipping the keypad silently orphans accounts")
check("worded as what it is for",
    slurp("main/profile.gui_script"):find("Already have an account?", 1, true) ~= nil)
check("and offered only while there is no account yet",
    prof_code:find("if not has_account and app_state%.phone_required%(%) then"),
    "afterwards the same journey is VERIFY YOUR PHONE, a different sentence")
check("it opens the keypad in LOGIN mode, which signs in rather than links",
    prof_code:match('id == "phone_login_open".-self%.phone_mode = "login"') ~= nil)

check("the keypad always has a way out now",
    prof_code:find('id = "phone_cancel"')
        and not prof_code:find('if phone_mode%(self%) == "login" then'),
    "both modes are entered deliberately, so both need a back button")
check("and BACK returns to the profile step rather than the lobby",
    prof_code:match('id == "phone_cancel".-self%.step = "profile"') ~= nil,
    "dropping out to the lobby loses the name and avatar already picked")
check("falling back to the lobby when there is no profile step behind it",
    prof_code:match('id == "phone_cancel".-goto_lobby') ~= nil)

local prof = slurp("main/profile.gui_script")
check("the screen uses the shared predicate rather than its own condition",
    prof:find("app_state%.phone_step_required%(u%)")
        and not prof:gsub("%-%-[^\n]*", ""):find("phone_required%(%) and not app_state%.phone_complete"),
    "the old condition is what stopped a signed-in player on the number pad")

-- And the number really is in the payload the sign-in returns, which is what
-- makes the two checks above reachable at all.
check("the sign-in payload carries the number",
    (reply().data.user.phoneNumber or "") ~= "")

local profile = slurp("main/profile.gui_script")
check("a successful link re-decides the step rather than staying put",
    profile:find("phone_link_result") and profile:find("decide_step%(self%)"))
check("and a fully-complete account skips the profile step entirely",
    profile:find("app_state%.profile_complete%(u%)")
        and profile:find('msg%.post%("#controller", "goto_online"%)'),
    "a merge onto an old account should not re-ask for a name it already has")

-- ---------------------------------------------------------------------------
print("")
print("LINK-PHONE IS NEVER CALLED WHERE IT CANNOT WORK")
--
-- Reported, from the log: POST .../auth/link-phone fires and the flow stops
-- there. That endpoint is behind verifyToken and answers 401 without a BEARER
-- — which the app often does not have while still having an account id: a
-- cached session carries an id and no token, and the server issues no token
-- at all when JWT_SECRET is not configured. The old check asked
-- is_logged_in(), which answers the id question, so the request went out and
-- died before anybody had looked the number up.
-- api_service pulls in config.lua, which reads sys at load time for the
-- platform and the stamped build. None of it matters to the one accessor
-- under test.
_G.sys = _G.sys or {
    get_sys_info = function() return { system_name = "Linux" } end,
    get_config_string = function(_, d) return d or "" end,
    get_save_file = function() return "/dev/null" end,
}
_G.http = _G.http or { request = function() end }
_G.json = _G.json or { encode = function() return "" end, decode = function() return {} end }
local api = require("modules.api_service")

api.set_auth_token("")
check("no bearer is reported honestly", api.has_auth_token() == false)
api.set_auth_token("jwt.abc.123")
check("and one is, once it exists", api.has_auth_token() == true)
api.set_auth_token(nil)
check("clearing it clears the answer", api.has_auth_token() == false)

check("the decision requires a bearer, not just a session",
    code:find("if not %(is_logged_in%(%) and api%.has_auth_token%(%)%) then"),
    "is_logged_in alone is the check that sent a doomed request")
check("and falls through to the phone sign-in, which needs no credential",
    code:find('msg%.post%("#controller", "phone_login", { phoneNumber = phone }%)'))

check("a 401 or 403 from link-phone falls back rather than dead-ending",
    code:find("if status == 401 or status == 403 then"),
    "a stale bearer refuses before the handler runs, so the number was never judged")
check("and the dead bearer is dropped on the way",
    code:find('pcall%(api%.set_auth_token, ""%)'),
    "keeping it would send the next request into the same 401")
check("it reads the status field the client actually returns",
    code:find("tonumber%(result%.status_code%)"),
    "parse_response names it status_code; result.status is always nil")

-- /auth/phone is the endpoint this falls back to, and the reason the fallback
-- is worth anything: it does not merely link, it CREATES.
check("the phone sign-in sends the device id, so a created account keeps it",
    slurp("modules/api_service.lua")
        :find("payload%.deviceId = payload%.deviceId or M%.get_device_id%(%)"),
    "an account created without one is unreachable on the next launch")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
