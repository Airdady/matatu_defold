-- Tiny shared singleton passing data between the lobby and game screens.

local M = {}

-- "offline" (Quick Play vs AI) or "online" (multiplayer over websocket)
M.mode = "offline"

-- True only while a game board is actively in play (set on game screen_enter,
-- cleared on the final game-over modal or when leaving the game screen). Used
-- by the global incoming-request overlay to decide between the compact top
-- banner (mid-game) and the full dialog (no active game).
M.game_active = false

-- Name of the screen currently shown (set by the controller's show()).
M.current_screen = nil

-- The active offline game_logic object (set by the lobby on Quick Play).
M.offline_game = nil

-- Stake chosen in the lobby for the next match.
M.selected_stake = { amount = 0, charge = 0, points = 0 }

-- Active theme name (matches THEMES table keys).
M.theme = "default"

-- Auth state for the GPGS (Google Play Game Services) flow.
-- "idle" | "sending" | "verifying" | "done" | "error"
M.auth_state = "idle"
M.auth_error = ""

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

function M.get_theme()
  return M.THEMES[M.theme] or M.THEMES["default"]
end

-- Sync the active theme from a user object's themes array (the one with active=true).
function M.sync_theme_from_user(user)
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

-- Account is "complete" when an avatar is chosen AND the username is valid.
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

return M