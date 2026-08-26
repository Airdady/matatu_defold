-- THE CHAMPIONSHIP IS NOT PLAYED FOR THE POT.
--
--   Run: lua tools/test_championship_board.lua
--
-- A qualifier is played for a place in the next round. The coins on the table
-- are an entry, not a prize, and a two-stake bundle beside the scoreboard for
-- every one of seven rounds says the opposite: it makes each rung look like a
-- cash match, and makes the grand prize — the only money actually at stake —
-- look like one more of them.
--
-- So the ladder carries the championship's name instead of its money, and the
-- coins are held back for the one match they mean something in.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path
local CB = require("modules.championship_board")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end

local CHAMP_ID = "t-global"

-- The player's own tournament row, as getUserTournaments sends it.
local function champ(level, opts)
    opts = opts or {}
    return {
        _id = CHAMP_ID, name = "Global Championship", scope = "GLOBAL",
        tournamentCount = opts.levels or 7,
        levelNames = opts.levelNames,
        grandPrize = opts.grandPrize == nil and { value = 500000 } or opts.grandPrize,
        stake = { amount = 450 },
        userProgress = { currentLevel = level, levels = opts.played or {} },
    }
end

local function user(rows) return { tournaments = rows or {} } end

local function game(tid, stake)
    return { tournamentId = tid, stake = { amount = stake or 450 } }
end

----------------------------------------------------------------------
print("AN ORDINARY MATCH IS UNTOUCHED")
----------------------------------------------------------------------
do
    local p = CB.plan({ stake = { amount = 500 } }, user())
    check("not a championship", p.championship, false)
    check("the stake pot is still shown", p.pot.amount, 1000)
    check("in the centre, where it has always been", p.pot.y, CB.POT_Y_CENTRE)
    check("and it is not a grand prize", p.pot.grand, false)
    check("no watermark on an ordinary board", p.watermark, nil)
    check("coins may still fly at the end", CB.coins_may_settle(p), true)
end

do
    -- A free match still gets nothing: a "0 coins" bundle sitting there all
    -- game says less than no bundle.
    local p = CB.plan({ stake = { amount = 0 } }, user())
    check("a zero-stake game has no pot", p.pot, nil)
end

do
    -- A private cup is a tournament, but it is not THE championship.
    local cup = {
        _id = "t-cup", name = "Office Cup", scope = "PRIVATE",
        tournamentCount = 3, userProgress = { currentLevel = 3 },
    }
    local p = CB.plan(game("t-cup", 500), user({ cup }))
    check("a private cup keeps its stake pot", p.pot.amount, 1000)
    check("and is not badged as the championship", p.championship, false)
end

----------------------------------------------------------------------
print("A RUNG BELOW THE FINAL SHOWS THE NAME, NOT THE MONEY")
----------------------------------------------------------------------
do
    local p = CB.plan(game(CHAMP_ID), user({ champ(1) }))
    check("recognised as the championship", p.championship, true)
    check("no pot on the board", p.pot, nil)
    check("the watermark stands in for it", p.watermark, "CHAMPIONSHIP")
    check("and no coins fly at the end", CB.coins_may_settle(p), false)
end

do
    local p = CB.plan(game(CHAMP_ID), user({ champ(6) }))
    check("the semi-final is still a qualifier", p.pot, nil)
end

----------------------------------------------------------------------
print("THE FINAL IS THE ONE MATCH THE COINS MEAN SOMETHING IN")
----------------------------------------------------------------------
do
    local p = CB.plan(game(CHAMP_ID), user({ champ(7) }))
    check("the pot comes back", p.pot ~= nil, true)
    check("and it is the GRAND PRIZE, not the stake", p.pot.amount, 500000)
    check("marked as such", p.pot.grand, true)
    check("on this player's own side of the board", p.pot.y, CB.POT_Y_MINE)
    check("below the centre it sits at in an ordinary match",
        CB.POT_Y_MINE < CB.POT_Y_CENTRE, true)
    check("the watermark stays", p.watermark, "CHAMPIONSHIP")
    check("and the prize may fly to the winner", CB.coins_may_settle(p), true)
end

do
    -- A prize we cannot read is not a prize we may invent. The watermark still
    -- stands; a made-up figure about money does not.
    local p = CB.plan(game(CHAMP_ID), user({ champ(7, { grandPrize = 0 }) }))
    check("no pot for an unreadable prize", p.pot, nil)
    check("but still the championship", p.championship, true)
    check("and still no coins at the end", CB.coins_may_settle(p), false)
end

