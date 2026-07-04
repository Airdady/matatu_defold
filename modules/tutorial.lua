-- modules/tutorial.lua
-- First-time-player walkthrough — a faithful Defold port of the Godot
-- TutorialManager (src/global/TutorialManager.gd). One shared state machine
-- (Lua modules are shared across all scripts in the collection) that the lobby,
-- game, suit selector, emoji popover and game-over screens drive via hooks.
--
-- The manager never touches GUI nodes directly. It holds the desired highlight
-- (M.current()) and posts it to the `#tutorial` overlay component; each screen
-- supplies the on-screen rect of the element being pointed at (cards live in
-- world space, HUD elements in GUI space, so only the owning screen can measure
-- them). The overlay renders the spotlight + arrow + text + NEXT button.
--
-- IMPORTANT: this scripted walkthrough plays a fixed, Matatu-only card
-- sequence (2 of Diamonds, Ace of Spades/Clubs, Jack, cutting-card 7 — none of
-- which exist in a Whot deck). M.should_start / M.start_game hard-refuse to
-- activate outside a Matatu build (see modules/game_mode.lua) so it can never
-- be reactivated by mistake and show Matatu-only instructions/cards on a Whot
-- or Kadi build. A Whot equivalent needs its own scripted sequence + a
-- matching server-side scripted deal, and is not implemented yet.

local GameMode = require "modules.game_mode"

local M = {}

-- ── Steps (1:1 with the Godot enum order) ──────────────────────────────────────
M.STEP = {
    INACTIVE = 0,
    LOBBY_SELECT_STAKE = 1,
    LOBBY_SELECT_AI = 2,
    WAIT_DEALING = 3,
    PLAY_2D = 4,
    WAIT_AI_1 = 5,
    PLAY_15S = 6,
    WAIT_AI_2 = 7,
    PLAY_15C = 8,
    SUIT_CLUBS = 9,
    WAIT_AI_3 = 10,
    PLAY_11C = 11,
    PLAY_8C = 12,
    PLAY_4C = 13,
    WAIT_AI_4 = 14,
    PLAY_HISTORY_PINCH = 15,
    EMOJI_OPEN_BTN = 16,
    EMOJI_SELECT_FACE = 17,
    EMOJI_SELECT_VOICE = 18,
    PLAY_7C = 19,
    WAIT_GAME_OVER = 20,
    GAMEOVER_COINS = 21,
    GAMEOVER_POINTS = 22,
    GAMEOVER_MENU = 23,
    LOBBY_RETURN_STANDINGS = 24,
    LOBBY_RETURN_BONUS = 25,
    LOBBY_RETURN_PAYMENTS = 26,
    COMPLETED = 27,
}
local S = M.STEP

-- ── Bubble copy (BBCode stripped; the overlay text node is single-colour) ──────
M.TEXT = {
    lobby_stake     = "Welcome! Tap Stake to continue.",
    lobby_searching = "Searching for opponents...",
    lobby_opponent  = "Tap an opponent to play.",
    play_2d         = "Play the 2 of Diamonds to penalize!",
    play_15s        = "Play the Ace of Spades to block the penalty!",
    play_15c        = "Play the Ace of Clubs to change suit!",
    play_11c        = "Now play the Jack of Clubs.",
    play_8c         = "Rapid play! Chain your 8 of Clubs.",
    play_4c         = "Keep it going! Play the 4 of Clubs.",
    emoji_open      = "Send a reaction! Tap Emoji.",
    play_7c         = "Finish your combo with the 7 of Clubs!",
    suit_clubs      = "Tap Clubs for the next play.",
    emoji_face      = "Tap a reaction.",
    emoji_voice     = "Tap a voice note!",
    gameover_coins  = "Winning earns you Prizes!",
    gameover_points = "Earn Points to climb the weekly rank!",
    gameover_menu   = "Tap to return to the Lobby.",
    lobby_standings = "Rank #%s with %s PTS!\nTop players win big prizes.",
    lobby_bonus     = "Check the Bonus Table for Saturday rewards!",
    lobby_payments  = "Need more? Buy Coins here!",
    history_title   = "View History",
    history_desc    = "Pinch out to see played cards",
}

