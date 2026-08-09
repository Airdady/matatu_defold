-- modules/identify_recovery.lua
-- WHAT TO DO WHEN IDENTIFY DOES NOT SUCCEED.
--
-- THE PROBLEM THIS EXISTS FOR
--
-- A cached session is a permanent thing. The user id was resolved once, by a
-- Google sign-in on this device, and it does not expire — boot already uses it
-- directly (controller.script's `local cached = api.load_session()`), sending
-- IDENTIFY without going anywhere near Firebase.
--
-- Every failure path then threw it away. `identify_error` ran clear_session(),
-- which wipes the saved session and the auth token, and rebuilt the whole
-- identity through a Firebase silent login — a token fetch, an HTTP round trip
-- and a fresh backend match, to re-derive a user id the app already had
-- written down.
--
-- And it fired on the wrong things. identify_error is emitted from THREE
-- places, and only two of them are about the identity being wrong:
--
--   timeout     the client's own watchdog, after IDENTIFY went unanswered
--               three times. Nobody rejected anything — the socket dropped,
--               the server was slow, or (as actually shipped) the server
--               handled the reconnect down a branch that forgot to reply. The
--               cached identity is UNTESTED, not refused.
--   rejected    the server said IDENTIFY_ERROR, or answered a stale id with
--               "User not found". This one really is dead and has to be
--               rebuilt.
--
-- Treating the first as the second meant a network blip during the identify
-- window cost a full re-authentication, and on a device that could not reach
-- Firebase at that moment it cost the session entirely — the player was
-- signed out by a hiccup.
--
-- So: a timeout re-sends IDENTIFY and keeps the cache. Only a rejection
-- escalates.
local M = {}

-- How many times a timeout re-sends IDENTIFY before we stop assuming the
-- identity is fine.
--
-- Generous on purpose. Each of these is cheap — one small socket message
-- against a user id we already hold — whereas the alternative costs a Firebase
-- round trip and, if it fails, the session. The client's own watchdog has
-- already retried three times before we are called even once, so this is 5
-- rounds of 3.
M.MAX_REIDENTIFY = 5

-- Classify what actually happened. Anything not explicitly a rejection is
-- treated as a timeout, deliberately: wrongly re-identifying costs one socket
-- message, wrongly re-authenticating costs the cached session.
function M.classify(reason)
    return reason == "rejected" and "rejected" or "timeout"
end

--- What the app should do about a failed IDENTIFY.
--
-- @param reason    "timeout" | "rejected" (anything else reads as a timeout)
-- @param attempts  how many times we have already re-identified this run
-- @param has_cache is there a cached user id to identify AS?
-- @return "reidentify" send IDENTIFY again, keep the cached session
--         "reauth"     the identity is gone; rebuild it through Firebase
function M.plan(reason, attempts, has_cache)
    -- Nothing to re-send. Whatever the reason, the only route is a fresh
    -- sign-in.
    if not has_cache then return "reauth" end

    if M.classify(reason) == "rejected" then return "reauth" end

    if (tonumber(attempts) or 0) < M.MAX_REIDENTIFY then
        return "reidentify"
    end

    -- Out of budget. The identity has now gone unanswered fifteen times across
    -- five reconnects; something is wrong with it after all.
    return "reauth"
end

--- Does this plan destroy the cached session?
--
-- Its own function because it is the question that actually matters, and
-- because the bug was a call site that cleared the cache before looking at
-- the reason at all.
function M.clears_cache(plan)
    return plan == "reauth"
end

return M
