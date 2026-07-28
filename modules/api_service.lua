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

local function request(method, endpoint, payload, cb)
    local url = config.BASE_URL .. endpoint
    local headers = build_headers()
    local body = payload and json_util.encode(payload) or nil
    -- ignore_cache: every endpoint here returns live state. Defold's HTTP cache
    -- would otherwise replay a stored response, or revalidate it and hand us a
    -- bodyless 304 that parse_response can only read as "no data".
    local options = { timeout = 20, ignore_cache = true }
    print("[API] " .. method .. " " .. url)
    http.request(url, method, function(_, _, response)
        if cb then
            cb(parse_response(response))
        end
    end, headers, body, options)
end

-- STREAMING_CHUNK: Implementing GPGS auth endpoint...
function M.gpgs_login(server_auth_code, cb)
    -- Changed 'authCode' to 'serverAuthCode' to match the backend exactly
    local payload = {
        serverAuthCode = server_auth_code,
        deviceId       = M.get_device_id()
    }

    -- Directs to the standard GPGS login endpoint on your backend
    request("POST", "/auth/google", payload, function(result)
        -- Changed 'idToken' to 'token' to match backend's generated JWT
        if result.success and result.data and result.data.token then
            M.set_auth_token(result.data.token)
        end
        if cb then
            cb(result)
        end
    end)
end

-- Old-account migration: link a phone number to the just-authenticated
-- Google account. Requires the Bearer token already set via set_auth_token
-- (build_headers attaches it automatically). Backend response shape:
-- { success, merged, user, token? } — `token` is only present when `merged`
-- is true (the account identity changed to the old, now-linked account).
-- Phone sign-in — the way in when Google Play Games cannot work at all (Play
-- Services missing/disabled/out of date, no Google account, an OAuth client
-- not registered for the build).
--
-- payload = { phoneNumber, deviceId }. Three possible answers:
--   { success, isNewUser = true,  token, user }  account created, signed in
--   { success, isNewUser = false, token, user }  known account on THIS device
--   { success, requiresOtp = true }              known account, new device —
--                                                a code was sent, call
--                                                M.verify_phone_login next
-- The split is deliberate: a phone number is not a secret, so it alone must
-- not hand over an account that holds withdrawable coins. See the route.
function M.phone_login(payload, cb)
    payload = payload or {}
    payload.deviceId = payload.deviceId or M.get_device_id()
    request("POST", "/auth/phone", payload, function(result)
        if result.success and result.data and result.data.token then
            M.set_auth_token(result.data.token)
        end
        if cb then cb(result) end
    end)
end

-- Second half of the different-device path. payload = { phoneNumber, code }
function M.verify_phone_login(payload, cb)
    payload = payload or {}
    payload.deviceId = payload.deviceId or M.get_device_id()
    request("POST", "/auth/phone/verify", payload, function(result)
        if result.success and result.data and result.data.token then
            M.set_auth_token(result.data.token)
        end
        if cb then cb(result) end
    end)
end

function M.link_phone(payload, cb)
    request("POST", "/auth/link-phone", payload, cb)
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

function M.update_profile(user_id, payload, cb)
    if not user_id or user_id == "" then
        return cb({
            success     = false,
            status_code = 0,
            data        = {},
            message     = "User ID required"
        })
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

-- Open team tournaments for the lobby list. `user_id` marks the ones the
-- caller already joined/owns so the card can render JOINED instead of JOIN.
function M.list_active_team_tournaments(user_id, cb)
    local ep = "/tournaments/team/active"
    if user_id and user_id ~= "" then ep = ep .. "?userId=" .. urlencode(user_id) end
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
function M.advance_team_tournament_player(tournament_id, payload, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/advance", payload, cb)
end

function M.drop_team_tournament_player(tournament_id, payload, cb)
    request("POST", "/tournaments/team/" .. tournament_id .. "/drop", payload, cb)
end

return M