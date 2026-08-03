-- modules/lobby/cups.lua — this player's team-cup state for the lobby.
--
-- It used to own a right-hand rail that listed every open cup, which meant
-- browsing strangers' cups and typing an invite code to get into one. Then it
-- listed invitations only. Now it renders nothing at all: the TEAM CUPS tile
-- surfaces both the cup you own and any pending invitations, so a second
-- container beside it was just duplicating the same rows in less space.
--
-- What is left is the data side — fetching the lists and answering the two
-- questions the tile asks: which cup do I own, and how many invitations are
-- waiting. Being on a cup's allowedUsers is both the invitation and the
-- credential, so the tile's action is ACCEPT and no code is involved.

local ws  = require("modules.websocket_manager")
local api = require("modules.api_service")

local M = {}

-- The one cup this player owns, if any. Read off the active-cup list rather
-- than from a separate request: the list already carries isOwner/started/
-- members for every cup, so nothing can disagree about the owned one.
function M.my_owned_cup(self)
    for _, t in ipairs(self.team_cups or {}) do
        if t.isOwner then return t end
    end
    return nil
end

-- Invitations come from the USER OBJECT, not from a request.
--
-- The server attaches them to the same payload that carries tournaments,
-- battles and balance, on both sign-in and IDENTIFY, so by the time a player
-- is signed in the app already knows who has invited them.
--
-- The call this replaces was the one part of the lobby with its own round
-- trip, its own failure mode and its own timing. On a cold start it raced the
-- sign-in that produces the very userId it took as a parameter, and when it
-- lost that race the tile showed nothing — indistinguishable from having no
-- invitations at all.
function M.invitations()
    local u = ws.current_user_data or {}
    local list = u.teamInvitations
    return type(list) == "table" and list or {}
end

--- The cups the user object already carries, if it does.
---
--- IDENTIFY's payload now includes them (see handleNearbyPlayers), so at launch
--- there is nothing to fetch: the moment the socket answers, the rail has its
--- data. That gap is what the connection badge going green ahead of the tile
--- actually was — the badge is the socket, and the tile was waiting on an HTTP
--- request the client could not even issue until the socket had identified.
function M.from_user_data()
    local list = (ws.current_user_data or {}).teamTournaments
    return type(list) == "table" and list or nil
end

function M.load(self, on_loaded)
    self.invites = M.invitations()

    -- KEPT when the payload has none, rather than blanked.
    --
    -- A scoped user update — a balance change, a theme switch — carries only
    -- the keys in its scope, and the client merges payloads key by key, so
    -- teamTournaments simply is not in that message. `carried or {}` reads
    -- that absence as "this player has no cups" and empties a rail that was
    -- correct a moment earlier, every time the balance moves.
    --
    -- Absent means UNSAID. Only a payload that actually carries the key gets
    -- to change what is on screen.
    local carried = M.from_user_data()
    if carried then self.team_cups = carried end

    if self.nodes and on_loaded then on_loaded(self) end
end

-- How many invitations are waiting — the tile shows this as a badge.
function M.invite_count(self)
    -- Falls back to the user object so a tile painted before load() has run
    -- still shows the badge.
    local list = self.invites
    if type(list) ~= "table" then list = M.invitations() end
    return #list
end

return M
