-- WHICH INVITES AND RESULTS COUNT AS THE CHAMPIONSHIP.
--
-- Runs under plain Lua with no simulator: modules/championship.lua requires
-- nothing, deliberately, so the one question every screen asks can be checked
-- without booting a single gui_script.
--
-- The case that matters most is "content-blind payload matched by id". A
-- GAME_REQUEST from the deployed server carries {_id, name, stake, matchFormat}
-- — no scope, no levels — so every content-based test answers false on it, and
-- that is exactly why the badge was never once seen on a real device. Matching
-- the id against the player's own tournament list is what makes it work without
-- waiting for a server deploy.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local champ = require("modules.championship")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

-- The player's own tournament list, exactly as getUserTournaments builds it.
-- `scope` has been on this payload since long before any of the recent work.
local user_data = { tournaments = {
  { _id = "champ-1", scope = "GLOBAL", name = "Global Championship",
    levels = {1,2,3,4,5,6,7}, status = "active" },
  { _id = "battle-9", scope = "PRIVATE", levels = {1}, status = "active" },
}}

-- The request payload as the CURRENTLY DEPLOYED backend sends it: four fields,
-- no scope, no levels. This is the case that produced "I still don't see the
-- badge" — every content-based test answers false on it.
local old_payload = { _id = "champ-1", name = "Global Championship",
                      stake = { amount = 450 }, matchFormat = 3 }
-- Same, but for a tournament whose name is not the giveaway.
local old_payload_anon = { _id = "champ-1", name = "Season Ladder",
                           stake = { amount = 450 }, matchFormat = 3 }
local old_battle = { _id = "battle-9", name = "Quick Battle",
                     stake = { amount = 100 }, matchFormat = 3 }

check("content-blind payload matched by id", champ.matches(old_payload_anon, user_data), true)
check("same payload with NO user data is unknown", champ.matches(old_payload_anon, nil), false)
check("battle is never the championship", champ.matches(old_battle, user_data), false)
check("name alone is enough", champ.matches(old_payload, nil), true)

-- The new payload, once the backend branch is deployed. Must not regress.
check("scope", champ.matches({ _id = "x", scope = "GLOBAL" }, nil), true)
check("explicit flag", champ.matches({ _id = "x", isChampionship = true }, nil), true)
check("levels array", champ.matches({ _id = "x", levels = {1,2,3,4,5,6,7} }, nil), true)
check("levels count", champ.matches({ _id = "x", levels = 7 }, nil), true)

-- Game-over payload uses `id`, not `_id`. A matcher that only looked for _id
-- would silently never fire on that screen.
check("gameover shape uses `id`", champ.matches({ id = "champ-1", levels = 7 }, user_data), true)
check("gameover shape, id match only", champ.matches({ id = "champ-1" }, user_data), true)

-- Degenerate input must not crash or guess yes.
check("nil", champ.matches(nil, user_data), false)
check("empty table", champ.matches({}, user_data), false)
check("no id, no content", champ.matches({ name = "Whatever" }, user_data), false)
check("user data without tournaments", champ.matches({ _id = "champ-1" }, {}), false)
check("known_id finds it", champ.known_id(user_data), "champ-1")
check("known_id on nothing", champ.known_id(nil), "")

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
