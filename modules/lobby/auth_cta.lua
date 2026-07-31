-- When the PLAY ONLINE tile offers LOGIN WITH PHONE.
--
-- One boolean, in its own module, because the previous version of it was wrong
-- in a way nothing could catch. It lived inline in lobby.gui_script as
--
--     local show_phone_signin = not has_username
--
-- and has_username is not a test of whether sign-in worked. current_user_data
-- is populated at boot from the cached session (controller.script, via
-- api.load_session) — before a socket exists, let alone one the backend has
-- accepted. A returning player whose account cannot re-authenticate therefore
-- has a username from the cache, and the backup was hidden from them by the
-- very cache that proves nothing about their being signed in.
--
-- That is not a rare shape. Silent sign-in retries quietly and open-endedly and
-- deliberately never sets auth_state to "error" any more, so a player it can
-- never satisfy — a stale Play Games credential, an account the backend
-- rejects, no Play Services at all — sees no failure to react to. The tile
-- says PLAY NOW, the tap does nothing they can see, and with the button hidden
-- there was no other route in.
local M = {}

--- Should the PLAY ONLINE tile show its phone-login backup?
--
-- @param user_data  ws.current_user_data — may be nil, empty, or cached
-- @param identified ws.is_identified — the ONLY signal that means the backend
--                   accepted us. A token, a user payload and an open socket
--                   can each still be followed by a rejection, which is why
--                   this is the same thing controller.script sets identify_ok
--                   from rather than anything earlier in the sequence.
-- @return boolean
function M.should_offer_phone_login(user_data, identified)
    local username = type(user_data) == "table" and user_data.username or nil
    -- "" is TRUTHY in Lua, so an empty username has to be compared, not just
    -- tested. A signed-out payload carries exactly that.
    local has_username = type(username) == "string" and username ~= ""
    return not (has_username and identified and true or false)
end

return M
