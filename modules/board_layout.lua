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
    local target_w, target_h = LOGICAL_W, LOGICAL_H
    if screen_aspect > logical_aspect then target_w = LOGICAL_H * screen_aspect
    else target_h = LOGICAL_W / screen_aspect end
    local img_w = self.bg_img_w or LOGICAL_W
    local img_h = self.bg_img_h or LOGICAL_H
    local sf = math.max(target_w / img_w, target_h / img_h)
    pcall(function() go.set("#background", "scale", vmath.vector3(sf, sf, 1.0)) end)
end

----------------------------------------------------------------------
-- Deck stacking helpers
-- Higher index = nearer the TOP of the visual stack (drawn first, higher z).
-- Lower index sits below (rendered behind, drawn last) — this is what lets
-- freshly shuffled cards tuck UNDER the old deck cards during a reshuffle.
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
    for i, c in ipairs(hand) do
        local z = Z_HAND + i * 0.001
        local target = vmath.vector3(start + (i - 1) * spacing, y, z)
        if animate then
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD, target, go.EASING_OUTSINE, 0.42)
        else
            go.set_position(target, c.id)
        end
        go.set(c.id, "euler.z", 0)
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
    self.DECK_POS = vmath.vector3(right_edge - 130, LOGICAL_H / 2, 0)

    self.MAX_HAND_WIDTH = math.min(1100, vis_w - 400)
    self.PLAYER_HAND_Y  = bottom_edge + 96
    self.AI_HAND_Y      = top_edge - 96

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
