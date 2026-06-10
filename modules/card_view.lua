----------------------------------------------------------------------
-- card_view.lua
-- Everything that draws or animates a single card object: sprite faces,
-- spawning, the fly-to-pile commit, the riffle-shuffle choreography, and
-- the invalid-play shake. Pure visuals — no rule decisions here.
--
-- Sounds are routed through self.play_sound (wired in game.script init),
-- which keeps this module decoupled from the sound map.
----------------------------------------------------------------------
local Defs = require "modules.card_defs"
local util = require "modules.game_util"
local BL   = require "modules.board_layout"

local M = {}

local CARD_SCALE_F = BL.CARD_SCALE_F
local CARD_SCALE   = BL.CARD_SCALE
local PILE_OFFSET_X, PILE_OFFSET_Y = BL.PILE_OFFSET_X, BL.PILE_OFFSET_Y
local Z_PILE, Z_FLY = BL.Z_PILE, BL.Z_FLY

local rand_range = util.rand_range

----------------------------------------------------------------------
-- Sprite helpers
----------------------------------------------------------------------
function M.sprite_url(card) return msg.url(nil, card.id, "sprite") end
function M.set_face(card) sprite.play_flipbook(M.sprite_url(card), hash(Defs.frame_name(card))) end
function M.set_back(card) sprite.play_flipbook(M.sprite_url(card), hash(Defs.back_frame())) end

----------------------------------------------------------------------
-- Spawn a face-down card object
----------------------------------------------------------------------
function M.spawn_card(v, s, pos)
    local id = factory.create("#card_factory", pos, nil, {})
    local rec = { id = id, v = v, s = s }
    go.set(id, "scale", CARD_SCALE)
    M.set_back(rec)
    return rec
end

----------------------------------------------------------------------
-- Commit a card to the pile
----------------------------------------------------------------------
function M.animate_to_pile(self, rec, is_player, on_done)
    if not is_player then M.set_face(rec) end
    table.insert(self.played_cards, rec)
    local offset = vmath.vector3(rand_range(-PILE_OFFSET_X, PILE_OFFSET_X), rand_range(-PILE_OFFSET_Y, PILE_OFFSET_Y), 0)
    local rot = rand_range(-32, 32)
    local z = Z_PILE + #self.played_cards * 0.001
    local target = vmath.vector3(self.CENTER.x + offset.x, self.CENTER.y + offset.y, z)
    rec.pile_offset = offset
    go.set(rec.id, "position.z", Z_FLY)
    go.set(rec.id, "scale", CARD_SCALE)
    local seq = self._seq
    go.animate(rec.id, "position", go.PLAYBACK_ONCE_FORWARD, target, go.EASING_OUTCUBIC, 0.42, 0, function()
        if seq ~= self._seq then return end
        go.set(rec.id, "position.z", z)
        if on_done then on_done() end
    end)
    go.animate(rec.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, rot, go.EASING_OUTCUBIC, 0.42)
end

