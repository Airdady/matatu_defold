-- THE WINNERS ANNOUNCEMENT, FROM THE SOCKET TO THE NODES.
--
--   Run: lua tools/test_winners_flow.lua
--
-- modules/emoji_text and modules/flag_art are covered on their own by
-- tools/test_emoji_text.lua. What is NOT covered by that is the wiring: that
-- a message shaped exactly the way be_matatu sends it arrives at the marquee
-- and the Season Complete board and comes out as pictures.
--
-- The payloads below are copied from the server's own builders — the marquee
-- row from winnersBanner.ts (winnerRow), the board rows from the cross-game
-- standings snapshot it takes. They are the contract between two
-- repositories, and the field names in them (`country`, `currency`,
-- `winnersAreGlobal`) are the whole of it: rename one on either side and the
-- flags quietly stop being drawn, with nothing failing anywhere.
--
-- The specific thing being prevented is a flag reaching a TEXT node. Every
-- fonts/*.font here is built with `all_chars: false`, so a codepoint the font
-- lacks comes back as .notdef and paints as "~" — a winners banner reading
-- "1. ~~ StormRider".

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

for name in pairs(package.loaded) do
    if name:match("^modules%.") then package.loaded[name] = nil end
end
package.path = ROOT .. "?.lua;" .. package.path

local SIM = dofile(ROOT .. "tools/defold_sim.lua")
SIM.install_gui_stub()
_G.window.set_listener = function() end
_G.sys.get_config_string = function() return "" end
_G.sys.get_config = function() return "" end
_G.http = { request = function() end }

-- Both screens draw flags through flag_art.draw. Wrapping it is how we see
-- WHICH countries were drawn — the nodes themselves are anonymous rectangles.
local flag_art = require("modules.flag_art")
local flags_drawn = {}
local real_draw = flag_art.draw
flag_art.draw = function(pos, h, code, opts)
    flags_drawn[#flags_drawn + 1] = flag_art.code(code) or tostring(code)
    return real_draw(pos, h, code, opts)
end

local UG, NG, KE = "\240\159\135\186\240\159\135\172",
                   "\240\159\135\179\240\159\135\172",
                   "\240\159\135\176\240\159\135\170"

local function drew(code)
    for _, c in ipairs(flags_drawn) do if c == code then return true end end
    return false
end
local function texts_of(nodes)
    local out = {}
    for _, n in ipairs(nodes or {}) do
        if n.kind == "text" and n.text then out[#out + 1] = n.text end
        for _, c in ipairs(n.children or {}) do
            if c.kind == "text" and c.text then out[#out + 1] = c.text end
        end
    end
    return out
end
local function contains(list, needle)
    for _, v in ipairs(list) do if v:find(needle, 1, true) then return true end end
    return false
end

local ws = require("modules.websocket_manager")
require("modules.app_state").current_screen = "online"

SIM.add_recorder("controller")
SIM.load_script_component("announcement", ROOT .. "main/announcement.gui_script")
SIM.load_script_component("season", ROOT .. "main/season_results.gui_script")
SIM.init_component("announcement")
SIM.init_component("season")
SIM.pump(0.2)
ws.connect()
SIM.pump(0.5)

----------------------------------------------------------------------
print("THE MARQUEE")
----------------------------------------------------------------------
-- Verbatim winnerRow() output for two winners in two countries.
local MSG = "**CONGRATULATIONS TO THIS WEEK'S TOP 10 CHAMPIONS!**"
    .. " • **1.** {{a:5}} " .. UG .. " **StormRider** **1,240 pts** ~5,000 UGX/-"
    .. " • **2.** {{a:7}} " .. NG .. " **Bello** **980 pts** ~2,000 NGN/-"

flags_drawn = {}
SIM.server_send({ type = "PUBLIC_ANNOUNCEMENTS",
                  data = { { id = "w1", text = MSG, duration = 4000, rounds = 1 } } })
SIM.pump(1.0)

local ann = SIM.components.announcement.self
local ticker = {}
local function walk(n)
    if not n then return end
    ticker[#ticker + 1] = n
    for _, c in ipairs(n.children or {}) do walk(c) end
end
walk(ann.holder1)
local ticker_texts = texts_of(ticker)

ok("the banner rendered", #ticker_texts > 0)
ok("uganda was drawn", drew("UG"))
ok("nigeria was drawn", drew("NG"))
ok("no flag reached a text node — this is the '~' bug",
   not contains(ticker_texts, UG) and not contains(ticker_texts, NG))
ok("the names survived the emoji being lifted out",
   contains(ticker_texts, "StormRider") and contains(ticker_texts, "Bello"))
ok("each winner's own currency is named",
   contains(ticker_texts, "UGX") and contains(ticker_texts, "NGN"))
ok("...and their points", contains(ticker_texts, "1,240 pts"))
ok("no naira SIGN, which the fonts have no glyph for either",
   not contains(ticker_texts, "\226\130\166"))

----------------------------------------------------------------------
print("")
print("THE SEASON COMPLETE BOARD")
----------------------------------------------------------------------
-- The cross-game snapshot, in the shape winnersBanner.ts's toGlobalStanding
-- produces it.
local BOARD = {
    { rank = 1, userId = "u1", username = "StormRider", avatar = 3, points = 1240,
      coinsEarned = 5000, game = "matatu", country = "UG", currency = "UGX" },
    { rank = 2, userId = "u2", username = "Bello", avatar = 7, points = 980,
      coinsEarned = 2000, game = "whot", country = "NG", currency = "NGN" },
    { rank = 3, userId = "u3", username = "Wanjiru", avatar = 9, points = 640,
      coinsEarned = 200, game = "kadi", country = "KE", currency = "KES" },
    -- A payload cached before any of this shipped: no country, no currency.
    { rank = 4, userId = "u4", username = "Legacy", avatar = 1, points = 100,
      coinsEarned = 50 },
}

flags_drawn = {}
SIM.server_send({ type = "SEASON_COMPLETE", data = {
    seasonId = "s1", seasonNumber = 7,
    startDate = "2026-08-01T00:00:00.000Z", endDate = "2026-08-19T00:00:00.000Z",
    playerRank = 2, playerPointsEarned = 980, coinsEarned = 2000,
    savingCoinsEarned = 0, rewardPointsEarned = 0,
    badgesEarned = {}, missionsCompleted = {},
    finalLeaderboard = BOARD, topWinners = { BOARD[1], BOARD[2], BOARD[3] },
    winnersAreGlobal = true,
} })
SIM.pump(2.0)

local board_texts = texts_of(SIM.components.season.self.nodes)

ok("the dialog rendered", #board_texts > 0)
ok("every winner is on it, whatever they play",
   contains(board_texts, "StormRider") and contains(board_texts, "Bello")
   and contains(board_texts, "Wanjiru"))
ok("all three flags were drawn", drew("UG") and drew("NG") and drew("KE"))
ok("the ugandan's prize is in UGX", contains(board_texts, "+5,000 UGX"))
ok("the nigerian's in NGN", contains(board_texts, "+2,000 NGN"))
ok("the kenyan's in KES", contains(board_texts, "+200 KES"))
ok("a row from an older payload still shows its figure", contains(board_texts, "+50"))
ok("and the list says what it is", contains(board_texts, "All Games"))

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
