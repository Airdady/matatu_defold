-- THE BANNER THAT COULD NEVER SHOW THE THING IT WAS BUILT FOR.
--
--   Run: lua tools/test_announcements.lua
--
-- Reported from a handset, once per delivery and never once succeeding:
--
--   [WS] listener error on 'announcements': main/announcement.gui_script:230:
--   buffer (890 bytes) too small for table, exceeded at
--   '🏆 CONGRATULATIONS TO THIS WEEKS TOP 20 CHAMPIONS!  •  **1.** {{a:1}}
--   **StormRider** ~8,000/-  •  **2.** ...'
--
-- msg.post serialises its table into a fixed-size buffer and raises rather
-- than truncating. The listener was posting the whole announcement list
-- through it, and the weekly top-20 winners banner is a single string of well
-- over a kilobyte — twenty names, twenty avatar tags, twenty prize figures.
-- The post raised, the listener died with it, and the banner was never queued.
--
-- So the ONE announcement this feature exists for is the one it could never
-- show, and it failed harder the more players there were to congratulate. A
-- two-word "server maintenance at 9pm" fits the buffer and always worked,
-- which is why nothing looked wrong.
--
-- The list is parked on the socket module now and read back, the same way
-- MOVE payloads already travel — see websocket_manager's announcement_inbox.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

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

-- The engine's message buffer, which the plain stub does not model. Every
-- msg.post is measured; anything a real handset would refuse to serialise is
-- recorded here instead of silently sailing through.
--
-- 890 is the figure the handset reported, verbatim: Defold's message says
-- "buffer (N bytes) too small for table", where N is the buffer itself.
local MSG_BUFFER = 890
local oversized = {}

local function table_bytes(t, depth)
    local bytes = 0
    for k, v in pairs(t) do
        bytes = bytes + #tostring(k)
        if type(v) == "table" then
            bytes = bytes + table_bytes(v, (depth or 1) + 1)
        else
            bytes = bytes + #tostring(v)
        end
    end
    return bytes
end

local real_post = _G.msg.post
_G.msg.post = function(url, message_id, message)
    if type(message) == "table" then
        local bytes = table_bytes(message, 1)
        if bytes > MSG_BUFFER then
            oversized[#oversized + 1] = { id = tostring(message_id), bytes = bytes }
            -- The engine RAISES here. Modelled, because the reported symptom
            -- is the listener dying, not a message quietly going missing.
            -- Worded exactly as the engine words it, buffer size and all, so
            -- a future reader grepping the device log lands here.
            error(string.format("buffer (%d bytes) too small for table, needed %d",
                MSG_BUFFER, bytes))
        end
    end
    return real_post(url, message_id, message)
end

local ws = require("modules.websocket_manager")

-- Parked on the game screen for the whole run. show_next() deliberately holds
-- announcements back over live gameplay, so the queue keeps what arrives
-- instead of being drained into a marquee — which is what we want to inspect,
-- and it keeps the test off the rendering path entirely. What is under test is
-- whether the payload SURVIVES the trip, not how it is drawn.
require("modules.app_state").current_screen = "game"

SIM.add_recorder("controller")
SIM.load_script_component("announcement", ROOT .. "main/announcement.gui_script")
SIM.init_component("announcement")
SIM.pump(0.2)

-- The real payload, rebuilt from the device log.
local WEEKLY = "🏆 CONGRATULATIONS TO THIS WEEKS TOP 20 CHAMPIONS!"
local NAMES = { "StormRider","LuckyAce","MatatuKing","QueenB","NightOwl","FastHands",
                "GoldRush","SkyWalker","CardShark","IronWill","BlazeFire","SilentAce",
                "RoyalFlush","ThunderBolt","MysticQueen","TrickyJoker","VelvetTouch",
                "GhostRider","SwiftBlade","CrownJewel" }
for i, n in ipairs(NAMES) do
    WEEKLY = WEEKLY .. string.format("   •   **%d.** {{a:%d}} **%s** ~%s/-",
        i, i, n, tostring(8000 - (i - 1) * 350))
end

-- A real frame down a real socket, so parse_message's own
-- PUBLIC_ANNOUNCEMENTS branch is what runs — not a re-implementation of it.
ws.connect()
SIM.pump(0.5)

local function deliver(list)
    SIM.server_send({ type = "PUBLIC_ANNOUNCEMENTS", data = list })
    SIM.pump(0.5)
end

print("THE PAYLOAD IS GENUINELY TOO BIG TO TRAVEL IN A MESSAGE")
check("the weekly banner is over the buffer on its own", #WEEKLY > MSG_BUFFER, true)
check("and so is the message the listener used to post",
    table_bytes({ list = { { id = "a1", text = WEEKLY } } }, 1) > MSG_BUFFER, true)

print("")
print("IT REACHES THE BANNER ANYWAY")
local item = { id = "a1", text = WEEKLY, duration = 0, rounds = 3, isDismissable = true }
deliver({ item })

check("nothing overflowed a message", #oversized, 0)
local shown = (SIM.components.announcement.self.queue or {})[1]
check("the banner received the announcement", shown ~= nil, true)
check("with its text intact", shown and shown.text == WEEKLY, true)
check("all of it, not a truncation", shown and #shown.text, #WEEKLY)
check("and its rounds", shown and shown.rounds, 3)

print("")
print("A BURST IS NOT LOST BETWEEN THE EVENT AND THE MESSAGE")
-- A live broadcast can land while IDENTIFY is replaying missed ones. A single
-- parked slot would drop whichever lost that race; a queue keeps both.
SIM.components.announcement.self.queue = {}
deliver({ { id = "b1", text = WEEKLY, rounds = 1 },
          { id = "b2", text = WEEKLY, rounds = 1 },
          { id = "b3", text = WEEKLY, rounds = 1 } })
local a = SIM.components.announcement.self
check("all three arrived", #(a.queue or {}), 3)
check("and nothing overflowed", #oversized, 0)

print("")
print("THE PARK IS EMPTIED, SO NOTHING SHOWS TWICE")
check("nothing left parked", #ws.announcement_inbox, 0)
a.queue = {}
SIM.with_ctx("announcement", function()
    msg.post(msg.url("#announcement"), "announcements_push")
end)
SIM.pump(0.5)
check("a second signal replays nothing", #(a.queue or {}), 0)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
