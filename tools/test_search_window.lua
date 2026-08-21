-- THE SEARCH DIALOG RUNS THE SERVER'S WINDOW, NOT ITS OWN GUESS.
--
--   Run: lua tools/test_search_window.lua
--
-- Reported: the searching-for-opponents dialog still counts ten seconds, and
-- when it reaches zero it closes — so it is not aligned with the eight seconds
-- of shortlisting, and a championship's twelve-second window outlives it.
--
-- Both halves are bugs, and the second is the expensive one. The countdown
-- emptying used to BE the failure: the dialog announced "no opponent" the
-- instant the ring hit zero, which on a ladder was two seconds before the
-- server finished choosing between the players who had accepted. The player
-- was told nobody wanted to play them while a match was being made for them.
--
-- So: the server states the window (GAME_SEARCH_STARTED), the ring runs down
-- to the moment answers stop being accepted, and zero means CHOOSING.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond) check(label, cond and true or false, true) end

local SIM = dofile(here .. "/defold_sim.lua")
SIM.install_gui_stub()
_G.window.set_listener = function() end
_G.http = { request = function() end }

local ui = require("modules.ui")
local right = require("modules.online_right")
local dialog = require("modules.dialog_search")

----------------------------------------------------------------------
print("THE FALLBACK OUTLIVES THE LONGEST WINDOW")
----------------------------------------------------------------------
-- Twelve, not ten: a countdown that is too long merely waits, one that is too
-- short lies about the outcome.
check("the placeholder window is the ladder's twelve", right.SEARCH_WINDOW_FALLBACK, 12)
ok("and the local give-up sits beyond it, not on it", right.SEARCH_FAILSAFE_GRACE > 0)