M.step = S.INACTIVE
M._highlight = nil       -- { screen, target, text, show_next, click_anywhere, block, force_center }
M._user_data = nil

local OVERLAY = "/controller#tutorial"

-- ── Overlay plumbing ───────────────────────────────────────────────────────────
local function clear_highlight()
    M._highlight = nil
    pcall(msg.post, OVERLAY, "tut_hide", {})
    -- Also drop the pinch-history hint so a reset never leaves it on screen.
    pcall(msg.post, OVERLAY, "tut_history_hide", {})
end

-- A screen calls this once it has measured the target rect (in 1280x720 logical
-- space). The manager forwards it to the overlay with the active step's copy.
function M.show_rect(x, y, w, h)
    local hl = M._highlight
    if not hl then return end
    pcall(msg.post, OVERLAY, "tut_show", {
        x = x, y = y, w = w, h = h,
        text = hl.text or "",
        show_next = hl.show_next or false,
        click_anywhere = hl.click_anywhere or false,
        block = hl.block or false,
        force_center = hl.force_center or false,
        arrow = hl.arrow ~= false,
    })
end

local function want(screen, target, text, opts)
    opts = opts or {}
    M._highlight = {
        screen = screen, target = target, text = text or "",
        show_next = opts.show_next, click_anywhere = opts.click_anywhere,
        block = opts.block, force_center = opts.force_center, arrow = opts.arrow,
        -- card targets carry the value/suit the owning screen should locate
        v = opts.v, s = opts.s,
    }
end

function M.is_active()
    return M.step ~= S.INACTIVE and M.step ~= S.COMPLETED
end

function M.current() return M._highlight end

-- Which value/suit the player must play right now (so the game can gate taps to
-- only the scripted card). Mirrors Godot is_card_allowed.
function M.is_card_allowed(v, s)
    if not M.is_active() then return true end
    local st = M.step
    if st == S.LOBBY_SELECT_STAKE or st == S.LOBBY_SELECT_AI
        or st == S.LOBBY_RETURN_STANDINGS or st == S.LOBBY_RETURN_BONUS
        or st == S.LOBBY_RETURN_PAYMENTS then
        return true
    end
    if st == S.PLAY_HISTORY_PINCH then return false end
    v, s = tonumber(v), tostring(s)
    if st == S.PLAY_2D  and v == 2  and s == "D" then return true end
    if st == S.PLAY_15S and v == 15 and s == "S" then return true end
    if st == S.PLAY_15C and v == 15 and s == "C" then return true end
    if st == S.PLAY_11C and v == 11 and s == "C" then return true end
    if st == S.PLAY_8C  and v == 8  and s == "C" then return true end
    if st == S.PLAY_4C  and v == 4  and s == "C" then return true end
    if st == S.PLAY_7C  and v == 7  and s == "C" then return true end
    return false
end

-- ── Lobby hooks ────────────────────────────────────────────────────────────────
-- Returns true if a first-time player should see the onboarding flow.
function M.should_start(user_data)
    if not GameMode.is_matatu() then return false end -- Matatu-only card sequence
    user_data = user_data or {}
    local games_played = tonumber(user_data.gamesPlayed) or 0
    if user_data.tutorialCompleted == true and games_played > 0 then return false end
    return games_played == 0
end

function M.start_lobby(user_data)
    M._user_data = user_data or {}
    if M.step == S.INACTIVE and M.should_start(user_data) then
        M.step = S.LOBBY_SELECT_STAKE
        want("lobby", "stake", M.TEXT.lobby_stake)
    end
end