----------------------------------------------------------------------
print("READING THE LADDER")
----------------------------------------------------------------------
do
    -- `levels` is the player's own PROGRESS and is empty until they have
    -- played one, so it cannot be counted on for the ladder's length.
    local t = champ(1, { played = {} })
    check("the length comes from tournamentCount", CB.level_count(t), 7)

    local named = { _id = CHAMP_ID, scope = "GLOBAL",
                    levelNames = { "a", "b", "c" }, userProgress = { currentLevel = 3 } }
    check("levelNames is the fallback", CB.level_count(named), 3)
    check("and a player on its last rung is a finalist", CB.at_final(named), true)
end

do
    -- The dangerous case. A ladder whose length we could not read answers 0,
    -- and a player on level 3 of an unknown ladder must NOT be a finalist —
    -- that would put the grand prize on a qualifier's board.
    local unknown = { _id = CHAMP_ID, scope = "GLOBAL", userProgress = { currentLevel = 3 } }
    check("an unreadable ladder has no final", CB.at_final(unknown), false)
    local p = CB.plan(game(CHAMP_ID), user({ unknown }))
    check("so no pot is drawn", p.pot, nil)
end

do
    check("level 0 is not the final of a 7-rung ladder", CB.at_final(champ(0)), false)
    check("level 7 is", CB.at_final(champ(7)), true)
    -- Past the end is still the end: a progress row can read 8 of 7 between
    -- winning the final and the tournament closing.
    check("and so is anything past it", CB.at_final(champ(8)), true)
end

----------------------------------------------------------------------
print("A GAME WE CANNOT PLACE IS TREATED AS ORDINARY")
----------------------------------------------------------------------
do
    -- No tournament id at all, or an id that is in no list we hold. Falling
    -- back to "championship" would strip the pot off an ordinary cash match.
    local p1 = CB.plan({ stake = { amount = 500 } }, user({ champ(1) }))
    check("a game with no tournament id keeps its pot", p1.pot.amount, 1000)

    local p2 = CB.plan(game("t-unheard-of", 500), user({ champ(1) }))
    check("and so does an unknown tournament", p2.pot.amount, 1000)
    check("neither is badged", p2.championship, false)
end

do
    check("no state at all does not crash", CB.plan(nil, nil).championship, false)
    check("and offers no pot", CB.plan(nil, nil).pot, nil)
end

----------------------------------------------------------------------
print("THE THREE PLACES THAT HAVE TO AGREE")
----------------------------------------------------------------------
-- One decision, three consumers. If any of them re-derives it, the board can
-- draw a pot the game-over screen refuses to settle, or the other way round.
local function src(rel)
    local f = io.open(ROOT .. rel)
    local text = f:read("a")
    f:close()
    -- Comments explain the intent; they must not be what passes the test.
    return (text:gsub("%-%-[^\n]*", ""))
end

do
    local controller = src("main/controller.script")
    check("the pot is raised from the plan, not from the stake",
        controller:find("champ_board.plan(gs, ws.current_user_data)", 1, true) ~= nil, true)
    check("and the plan's own position is used",
        controller:find("x = plan.pot.x, y = plan.pot.y", 1, true) ~= nil, true)
    check("no pot means no pot",
        controller:find("if not plan.pot then return end", 1, true) ~= nil, true)
    check("the watermark is published for the board",
        controller:find("app_state.board_watermark = plan.watermark", 1, true) ~= nil, true)
    check("and so is the coin verdict",
        controller:find("app_state.board_coins_may_settle", 1, true) ~= nil, true)
end

do
    local gameover = src("main/gameover.gui_script")
    check("game over asks before flying coins",
        gameover:find("coins_may_settle", 1, true) ~= nil, true)
    -- Absence must not silently disable a payout that used to work.
    check("and an unset verdict means yes",
        gameover:find("if coins_may_settle == nil then coins_may_settle = true end", 1, true) ~= nil,
        true)
end

do
    local overlay = src("modules/overlay_ui.lua")
    check("the overlay has a watermark to set",
        overlay:find("function M.set_watermark", 1, true) ~= nil, true)
    check("it reads the published value rather than being told",
        overlay:find("M.set_watermark(self, app_state.board_watermark)", 1, true) ~= nil, true)
    check("it is turned a quarter turn, so it reads vertically",
        overlay:find("gui.set_rotation(self.watermark, vmath.vector3(0, 0, 90))", 1, true) ~= nil,
        true)
    check("and leaving the board clears it",
        overlay:find("M.set_watermark(self, nil)", 1, true) ~= nil, true)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
