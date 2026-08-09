-- WAS THAT A SIGN-IN?
--
-- One question, asked in two places — the device sign-in and the phone
-- sign-in — and they had drifted into two different answers:
--
--   device   result.success and data.token   ...then an id check afterwards
--   phone    result.success and data.token   ...and no id check at all
--
-- Both were wrong in the same way. THE TOKEN IS NOT THE PROOF. The server
-- issues one when it can and returns `token: null` when it cannot — on a
-- deployment with no JWT_SECRET it signs the player in and says so
-- deliberately, because a missing secret must not be able to cost somebody
-- their account (see signAppToken in be_matatu's auth.routes.ts). Every one of
-- those successful sign-ins was read as a failure:
--
--   * device: "Could not sign in on this device", so a returning player was
--     sent to the phone screen with an account already waiting for them
--   * phone: the number was accepted, the account signed in behind the
--     screen — and the screen showed an error and stayed on the number pad
--
-- THE PROOF IS AN ACCOUNT ID. Without one there is nobody to identify as, and
-- no balance, bracket or name to route to. With one, everything downstream
-- works whether a token came or not: api_service only sets a bearer header
-- when there is a bearer to set, and the four routes behind it are the only
-- things that need one.
--
-- Its own module so both callers ask the same question and a test can ask it
-- directly — the bug was one boolean, and it lived inside a network callback
-- where nothing could reach it.
local M = {}

--- The account id in a sign-in response, or "" if there is not one.
---
--- `localId` is accepted alongside `_id`: it is what the older sign-in paths
--- named it, and a response carrying only that is still a real account.
function M.account_id(result)
    if type(result) ~= "table" then return "" end
    local data = type(result.data) == "table" and result.data or {}
    local user = type(data.user) == "table" and data.user or {}
    for _, key in ipairs({ "_id", "localId" }) do
        local v = user[key]
        if type(v) == "string" and v ~= "" then return v end
    end
    return ""
end

--- True when this response signed the player in.
---
--- `result.success` AND an account. Not the token: see the note above.
function M.signed_in(result)
    if type(result) ~= "table" or not result.success then return false end
    return M.account_id(result) ~= ""
end

--- The bearer token in a response, or "" when none was issued.
---
--- "" rather than nil so callers can compare without a type check, and so
--- "not issued" and "issued as an empty string" collapse into the one case
--- that matters: there is nothing to put in an Authorization header.
function M.token(result)
    if type(result) ~= "table" then return "" end
    local data = type(result.data) == "table" and result.data or {}
    return (type(data.token) == "string" and data.token) or ""
end

return M