function M.on_lobby_stake_pressed()
    if M.step == S.LOBBY_SELECT_STAKE then
        M.step = S.LOBBY_SELECT_AI
        -- Dim the whole centre column ("searching..."), no arrow, blocked.
        want("lobby", "ai", M.TEXT.lobby_opponent, { show_next = false })
    end
end

function M.on_lobby_ai_selected()
    if M.step == S.LOBBY_SELECT_AI then
        clear_highlight()
        M.step = S.INACTIVE -- handed off to the in-game flow on game start
    end
end

-- ── Game hooks ─────────────────────────────────────────────────────────────────
function M.start_game(is_scripted)
    if not is_scripted or not GameMode.is_matatu() then
        M.step = S.INACTIVE
        clear_highlight()
        return
    end
    M.step = S.WAIT_DEALING
end

function M.on_dealing_completed()
    if M.step == S.WAIT_DEALING then
        M.step = S.PLAY_2D
        M.on_player_turn()
    end
end

-- Re-assert the highlight for the current "play X" step (called when it becomes
-- the player's turn, or after the board settles).
function M.on_player_turn()
    if not M.is_active() then return end
    local st = M.step
    if st == S.PLAY_2D  then want("game", "card", M.TEXT.play_2d,  { v = 2,  s = "D" })
    elseif st == S.PLAY_15S then want("game", "card", M.TEXT.play_15s, { v = 15, s = "S" })
    elseif st == S.PLAY_15C then want("game", "card", M.TEXT.play_15c, { v = 15, s = "C" })
    elseif st == S.PLAY_11C then want("game", "card", M.TEXT.play_11c, { v = 11, s = "C" })
    elseif st == S.PLAY_8C  then want("game", "card", M.TEXT.play_8c,  { v = 8,  s = "C" })
    elseif st == S.PLAY_4C  then want("game", "card", M.TEXT.play_4c,  { v = 4,  s = "C" })
    elseif st == S.PLAY_7C  then want("game", "card", M.TEXT.play_7c,  { v = 7,  s = "C" })
    elseif st == S.EMOJI_OPEN_BTN then want("game", "emoji_btn", M.TEXT.emoji_open)
    end
end

function M.on_card_played(v, s)
    if not M.is_active() then return end
    v, s = tonumber(v), tostring(s)
    local st = M.step
    if st == S.PLAY_2D and v == 2 and s == "D" then
        M.step = S.WAIT_AI_1; clear_highlight()
    elseif st == S.PLAY_15S and v == 15 and s == "S" then
        M.step = S.WAIT_AI_2; clear_highlight()
    elseif st == S.PLAY_15C and v == 15 and s == "C" then
        clear_highlight() -- next stop is the suit selector
    elseif st == S.PLAY_11C and v == 11 and s == "C" then
        M.step = S.PLAY_8C; M.on_player_turn()
    elseif st == S.PLAY_8C and v == 8 and s == "C" then
        M.step = S.PLAY_4C; M.on_player_turn()
    elseif st == S.PLAY_4C and v == 4 and s == "C" then
        M.step = S.WAIT_AI_4; clear_highlight()
    elseif st == S.PLAY_7C and v == 7 and s == "C" then
        M.step = S.WAIT_GAME_OVER; clear_highlight()
    end
end

function M.on_suit_opened()
    if M.step == S.PLAY_15C then
        M.step = S.SUIT_CLUBS
        want("suit", "suit_clubs", M.TEXT.suit_clubs)
    end
end

function M.on_suit_selected()
    if M.step == S.SUIT_CLUBS then
        M.step = S.WAIT_AI_3; clear_highlight()
    end
end

function M.on_opponent_played()
    if M.step == S.WAIT_AI_1 then
        M.step = S.PLAY_15S; M.on_player_turn()
    elseif M.step == S.WAIT_AI_2 then
        M.step = S.PLAY_15C; M.on_player_turn()
    elseif M.step == S.WAIT_AI_3 then
        M.step = S.PLAY_11C; M.on_player_turn()
    elseif M.step == S.WAIT_AI_4 then
        M.step = S.PLAY_HISTORY_PINCH
        -- Show the pinch hint overlay (animated hand + copy).
        pcall(msg.post, OVERLAY, "tut_history", { title = M.TEXT.history_title, desc = M.TEXT.history_desc })
    end
end

-- Player performed the pinch-to-view-history gesture.
function M.on_history_viewed()
    if M.step == S.PLAY_HISTORY_PINCH then
        pcall(msg.post, OVERLAY, "tut_history_hide", {})
        M.step = S.EMOJI_OPEN_BTN
        M.on_player_turn()
    end
end

-- ── Emoji hooks ────────────────────────────────────────────────────────────────
function M.on_emoji_opened()
    if M.step == S.EMOJI_OPEN_BTN then
        M.step = S.EMOJI_SELECT_FACE
        want("game", "emoji_face", M.TEXT.emoji_face)
    end
end

function M.on_emoji_face_selected()
    if M.step == S.EMOJI_SELECT_FACE then
        M.step = S.EMOJI_SELECT_VOICE
        want("game", "emoji_voice", M.TEXT.emoji_voice)
    end
end

function M.on_emoji_voice_selected()
    if M.step == S.EMOJI_SELECT_VOICE then
        M.step = S.PLAY_7C; clear_highlight()
        M.on_player_turn()
    end
end

-- ── Game-over hooks ────────────────────────────────────────────────────────────
function M.on_game_over()
    if M.step == S.WAIT_GAME_OVER then
        M.step = S.GAMEOVER_COINS
        want("gameover", "prizes", M.TEXT.gameover_coins, { show_next = true, block = true })
    end
end

-- NEXT button (or click-anywhere) advances the game-over / lobby-return steps.
function M.on_next()
    local st = M.step
    if st == S.GAMEOVER_COINS then
        M.step = S.GAMEOVER_POINTS
        want("gameover", "points", M.TEXT.gameover_points, { show_next = true, block = true })
    elseif st == S.GAMEOVER_POINTS then
        M.step = S.GAMEOVER_MENU
        want("gameover", "menu", M.TEXT.gameover_menu)
    elseif st == S.LOBBY_RETURN_STANDINGS then
        M.step = S.LOBBY_RETURN_BONUS
        want("lobby", "bonus", M.TEXT.lobby_bonus, { show_next = true, block = true, force_center = true })
    elseif st == S.LOBBY_RETURN_BONUS then
        M.step = S.LOBBY_RETURN_PAYMENTS
        want("lobby", "payments", M.TEXT.lobby_payments, { show_next = true, block = true, force_center = true })
    elseif st == S.LOBBY_RETURN_PAYMENTS then
        clear_highlight()
        M.step = S.COMPLETED
        M.mark_completed()
    end
end

function M.on_gameover_menu_pressed()
    if M.step == S.GAMEOVER_MENU then
        clear_highlight()
        M.step = S.LOBBY_RETURN_STANDINGS
    end
end

-- ── Post-game lobby return ─────────────────────────────────────────────────────
function M.start_lobby_return()
    if M.step == S.LOBBY_RETURN_STANDINGS then
        local pos = (M._user_data or {}).position or "-"
        local pts = (M._user_data or {}).points or "0"
        want("lobby", "standings", string.format(M.TEXT.lobby_standings, tostring(pos), tostring(pts)),
            { show_next = true, block = true, force_center = true })
    end
end

function M.mark_completed()
    if M._user_data then M._user_data.tutorialCompleted = true end
    -- Persist server-side via the websocket profile update.
    local ok, ws = pcall(require, "modules.websocket_manager")
    if ok and ws and ws.update_profile then
        pcall(ws.update_profile, { tutorialCompleted = true })
    end
end

function M.reset()
    M.step = S.INACTIVE
    clear_highlight()
end

return M
