-- WHO DROPPED, FOR HOW LONG, AND WHO IS ALLOWED TO SAY THEY ARE BACK.
--
-- THE BUG THIS EXISTS FOR
--
-- The opponent-disconnected dialog was driven by a payload the client never
-- actually read. wsUtil.ts broadcasts PLAYER_DISCONNECTED with
-- `disconnectedPlayer` and `gracePeriod`, but every other message this server
-- sends wraps its payload in `data`, so the client unwrapped `message.data`
-- first and then looked for its fields there — and found an empty table, every
-- single time. Both defaults then fired silently:
--
--   * the countdown became a hardcoded 30 seconds, unrelated to the grace the
--     server had actually granted, and
--   * the player id became "", so the dialog could not name who had dropped,
--     could not tell somebody else's disconnect from our own, and could not
--     tell whether an incoming reconnect was the one it was waiting for.
--
-- Underneath that sat a second trap. `gracePeriod` is a DEADLINE —
-- Date.now() + PLAY_TIMEOUT_DURATION — but it is named like a duration, and a
-- client that counts down from it directly counts down from about fifty
-- thousand years. The value being unreadable is the only reason that never
-- showed: the moment the payload was fixed, the timer would have broken
-- instead. Both halves have to be handled together, so both live here.
--
-- Pure and separate from websocket_manager because that module needs the
-- Defold engine to load, and "which fields mean what" is a claim that should
-- be provable rather than read.
local M = {}

-- Epoch milliseconds are ~1.7e12 and climbing. A grace expressed as a plain
-- duration is a few tens of thousands of ms at the very most. Nothing sane
-- lands between them, so the gap is the test.
local EPOCH_MS_FLOOR = 1e11

-- Server default when it tells us nothing usable. Matches PLAY_TIMEOUT_DURATION.
local FALLBACK_SECONDS = 30

--- First non-nil, non-empty value for `key` across the payload and its envelope.
--
-- Reads BOTH because the server has sent these fields at the top level
-- historically and under `data` now, and a client in the wild talks to
-- whichever backend happens to be deployed. Preferring `data` keeps the newer,
-- documented shape authoritative.
local function field(data, message, key)
    local v = (data or {})[key]
    if v ~= nil and v ~= "" then return v end
    v = (message or {})[key]
    if v ~= nil and v ~= "" then return v end
    return nil
end

--- How many seconds the dropped player actually has left.
--
-- `now` is passed in rather than read so this is testable; callers hand it
-- socket.gettime().
function M.grace_seconds(data, message, now)
    local secs = tonumber(field(data, message, "graceSeconds"))
    if not secs then
        local grace = tonumber(field(data, message, "gracePeriod"))
        if grace and grace > EPOCH_MS_FLOOR then
            -- A deadline. What is left is the interesting part.
            secs = (grace / 1000) - (tonumber(now) or 0)
        else
            secs = grace
        end
    end
    -- A grace that already expired is not a countdown to show. Fall back rather
    -- than render "0s" forever or, worse, a negative number.
    if not secs or secs <= 0 then return FALLBACK_SECONDS end
    return secs
end

--- Normalize a PLAYER_DISCONNECTED into what the dialog needs.
function M.parse_disconnect(data, message, now)
    return {
        player_id = tostring(field(data, message, "disconnectedPlayer")
            or field(data, message, "_id") or ""),
        grace     = M.grace_seconds(data, message, now),
        reason    = tostring(field(data, message, "reason") or "Unknown"),
    }
end

--- Normalize a PLAYER_RECONNECTED.
--
-- Both server paths that send this — heartbeatCleanup's and handleIdentify's —
-- name the field `reconnectedPlayer`.
function M.parse_reconnect(data, message)
    return {
        player_id = tostring(field(data, message, "reconnectedPlayer")
            or field(data, message, "_id") or ""),
    }
end

--- Is this event about US rather than the opponent?
--
-- The server broadcasts to the whole game. It terminates the dropped socket
-- before sending, so our own disconnect normally cannot reach us — but that is
-- a property of the server's ordering, not something the screen should lean on,
-- and it stops holding the moment we are the one reconnecting and a queued copy
-- lands. An unattributed event ("") is never treated as ours: raising a dialog
-- we should not have is recoverable, suppressing one we needed is not.
function M.is_self(player_id, my_id)
    local who = tostring(player_id or "")
    local me  = tostring(my_id or "")
    return who ~= "" and me ~= "" and who == me
end

--- May this reconnect dismiss the dialog we currently have up?
--
-- Only the player we are waiting on can, with one deliberate exception: an
-- unattributed reconnect dismisses it too. A reconnect we cannot attribute is
-- far likelier to be the one we are waiting for than a stray, and the two
-- failure modes are not symmetric — the dialog's scrim swallows every tap, so
-- leaving it up wrongly locks the player out for the rest of the game, while
-- dropping it wrongly costs one dialog that the next PLAYER_DISCONNECTED
-- raises again.
function M.should_dismiss(waiting_for, player_id)
    local waiting = tostring(waiting_for or "")
    local who     = tostring(player_id or "")
    if waiting == "" then return true end
    if who == "" then return true end
    return who == waiting
end

return M
