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
-- call it a BATTLE; and the championship is checked first because it is the one
-- kind that is never either of the others.
--
-- A MATCH FORMAT OF ONE IS A KNOCKOUT, not a one-game battle.
--
-- matchType is the field that says so outright, but it only reaches the client
-- from a server new enough to send it, and a knockout carries matchFormat 1
-- because its length is set by a score cap rather than by a series — the engine
-- reads requiredWins from scoreCap for exactly these (see
-- updateTournamentProgress). So the format is a second, independent tell.
--
-- It is safe to read it that way HERE specifically: this strip only ever shows
-- tournament, battle and knockout invites, and none of those is a single game.
-- Before this, such an invite fell through to "Best of 1" — a series of one,
-- which describes nothing — and wore no badge at all.
--
-- nil means "say nothing" rather than "ordinary". A multi-level private cup is
-- none of these three, and inventing a label for it would be worse than leaving
-- the strip as it was.
function M.kind(t, user_data)
    if M.matches(t, user_data) then return "CHAMPIONSHIP" end
    if type(t) ~= "table" then return nil end
    if tostring(t.matchType or ""):upper() == "KNOCKOUT" then return "KNOCKOUT" end
    local fmt = tonumber(t.matchFormat)
    if fmt and fmt <= 1 then return "KNOCKOUT" end
    if level_count(t) == 1 then return "BATTLE" end
    return nil
end

--- IS THIS INVITE A LADDER, OR JUST A GAME?
--
-- THE QUESTION THE SURFACE TURNS ON, and the one `gameType` cannot answer.
--
-- A battle — one player challenging another to a single game at a stake — goes
-- out as `gameType: "TOURNAMENT"` with a tournament id, because that is how
-- the battle plumbing routes it. So every check of the form
--
--     raw.gameType == "TOURNAMENT" or raw.tournament
--
-- calls it a tournament invite and gives it the inline strip, when what the
-- player sees is somebody asking them for a normal game. Reported exactly that
-- way, twice: "incoming game request for normal game is still showing up in
-- inline banner".
--
-- So the surfaces ask what the invite IS:
--
--   a LADDER    a championship, a knockout, or any tournament with more than
--               one level. One of several a player may be offered, often while
--               they are doing something else, and none of them needs
--               answering — the strip, which leaves the app working
--   a GAME      a plain challenge, or a one-level battle. One person asking
--               THIS player, with ten seconds on it and somebody watching the
--               other end — the centred dialog, which takes the screen
--
-- Fails towards A GAME when the payload says nothing useful: an unlabelled
-- invite is far more likely to be a challenge than a ladder, and the dialog is
-- the surface that cannot be missed.
--
-- Shared so the two surfaces cannot disagree. They must answer this
-- identically or a request is shown twice — the online screen's inline strip
-- AND the global overlay — or not at all, since the overlay stands down for
-- exactly what the online screen draws.
function M.is_ladder(raw, user_data)
    if type(raw) ~= "table" then return false end
    local t = type(raw.tournament) == "table" and raw.tournament or nil
    local kind = M.kind(t, user_data)
    if kind == "CHAMPIONSHIP" or kind == "KNOCKOUT" then return true end
    -- More than one level is a run at something, whatever kind() has a word
    -- for: kind() answers nil for a plain multi-level tournament.
    return level_count(t) > 1
end