----------------------------------------------------------------------
-- Riffle-shuffle choreography over a set of visual cards
----------------------------------------------------------------------
function M.animate_shuffle(self, visual_cards, done)
    local n = #visual_cards
    if n == 0 then if done then done() end return end

    local seq    = self._seq
    local cx, cy = self.CENTER.x, self.CENTER.y
    local base_s = CARD_SCALE_F

    local half  = math.ceil(n / 2)
    local left, right = {}, {}
    for i = 1, n do
        if i <= half then left[#left + 1] = visual_cards[i]
        else right[#right + 1] = visual_cards[i] end
    end

    local SPLIT_X     = 165
    local LIFT        = 12
    local PACKET_TILT = 6
    local FAN         = 5
    local STACK_DX    = 0.7
    local SPLIT_DUR   = 0.28
    local STEP        = 0.015
    local CARD_DUR    = 0.20
    local POP         = 1.07
    local SQUARE_DUR  = 0.16

    local function spread_packet(packet, dir)
        local cnt = #packet
        for i, c in ipairs(packet) do
            local frac = (cnt > 1) and ((i - 1) / (cnt - 1)) or 0
            local px = cx + dir * (SPLIT_X - i * STACK_DX)
            local py = cy + LIFT + i * 0.25
            local tilt = dir * (PACKET_TILT + frac * FAN)
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
                vmath.vector3(px, py, 0.4 + i * 0.001), go.EASING_OUTCUBIC, SPLIT_DUR)
            go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, tilt, go.EASING_OUTCUBIC, SPLIT_DUR)
        end
    end
    spread_packet(left,  -1)
    spread_packet(right,  1)

    local merged = {}
    local li, ri, take_left = 1, 1, true
    while li <= #left or ri <= #right do
        if take_left and li <= #left then
            merged[#merged + 1] = left[li]; li = li + 1
        elseif (not take_left) and ri <= #right then
            merged[#merged + 1] = right[ri]; ri = ri + 1
        elseif li <= #left then
            merged[#merged + 1] = left[li]; li = li + 1
        else
            merged[#merged + 1] = right[ri]; ri = ri + 1
        end
        take_left = not take_left
    end

    local riffle_start  = SPLIT_DUR + 0.05
    local cascade_total = #merged * STEP

    timer.delay(riffle_start, false, function()
        if seq ~= self._seq then return end
        self.play_sound("SoundShuffle")
        for k, c in ipairs(merged) do
            local d  = (k - 1) * STEP
            local fx = cx + rand_range(-5, 5)
            local fy = cy + rand_range(-4, 4)
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
                vmath.vector3(fx, fy, 0.1 + k * 0.001), go.EASING_OUTBACK, CARD_DUR, d)
            go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, rand_range(-3, 3), go.EASING_OUTCUBIC, CARD_DUR, d)
            go.animate(c.id, "scale", go.PLAYBACK_ONCE_PINGPONG,
                vmath.vector3(base_s * POP, base_s * POP, 1), go.EASING_INOUTSINE, CARD_DUR, d)
        end
    end)

    local total = riffle_start + cascade_total + CARD_DUR + 0.06
    timer.delay(total, false, function()
        if seq ~= self._seq then return end
        for k, c in ipairs(merged) do
            go.animate(c.id, "position", go.PLAYBACK_ONCE_FORWARD,
                vmath.vector3(cx + k * 0.5, cy - k * 0.5, 0.1 + k * 0.001), go.EASING_INOUTSINE, SQUARE_DUR)
            go.animate(c.id, "euler.z", go.PLAYBACK_ONCE_FORWARD, 0, go.EASING_INOUTSINE, SQUARE_DUR)
            go.animate(c.id, "scale", go.PLAYBACK_ONCE_FORWARD,
                vmath.vector3(base_s, base_s, 1), go.EASING_OUTSINE, SQUARE_DUR)
        end
        timer.delay(SQUARE_DUR + 0.05, false, function()
            if seq == self._seq and done then done() end
        end)
    end)
end

----------------------------------------------------------------------
-- Invalid-play shake: horizontal jolt only.
----------------------------------------------------------------------
function M.shake_card(self, rec)
    if not rec or not rec.id then return end
    local id     = rec.id
    local seq    = self._seq
    local anchor = go.get_position(id)

    self.play_sound("SoundInvalid")

    local function step(x, dur, easing, nxt)
        go.animate(id, "position.x", go.PLAYBACK_ONCE_FORWARD, x, easing, dur, 0, function()
            if seq ~= self._seq then return end
            if nxt then nxt() end
        end)
    end

    step(anchor.x + 14, 0.05, go.EASING_OUTSINE, function()
        step(anchor.x - 14, 0.06, go.EASING_INOUTSINE, function()
            step(anchor.x + 8,  0.05, go.EASING_INOUTSINE, function()
                step(anchor.x,   0.05, go.EASING_OUTSINE, nil)
            end)
        end)
    end)
end

return M
