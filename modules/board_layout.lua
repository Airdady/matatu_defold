----------------------------------------------------------------------
-- board_layout.lua
-- All visual layout: card-size constants, z-bands, screen-fit math, and
-- positioning of hands / deck / background. NO game rules live here.
--
-- Constants are exposed as fields on M so other modules can read them
-- (e.g. BL.CARD_SCALE, BL.Z_PILE) without duplicating magic numbers.
----------------------------------------------------------------------
local M = {}

----------------------------------------------------------------------
-- Layout / animation constants
----------------------------------------------------------------------
M.NATIVE_CARD_W = 186
M.NATIVE_CARD_H = 204
M.TARGET_W      = 110
M.CARD_SCALE_F  = M.TARGET_W / M.NATIVE_CARD_W
M.TARGET_H      = M.NATIVE_CARD_H * M.CARD_SCALE_F
M.CARD_SCALE    = vmath.vector3(M.CARD_SCALE_F, M.CARD_SCALE_F, 1.0)

M.PILE_OFFSET_X = 50
M.PILE_OFFSET_Y = 34
M.SAVE_NAME     = "matatu_defold_state"

M.CUTTING_CARD_OFFSET_X = -60

M.Z_HAND = 0.05
M.Z_PILE = 0.10
M.Z_FLY  = 0.30
M.Z_CUT  = 0.0008

M.LOGICAL_W = 1280
M.LOGICAL_H = 720

-- Local aliases for readability inside this module.
local LOGICAL_W, LOGICAL_H = M.LOGICAL_W, M.LOGICAL_H
local TARGET_W = M.TARGET_W
local CUTTING_CARD_OFFSET_X = M.CUTTING_CARD_OFFSET_X
local Z_HAND, Z_CUT = M.Z_HAND, M.Z_CUT

----------------------------------------------------------------------
-- Hand spacing
----------------------------------------------------------------------
function M.calc_spacing(self, n)
    if n <= 1 then return 0 end
    local base_gap = TARGET_W
    local extra_gap = math.min(24, math.max(0, 8 - n) * 6)
    local desired_gap = base_gap + extra_gap

    local required = n * desired_gap
    if required <= self.MAX_HAND_WIDTH then
        return desired_gap
    end
    return self.MAX_HAND_WIDTH / n
end

----------------------------------------------------------------------
-- Background fit (aspect-fill)
----------------------------------------------------------------------
function M.fit_background(self)
    local ok, ww, wh = pcall(window.get_size)
    if not ok or not ww or ww == 0 then ww = LOGICAL_W end
    if not wh or wh == 0 then wh = LOGICAL_H end
    
    local screen_aspect  = ww / wh
    local logical_aspect = LOGICAL_W / LOGICAL_H
    
    -- Calculate the visible area dimensions
    local target_w, target_h = LOGICAL_W, LOGICAL_H
    if screen_aspect > logical_aspect then 
        target_w = LOGICAL_H * screen_aspect
    else 
        target_h = LOGICAL_W / screen_aspect 
    end
    
    -- CRITICAL: Always try to get the actual texture size from the sprite
    local img_w = LOGICAL_W  -- default fallback
    local img_h = LOGICAL_H  -- default fallback
    
    pcall(function()
        local url = msg.url("#background")
        local texture_w, texture_h = go.get(url, "texture_size")
        
        if texture_w and texture_h and texture_w > 0 and texture_h > 0 then
            img_w = texture_w
            img_h = texture_h
            self.bg_img_w = img_w
            self.bg_img_h = img_h
        else
            local sz = go.get(url, "size")
            if sz and sz.x > 0 and sz.y > 0 then
                img_w = sz.x
                img_h = sz.y
                self.bg_img_w = img_w
                self.bg_img_h = img_h
            elseif self.bg_img_w and self.bg_img_w > 0 then
                img_w = self.bg_img_w
                img_h = self.bg_img_h
            end
        end
    end)
    
    -- Calculate scale to fill the screen (aspect-fill)
    local scale_x = target_w / img_w
    local scale_y = target_h / img_h
    local sf = math.max(scale_x, scale_y)
    
    -- Apply the scale
    pcall(function()
        go.set("#background", "scale", vmath.vector3(sf, sf, 1.0))
    end)
end

----------------------------------------------------------------------
-- Initialize background on first load
----------------------------------------------------------------------
function M.init_background(self)
    self.bg_img_w = nil
    self.bg_img_h = nil
    
    M.fit_background(self)
    
    local delays = {0.05, 0.15, 0.3, 0.6, 1.0}
    for _, delay in ipairs(delays) do
        timer.delay(delay, false, function()
            if self.active ~= false then
                M.fit_background(self)
            end
        end)
    end
end

----------------------------------------------------------------------
-- Deck stacking helpers
----------------------------------------------------------------------
function M.deck_slot_pos(self, idx)
    return vmath.vector3(
        self.DECK_POS.x + idx * 0.5,
        self.DECK_POS.y - idx * 0.5,
        idx * 0.001)
end

function M.restack_deck(self)
    if not self.deck then return end
    for i, c in ipairs(self.deck) do
        go.set_position(M.deck_slot_pos(self, i), c.id)
        go.set(c.id, "euler.z", 0)
    end
