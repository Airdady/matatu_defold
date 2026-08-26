-- Tiny shared singleton passing data between the lobby and game screens.

local M = {}

-- "offline" (Quick Play vs AI) or "online" (multiplayer over websocket)
M.mode = "offline"

-- True only while a game board is actively in play (set on game screen_enter,
-- cleared on the final game-over modal or when leaving the game screen). Read
-- by controller.script to tell a round continuation from a fresh match.
--
-- It used to also pick the incoming-request surface — a small corner panel
-- mid-game, the full dialog otherwise. That third surface is gone: a plain
-- game request is now always the full dialog, and a tournament/battle/knockout
-- invite is always the top banner, wherever the player is.
M.game_active = false

-- Name of the screen currently shown (set by the controller's show()).
M.current_screen = nil

-- The active offline game_logic object (set by the lobby on Quick Play).
M.offline_game = nil

-- Stake chosen in the lobby for the next match.
M.selected_stake = { amount = 0, charge = 0, points = 0 }

-- Active theme name (matches THEMES table keys).
M.theme = "default"

-- Auth state for the Firebase authentication flow.
-- "idle" | "sending" | "verifying" | "done" | "error"
M.auth_state = "idle"
M.auth_error = ""

-- Available-username alternatives returned alongside a USERNAME_TAKEN save
-- failure (e.g. "scovia" -> "scovia7"/"scovia23"/"scovia1993"). Parked here
-- rather than riding through msg.post's "profile_saved" payload — this
-- codebase's established convention for data too structured to reliably pass
-- through a message table (see websocket_manager.lua's last_head_to_head/
-- last_season_complete for the same pattern).
M.username_suggestions = {}

-- True while the global Half-Week Season Complete modal (main/season_results.gui_script)
-- is open. Other global modals (e.g. the daily bonus dialog) check this before
-- auto-opening themselves so they never fight the season modal for screen space.
M.season_modal_active = false

-- Themes table – each entry defines the visual style applied across lobby + game.
-- bg_image  : animation name in the ui atlas
-- card_set  : which card sprite sheet the deck uses ("default"|"drago"|"batman")
--             — mirrors the Godot THEME_TEXTURE_PATHS model where drago and
--             batman themes restyle EVERY card face (A→K, jokers, back)
-- card_back : back animation id inside that card set's atlas
--             (mirrors Godot's THEME_BACK_CARD_MAP)
-- accent    : vmath.vector4 accent colour for buttons / highlights
-- panel     : vmath.vector4 primary panel colour
M.THEMES = {
  default    = { id = "default",     label = "Classic Red",  bg_image = "bg_1", card_set = "default", card_back = "card_back",       accent = vmath.vector4(0.85, 0.25, 0.25, 1), panel = vmath.vector4(0.12, 0.14, 0.20, 1) },
  blue_basic = { id = "blue_basic",  label = "Classic Blue", bg_image = "bg_2", card_set = "default", card_back = "card_back_blue",  accent = vmath.vector4(0.25, 0.55, 0.90, 1), panel = vmath.vector4(0.08, 0.12, 0.22, 1) },
  black_basic= { id = "black_basic", label = "Classic Black",bg_image = "bg_3", card_set = "default", card_back = "card_back_black", accent = vmath.vector4(0.50, 0.50, 0.55, 1), panel = vmath.vector4(0.10, 0.10, 0.12, 1) },
  red_drago  = { id = "red_drago",   label = "Red Dragon",   bg_image = "bg_1", card_set = "drago",   card_back = "card_back",       accent = vmath.vector4(0.95, 0.30, 0.10, 1), panel = vmath.vector4(0.15, 0.06, 0.06, 1) },
  blue_drago = { id = "blue_drago",  label = "Blue Dragon",  bg_image = "bg_2", card_set = "drago",   card_back = "card_back_blue",  accent = vmath.vector4(0.20, 0.60, 1.00, 1), panel = vmath.vector4(0.05, 0.10, 0.20, 1) },
  batman     = { id = "batman",      label = "Dark Knight",  bg_image = "bg_3", card_set = "batman",  card_back = "card_back",       accent = vmath.vector4(0.95, 0.75, 0.05, 1), panel = vmath.vector4(0.06, 0.06, 0.08, 1) },
}

-- Ordered list so cycling is deterministic.
M.THEME_ORDER = { "default", "blue_basic", "black_basic", "red_drago", "blue_drago", "batman" }

-- THE PRICE THE BACKEND WILL ACTUALLY CHARGE.
--
-- Mirrors DEFAULT_THEMES_DATA in be_matatu's models/Theme.ts. It is a MIRROR,
-- not a second opinion: the server is the only side that can be right about a
-- price, because it is the side that deducts it.
--
-- It exists at all because the shop has to be able to draw something when the
-- payload has not arrived — an app opened offline, or a build talking to a
-- backend whose catalogue has not been seeded. What it drew before was a flat
-- 2000 for everything, which matched none of these and meant a player could be
-- shown one number and charged another.
--
-- `label` above and `name` here serve the same purpose and are now the same
-- strings on both sides, so whichever list wins, the player reads the same
-- word. See the comment on DEFAULT_THEMES_DATA for why the server's names were
-- changed to match these rather than the other way round.
M.THEME_PRICES = {
  default     = 0,
  blue_basic  = 0,
  black_basic = 0,
  blue_drago  = 1000,
  red_drago   = 2000,
  batman      = 5000,
}

function M.get_theme()
  return M.THEMES[M.theme] or M.THEMES["default"]
end

-- THE MATCH OWNS THE THEME WHILE A MATCH IS ON SCREEN.
--
-- The server picks one theme for a game — the more expensive of the two
-- players' — so both people see the same board. That decision has to outrank
-- the local "my own theme" sync, and it did not: sync_theme_from_user runs on
-- IDENTIFY, which fires on every reconnect, so a mid-game reconnect quietly
-- reset the board to the viewer's own theme. For the player who does not own
-- the match's theme, that is the default sheet, and any card created after it
-- was built from the wrong one.
--
-- Set by OnlineHandler.start_game, cleared when the game screen is left.
M.match_theme = nil

function M.set_match_theme(theme_id)
  local id = (type(theme_id) == "string" and M.THEMES[theme_id]) and theme_id or "default"
  M.match_theme = id
  M.theme = id
end

function M.clear_match_theme()
  M.match_theme = nil
end

-- Sync the active theme from a user object's themes array (the one with active=true).
function M.sync_theme_from_user(user)
  -- A match theme is not a preference, it is what both players are looking at.
  -- Refuse to overwrite it here; the game screen clears it on the way out and
  -- re-syncs then.
  if M.match_theme then return end
  if type(user) ~= "table" or type(user.themes) ~= "table" then return end
  for _, t in ipairs(user.themes) do
    if t.active and t.id and M.THEMES[t.id] then
      M.theme = t.id
      return
    end
  end
end

-- A username is "valid/complete" if >= 3 chars and not the default Player_ name.
function M.username_complete(name)
  if type(name) ~= "string" then return false end
  name = name:gsub("^%s*(.-)%s*$", "%1")
  if #name < 3 then return false end
  if name:sub(1, 7) == "Player_" then return false end
  return true
end

-- THE PHONE NUMBER IS NO LONGER A GATE.
--
-- It used to be mandatory for Matatu accounts, re-evaluated on every login and
-- reconnect, and a missing one sent the player to the phone screen. That made
-- sense when the phone number was the migration path off pre-Google accounts.
--
-- It does not now. Sign-in is the device id, so a player whose handset is
-- recognised is signed in, full stop — and putting a number-entry screen in
-- front of them at that moment asks for something the app did not need to let
-- them in and cannot explain the reason for. The reported version of this was
-- the phone screen turning up after a perfectly successful launch.
--
-- The phone number still MATTERS, and this is the one thing worth being clear
-- about: it is the identity that survives a new handset. Without it, changing
-- phones loses the account. So it stays offered on the profile screen, and it
-- is still the entire answer to DEVICE_UNKNOWN — a handset we do not recognise
-- has nothing else to go on. What it no longer does is interrupt somebody the
-- device already identified.
--
-- phone_complete is kept, and still answers honestly, because the profile
-- screen uses it to decide whether to show the prompt. It simply no longer
-- feeds profile_complete.
--
-- MATATU ONLY, AND THAT IS ABOUT WHAT THE NUMBER CAN PROVE.
--
-- A number is worth asking for where something can be learned from it. In
-- Uganda that is a live mobile-money name enquiry: the backend looks the
-- number up, gets the account holder's real name back, and matches it against
-- the blocked-identity lists. That is the identity check, and the number is
-- how it is run.
--
-- Nigeria (Whot) and Kenya (Kadi) have no such provider wired up — be_matatu's
-- validatePhone says so itself, answering "format check only, no live
-- verification yet" and no name at all. So in those apps the keypad would
-- collect a string, verify nothing with it, and stand between the player and
-- the game on the strength of it. There is nothing to skip TO the number for,
-- so it is skipped: sign-in is the device id, and the username/avatar screen
-- is the whole of signing up (POST /auth/device/profile).
function M.phone_required()
  local ok, GameMode = pcall(require, "modules.game_mode")
  return ok and GameMode.is_matatu()
end

function M.phone_complete(user)
  if not M.phone_required() then return true end
  if type(user) ~= "table" then return false end
  local p = user.phoneNumber or user.phone or ""
  return type(p) == "string" and p ~= ""
end

-- Account is "complete" when an avatar is chosen and the username is valid.
--
-- Deliberately NOT phone_complete — see above. This is re-evaluated every time
-- route_after_auth runs, so anything in here reappears on every login and every
-- reconnect until satisfied, which is the right shape for "you have not chosen
-- a name yet" and the wrong one for a credential the player was not asked for.
function M.profile_complete(user)
  if type(user) ~= "table" then return false end
  local avatar = tonumber(user.avatar) or 0
  if avatar <= 0 then return false end
  return M.username_complete(user.username)
end

function M.next_theme()
  for i, k in ipairs(M.THEME_ORDER) do
    if k == M.theme then
      M.theme = M.THEME_ORDER[(i % #M.THEME_ORDER) + 1]
      return
    end
  end
  M.theme = M.THEME_ORDER[1]
end

-- ---------------------------------------------------------------------------
-- Modal input priority
-- ---------------------------------------------------------------------------
-- Every screen and dialog in this app is a gui component on ONE game object
-- (controller.go), and Defold hands on_input to each of them in the order
-- they are listed there — not in the order they are stacked on screen. The
-- first component to return true consumes the tap.
--
-- "gameover" is listed before "incoming", so with a game-over dialog open
-- underneath an incoming game request, a tap on DECLINE reached PLAY AGAIN
-- first and started a rematch. The same ordering let taps land on the lobby,
-- the online screen and the board while a request dialog was up.
--
-- So priority has to be declared rather than inherited from the .go file.
-- A modal claims a priority while it is visible; anything of LOWER priority
-- ignores input until it is gone. Screens use priority 0 and are therefore
-- blocked by every modal.
M.modals = {}

M.MODAL_PRIORITY = {
    incoming        = 100,  -- time-limited: must always win
    network         = 90,
    announcement    = 80,
    daily_bonus     = 70,
    signup_bonus    = 70,
    season_results  = 60,
    gameover        = 50,
    suit_select     = 40,
    tutorial        = 30,
}

function M.modal_open(name, priority)
    M.modals[name] = priority or M.MODAL_PRIORITY[name] or 10
end

function M.modal_close(name)
    M.modals[name] = nil
end

-- Highest priority currently claimed, or 0 when nothing is up.
function M.modal_top()
    local top = 0
    for _, p in pairs(M.modals) do
        if p > top then top = p end
    end
    return top
end

-- True when something of HIGHER priority than `name` is on screen, so `name`
-- must keep its hands off input. Pass no name (or an unknown one) for a plain
-- screen, which any modal outranks.
function M.input_blocked(name)
    local mine = M.modals[name] or 0
    return M.modal_top() > mine
end

-- ---------------------------------------------------------------------------
-- Board lock
-- ---------------------------------------------------------------------------
-- Set the moment a game is DECLARED over — however it was declared, in any
-- mode (offline, online, tournament chamber) and any game type. From then on
-- no card may be played, no card may be drawn, and no HUD control responds,
-- until a new game or round actually starts.
--
-- Why a shared flag rather than the per-game `self.game_over`: the board and
-- the HUD are two separate scripts with two separate `self` tables, and only
-- the board's one carried the game state. The HUD therefore kept EXIT, SKIP
-- and the emoji tray live over a finished game.
--
-- It is deliberately independent of the modal registry too. `input_blocked`
-- only says "a dialog is on top", which goes false the instant the game-over
-- dialog closes — while the board underneath is still finished.
M.board_locked = false

function M.lock_board()   M.board_locked = true  end
function M.unlock_board() M.board_locked = false end

-- WHAT THE BOARD IS SHOWING INSTEAD OF, OR AS WELL AS, A COIN POT.
--
-- Both are decided once when the game is accepted, by
-- modules/championship_board.lua, and read from here by the two places that
-- have to agree about it: overlay_ui draws the watermark, and gameover
-- consults board_coins_may_settle before flying a stake to the winner.
--
-- Parked in app_state rather than passed along because the decision is made
-- before the board GUI exists — controller raises the pot on the accept, and
-- the searching player's board is not created for another 1.8s.
--
-- nil watermark means an ordinary board. board_coins_may_settle nil is read as
-- TRUE, so nothing that never sets it loses its payout animation.
M.board_watermark = nil
M.board_coins_may_settle = nil

return M

