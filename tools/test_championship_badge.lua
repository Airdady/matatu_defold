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

-- ── Which badge an invite wears ──────────────────────────────────────────────
--
-- The three are NOT separable by any single field. A knockout is usually one
-- level, so a level count alone calls it a BATTLE; matchType is the only thing
-- that tells them apart.
check("championship", champ.kind({ _id = "champ-1", scope = "GLOBAL", levels = 7 }), "CHAMPIONSHIP")
check("championship by id, payload says nothing",
      champ.kind({ _id = "champ-1", name = "Season Ladder" }, user_data), "CHAMPIONSHIP")

check("knockout", champ.kind({ _id = "k", matchType = "KNOCKOUT", levels = 1 }), "KNOCKOUT")
check("knockout, lowercase", champ.kind({ _id = "k", matchType = "knockout", levels = 1 }), "KNOCKOUT")
check("knockout beats the single-level BATTLE reading",
      champ.kind({ _id = "k", matchType = "KNOCKOUT", levels = 1 }), "KNOCKOUT")
check("a multi-level knockout is still a knockout",
      champ.kind({ _id = "k", matchType = "KNOCKOUT", levels = 4 }), "KNOCKOUT")

-- A MATCH FORMAT OF ONE IS A KNOCKOUT ON THIS STRIP.
--
-- The reported case: a knockout invite showed no badge and read "Best of 1",
-- because matchType had not reached the client and the level count said BATTLE.
-- A knockout carries matchFormat 1 — its length comes from the score cap, not
-- from a series — and the strip only ever shows tournament, battle and knockout
-- invites, so a one-game series there is a knockout by elimination.
check("format of 1 is a knockout even with no matchType",
      champ.kind({ _id = "k", matchFormat = 1, levels = 1 }), "KNOCKOUT")
check("format of 0 too", champ.kind({ _id = "k", matchFormat = 0, levels = 1 }), "KNOCKOUT")
check("an absent format does NOT imply a knockout",
      champ.kind({ _id = "b", levels = 1 }), "BATTLE")
check("nor does a real series", champ.kind({ _id = "b", matchFormat = 3, levels = 1 }), "BATTLE")

check("single level is a battle", champ.kind({ _id = "b", levels = 1 }), "BATTLE")
check("single level as an array", champ.kind({ _id = "b", levels = {1} }), "BATTLE")
check("NORMAL matchType does not override the level count",
      champ.kind({ _id = "b", matchType = "NORMAL", levels = 1 }), "BATTLE")

-- nil means "say nothing", which is not the same as "ordinary". Inventing a
-- label for a shape nobody named would be worse than leaving the strip alone.
check("a multi-level private cup gets no badge",
      champ.kind({ _id = "cup", scope = "PRIVATE", levels = 4 }), nil)
check("nothing at all gets no badge", champ.kind(nil, user_data), nil)
check("an empty payload gets no badge", champ.kind({}, user_data), nil)

-- ── What the strip says underneath the title ─────────────────────────────────
--
-- "Best of 1" must be unreachable: a format of one is a KNOCKOUT by the rule
-- above, and a knockout is described by its cap. It is the exact string the
-- knockout banner was showing.
check("a knockout is described by its cap",
      champ.format_text({ matchFormat = 1, scoreCap = 250 }, "KNOCKOUT"), "SCORE CAP 250")
check("a knockout with no cap falls back to the engine's own figure",
      champ.format_text({ matchFormat = 1 }, "KNOCKOUT"), "SCORE CAP 200")
check("a series is described by its length",
      champ.format_text({ matchFormat = 3 }, "BATTLE"), "Best of 3")
check("and an absent format reads as best of three",
      champ.format_text({}, "BATTLE"), "Best of 3")

-- The end-to-end shape of the reported bug: this payload used to produce no
-- badge and "Best of 1".
local knockout_payload = { _id = "k", matchFormat = 1, scoreCap = 300, levels = {1} }
local k = champ.kind(knockout_payload)
check("the reported payload badges KNOCKOUT", k, "KNOCKOUT")
check("...and reads SCORE CAP 300", champ.format_text(knockout_payload, k), "SCORE CAP 300")
check("...and never says Best of 1", champ.format_text(knockout_payload, k) ~= "Best of 1", true)

-- Pill widths are derived, not picked per label, so a new label cannot arrive
-- with a width nobody checked.
check("CHAMPIONSHIP width", champ.badge_width("CHAMPIONSHIP"), 132)
check("KNOCKOUT width", champ.badge_width("KNOCKOUT"), 88)
check("BATTLE width clamps to the minimum", champ.badge_width("BATTLE"), 66)
check("every label fits the reserved slot",
      champ.badge_width("CHAMPIONSHIP") <= 132
      and champ.badge_width("KNOCKOUT") <= 132
      and champ.badge_width("BATTLE") <= 132, true)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
