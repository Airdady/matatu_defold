-- WHAT THE PLAY ONLINE TILE SHOULD SAY.
--
-- THE BUG THIS EXISTS TO KILL
--
-- The top-right badge went green — ONLINE, correct, driven by the socket
-- itself — while the PLAY ONLINE tile sat on "CONNECTING… / Signing in with
-- Firebase…", with the player's session sitting in the cache the whole time.
-- Two widgets, one connection, opposite answers.
--
-- They disagreed because they were reading different things. The badge reads
-- the connection. The tile read app_state.auth_state, which is not a fact
-- about the connection at all — it is a note left behind by whichever code
-- path last started a sign-in, and NINE places set it. Every one of them has
-- to remember to clear it, and identify_success cleared it only on the
-- _restore_pending branch. So any sign-in attempt that completed some other
-- way — the reconciler adopting the cached session, a device identify, an
-- IDENTIFY_SUCCESS arriving on a socket that reconnected by itself — left the
-- note pinned to the fridge saying "signing in" while the player was already
-- signed in and live.
--
-- THE RULE
--
-- ws.is_identified means the server has accepted this player on this socket.
-- There is no state of the world in which that is true and "signing in with
-- Firebase" is also true. So it is checked FIRST, ahead of every auth_state
-- branch, and a stale note cannot outrank an accepted identity.
--
-- Deliberately is_identified and not merely socket_connected, even though the
-- badge is happy with the latter: the tile leads into matchmaking, and firing
-- matchmaking down a socket the server has not registered is the exact thing
-- this gate was built to prevent. Connected-but-not-yet-identified is a real
-- state and it is still "verifying" here — it just isn't allowed to last,
-- which is the reconciler's job.
--
-- Everything below that first rule keeps the order it already had.
local M = {}

--- Is a sign-in attempt notionally in flight?
function M.auth_is_busy(auth_state)
    return auth_state == "sending" or auth_state == "verifying"
end

--- What the tile should be showing.
---
--- facts: is_identified, reconnect_exhausted, has_cached_user, auth_state
--- returns one of: "ready" | "offline" | "verifying" | "signing_in" | "error"
function M.tile_state(f)
    f = f or {}

    -- 1. THE ONE THAT WAS MISSING. Accepted by the server: nothing else can
    --    make that untrue, so nothing else gets to speak first.
    if f.is_identified then return "ready" end

    -- 2. Retries given up on. Greyed but tappable — see auth_cta.
    if f.reconnect_exhausted then return "offline" end

    -- 3. A session we know, not yet confirmed live.
    if f.has_cached_user then return "verifying" end

    -- 4. No session yet and an attempt running.
    if M.auth_is_busy(f.auth_state) then return "signing_in" end

    -- 5. Kept last, exactly where it was: a cached player mid-verify should
    --    not be shown a failure that a reconnect is already recovering from.
    if f.auth_state == "error" then return "error" end

    return "ready"
end

--- Is auth_state a leftover that the live connection has already overtaken?
---
--- Used to clear the note rather than merely out-vote it. The label is only
--- half the damage: go_online() refuses to act while auth_state reads busy,
--- so a stranded one leaves the tile looking wrong AND swallowing the tap.
--- Fixing the display alone would have produced a tile that says PLAY NOW and
--- does nothing, which is worse than one that admits it is stuck.
function M.stale_auth(auth_state, is_identified)
    if not is_identified then return false end
    return M.auth_is_busy(auth_state) or auth_state == "error"
end

return M
