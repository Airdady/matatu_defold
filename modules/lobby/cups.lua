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

-- Pull this player's pending invitations, plus the active-cup list the tile
-- reads to find the cup they own. Two cheap calls on screen entry rather
-- than polling.
function M.load(self, on_loaded)
    if self.team_cups_loading then return end
    self.team_cups_loading = true
    local uid = tostring((ws.current_user_data or {})._id or "")
    api.list_active_team_tournaments(uid, function(res)
        self.team_cups = ((res or {}).data or {}).tournaments or {}
        api.list_team_invitations(uid, function(ires)
            self.team_cups_loading = false
            self.invites = ((ires or {}).data or {}).invitations or {}
        -- Unlike the other screens, lobby has no self._active flag — gating on
        -- one would silently never repaint, leaving the tile stuck on
        -- "Loading..." forever. self.nodes is the real signal that the screen
        -- is currently built.
            if self.nodes and on_loaded then on_loaded(self) end
        end)
    end)
end

-- How many invitations are waiting — the tile shows this as a badge.
function M.invite_count(self)
    return #(self.invites or {})
end

return M
