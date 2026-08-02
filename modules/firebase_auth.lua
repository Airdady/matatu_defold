-- Firebase Authentication, Lua side.
--
-- Wraps the `firebaseauth` native extension and gives the rest of the app one
-- place to ask "who is signed in" without every call site having to know
-- whether the extension exists on this platform. In the editor it does not, so
-- everything here answers "unavailable" rather than erroring — which is what
-- lets the game still run outside a device build.
--
-- WHAT THE REST OF THE APP GETS
--
--   M.silent_login(cb)  no UI. Runs at every app start; a returning player
--                       never sees a sign-in screen.
--   M.login(cb)         the account picker. Needed once per install.
--   M.refresh_token(cb) a fresh ID token. They last an hour.
--
-- The callback is always called with one table: { success, id_token, uid,
-- email, name, photo, code, error }.
local M = {}

-- Resolved once. The extension registers nothing outside Android, so this is
-- nil in the editor and on desktop, and every function below takes its stub
-- path.
local ext = _G.firebaseauth

M.available = ext ~= nil and ext.is_available ~= nil and ext.is_available()

-- ---------------------------------------------------------------------------
-- What a failure MEANS
-- ---------------------------------------------------------------------------
-- Three completely different situations arrive down one error channel, and
-- treating them alike is how sign-in problems became unreadable in the old
-- flow. They need three different responses:
--
--   "offer"   nothing is wrong. No Google account on the device, no cached
--             session, or the player closed the picker. Show the button and
--             wait — retrying behind their back accomplishes nothing.
--   "retry"   transient. Network, Play Services still warming up at cold
--             start. Back off and try again.
--   "broken"  the BUILD is wrong: an OAuth client that does not match, a
--             missing config value. This fails for every user of the build and
--             no amount of retrying will fix it. It has to be loud.
--
-- Pure, and exported, so it can be tested. A rule that decides whether the app
-- retries forever or shows a button should be provable rather than read.
local OFFER = {
    ['no-silent-session'] = true,   -- nothing cached yet; entirely normal
    ['not-signed-in']     = true,
    ['google-12501']      = true,   -- SIGN_IN_CANCELLED — the player closed it
    ['google-12502']      = true,   -- SIGN_IN_CURRENTLY_IN_PROGRESS
    ['google-4']          = true,   -- SIGN_IN_REQUIRED
}

local RETRY = {
    ['google-7']          = true,   -- NETWORK_ERROR
    ['google-8']          = true,   -- INTERNAL_ERROR
    ['google-14']         = true,   -- INTERRUPTED
    ['token-fetch-failed'] = true,
    ['sign-in-launch-failed'] = true,
}

local BROKEN = {
    ['google-10']         = true,   -- DEVELOPER_ERROR: wrong SHA-1 / client id
    ['google-12500']      = true,   -- SIGN_IN_FAILED, usually the same cause
    ['no-id-token']       = true,   -- requestIdToken given a client Google rejects
    ['not-initialised']   = true,   -- game.project [firebase] incomplete
}

function M.classify(result)
    if result and result.success then return "success" end
    local code = result and result.code or ""
    if BROKEN[code] then return "broken" end
    if RETRY[code]  then return "retry" end
    if OFFER[code]  then return "offer" end
    -- Anything unrecognised is treated as transient rather than fatal. Getting
    -- this wrong in the "broken" direction would strand a player the app could
    -- have signed in a moment later; getting it wrong here costs one retry.
    return "retry"
end

-- ---------------------------------------------------------------------------

local function unavailable(cb)
    if not cb then return end
    -- Deferred rather than called inline, so a caller that sets state after
    -- calling us does not have its own callback run before that state exists.
    timer.delay(0, false, function()
        cb({
            success = false,
            code = "not-available",
            error = "Firebase Auth is not available on this platform",
            id_token = "", uid = "", email = "", name = "", photo = "",
        })
    end)
end

--- Sign in with no UI, using a session this device already holds.
function M.silent_login(cb)
    if not M.available then return unavailable(cb) end
    ext.silent_login(function(_, result) if cb then cb(result) end end)
end

--- Open the Google account picker.
function M.login(cb)
    if not M.available then return unavailable(cb) end
    ext.login(function(_, result) if cb then cb(result) end end)
end

--- A fresh ID token for the account already signed in.
function M.refresh_token(cb)
    if not M.available then return unavailable(cb) end
    ext.refresh_token(function(_, result) if cb then cb(result) end end)
end

function M.logout()
    if not M.available then return end
    pcall(ext.logout)
end

function M.is_signed_in()
    if not M.available then return false end
    local ok, v = pcall(ext.is_signed_in)
    return ok and v or false
end

function M.get_fcm_token()
    if not M.available or not ext.get_fcm_token then return "" end
    local ok, tok = pcall(ext.get_fcm_token)
    return (ok and tok) and tok or ""
end

function M.fetch_fcm_token()
    if not M.available or not ext.fetch_fcm_token then return end
    pcall(ext.fetch_fcm_token)
end

--- Called every time a registration token arrives.
--
-- WHY A LISTENER AND NOT JUST get_fcm_token()
--
-- getToken() is asynchronous and usually finishes AFTER the app has booted,
-- identified and gone quiet. Anything that reads the cached token at one fixed
-- moment — which is what IDENTIFY did — reads an empty string on most cold
-- starts and never finds out otherwise, so the backend ends up holding no token
-- for that install and the player silently stops receiving push.
--
-- It also fires on ROTATION. A token changes on reinstall, on a restore to a
-- new handset, and when app data is cleared; pushes to the old one go nowhere
-- and nothing reports an error, so a stale token is indistinguishable from a
-- player who has notifications turned off.
function M.on_fcm_token(fn)
    if not M.available or not ext.set_fcm_listener then return end
    pcall(ext.set_fcm_listener, function(_, token)
        if type(token) == "string" and token ~= "" then fn(token) end
    end)
end

--- The notification button the player pressed to open the app, if any.
--
-- @return action, request_id  — both nil when the app was opened normally.
--
-- READ ONCE. The native side clears the intent extra as it hands this over,
-- because Android returns the same intent for the life of the activity: left in
-- place, every focus regain for the rest of the session would look like a fresh
-- Accept press and re-accept a game that finished an hour ago.
function M.consume_pending_action()
    if not M.available or not ext.consume_pending_action then return nil, nil end
    local ok, action, request_id = pcall(ext.consume_pending_action)
    if not ok then return nil, nil end
    -- "" is TRUTHY in Lua, so an empty action has to be compared rather than
    -- tested, or "no button was pressed" reads as a button press with no name.
    if type(action) ~= "string" or action == "" then return nil, nil end
    if type(request_id) ~= "string" or request_id == "" then request_id = nil end
    return action, request_id
end

return M
