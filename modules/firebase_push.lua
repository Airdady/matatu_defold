-- Firebase Cloud Messaging, Lua side. PUSH ONLY.
--
-- This was modules/firebase_auth.lua and it did two unrelated jobs: signing
-- players in, and carrying push notifications. Sign-in is now the device id,
-- and the phone number when that is not enough — plain HTTP against our own
-- backend, no provider of any kind. Everything to do with credentials, ID
-- tokens and failure classification went with it. What is left is the half
-- that was never about auth.
--
-- WHY THERE IS STILL A FIREBASE HERE AT ALL
--
-- Because FCM *is* Firebase. Push notifications cannot outlive the Firebase
-- app, so the native extension stays and stays initialised — see
-- firebaseauth/src/FirebaseAuthDefold.java, which builds FirebaseOptions by
-- hand (Defold does not apply the Google Services Gradle plugin, so
-- google-services.json never becomes the string resources that would normally
-- do it) and, in the same breath, fetches the registration token and creates
-- the notification channels.
--
-- The extension used to expose silent_login/login/refresh_token as well. They
-- are gone now — not merely unexported here, but removed from the Java, the
-- JNI bridge and the gradle dependencies behind them. Authentication is the
-- device id, and the phone number when that is not enough, both over plain
-- HTTP to our own backend.
--
-- WHAT THE REST OF THE APP GETS
--
--   M.get_fcm_token()          the cached registration token, "" if none yet
--   M.fetch_fcm_token()        ask for one
--   M.on_fcm_token(fn)         called whenever one arrives, including rotations
--   M.consume_pending_action() the notification button that opened the app
local M = {}

-- Resolved once. The extension registers nothing outside Android, so this is
-- nil in the editor and on desktop, and every function below takes its stub
-- path rather than erroring — which is what lets the game still run outside a
-- device build.
local ext = _G.firebaseauth

M.available = ext ~= nil and ext.is_available ~= nil and ext.is_available()

--- The registration token this device already holds, or "".
function M.get_fcm_token()
    if not M.available or not ext.get_fcm_token then return "" end
    local ok, tok = pcall(ext.get_fcm_token)
    return (ok and tok) and tok or ""
end

--- Ask for a registration token. Answers on the listener, not here.
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