end

----------------------------------------------------------------------
-- Hand layout
----------------------------------------------------------------------
function M.layout_hand(self, hand, y, animate)
    local n = #hand
    if n == 0 then return end
    local spacing = M.calc_spacing(self, n)
    local start = self.CENTER.x - ((n - 1) * spacing) / 2.0

    -- Gentle arch + fan in EVERY mode (offline, online and the 4-player
    -- tournament) so the look is consistent. The human's bottom hand arches up;
    -- the opponent's top hand mirrors it (bulges down toward the centre). In a
    -- 4-player tournament only the live human's hand is arched.
    local is_player_hand = (hand == self.player_hand)
    local is_ai_hand     = (hand == self.ai_hand)
    local arch = (is_player_hand and (not self.t4 or self.t4.human_alive))
              or (is_ai_hand and not self.t4)
    local arc_amt = arch and math.min(34, n * 5.0) or 0
    local fan_amt = arch and math.min(8, n * 1.3) or 0
    local dir     = is_ai_hand and -1 or 1   -- mirror the curve for the top hand

    for i, c in ipairs(hand) do
        local z = Z_HAND + i * 0.001
        local t = (n > 1) and ((i - 1) / (n - 1) - 0.5) or 0
        local by = dir * (0.25 - t * t) * arc_amt
        local target = vmath.vector3(start + (i - 1) * spacing, y + by, z)
        if animate then
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, target, go.EASING_OUTSINE, 0.42)
        else
            go.set_position(target, c.id)
        end
        go.set(c.id, "euler.z", -t * fan_amt * dir)
    end
end

function M.position_hands(self, animate)
    M.layout_hand(self, self.player_hand, self.PLAYER_HAND_Y, animate)
    M.layout_hand(self, self.ai_hand, self.AI_HAND_Y, animate)
end

----------------------------------------------------------------------
-- Full layout recompute (call on init and layout_changed)
----------------------------------------------------------------------
function M.update_layout(self)
    local ok, ww, wh = pcall(window.get_size)
    if not ok or not ww or ww == 0 then ww = LOGICAL_W end
    if not wh or wh == 0 then wh = LOGICAL_H end

    local screen_aspect  = ww / wh
    local logical_aspect = LOGICAL_W / LOGICAL_H

    local vis_w = LOGICAL_W
    local vis_h = LOGICAL_H
    if screen_aspect > logical_aspect then
        vis_w = LOGICAL_H * screen_aspect
    else
        vis_h = LOGICAL_W / screen_aspect
    end

    local right_edge = (LOGICAL_W / 2) + (vis_w / 2)
    local top_edge = (LOGICAL_H / 2) + (vis_h / 2)
    local bottom_edge = (LOGICAL_H / 2) - (vis_h / 2)

    self.CENTER   = vmath.vector3(LOGICAL_W / 2, LOGICAL_H / 2, 0.05)
    
    -- 4-player tournament seats
    local left_edge = (LOGICAL_W / 2) - (vis_w / 2)
    self.SEAT_TOP   = vmath.vector3(LOGICAL_W / 2,    top_edge - 70,    0)
    self.SEAT_LEFT  = vmath.vector3(left_edge + 110,  LOGICAL_H / 2,    0)
    self.SEAT_RIGHT = vmath.vector3(right_edge - 110, LOGICAL_H / 2 + 70, 0)

    self.MAX_HAND_WIDTH = math.min(1100, vis_w - 400)
    self.PLAYER_HAND_Y  = bottom_edge + 96
    self.AI_HAND_Y      = top_edge - 96

    -- DECK POSITIONING LOGIC
    -- We safely evaluate whether we are genuinely inside a multi-player T4 mode
    -- using explicit length checks to prevent empty table bleed from 2P game mode.
    local is_multiplayer_t4 = self.t4 and self.t4.seats and (#self.t4.seats > 0) and not self.t4.is_heads_up
    
    if is_multiplayer_t4 then
        -- 4 (or 3) active players: Deck shifts exactly midway between the center pile and the right player!
        local mid_x = self.CENTER.x + (self.SEAT_RIGHT.x - self.CENTER.x) / 2
        self.DECK_POS = vmath.vector3(mid_x, self.CENTER.y, 0)
    else
        -- Standard 2-player match OR heads-up T4 finals: deck to the far right edge
        self.DECK_POS = vmath.vector3(right_edge - 130, LOGICAL_H / 2, 0)
    end

    M.fit_background(self)
    if self.player_hand and #self.player_hand > 0 then M.position_hands(self, false) end
    if self.ai_hand and #self.ai_hand > 0 then M.position_hands(self, false) end
    if self.deck then
        for i, c in ipairs(self.deck) do
            local p = go.get_position(c.id)
            go.set_position(vmath.vector3(self.DECK_POS.x + i * 0.5, self.DECK_POS.y - i * 0.5, p.z), c.id)
        end
    end
    if self.cutting_card then
        go.set_position(vmath.vector3(self.DECK_POS.x + CUTTING_CARD_OFFSET_X, self.DECK_POS.y, Z_CUT), self.cutting_card.id)
    end
end

return M