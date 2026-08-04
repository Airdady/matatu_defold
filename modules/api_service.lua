-- api_service.lua
-- REST client for the Matatu backend
local config = require("modules.config")
local json_util = require("modules.json_util")

local M = {}

local _device_id = nil
local _auth_token = ""
local SAVE_FILE = sys.get_save_file("matatu_gdt", "device.json")

-- STREAMING_CHUNK: Setting up device ID generation...
local function generate_id()
    local info = sys.get_sys_info()
    if info.device_ident and info.device_ident ~= "" then
        return info.device_ident
    end
    math.randomseed(os.time() + (os.clock() * 1000000))
    local t = {}
    for _ = 1, 24 do
        t[#t + 1] = string.format("%x", math.random(0, 15))
    end
    return "defold_" .. table.concat(t)
end

function M.get_device_id()
    if _device_id then
        return _device_id
    end
    local saved = sys.load(SAVE_FILE)
    if saved and saved.device_id and saved.device_id ~= "" then
        _device_id = saved.device_id
    else
        _device_id = generate_id()
        sys.save(SAVE_FILE, { device_id = _device_id })
    end
    return _device_id
end

function M.set_auth_token(token)
    _auth_token = token or ""
end

-- STREAMING_CHUNK: Defining session persistence...
local SESSION_FILE = sys.get_save_file("matatu_gdt", "session.json")

function M.save_session(user)
    if type(user) ~= "table" then
        return
    end
    local data = {
        _id         = user._id or user.localId or "",
        username    = user.username or "",
        avatar      = user.avatar or 1,
        balance     = user.balance or 0,
        points      = user.points or 0,
        phoneNumber = user.phoneNumber or user.phone or "",
        idToken     = user.idToken or user.token or _auth_token or "",
        -- Whether the live login that produced this session was resolved by
        -- an actual Google identity match (see auth.routes.ts's /google
        -- response) — app_state.phone_complete() uses this to skip the
        -- mandatory phone-migration step for already-fully-identified
        -- accounts. Persisted here (not just held in memory) so a cold app
        -- restart using this cached session doesn't lose the signal and
        -- re-prompt for a phone number before the next fresh login even runs.
        matchedByGoogleId = user.matchedByGoogleId and true or false,
    }
    sys.save(SESSION_FILE, data)
end

function M.load_session()
    local d = sys.load(SESSION_FILE)
    if type(d) ~= "table" or (d._id or "") == "" then
        return nil
    end
    return d
end

function M.clear_session()
    sys.save(SESSION_FILE, {})
end

-- ── the offline latch, on disk ──────────────────────────────────────────────
--
-- An account the server refuses stays refused. Keeping that only in memory
-- means every launch rediscovers it: a device sign-in, a 403, and a socket
-- attempt, all to be told the same thing again — on every cold start, forever.
--
-- Written to its OWN file rather than into the session, because the session is
-- cleared when the app goes offline and this has to outlive that. Reading it
-- costs one file read at boot and saves every request that would otherwise be
-- made to learn something already known.
local OFFLINE_FILE = sys.get_save_file("matatu_gdt", "offline.json")

--- Remember that this install is offline, and why.
function M.set_app_offline(reason)
    pcall(sys.save, OFFLINE_FILE, {
        offline = true,
        reason  = tostring(reason or ""),
        at      = os.time(),
    })
end

--- Forget it. Called when the server accepts an identify — the one event that
--- proves the refusal no longer applies.
function M.clear_app_offline()
    pcall(sys.save, OFFLINE_FILE, {})
end

--- Is this install offline? Answers from disk, asking nobody.
function M.is_app_offline()
    local ok, d = pcall(sys.load, OFFLINE_FILE)
    if not ok or type(d) ~= "table" then return false end
    return d.offline == true
end

-- STREAMING_CHUNK: Building request parsers...
local function build_headers()
    local h = {
        ["Content-Type"]  = "application/json",
        ["X-Device-ID"]   = M.get_device_id(),
        ["X-Platform"]    = "android",
        ["X-App-Version"] = config.APP_VERSION,
        -- Android versionCode. The server's force-update floor compares this
        -- rather than the display name: it is a monotonic integer, so there is
        -- nothing to parse and no way for "18.5.9" vs "18.5.10" to sort wrong.
        ["X-App-Build"]   = tostring(config.APP_BUILD or 0),
        -- Which of the two matatus this is. com.matatu.champ and
        -- com.matatu.nap are the same game with independent versionCode
        -- sequences, so the build above only means something once the server
        -- knows which sequence it came from. Absent, the server falls back to
        -- the game — exact for whot and kadi, a coin toss between the two
        -- matatus.
        ["X-App-Package"] = tostring(config.APP_PACKAGE or ""),
        -- ngrok's free tier puts an HTML interstitial in front of a tunnel for
        -- anything it takes for a browser, and this header is how it is waived.
        -- Without it a request can come back 200 with a page of markup where
        -- the JSON should be, which json_util decodes to nothing and every
        -- caller then reads as an empty answer rather than a wrong one.
        --
        -- Harmless everywhere else: a header no other host looks at.
        ["ngrok-skip-browser-warning"] = "true",
    }
    if _auth_token ~= "" then
        h["Authorization"] = "Bearer " .. _auth_token
    end
    return h
end

-- Called with the server's UPDATE_REQUIRED payload the first time any request
-- is refused for being out of date. Set by controller.script; parked here so
-- the check can live in parse_response, which EVERY endpoint funnels through —
-- a per-caller check would only cover the endpoints someone remembered.
M.on_update_required = nil
local _update_notified = false

local function notify_update_required(data)
    if _update_notified then return end   -- one screen, not one per request
    _update_notified = true
    if M.on_update_required then
        pcall(M.on_update_required, type(data) == "table" and data or {})
    end
end

local function parse_response(response)
    if not response then
        return {
            success     = false,
            status_code = 0,
            data        = {},
            message     = "Connection Error"
        }
    end
    local code = response.status or 0
    local data = json_util.decode(response.response or "") or {}
    local success = code >= 200 and code < 300
    local message = "Success"
    if code == 426 then
        -- 426 UPGRADE REQUIRED: this build is below the server's minimum and
        -- nothing it asks for will be answered. Raise the blocking update
        -- screen rather than letting the caller render this as an ordinary
        -- failure — the player cannot retry their way out of it.
        message = (type(data) == "table" and data.message)
            or "A new version is required to keep playing."
        notify_update_required(data)
    elseif code == 304 then
        -- 304 carries NO body, so `data` is empty. Every caller reads fields
        -- off data — ownerId, players, balance — and an empty table looks
        -- exactly like a legitimate "you are not the owner" or "this bracket
        -- has nobody in it". Both ends now prevent 304s (the server sends
        -- no-store and generates no ETag; requests below set ignore_cache), so
        -- if one still arrives it is a proxy's doing: fail it plainly rather
        -- than letting a bodyless response masquerade as data.
        message = "Stale response from the network. Pull to refresh."
    elseif not success then
        if type(data) == "table" and data.message then
            message = data.message
        elseif type(data) == "table" and data.reason then
            message = data.reason
        -- Several controllers (tournament.controller.js's createTournament/
        -- createTeamTournament/etc.) respond with { error: "..." } instead
        -- of { message }/{ reason } — last-resort fallback so those human-
        -- readable strings ("Insufficient balance...", "That invitation
        -- code is already taken.") actually reach the player instead of a
        -- generic "Server Error: 400".
        elseif type(data) == "table" and type(data.error) == "string" then
            message = data.error
        else
            message = "Server Error: " .. tostring(code)
        end
    end
    return {
        success     = success,
        status_code = code,
        data        = data,
        message     = message
    }
end

-- RETRYING A REQUEST THAT NEVER LANDED.
--
-- parse_response maps "no response at all" to status_code 0. That is not a
-- server answer — it is the request failing below HTTP: a refused TLS
-- handshake, a dropped connection, a name that would not resolve. The observed
-- case is a tunnel closing connections at its edge, where the handshake dies
-- about a second and a half in and the backend never sees anything:
--
--   SSLSocket mbedtls_ssl_handshake: -29312          (CONN_EOF: peer hung up)
--   HTTP request to '.../auth/link-phone' failed
--     (http result: -1  socket result: -1000)
--
-- One retry turns most of those into a success, because they are sporadic
-- rather than sustained.
--
-- OPT-IN, AND DEFAULTING TO ZERO, WHICH IS THE IMPORTANT PART.
--
-- status_code 0 means "no answer came back", NOT "the server did not act". A
-- response lost on the way home looks identical to a request that never
-- arrived, so retrying a withdrawal, a theme purchase or a cup creation could
-- charge a player twice for one action. Those endpoints must never opt in, and
-- with the default at zero they cannot do so by accident — only a call that
-- deliberately asks for retries gets them, and only the safe-to-repeat ones do.
local RETRY_BACKOFF = 0.6

local function request(method, endpoint, payload, cb, opts)
    opts = opts or {}
    local retries_left = opts.retries or 0
    local url = config.BASE_URL .. endpoint
    local body = payload and json_util.encode(payload) or nil
    -- ignore_cache: every endpoint here returns live state. Defold's HTTP cache
    -- would otherwise replay a stored response, or revalidate it and hand us a
    -- bodyless 304 that parse_response can only read as "no data".
    local options = { timeout = 20, ignore_cache = true }
    local attempt = 0

    local fire
    fire = function()
        attempt = attempt + 1
        -- Rebuilt per attempt so a token that arrived between tries is used.
        local headers = build_headers()
        print("[API] " .. method .. " " .. url
            .. (attempt > 1 and (" (retry " .. (attempt - 1) .. ")") or ""))
        http.request(url, method, function(_, _, response)
            local res = parse_response(response)
            if res.status_code == 0 and retries_left > 0 then
                retries_left = retries_left - 1
                print("[API] no answer - retrying in "
                    .. string.format("%.1fs", RETRY_BACKOFF * attempt))
                timer.delay(RETRY_BACKOFF * attempt, false, fire)
                return
            end
            if cb then cb(res) end
        end, headers, body, options)
    end

    fire()
end

-- DEVICE SIGN-IN. The way in.
--
-- No provider, no consent screen, no token exchange, no Play Services. The
-- device id is generated on first run and already sits on the User document,
-- so for anybody who has opened the app before this is the whole of signing in
-- — one request, and it is the first thing a launch makes.
--
-- The 404 is NOT an error. It means "we do not know this handset yet", which is
-- the ordinary state on a first run and the expected state on a new phone.
-- Both are answered by the phone number, which is the identity that survives
-- changing handsets — see phone_login below. The caller distinguishes the two
-- by result.data.code == "DEVICE_UNKNOWN" rather than by the status alone, so
-- a network failure (status 0) is never mistaken for "no account here".
function M.device_login(cb)
    local fcm_token = ""
    pcall(function()
        local fbpush = require("modules.firebase_push")
        if fbpush and fbpush.get_fcm_token then
            fcm_token = fbpush.get_fcm_token()
        end
    end)

    local payload = {
        deviceId = M.get_device_id(),
        fcmToken = (fcm_token and fcm_token ~= "") and fcm_token or nil,
    }

    -- Retried: a pure lookup, so repeating it cannot change anything, and it
    -- is the FIRST request a launch makes — losing it to a dropped handshake
    -- means the app cannot get in at all.
    request("POST", "/auth/device", payload, function(result)
        if result.success and result.data and result.data.token then
            M.set_auth_token(result.data.token)
        end
        if cb then cb(result) end
    end, { retries = 2 })
end

--- Does this answer mean "this handset is not on any account"?
---
--- A named predicate rather than `status_code == 404` at the call site: the
--- difference between "no account here" and "the request did not arrive" is
--- the difference between showing the phone screen and retrying quietly, and
--- getting it wrong in either direction is a player stuck on the wrong screen.
function M.is_device_unknown(result)
    if not result or result.success then return false end
    local code = result.data and result.data.code
    return code == "DEVICE_UNKNOWN" or code == "DEVICE_ID_INVALID"
end

function M.phone_login(payload, cb)
    payload = payload or {}
    payload.deviceId = payload.deviceId or M.get_device_id()
    if not payload.fcmToken then
        pcall(function()
            local fbpush = require("modules.firebase_push")
            if fbpush and fbpush.get_fcm_token then
                local tok = fbpush.get_fcm_token()
                if tok and tok ~= "" then payload.fcmToken = tok end
            end
        end)
    end
    -- Retried: find-or-create, so a repeat after a lost response finds the
    -- account the lost one made rather than making a second.
    request("POST", "/auth/phone", payload, function(result)
        if result.success and result.data and result.data.token then
            M.set_auth_token(result.data.token)
        end
        if cb then cb(result) end
    end, { retries = 2 })
end

-- Retried, with one caveat stated rather than glossed.
--
-- The merge path deletes the duplicate account once the merge is safely
-- persisted, so if a response is lost AFTER that happened, the retry carries a
-- token for an account that no longer exists and comes back 401. The player's
-- data is correct and merged; the screen wrongly says it failed.
--
-- Worth it anyway: that needs the response to be lost on the way home, whereas
-- the failure this fixes is the request never arriving at all, which is the one
-- actually being hit. No money moves either way.
function M.link_phone(payload, cb)
    request("POST", "/auth/link-phone", payload, cb, { retries = 2 })
end

function M.get_user(user_id, cb)
    if not user_id or user_id == "" then
        return cb({
            success     = false,
            status_code = 0,
            data        = {},
            message     = "User ID required"
        })
    end
    request("GET", "/users/" .. user_id, nil, cb)
end

-- Save the username and avatar, whether or not there is an account yet.
--
-- THE "USER ID REQUIRED" A NEW PLAYER HIT. This used to refuse here, on the
-- handset, without ever asking the server — and for a player who skipped phone
-- linking there IS no id, because nothing on that path creates an account:
-- /auth/device deliberately only resumes one, and the account-creating route
-- is the phone step they just skipped. So the very first thing a new player
-- does was answered with an error about an id they could not have.
--
-- With no id, this goes to the create-or-update route instead, which makes the
-- account against this device and applies the same username rules. The device
-- id rides along either way: on create it is what the new account is addressed
-- by, and on update it backfills accounts stored before device ids were kept.
function M.update_profile(user_id, payload, cb)
    payload = payload or {}
    payload.deviceId = payload.deviceId or M.get_device_id()

    if not user_id or user_id == "" then
        return request("POST", "/auth/device/profile", payload, cb)
    end
    request("PUT", "/users/" .. user_id, payload, cb)
end

function M.send_transaction(payload, cb)
    request("POST", "/payments", payload, cb)
end

-- Realtime mobile-money name enquiry. payload = { phoneNumber, _id?, save? }
function M.validate_phone(payload, cb)
    request("POST", "/payments/validate-phone", payload, cb)
end

-- Persist which saved number is the user's default. payload = { _id, phoneNumber }
function M.set_default_phone(payload, cb)
    request("POST", "/payments/phone/default", payload, cb)
end

-- Remove a saved number. payload = { _id, phoneNumber }
function M.delete_phone(payload, cb)
    request("POST", "/payments/phone/delete", payload, cb)
end

-- STREAMING_CHUNK: Adding theme and tournament endpoints...
function M.purchase_theme(user_id, theme_id, cb)
    request("POST", "/themes/purchase", { _id = user_id, themeId = theme_id }, cb)
end

function M.switch_theme(user_id, theme_id, cb)
    request("PATCH", "/themes/switch/user/" .. user_id, { themeId = theme_id }, cb)
end

function M.create_tournament(payload, cb)
    request("POST", "/tournaments", payload, cb)
end

function M.update_tournament(tournament_id, payload, cb)
    request("PUT", "/tournaments/" .. tournament_id, payload, cb)
end

-- Team Tournaments — player-created, owner-funded multi-level brackets.
-- payload = { userId, name?, grandPrizeCoins, maxPlayers, gamesPerLevel,
--             invitationCode?, inviteUsernames? }
-- Percent-encode a query-string value. Usernames can legitimately contain
-- spaces and punctuation, which would otherwise produce a malformed URL.
local function urlencode(v)
    return (tostring(v or ""):gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Autocomplete for the invite field. Server caps at 5 and returns usernames
-- only; `exclude` keeps the caller out of their own suggestions.
function M.search_usernames(q, exclude, cb)
    local ep = "/users/search/usernames?q=" .. urlencode(q)
    if exclude and exclude ~= "" then ep = ep .. "&excludeUserId=" .. urlencode(exclude) end
    request("GET", ep, nil, cb)
end

function M.create_team_tournament(payload, cb)
    request("POST", "/tournaments/team", payload, cb)
end

-- payload = { userId, usernames = {...} }
function M.invite_team_tournament(tournament_id, payload, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/invite", payload, cb)
end

-- payload = { userId, code }
function M.join_team_tournament(payload, cb)
    request("POST", "/tournaments/team/join", payload, cb)
end

-- Cups this player was invited to but has not joined. No code needed to
-- accept one — being on the cup's allowedUsers IS the credential.
-- DEPRECATED. Invitations arrive on the user object now (ws.current_user_data
-- .teamInvitations), attached by the server to both the sign-in response and
-- the IDENTIFY reply — see modules/lobby/cups.lua. Nothing in the app calls
-- this any more; it is kept only so a rollback does not have to restore it.
function M.list_team_invitations(user_id, cb)
    request("GET", "/tournaments/team/invitations?userId=" .. urlencode(user_id), nil, cb)
end

function M.accept_team_invitation(tournament_id, user_id, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/accept", { userId = user_id }, cb)
end

-- Owner-only: cancels the cup and refunds the escrowed grand prize.
-- POSTed rather than DELETEd: a body on DELETE is dropped by some HTTP
-- stacks, which made the backend see no userId and refuse the real owner.
function M.delete_team_tournament(tournament_id, user_id, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/delete", { userId = user_id }, cb)
end

-- Owner-only: withdraw an invitation that was never accepted. Distinct from
-- drop_team_player, which removes someone already on the bracket.
function M.revoke_team_invitation(tournament_id, user_id, player_id, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/revoke",
        { userId = user_id, playerId = player_id }, cb)
end

-- Owner-only: remove a player from the bracket.
function M.drop_team_player(tournament_id, user_id, player_id, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/drop",
        { userId = user_id, playerId = player_id }, cb)
end

-- Owner-only: flips a gathering cup ('upcoming') to running ('active').
-- Refused by the backend with fewer than 2 players joined.
function M.start_team_tournament(tournament_id, user_id, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/start", { userId = user_id }, cb)
end

-- Populated bracket view (every player's level/status + the owner) —
-- viewable by the owner (playing or not) and by any joined player.
function M.get_team_tournament_bracket(tournament_id, cb)
    request("GET", "/tournaments/team/" .. tournament_id .. "/bracket", nil, cb)
end

-- Owner-only admin overrides. payload = { userId, playerId }
--
-- No caller since the online lobby's VIEW BRACKET modal was removed — team
-- cups are managed from the main lobby, and the standings screen reaches the
-- drop endpoint through drop_team_player instead. Kept, like
-- list_team_invitations above, because the endpoints are still there and a
-- rollback should not have to restore the bindings.
function M.advance_team_tournament_player(tournament_id, payload, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/advance", payload, cb)
end

function M.drop_team_tournament_player(tournament_id, payload, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/drop", payload, cb)
end

return M