----------------------------------------------------------------------
print("")
print("WHAT THE DIALOG DRAWS")
----------------------------------------------------------------------
-- Every string the card put on screen, so the state can be read back.
local drawn = {}
local real_text = ui.text
ui.text = function(pos, str, font, col)
    drawn[#drawn + 1] = tostring(str or "")
    return real_text(pos, str, font, col)
end

local C = setmetatable({}, { __index = function(_, k)
    return tostring(k):match("^COL_") and vmath.vector4(1, 1, 1, 1) or 20
end })

local function draw(sr)
    drawn = {}
    local self_ = { nodes = {}, buttons = {} }
    local ctx = {
        track = function(_, n) return n end,
        ui = ui, C = C, CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
    }
    local okd, err = pcall(dialog.draw, self_, ctx, sr, "reel")
    if not okd and os.getenv("DEBUG_DRAW") then print("DRAW ERROR: " .. tostring(err)) end
    return table.concat(drawn, "\n")
end

local function shows(txt, needle) return txt:find(needle, 1, true) ~= nil end

-- A championship: twelve seconds, the last two of them the accept grace.
local ladder = function(t) return { active = true, t = t, max_time = 12, grace_time = 2, invited = 6 } end

local early = draw(ladder(1))
ok("early on it is searching", shows(early, "SEARCHING FOR OPPONENT"))
ok("...and counts the window down, not ten seconds", shows(early, "9"))

local mid = draw(ladder(5))
ok("halfway it is still searching", shows(mid, "SEARCHING FOR OPPONENT"))
ok("...still counting", shows(mid, "5"))

----------------------------------------------------------------------
print("")
print("ZERO IS THE SHORTLIST CLOSING, NOT THE SEARCH FAILING")
----------------------------------------------------------------------
-- The ring empties when answers stop being accepted — at ten seconds of a
-- twelve-second window — and the two seconds after it are the server choosing.
local closing = draw(ladder(10.5))
ok("the ring has emptied", shows(closing, "0"))
ok("but the dialog says it is assessing", shows(closing, "ASSESSING THE BEST CANDIDATE"))
ok("...not that nobody came", not shows(closing, "NO OPPONENT FOUND"))
ok("with nobody in yet it says what it is doing rather than a count",
   shows(closing, "picking the best match"))

local one = draw({ active = true, t = 7, max_time = 8, grace_time = 2, invited = 1,
                   roster = { { userId = "u1", username = "Ada", avatar = 3 } } })
ok("one candidate is not pluralised", shows(one, "assessing 1 candidate"))
ok("a battle's window is eight, so seven seconds in it is already assessing",
   shows(one, "ASSESSING THE BEST CANDIDATE"))

----------------------------------------------------------------------
print("")
print("OPPONENTS ARRIVING, SHOWN AS THEY LAND")
----------------------------------------------------------------------
-- A search used to be a spinner and then a board. Everything in between —
-- somebody accepting, somebody else accepting — happened silently, so on a
-- twelve-second window the player was told nothing for twelve seconds.
--
-- An arrival is NOT a match, though: the opponent is chosen when the window
-- closes, and titling the first arrival "OPPONENT FOUND" would be the
-- first-to-tap rule again, drawn rather than enforced.
local function withRoster(t, list, chosen)
    return { active = true, t = t, max_time = 12, grace_time = 2, invited = 6,
             roster = list, chosen_id = chosen }
end

local ada = { userId = "u1", username = "Ada", avatar = 3 }
local bem = { userId = "u2", username = "Bem", avatar = 7 }

local one_in = draw(withRoster(4, { ada }))
ok("the title says somebody is here", shows(one_in, "OPPONENTS FOUND"))
ok("...and NOT that the opponent is settled", not shows(one_in, "OPPONENT FOUND!"))
ok("the count is shown", shows(one_in, "1 player joined, still searching"))
ok("the slot names the player who joined", shows(one_in, "ADA"))
ok("...instead of the unknown placeholder", not shows(one_in, "? ? ?"))
ok("and the shortlist is labelled", shows(one_in, "JOINED"))

local two_in = draw(withRoster(6, { ada, bem }))
ok("a second arrival is counted", shows(two_in, "2 players joined, still searching"))
ok("...and the slot follows the latest", shows(two_in, "BEM"))

local assessing = draw(withRoster(10.5, { ada, bem }))
ok("once the ring empties it is assessing", shows(assessing, "ASSESSING THE BEST CANDIDATE"))
ok("...over the candidates it has", shows(assessing, "assessing 2 candidates"))

local matched = draw(withRoster(11.5, { ada, bem }, "u1"))
ok("the winner is named at the end", shows(matched, "ADA"))
ok("...and the shortlist says so", shows(matched, "MATCHED"))

local nobody = draw(withRoster(3, {}))
ok("with nobody yet it still reads as searching", shows(nobody, "SEARCHING FOR OPPONENT"))
ok("...and the slot is honestly unknown", shows(nobody, "? ? ?"))

----------------------------------------------------------------------
print("")
print("THE OTHER STATES ARE UNCHANGED")
----------------------------------------------------------------------
local found = draw({ active = true, t = 4, max_time = 12, grace_time = 2, found = true, opp_name = "ADA" })
ok("a match still reads as found", shows(found, "OPPONENT FOUND!"))

local failed = draw({ active = true, t = 15, max_time = 12, grace_time = 2, failed = true,
                      fail_msg = "No opponents available right now" })
ok("a real failure still says so", shows(failed, "NO OPPONENT FOUND"))
ok("...with its reason", shows(failed, "No opponents available right now"))

----------------------------------------------------------------------
print("")
print("THE WIRING THAT CARRIES THE WINDOW")
----------------------------------------------------------------------
local function source(path)
    local f = assert(io.open(here .. "/../" .. path)); local s = f:read("*a"); f:close(); return s
end

local wsm = source("modules/websocket_manager.lua")
ok("the socket understands GAME_SEARCH_STARTED", wsm:find('GAME_SEARCH_STARTED', 1, true) ~= nil)
ok("...and emits it", wsm:find('emit("search_window"', 1, true) ~= nil)

local ctrl = source("main/controller.script")
ok("the controller forwards it to whichever dialog is open",
   ctrl:find('ws.on("search_window"', 1, true) ~= nil
   and ctrl:find('"#online", "ws_search_window"', 1, true) ~= nil
   and ctrl:find('"#tournaments", "ws_search_window"', 1, true) ~= nil)

local tour = source("main/tournaments.gui_script")
ok("the tournament dialog adopts it", tour:find('hash("ws_search_window")', 1, true) ~= nil)
ok("...and re-arms its give-up against the real window",
   tour:find("SEARCH_FAILSAFE_GRACE", 1, true) ~= nil)
ok("...and no longer opens on a hardcoded ten", tour:find("max_time = 10", 1, true) == nil)

local onl = source("main/online.gui_script")
ok("the invite dialog adopts it too", onl:find('hash("ws_search_window")', 1, true) ~= nil)

ok("the socket understands GAME_REQUEST_ROSTER", wsm:find('GAME_REQUEST_ROSTER', 1, true) ~= nil)
ok("...and emits it", wsm:find('emit("search_roster"', 1, true) ~= nil)
ok("the controller forwards the roster to the open dialog",
   ctrl:find('ws.on("search_roster"', 1, true) ~= nil)
ok("both dialogs take it", tour:find('hash("ws_search_roster")', 1, true) ~= nil
   and onl:find('hash("ws_search_roster")', 1, true) ~= nil)
ok("and neither closes on an arrival — only ws_match_found does that",
   tour:find('hash("ws_search_roster")', 1, true) ~= nil
   and not tour:match('ws_search_roster"%)[^\n]*\n[^\n]*stop_search'))

local rp = source("modules/online_right.lua")
ok("and its give-up is no longer a flat ten seconds",
   rp:find("timer.delay(10, false", 1, true) == nil)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
