-- EXIT USED TO BE A NAVIGATION AND NOTHING ELSE.
--
--   Run: lua5.4 tools/test_exit_game.lua
--
-- Pressing EXIT posted exit_to_lobby, the client went back to the online
-- screen, and the server was never told. The game stayed live with a player
-- who was no longer looking at it: the opponent watched a clock run down on
-- somebody who had gone — every turn, until the turn timer eventually
-- forfeited it for them — and at a party the empty seat held the table up on
-- every rotation.
--
-- Read out of the source, because these are one-line decisions inside a
-- .script and a .gui_script, neither of which can be required.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end

local function read(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close(); return s
end
-- Comments name the very things these look for, so they are stripped first.
local function code(s) return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")) end

local GAME    = code(read("main/game.script"))
local WS      = code(read("modules/websocket_manager.lua"))
local OVERLAY = code(read("modules/overlay_ui.lua"))
local OVER    = read("main/gameover.gui_script")
local HANDLER = code(read("modules/online_handler.lua"))

-- ── THE SEND ────────────────────────────────────────────────────────────────
check("exiting a live online game tells the server",
  GAME:match('hash%("exit_to_lobby"%).-pcall%(ws%.leave_game, self%.online_game_id%)') ~= nil,
  "the server is the only side that can end it for the opponent too")
check("...before it navigates",
  GAME:match('ws%.leave_game.-goto_online') ~= nil)
check("...and a socket that refuses the send does not trap the player",
  GAME:find("pcall%(ws%.leave_game") ~= nil,
  "leaving must not depend on the send succeeding")
check("...and NOT once the game is already over",
  GAME:find("self%.online_mode and not self%.game_over") ~= nil,
  "there is nothing to leave: the server has settled it and released both players")
check("an offline game sends nothing",
  GAME:match('hash%("exit_to_lobby"%).-if self%.online_mode and not self%.game_over then') ~= nil)

check("the socket has a way to say it", WS:find("function M%.leave_game") ~= nil)
check("...carrying the game id, so a LATE tap cannot end the wrong game",
  WS:find('M%.send_message%("LEAVE_GAME", %{ gameId = id %}%)') ~= nil)
check("...and refusing to send with no game at all",
  WS:match("function M%.leave_game.-if id == \"\" then return false end") ~= nil)

-- ── THE ANSWER ──────────────────────────────────────────────────────────────
check("the ack is handled", WS:find('elseif t == "LEFT_GAME" then') ~= nil)
check("...and clears the game the client thought it was in",
  WS:match('t == "LEFT_GAME".-M%.active_game_id = ""') ~= nil,
  "left behind, it makes the next screen think a game is still running")

-- ── WHAT THE OTHER PLAYERS ARE TOLD ─────────────────────────────────────────
-- A duel ends, so the opponent gets the ordinary game-over — with a reason
-- that says what actually happened.
check("a walkout is not dressed up as a disconnection",
  OVER:find('reason == "PLAYER_LEFT"') ~= nil,
  '"Opponent disconnected" reads as a fault; this was a choice')
check("...and the loser is told the truth about their own defeat too",
  OVER:find('is_win and "Opponent left the game%." or "You left the game%."') ~= nil)

-- A party carries on, so the survivors get a line rather than an ending.
check("a party names the seat that just emptied",
  HANDLER:match('ws%.on%("party_player_out".-toast%.info') ~= nil)
check("...and says which of the two things happened to it",
  HANDLER:find('why == "TIMEOUT" and " ran out of time" or " left the table"') ~= nil,
  "somebody quitting on you and somebody's phone dying are not the same event")
check("...but never about ourselves, who know",
  HANDLER:find("pid ~= tostring%(self%.my_player_id or \"\"%)") ~= nil)

-- ── AND THE PLAYER IS TOLD WHAT IT COSTS, BEFORE THEY CHOOSE ────────────────
check("the exit popover says what leaving does",
  OVERLAY:find("function M%.word_exit_warning") ~= nil)
check("...worded for the ending they are actually choosing",
  OVERLAY:find("You leave the table; the others play on%.") ~= nil
    and OVERLAY:find("Your opponent wins the game%.") ~= nil)
check("...and says nothing offline, where nothing is at stake",
  OVERLAY:match('function M%.word_exit_warning.-local text = ""') ~= nil)
check("...set when the popover opens, not once at init",
  OVERLAY:match("hit%(self%.exit_btn, action%).-M%.word_exit_warning%(self%)") ~= nil)

print(("exit game: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
