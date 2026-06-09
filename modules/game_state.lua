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
    self.chosen_suit      = ""
    self.player_has_drawn = false
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

    self._seq = (self._seq or 0) + 1
end

function M.destroy_all(self)
    local function purge(list) for _, c in ipairs(list or {}) do pcall(go.delete, c.id) end end
    purge(self.deck); purge(self.player_hand); purge(self.ai_hand); purge(self.played_cards)
    if self.cutting_card then pcall(go.delete, self.cutting_card.id); self.cutting_card = nil end
    self.deck, self.player_hand, self.ai_hand, self.played_cards = {}, {}, {}, {}

    if self.ws_listeners then
        for _, token in ipairs(self.ws_listeners) do ws.off(token) end
    end
    self.ws_listeners = {}
end

return M
