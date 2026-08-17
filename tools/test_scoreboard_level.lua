-- WHOSE LEVEL, AND WHETHER TO SAY ONE AT ALL.
--
--   Run: lua5.4 tools/test_scoreboard_level.lua
--
-- Two reports about the same caption on the game board's scoreboard.
--
-- 1. "when the game has 1 level don't display the level number". A battle's
--    single level IS the match, so "LEVEL 1" says nothing and reads as though
--    six more are coming.
--
-- 2. "display level according to the player — at times one player is on level 1
--    and the other on level 5". Players are matched on COMPATIBLE levels, never
--    equal ones: level 1 pairs with anyone at 1 or below, above that with anyone
--    at your level or higher. So differing is the ordinary case, and a single
--    number captioning both shows one of the two players the OTHER's level.
--
-- Underneath both sat a plain type error. `totalLevels` is a count, named and
-- typed as one, and initializeDeck was putting the levels ARRAY in it — so the
-- board could not tell a one-level battle from a seven-level ladder even in
-- principle. Fixed on the server; the reader below still accepts both shapes,
-- because the fixed server has to reach handsets already running and until it
-- does every live game is still sending the array.
--
-- The rule is extracted from main/game.gui_script rather than restated, so a
-- change there that breaks it fails here.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

local src = (function()
  local f = assert(io.open(here .. "/../main/game.gui_script"))
  local s = f:read("*a"); f:close()
  return s
end)()

----------------------------------------------------------------------
-- The real level_count, lifted out of the file it lives in.
----------------------------------------------------------------------
local body = src:match("(local function level_count%(v%).-\nend)")
assert(body, "level_count not found in game.gui_script")
local level_count = assert(load(body .. "\nreturn level_count"))()

print("── how many levels is this ──")
check("a count comes through as itself", level_count(7), 7)
check("...and so does a one", level_count(1), 1)
-- The shape every already-installed server still sends.
check("an ARRAY of levels is measured, not read as nil", level_count({ 1, 2, 3, 4, 5, 6, 7 }), 7)
check("a one-element array is one level", level_count({ 1 }), 1)
check("an empty array is one, not zero", level_count({}), 1)
check("nothing at all is one — a battle IS its single level", level_count(nil), 1)
check("junk is one rather than nil", level_count("nonsense"), 1)
check("zero is not a level count", level_count(0), 1)
check("negative is not either", level_count(-3), 1)

----------------------------------------------------------------------
-- The caption rule, read as the source states it.
----------------------------------------------------------------------
print("\n── what the caption says ──")

-- The block that decides the stage from tournamentScore.
local block = src:match("local total = level_count%(state%.tournamentScore%.totalLevels%).-stage_per_player = true%s*\n%s*end")
check("the caption is decided from a level COUNT", block ~= nil, true)

check("a multi-level game captions the VIEWER'S own rung",
      block ~= nil and block:find('stage = "Level " %.%. tostring%(my_lv%)') ~= nil, true)

check("the opponent's level is not put on the board",
      src:find("LV %%d vs LV %%d") == nil, true)

check("a one-level game says nothing at all",
      block ~= nil and block:find('stage = "Match"') ~= nil, true)

-- "Match" is the exact value the title builder treats as "no stage", so this
-- pairing is what actually suppresses the caption rather than printing it.
check("...and 'Match' is what the title treats as no stage",
      src:find('stage ~= "Match"') ~= nil, true)

check("my own level is read from the per-player map first",
      block ~= nil and block:find("my_lv = tonumber%(lv%[self%.my_id%]%)") ~= nil, true)
check("...falling back to the single number only when there is no map",
      block ~= nil and block:find("state%.tournamentScore%.currentLevel") ~= nil, true)

-- The OTHER source of a caption. A one-level tournament must not get one from
-- here either: "Quarter Finals" and "Level 1" are both claims about a bracket.
local t_block = src:match("local t_total = level_count%(.-\n%s*end\n%s*end")
check("the tournament object's own caption is gated the same way", t_block ~= nil, true)
check("...on its own level count, so it holds with no tournamentScore",
      t_block ~= nil and t_block:find("if t_total > 1 then") ~= nil, true)
check("...and it is the thing that carries stageName",
      t_block ~= nil and t_block:find("stageName") ~= nil, true)

----------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
