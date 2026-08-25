-- A MOVE PLAYED INTO A DEAD SOCKET MUST NOT SIMPLY VANISH.
--
--   Run: lua tools/test_pending_move_resend.lua
--
-- THE REPORTED BUG, exactly: "I played K of spades, then the network
-- glitched, and the K I had placed came back from the pile to my hand."
--
-- What actually happened is not a rendering fault and not a bad reconcile —
-- sync_my_hand was right to put the card back. The server genuinely still
-- had it in hand, because the move never arrived:
--
--   * play_card removes the card from player_hand immediately (optimistic)
--   * send_move -> send_message, which returns FALSE without sending a byte
--     when the socket is down...
--   * ...and send_move dropped that return value on the floor.
--
-- So the client believed the move was made, the server never heard of it,
-- and the next authoritative state legitimately contradicted the board the
-- player was looking at. Every server->client message has an ack behind it
-- (_ackId/_replayId/MISSED_MOVE_ACK, with missedMoves requeueing anything
-- unacked); this is the same guarantee for the other direction.

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("  FAIL %s (got %s, want %s)", label, tostring(got), tostring(want)))
    end
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

local ws = require("modules.websocket_manager")

local ME, THEM, GID = "me-1", "them-2", "g-1"
local K_SPADES = { type = "PLAY", v = 13, s = "S" }

-- How many MOVE messages have actually gone out on the wire.
local function moves_out()
    local n = 0
    for _, m in ipairs(SIM.outbound) do if m.type == "MOVE" then n = n + 1 end end
    return n
end

-- The authoritative state the server would send on reconnect.
--   my_hand : what the SERVER thinks we are holding
--   turn    : whose turn the SERVER thinks it is
local function state(my_hand, turn)
    return {
        gameId = GID, currentTurn = turn,
        players = {
            [ME]   = { _id = ME, hand = my_hand },
            [THEM] = { _id = THEM, handCount = 5 },
        },
        deckCount = 20, playedCards = { { v = 3, s = "H" } },
    }
end

ws.connect()
SIM.pump(0.5)
ws.current_user_id = ME

----------------------------------------------------------------------
print("A MOVE SENT ON A HEALTHY SOCKET")
----------------------------------------------------------------------
SIM.outbound = {}
local ok = ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
check("reports that it went out", ok, true)
check("and it did", moves_out(), 1)
check("but it is still held until the server confirms it", ws.pending_move ~= nil, true)

-- The server's echo of our own move is the confirmation.
SIM.server_send({ type = "MOVE", data = {
    from = ME, gameState = state({ { v = 5, s = "D" } }, THEM),
} })
SIM.pump(0.2)
check("the server's echo retires it", ws.pending_move, nil)

----------------------------------------------------------------------
print("")
print("A MOVE PLAYED INTO A DEAD SOCKET — THE REPORTED BUG")
----------------------------------------------------------------------
SIM.outbound = {}
ws.socket_connected = false          -- the glitch
local ok2 = ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)

check("the send reports failure rather than pretending", ok2, false)
check("nothing went out on the wire", moves_out(), 0)
check("but the move is HELD, not lost", ws.pending_move ~= nil, true)
check("and it remembers the card that was played", ws.pending_move.plays[1].v, 13)

-- Reconnect. The server's state still has K of spades in our hand and still
-- says it is our turn — proof it never saw the move.
ws.socket_connected = true
SIM.outbound = {}
SIM.server_send({ type = "IDENTIFY", data = {
    _id = ME, username = "Ada",
    gameState = state({ { v = 13, s = "S" }, { v = 5, s = "D" } }, ME),
} })
SIM.pump(0.2)

check("the move is resent on reconnect", moves_out(), 1)
check("and it is still held, pending the server's echo", ws.pending_move ~= nil, true)

-- Now the server applies it and echoes back. K is gone from our hand.
SIM.server_send({ type = "MOVE", data = {
    from = ME, gameState = state({ { v = 5, s = "D" } }, THEM),
} })
SIM.pump(0.2)
check("the echo retires it for good", ws.pending_move, nil)

----------------------------------------------------------------------
print("")
print("A MOVE THAT DID LAND IS NEVER SENT TWICE")
----------------------------------------------------------------------
-- The dangerous case: the move reached the server, but the ECHO was lost on
-- the way back. On reconnect the state proves it landed — the card is gone
-- from our hand and the turn has moved on — so it must not be replayed.
SIM.outbound = {}
ws.socket_connected = false
ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
ws.socket_connected = true
check("held before reconnect", ws.pending_move ~= nil, true)

SIM.outbound = {}
SIM.server_send({ type = "IDENTIFY", data = {
    _id = ME, username = "Ada",
    gameState = state({ { v = 5, s = "D" } }, THEM),  -- K gone, their turn
} })
SIM.pump(0.2)

check("no resend — the server already has it", moves_out(), 0)
check("and the held copy is dropped", ws.pending_move, nil)

----------------------------------------------------------------------
print("")
print("STILL OUR TURN, BUT THE CARD IS GONE — ALSO NOT RESENT")
----------------------------------------------------------------------
-- A Whot hold-on or a penalty stack can leave the turn with us after the
-- move landed. The card being gone from the server's copy of our hand is
-- what settles it, not the turn alone.
SIM.outbound = {}
ws.socket_connected = false
ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
ws.socket_connected = true
SIM.outbound = {}
SIM.server_send({ type = "IDENTIFY", data = {
    _id = ME, username = "Ada",
    gameState = state({ { v = 5, s = "D" } }, ME),  -- K gone, still our turn
} })
SIM.pump(0.2)
check("not resent", moves_out(), 0)
check("and dropped", ws.pending_move, nil)

----------------------------------------------------------------------
print("")
print("A MOVE THE SERVER REFUSED IS NOT RETRIED FOREVER")
----------------------------------------------------------------------
SIM.outbound = {}
ws.socket_connected = true
ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
check("held", ws.pending_move ~= nil, true)

SIM.server_send({ type = "RESYNC", data = {
    reason = "Invalid move", gameState = state({ { v = 13, s = "S" } }, ME),
} })
SIM.pump(0.2)
check("a RESYNC is an answer, so the move is dropped", ws.pending_move, nil)

-- NOT_YOUR_TURN is the other refusal, and was not handled at all before.
ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
SIM.server_send({ type = "NOT_YOUR_TURN", data = { gameId = GID, currentTurn = THEM } })
SIM.pump(0.2)
check("NOT_YOUR_TURN drops it too", ws.pending_move, nil)

----------------------------------------------------------------------
print("")
print("THE ROUND ENDING CLEARS WHATEVER WAS IN FLIGHT")
----------------------------------------------------------------------
ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
SIM.server_send({ type = "ROUND_COMPLETE", data = { gameState = state({}, THEM) } })
SIM.pump(0.2)
check("round complete clears it", ws.pending_move, nil)

ws.send_move(GID, ME, THEM, { K_SPADES }, "", 0)
SIM.server_send({ type = "GAME_OVER", data = { gameOverState = { winner = THEM } } })
SIM.pump(0.2)
check("game over clears it", ws.pending_move, nil)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
