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

-- Pull the active-cup list the tile reads to find the cup this player owns.
-- One call on screen entry rather than polling; invitations no longer need one
-- at all.
function M.load(self, on_loaded)
    if self.team_cups_loading then return end
    self.team_cups_loading = true
    local uid = tostring((ws.current_user_data or {})._id or "")
    -- Read before the request as well as after: the user object already has
    -- them, so the tile is correct on the very first paint instead of after a
    -- round trip.
    self.invites = M.invitations()
    api.list_active_team_tournaments(uid, function(res)
        self.team_cups_loading = false
        self.team_cups = ((res or {}).data or {}).tournaments or {}
        self.invites = M.invitations()
        -- Unlike the other screens, lobby has no self._active flag — gating on
        -- one would silently never repaint, leaving the tile stuck on
        -- "Loading..." forever. self.nodes is the real signal that the screen
        -- is currently built.
        if self.nodes and on_loaded then on_loaded(self) end
    end)
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
