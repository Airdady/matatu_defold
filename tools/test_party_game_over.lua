-- THE BOARD NEVER HEARD THE PARTY END.
--
--   Run: lua5.4 tools/test_party_game_over.lua
--
-- Reported, with the server log to match:
--
--   [PARTY-END 6a9912d90b5f676b719a9a31] LAST_STANDING:
--     6a7eee77de67d479c7e7680f takes 400
--     (6a7eee77de67d479c7e7680f#1 6a7ead2c4ab07037b0142e51#2)
--
-- The table was settled and the pot was paid. The board sat there. The game
-- was over everywhere except on screen.
--
-- PARTY_GAME_OVER emitted `party_game_over`, and nothing anywhere subscribed to
-- it. The board reacts to exactly one event, `game_over`: online_handler parks
-- it as ws.last_game_over, game.script queues it, and process_game_over_queue
-- calls end_game with `results.winner == my_player_id`.
--
-- That is not a defect a diff shows. The code reads correctly, the emit
-- succeeds, and the message goes nowhere — so the frame has to be DRIVEN
-- through the real parse_message and the real pub/sub, which is what this
-- does. websocket_manager.handle_frame is the seam; nothing else uses it.
package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

-- Defold globals the module touches at load time.
_G.sys = { get_sys_info = function() return { system_name = "Linux" } end,
           get_config = function() return nil end,
           get_config_string = function() return nil end }
_G.socket = { gettime = function() return os.time() end }
_G.timer = { delay = function() return 0 end, cancel = function() end }
_G.msg = { post = function() end, url = function() return {} end }
_G.hash = function(s) return s end
_G.websocket = { EVENT_MESSAGE = 1, EVENT_CONNECTED = 2, EVENT_DISCONNECTED = 3, EVENT_ERROR = 4 }
_G.http = { request = function() end }
_G.json = nil

local WS = require("modules.websocket_manager")

local function eq(a, b, m)
  if a ~= b then error(m .. " — expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function ok(v, m) if not v then error(m, 2) end end

-- One PARTY_GAME_OVER exactly as the server sends it: the shape from
-- endPartyGame.ts, with the ids and the pot from the reported log.
local WINNER = "6a7eee77de67d479c7e7680f"
local LOSER  = "6a7ead2c4ab07037b0142e51"

local FRAME = [[{"type":"PARTY_GAME_OVER","data":{
  "gameId":"6a9912d90b5f676b719a9a31","reason":"LAST_STANDING","pot":400,
  "winner":"]] .. WINNER .. [[","entry":200,"mode":"LAST_STANDING",
  "placements":[
    {"playerId":"]] .. WINNER .. [[","place":1,"won":true,"username":"Ann"},
    {"playerId":"]] .. LOSER  .. [[","place":2,"won":false,"username":"Ben"}]}}]]

--- Deliver the frame as `me`, and collect what came back out.
local function deliver(me)
  local heard = {}
  local tokens = {}
  for _, ev in ipairs({ "game_over", "party_game_over", "user_updated" }) do
    tokens[#tokens + 1] = WS.on(ev, function(a) heard[ev] = a or true end)
  end
  WS.current_user_id = me
  WS.current_user_data = { recentForm = { "W", "L" } }
  WS.last_game_over = nil
  WS.handle_frame(FRAME)
  for _, t in ipairs(tokens) do WS.off(t) end
  return heard
end

-- ── THE FAILURE ────────────────────────────────────────────────────────────
local won = deliver(WINNER)

ok(won.game_over, "the winner's board is told the game is over at all — " ..
   "this is the assertion the whole bug was: party_game_over fired and " ..
   "`game_over`, the only event the board listens to, never did")

-- ── AND IT SAYS THE RIGHT THING ────────────────────────────────────────────
-- process_game_over_queue does `end_game(results.winner == my_player_id)`, so
-- `winner` is the single field that decides whether this reads as a win.
eq(won.game_over.winner, WINNER, "the winner is carried through verbatim")
eq(won.game_over.gameType, "PARTY", "marked as a party, not a duel")
eq(won.game_over.reason, "LAST_STANDING", "the server's reason survives")
eq(won.game_over.isPartyOver, true, "flagged as a party ending")
eq(won.game_over.pot, 400, "the pot rides along for the panel to draw")

-- ── THE LOSERS' BOARDS END TOO ─────────────────────────────────────────────
-- The half of this that is easy to get wrong: end_game takes a BOOLEAN, so a
-- losing seat must still receive the event and simply resolve it to false. A
-- fix that only ended the winner's board would leave three players stuck.
local lost = deliver(LOSER)
ok(lost.game_over, "a losing seat is told as well")
eq(lost.game_over.winner, WINNER, "and is told who won, so it resolves to a loss")
ok(lost.game_over.winner ~= LOSER, "which is not them")

-- ── THE PARKED COPY ────────────────────────────────────────────────────────
-- online_handler reads ws.last_game_over when the board comes up mid-teardown;
-- an emit without the parked copy loses the result on that path.
ok(WS.last_game_over ~= nil, "the result is parked for online_handler")
eq(WS.last_game_over.winner, WINNER, "and it is the same result")

-- ── BALANCES ───────────────────────────────────────────────────────────────
-- Everybody paid their entry when they took a seat, not at the end. So the
-- winner gains the pot and everyone else moves by ZERO at this moment —
-- reporting "minus the entry" here would double-count a charge already taken.
eq(won.game_over.rewards[WINNER], 400, "the winner is shown the pot")
eq(won.game_over.rewards[LOSER], 0, "a loser moves by zero, not by minus the entry")

-- ── FORM ───────────────────────────────────────────────────────────────────
-- The lobby form panel reads current_user_data and would sit stale until the
-- next identify.
-- Re-delivered rather than read off `won`: deliver() resets current_user_data
-- each time, and the loser's delivery above was the most recent write to it.
local w2 = deliver(WINNER)
ok(w2.user_updated, "the winner's own form is refreshed")
eq(WS.current_user_data.recentForm[1], "W", "and records the win at the front")

local l2 = deliver(LOSER)
ok(l2.user_updated, "the loser's form is refreshed too")
eq(WS.current_user_data.recentForm[1], "L", "and records the loss")

-- ── THE ORIGINAL EVENT STILL FIRES ─────────────────────────────────────────
-- Translated, not replaced: anything that wants the placements can still have
-- them without going through the duel-shaped result.
ok(won.party_game_over, "party_game_over is still emitted for party surfaces")
eq(#won.party_game_over.placements, 2, "carrying the whole finishing order")

print("party_game_over: all assertions passed")