-- WHAT THIS INVITE IS ASKING THE PLAYER TO DO.
--
-- Championship invites now reach every eligible player, joined or not, because
-- a ladder nobody may be invited to fills up very slowly. So one strip has to
-- carry two different questions:
--
--   already in    ACCEPT / DECLINE. A match, on terms they have already paid.
--   not in        JOIN / CANCEL, with the one-off entry fee stated. Tapping it
--                 enters them AND starts the match, and it costs real coins —
--                 so it must not look like the same button as ACCEPT.
--
-- The server settles which of the two it is (`youHaveJoined` on the payload,
-- decided against the recipient's own progress row) precisely so the client
-- never has to infer it from a level number: level 1 is both "just joined" and
-- "knocked back to the start", and only one of those has to pay again.
--
-- `entryFee` is what THIS recipient would pay — zero for somebody already in,
-- and zero for anything that is not the championship — so the strip can never
-- quote a fee nobody is being charged.
--
-- Falls back to "no join needed" whenever the payload says nothing, which is
-- every build older than this one. An unlabelled invite showing ACCEPT is the
-- behaviour that already exists; showing JOIN and a fee that nothing will
-- actually charge would be a lie.
local function num(v)
    local n = tonumber(v)
    return (n and n > 0) and n or 0
end

--- The grand prize on offer, as a plain number, or 0 if the payload has none.
--
-- Reads the shape the tournament document uses — grandPrize.value — and the
-- two flatter spellings older payloads carried, because the strip leads on
-- this figure and a banner with a blank where the prize should be is worse
-- than one that quietly omits the block.
function M.grand_prize(t)
    if type(t) ~= "table" then return 0 end
    local gp = t.grandPrize
    if type(gp) == "table" then
        return num(gp.value) > 0 and num(gp.value) or num(gp.coins)
    end
    return num(gp)
end

--- What the strip should offer for this request.
--
-- `payload` is the GAME_REQUEST data as it arrived. Returns a plain table so
-- both banner surfaces render from one answer and cannot disagree about
-- whether a player is being asked to join or to accept.
function M.offer(payload, user_data)
    local t = (type(payload) == "table" and type(payload.tournament) == "table")
        and payload.tournament or nil

    -- THREE WAYS TO RECOGNISE IT, because three shapes of invite arrive.
    --
    --   isChampionship      stated outright. The one to rely on.
    --   the tournament      matched by scope / name / level count, or by its id
    --                       against the player's own list — see M.matches.
    --   a bare tournamentId some paths send no tournament object at all (a
    --                       round continuation, and handleGameRequest's
    --                       mid-game branch). Without this they fall through to
    --                       the ordinary strip, which is the failure this whole
    --                       function exists to prevent.
    local is_champ = (type(payload) == "table" and payload.isChampionship == true)
        or M.matches(t, user_data)
    if not is_champ and type(payload) == "table" and payload.tournamentId then
        local known = M.known_id(user_data)
        is_champ = known ~= "" and tostring(payload.tournamentId) == known
    end

    -- Present and false is the only thing that means "not in yet". Absent means
    -- an older server that never answered the question, and inventing a JOIN
    -- prompt on top of one would ask for money nothing is going to take.
    --
    -- Written out rather than as `x and y or nil`: the value being tested for
    -- is FALSE, and that idiom collapses false to nil — which is exactly the
    -- one distinction this has to keep.
    local said = nil
    if type(payload) == "table" then said = payload.youHaveJoined end
    local joining = is_champ and said == false

    -- WHAT SWITCHES THE PREMIUM STRIP ON IS `championship`, NOT `joining`.
    --
    -- Those were conflated once, and the result was a design nobody could see:
    -- it fired only for a player who had not joined, so anybody already in the
    -- championship — which is everybody testing it — got the ordinary grey
    -- strip, and so did every player on a server that does not yet send
    -- `youHaveJoined` at all. A championship invite looks like a championship
    -- invite either way; joining only changes the BUTTON and whether a fee is
    -- named.
    return {
        championship = is_champ,
        joining      = joining,
        entry_fee    = joining and num(type(payload) == "table" and payload.entryFee) or 0,
        prize        = M.grand_prize(t),
        -- The label carries the PRICE, not just the verb: "JOIN FOR 500". A
        -- button that spends coins should say how much on its own face — the
        -- fee line beside it is the explanation, not the disclosure, and a
        -- player who reads only the button must still know what it costs.
        -- champ_banner owns the wording so the strip that draws it and the
        -- strip that measures it cannot disagree.
        accept_label = joining and "JOIN" or "ACCEPT",
        decline_label = joining and "CANCEL" or "DECLINE",
    }
end

--- The line under the buttons when a fee is about to be charged.
function M.fee_text(offer)
    if not offer or not offer.joining or offer.entry_fee <= 0 then return nil end
    return "One-time join fee"
end

-- The cap a knockout is played to.
--
-- 200 mirrors updateTournamentProgress's own fallback, so the number on the
-- banner is the number the match is actually played to. (The schema default is
-- 100 and the engine's fallback is 200 — they disagree, but the field has a
-- default so the fallback effectively never fires. Matching the engine is the
-- safer of the two if it ever does.)
function M.score_cap(t)
    return tonumber(type(t) == "table" and t.scoreCap or nil) or 200
end

-- What the strip says underneath the title.
--
-- "Best of 1" can no longer appear: anything with a format of one is a KNOCKOUT
-- by the rule above, and a knockout is described by its cap.
function M.format_text(t, kind)
    if kind == "KNOCKOUT" then
        return "SCORE CAP " .. M.score_cap(t)
    end
    return "Best of " .. (tonumber(type(t) == "table" and t.matchFormat or nil) or 3)
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
