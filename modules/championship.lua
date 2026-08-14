-- WHAT KIND OF TOURNAMENT IS THIS?
--
-- One answer, for every screen that has to ask. It is asked from three places
-- that see three different shapes of the same tournament:
--
--   incoming.gui_script   raw.tournament   from a GAME_REQUEST
--   online.gui_script     raw.tournament   the same request, rendered inline
--   gameover.gui_script   tournamentData   from the game-over payload
--
-- and they were each answering it their own way, off whichever fields their own
-- payload happened to carry. That is how the same match could be a championship
-- on one screen and an ordinary tournament on the next.
--
-- IT MUST NOT DEPEND ON A FIELD THE SERVER MIGHT NOT SEND.
--
-- The first cut of the badge tested `#levels >= 7`. The request payload carries
-- {_id, name, stake, matchFormat} and no levels at all, so the test read an
-- absent field, answered 1, and no invite was ever badged — a check that could
-- not fire, sitting next to a badge nobody ever saw. Adding `scope` to the
-- payload fixes it, but only once that server is actually deployed, and until
-- then the badge stays invisible for exactly the same reason as before.
--
-- So the last resort asks nothing of the payload beyond an id. The player's own
-- tournament list already names the championship — it arrives with every
-- IDENTIFY, it is what the tournament map is drawn from, and it has carried
-- `scope` since long before any of this. Matching the id against that list
-- answers the question from data the client already holds, whatever the request
-- payload does or does not include.
local M = {}

-- The multi-level ladder. Mirrors MIN_TOURNAMENT_LEVELS_FOR_ANNOUNCEMENT on the
-- server, so "championship" means the same set of tournaments on both sides.
M.MIN_LEVELS = 7

local function level_count(t)
    local levels = type(t) == "table" and t.levels or nil
    if type(levels) == "table" then return #levels end
    return tonumber(levels) or 0
end

--- Does this tournament object SAY it is the championship?
--
-- In descending order of directness: the explicit flag, the scope it is derived
-- from, the name the scope replaced, and the level count. Every one of these is
-- absent from some payload somewhere, which is why there are four.
function M.is_championship(t)
    if type(t) ~= "table" then return false end
    if t.isChampionship == true then return true end
    if t.scope == "GLOBAL" then return true end
    if t.name == "Global Championship" then return true end
    return level_count(t) >= M.MIN_LEVELS
end

--- The id of the championship in the player's own tournament list, or "".
--
-- Deliberately takes the user data rather than requiring websocket_manager:
-- api_service already caused one "Circular dependency detected" build failure
-- by reaching for that module, and bob resolves `require` statically, so a
-- require here would tie every screen's dependency graph together for one
-- field. The callers all hold this table already.
function M.known_id(user_data)
    local list = type(user_data) == "table" and user_data.tournaments or nil
    if type(list) ~= "table" then return "" end
    for _, t in ipairs(list) do
        if type(t) == "table" and M.is_championship(t) then
            return tostring(t._id or t.id or "")
        end
    end
    return ""
end

--- Is THIS the championship, judged by what it says or by what we already know?
--
-- `user_data` is optional: pass it and a payload that says nothing useful can
-- still be recognised by its id. Without it this is just is_championship.
function M.matches(t, user_data)
    if M.is_championship(t) then return true end
    if type(t) ~= "table" then return false end
    local id = tostring(t._id or t.id or "")
    if id == "" then return false end
    return id == M.known_id(user_data)
end


-- WHICH BADGE THIS INVITE WEARS.
--
-- Three kinds, and they are NOT distinguishable by any single field:
--
--   CHAMPIONSHIP  the global multi-level ladder
--   KNOCKOUT      matchType KNOCKOUT — a score-cap match, not a series
--   BATTLE        a single level: the tournament IS the match
--
-- Order matters. A knockout is usually one level, so a level count alone would
-- call it a BATTLE; matchType is the only thing that separates the two. And the
-- championship is checked first because it is the one kind that is never either
-- of the others.
--
-- nil means "say nothing" rather than "ordinary". A multi-level private cup is
-- none of these three, and inventing a label for it would be worse than leaving
-- the strip as it was.
function M.kind(t, user_data)
    if M.matches(t, user_data) then return "CHAMPIONSHIP" end
    if type(t) ~= "table" then return nil end
    if tostring(t.matchType or ""):upper() == "KNOCKOUT" then return "KNOCKOUT" end
    if level_count(t) == 1 then return "BATTLE" end
    return nil
end

-- HOW WIDE THE PILL HAS TO BE FOR A GIVEN LABEL.
--
-- Nothing in the Defold GUI measures text at build time, so the pill is sized
-- from the character count. Derived from the badge that was already on screen
-- and looked right — 148px for "[CHAMPIONSHIP]", 14 characters — rather than
-- picked per label, so a new label cannot arrive with a width nobody checked.
--
-- Lives here, not in the two banner files, because both draw the same strip and
-- the layout test asserts they agree. No vmath: this module is deliberately
-- runnable outside Defold so the rules can be tested without booting a screen.
M.BADGE_CHAR_W = 11
M.BADGE_MIN_W  = 66

function M.badge_width(label)
    local n = #tostring(label or "")
    local w = n * M.BADGE_CHAR_W
    return w > M.BADGE_MIN_W and w or M.BADGE_MIN_W
end

return M
