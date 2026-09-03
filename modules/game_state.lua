----------------------------------------------------------------------
-- game_state.lua
-- Owns the lifecycle of the in-memory game state: zeroing every field on a
-- fresh game (fresh_state) and tearing down all spawned card objects plus
-- WebSocket listeners (destroy_all).
----------------------------------------------------------------------
local ws = require "modules.websocket_manager"

local M = {}

function M.fresh_state(self)
    self.deck             = {}
    self.player_hand      = {}
    self.ai_hand          = {}
    self.played_cards     = {}
    self.cutting_card     = nil
    self.game_state       = {}
    self.current_turn     = "player"
    self.active_penalty   = 0
    -- Offline General Market debt: { who, count, return_to }. Must reset with
    -- the board, or a debt left over from the previous deal would strand the
    -- next one on a market draw nobody owes.
    self.pending_market_draw = nil
    self.chosen_suit      = ""
    self.player_has_drawn = false
    self._drew_on_turn    = nil
    self.is_local_action_locked = false
    self.lock_stuck       = 0
    self.is_suit_selection_active = false
    self.game_over        = false
    self.is_animating     = false
    self.stuck_count      = 0
    self.turn_count       = 0
    self.online_mode      = false
    self.my_player_id     = ""
    self.opponent_id      = ""
    self.online_game_id   = ""
    self.waiting          = false
    self._online_pending_card = nil
    self.last_local_play  = {}
    self.current_turn_actions = {}
    self.is_waiting_for_server_response = false

    self.move_queue = {}
    self.is_processing_move = false

    -- Pile scatter: offline games roll a fresh seed; online games overwrite
    -- it with a game-id-derived seed so resumes reproduce the exact pile.
    self.scatter_seed = math.random(2147483646)
    self.pile_index_base = 0

    self._seq = (self._seq or 0) + 1
end

function M.destroy_all(self)
    local function purge(list) for _, c in ipairs(list or {}) do pcall(go.delete, c.id) end end
    purge(self.deck); purge(self.player_hand); purge(self.ai_hand); purge(self.played_cards)
    if self.cutting_card then pcall(go.delete, self.cutting_card.id); self.cutting_card = nil end
    self.deck, self.player_hand, self.ai_hand, self.played_cards = {}, {}, {}, {}

    -- Tear down any 4-player tournament seat visuals + state.
    local had_seats = false
    if self.t4 then
        for _, s in ipairs(self.t4.seats or {}) do purge(s.cards) end
        self.t4 = nil
        had_seats = true
    end

    -- Same for an online party's seats, which use the same badges. Cleared
    -- here rather than on game-over so a board torn down mid-hand (a
    -- disconnect, a forced exit) does not leave three opponents on screen for
    -- whatever game is dealt next.
    if self.party_seats then
        for _, s in pairs(self.party_seats) do purge(s.cards) end
        self.party_seats = nil
        had_seats = true
    end

    -- THE CARDS WERE DELETED; THE BADGES WERE NOT.
    --
    -- The seat cards above are game objects this module owns, so purging them
    -- is enough. The avatar disc, the name and the timer ring are GUI nodes
    -- living in game.gui_script's own t4_badges table, and nothing here could
    -- reach them — so they survived destroy_all and were still on screen when
    -- the next game was dealt. That is the opponent "already staged" on a
    -- fresh party board: not a new avatar drawn too early, an old one never
    -- taken down.
    --
    -- t4_clear is the message that owns them, and both the offline chamber and
    -- party_board already use it; it simply was not sent on this path.
    if had_seats then
        pcall(msg.post, "#game", "t4_clear", {})
    end

    if self.ws_listeners then
        for _, token in ipairs(self.ws_listeners) do ws.off(token) end
    end
    self.ws_listeners = {}
end

return M
