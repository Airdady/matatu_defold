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
    }
    if _auth_token ~= "" then
        h["Authorization"] = "Bearer " .. _auth_token
    end
    return h
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
    if not success then
        if type(data) == "table" and data.message then
            message = data.message
        elseif type(data) == "table" and data.reason then
            message = data.reason
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
    local options = { timeout = 20 }
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

return M