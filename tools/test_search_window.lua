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
-- CREATION IS NO LONGER WHERE THE WORDS COME FROM.
--
-- The dialog builds its layout once and then sets strings on the nodes that
-- already exist, every frame, instead of asking the host to rebuild the whole
-- screen twice a second so a countdown digit can change. So a harness that
-- only watches ui.text sees empty placeholders and none of the actual copy;
-- gui.set_text is now half of what the dialog says.
local drawn = {}
local real_text = ui.text
ui.text = function(pos, str, font, col)
    drawn[#drawn + 1] = tostring(str or "")
    return real_text(pos, str, font, col)
end
local real_set_text = gui.set_text
gui.set_text = function(node, str)
    drawn[#drawn + 1] = tostring(str or "")
    return real_set_text(node, str)
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
ok("...and counts the WHOLE window down, assessment included", shows(early, "11"))

local mid = draw(ladder(5))
ok("halfway it is still searching", shows(mid, "SEARCHING FOR OPPONENT"))
ok("...still counting", shows(mid, "7"))

----------------------------------------------------------------------
print("")
print("THE CLOCK KEEPS RUNNING WHILE THE BEST CANDIDATE IS PICKED")
----------------------------------------------------------------------
-- The last two seconds of a twelve-second window are the server's grace for
-- answers already in flight. The ring USED to stop dead at ten and sit on
-- zero through them — and a clock that has stopped reads as a clock that has
-- failed, at exactly the moment the match is being decided.
--
-- It counts through them now. Assessing is a PHASE of the countdown, not a
-- state after it: the label changes, the number keeps moving, and zero lands
-- where the server actually settles.
local closing = draw(ladder(10.5))
-- 12 - 10.5 = 1.5, and the ring rounds UP so a part-second still reads as
-- time on the clock rather than as none.
ok("the clock is still running, not stuck on zero", shows(closing, "2"))
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
-- "HELD FOR YOU", not "JOINED". The rail is not a list of who turned up, it
-- is the answer to "why has the search not stopped?" — these people are being
-- kept while a better match is still allowed to answer.
ok("and the shortlist says what it is for", shows(one_in, "HELD FOR YOU"))

local two_in = draw(withRoster(6, { ada, bem }))
ok("a second arrival is counted", shows(two_in, "2 players joined, still searching"))
ok("...and the slot follows the latest", shows(two_in, "BEM"))

local assessing = draw(withRoster(10.5, { ada, bem }))
ok("once the ring empties it is assessing", shows(assessing, "ASSESSING THE BEST CANDIDATE"))
ok("...over the candidates it has", shows(assessing, "assessing 2 candidates"))

local matched = draw(withRoster(11.5, { ada, bem }, "u1"))
ok("the winner is named at the end", shows(matched, "ADA"))
ok("...and the shortlist says so", shows(matched, "MATCHED"))

----------------------------------------------------------------------
print("")
print("TIME PASSING IS NOT A REASON TO REBUILD A SCREEN")
----------------------------------------------------------------------
-- WHERE THE FRAME RATE WENT.
--
-- The hosts asked for a full screen rebuild twice a second for as long as this
-- dialog was open — the whole online player list, both panels, the dividers,
-- the banner; or the entire tournament map — so that a countdown digit could
-- change and three dots could cycle. Hundreds of gui nodes a second, to
-- animate a string.
--
-- structure_key is what the hosts test instead. It answers "is the LAYOUT
-- wrong?", not "has anything changed?", and almost nothing makes it wrong.
local SC = require("modules.search_clock")
local key = dialog.structure_key

local base = { active = true, t = 0, max_time = 12, grace_time = 2, invited = 6, roster = {} }
local k0 = key(base)
for _ = 1, 60 * 8 do SC.tick(base, 1 / 60) end
check("eight seconds of countdown need no rebuild", key(base), k0)

base.roster = { ada }
ok("...but somebody arriving does", key(base) ~= k0)
local k1 = key(base)
for _ = 1, 60 do SC.tick(base, 1 / 60) end
check("and their whole entrance needs none", key(base), k1)

base.roster = { ada, bem }
ok("a second arrival does", key(base) ~= k1)
local k2 = key(base)
base.chosen_id = "u1"
ok("naming the winner does", key(base) ~= k2)
local k3 = key(base)
base.found = true
ok("and so does the match starting", key(base) ~= k3)
ok("a failure does too", key({ failed = true }) ~= key({}))
check("rubbish does not throw", key(nil), "none")

----------------------------------------------------------------------
print("")
print("THE ENTRANCE MOVES WITHOUT A REDRAW")
----------------------------------------------------------------------
-- The other half of the same problem: a rebuild every 500ms means a 450ms
-- flight across the dialog gets exactly ONE frame, so an entrance meant to
-- travel simply teleports. The dialog is built once and animate() moves the
-- nodes that already exist.
do
    local host = { nodes = {}, buttons = {} }
    local ctx = {
        track = function(_, n) return n end, ui = ui, C = C,
        commas = function(x) return tostring(x) end,
        CX = 640, CY = 360, LOGICAL_W = 1280, LOGICAL_H = 720,
    }
    local sr = { active = true, max_time = 12, grace_time = 2, invited = 6, roster = {} }
    SC.tick(sr, 0)
    SC.note_arrivals(sr, { ada, bem })

    -- Build once, then never again.
    local built = pcall(dialog.draw, host, ctx, sr, "reel")
    ok("the dialog builds", built)
    local card = host.search_anim and host.search_anim.cards[2]
    ok("with a node per candidate", card ~= nil)

    local function pos_of(n) return gui.get_position(n).x, gui.get_position(n).y end

    -- HOLD: the newest arrival is standing in the opponent slot.
    dialog.animate(host, sr)
    local hx, hy = pos_of(card.av)
    check("the newest arrival holds the slot", math.floor(hx), math.floor(host.search_anim.bx))

    ok("...so the reel is not left churning behind them", host.reel == nil)

    -- FLY: they travel out towards their seat, and keep travelling. The hold
    -- comes first, so wind past it before sampling.
    for _ = 1, math.ceil(SC.ARRIVE_HOLD * 60) do SC.tick(sr, 1 / 60) end
    local seen = {}
    for _ = 1, math.floor(SC.ARRIVE_FLY * 60) do
        SC.tick(sr, 1 / 60)
        dialog.animate(host, sr)
        local x = select(1, pos_of(card.av))
        seen[#seen + 1] = x
    end
    local moved, monotone = false, true
    for i = 2, #seen do
        if seen[i] ~= seen[i - 1] then moved = true end
        if seen[i] > seen[i - 1] + 0.001 then monotone = false end
    end
    ok("they travel, frame by frame, with no rebuild", moved)
    ok("...and only ever towards the rail", monotone)
    ok("...more than a single teleporting step", #seen > 10)
    ok("...and actually crossed most of the way", math.abs(seen[#seen] - seen[1]) > 50)

    -- REST: seated, and the slot is free to hunt again.
    for _ = 1, 120 do SC.tick(sr, 1 / 60) end
    dialog.animate(host, sr)
    local rx = select(1, pos_of(card.av))
    check("and land on their seat", math.floor(rx + 0.5), math.floor(card.seat + 0.5))
    ok("leaving the slot free to hunt again", host.reel ~= nil)

    -- RETURN: the winner comes back out of the rail into the slot.
    sr.chosen_id = "u2"
    dialog.animate(host, sr)
    local sx = select(1, pos_of(card.av))
    check("the winner starts from where they were kept", math.floor(sx + 0.5), math.floor(card.seat + 0.5))
    for _ = 1, 60 do SC.tick(sr, 1 / 60); dialog.animate(host, sr) end
    local ex = select(1, pos_of(card.av))
    check("and comes home to the slot", math.floor(ex), math.floor(host.search_anim.bx))
end

----------------------------------------------------------------------
print("")
print("EVERY CANDIDATE IS NAMED AND RANKED, NOT JUST COUNTED")
----------------------------------------------------------------------
-- The rail is the answer to "why has the search not stopped?", so it has to
-- say enough for the player to judge the wait: who is being held, and how good
-- they are. A row of anonymous 34px avatars said neither.
local tiered = draw(withRoster(6, {
    { userId = "u1", username = "Ada", avatar = 3, skillTier = "AMATEUR" },
    { userId = "u2", username = "Bem", avatar = 7, skillTier = "GRANDMASTER" },
}))
ok("everybody held is named", shows(tiered, "ADA") and shows(tiered, "BEM"))
ok("...with their tier beside them", shows(tiered, "GRANDMASTER"))
-- The server's word for the bottom tier is AMATEUR; the client's own bands
-- call it BEGINNER. The badge has to survive that, and the label shown is the
-- server's word rather than a silent re-spelling of what it sent.
ok("...including the tier the two ends spell differently", shows(tiered, "AMATEUR"))

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
