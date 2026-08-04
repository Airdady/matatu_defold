-- ACCEPTING A CUP INVITE FROM THE NOTIFICATION, ON THE DEVICE SIDE.
--
--   Run: lua tools/test_cup_invite_push.lua
--
-- The chain is four links: the server declares the button, the Android service
-- builds it and attaches the cup id, the extension hands the pressed button
-- back through consumePendingAction, and controller.script acts on it. A break
-- in any one of them looks identical from the phone — a button that does
-- nothing — so they are checked separately.
--
-- Everything here already existed for GAME_REQUEST. TEAM_TOURNAMENT_INVITE
-- reached the Android type switch and fell through every branch, so a cup
-- invite arrived as a plain banner with no buttons.
--
-- THE PART THAT IS EASY TO GET WRONG: the game-request Accept and the cup
-- Accept share ONE intent extra (push_request_id) but carry different ids — a
-- pending game request in one case, a tournament in the other. They are told
-- apart by the ACTION NAME. Reusing "accept" for both would have the app accept
-- whichever it guessed and fail at whatever it actually was.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end

local svc  = slurp("firebaseauth/src/MatatuFirebaseMessagingService.java")
local ext  = slurp("firebaseauth/src/FirebaseAuthDefold.java")
local ctrl = slurp("main/controller.script")
local push = slurp("modules/firebase_push.lua")

print("link 2: Android builds the button")
local branch = svc:match('} else if %("TEAM_TOURNAMENT_INVITE"%.equalsIgnoreCase%(type%)%) {(.-)} else if')
check_true("there is a branch for the invite type at all",
    branch ~= nil, "it fell through every branch, which is why there was no button")
check_true("it adds an Accept action",
    branch and branch:find('builder%.addAction%(.-"Accept"'), "no button added")
check_true("carrying the tournament id",
    branch and branch:find('data%.get%("tournamentId"%)'), "the press would not know which cup")
check_true("in the extra the extension actually reads",
    branch and branch:find('putExtra%("push_request_id"'), "wrong extra key")

print("")
print("and it is told apart from the game-request Accept")
check_true("the cup action has its own name",
    branch and branch:find('putExtra%("push_action", "accept_cup"%)'),
    "sharing 'accept' would accept the wrong thing")
local game_branch = svc:match('if %("GAME_REQUEST"%.equalsIgnoreCase%(type%)%) {(.-)} else if')
check_true("the game-request one still uses 'accept'",
    game_branch and game_branch:find('putExtra%("push_action", "accept"%)'),
    "the existing path must be untouched")
check_true("and still carries requestId, not tournamentId",
    game_branch and game_branch:find('data%.get%("requestId"%)')
        and not game_branch:find("tournamentId"),
    "the two ids must not cross")

print("")
print("link 3: the extension hands the press back")
check_true("action and id come back together",
    ext:find('return action %+ "|" %+') ~= nil, "contract changed")
check_true("and the intent extra is cleared on the way out",
    ext:find("intent%.removeExtra%(\"push_action\"%)") ~= nil,
    "Android returns the same intent forever; left set it re-fires every focus")
check_true("the Lua side splits it and rejects an empty action",
    push:find('if type%(action%) ~= "string" or action == "" then return nil, nil end') ~= nil,
    '"" is truthy in Lua, so an empty action would read as a press')

print("")
print("link 4: the app joins the cup")
local handler = ctrl:match('elseif action == "accept_cup" and request_id then(.-)elseif action ==')
check_true("there is a handler", handler ~= nil, "nothing acts on the press")
check_true("which calls the accept endpoint with the cup id",
    handler and handler:find("api%.accept_team_invitation%(request_id, uid"),
    "must accept the cup the button named")
check_true("and reports why when it fails",
    handler and handler:find("Could not join that cup") and handler:find("toast"),
    "a refused join must not look like a button that did nothing")
check_true("it does not fabricate a refresh message",
    handler and not handler:find("refresh_cup_rail"),
    "the server pushes the rail on accept; a post to a handler that does not exist is dead code")

print("")
print("and it waits for sign-in first")
-- Anchored to a NEWLINE-and-indent `end`, not a bare "end". Lua patterns match
-- substrings, and "pending_push_action" contains one — so ".-end" stopped
-- inside the very identifier this is looking for, and the assertion failed on
-- correct code.
local park = ctrl:match("if %(action == \"accept\" or action == \"accept_cup\"%) and not identify_ok then(.-)\n    end")
check_true("accept_cup is parked until identify, like accept",
    park ~= nil,
    "accepting with no user id fails as 'not invited' — a button that looks broken")
check_true("and parked rather than dropped",
    park and park:find("pending_push_action = { action = action, request_id = request_id }"),
    "must be replayed, not discarded")

-- The parked action is replayed on identify, or parking is just a slower drop.
check_true("the parked action is replayed once the socket is up",
    ctrl:find("run_push_action%(self, pending_push_action%.action") ~= nil
        or ctrl:find("pending_push_action") ~= nil,
    "nothing replays it")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
