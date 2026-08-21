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
ok("but the dialog says it is CHOOSING", shows(closing, "CHOOSING YOUR OPPONENT"))
ok("...not that nobody came", not shows(closing, "NO OPPONENT FOUND"))
ok("and says how many it is choosing between", shows(closing, "shortlisting from 6 players"))

local one = draw({ active = true, t = 7, max_time = 8, grace_time = 2, invited = 1 })
ok("one acceptance is not pluralised", shows(one, "shortlisting from 1 player"))
ok("a battle's window is eight, so seven seconds in it is already choosing",
   shows(one, "CHOOSING YOUR OPPONENT"))

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

local rp = source("modules/online_right.lua")
ok("and its give-up is no longer a flat ten seconds",
   rp:find("timer.delay(10, false", 1, true) == nil)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
