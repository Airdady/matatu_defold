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
----------------------------------------------------------------------
-- Deterministic pile scatter
-- The same (game seed, pile index) always lands a card on the same
-- random-looking offset + rotation, so a resumed game can rebuild the
-- discard pile EXACTLY as the player left it. Online games seed from the
-- game id (stable across app restarts); offline games roll a fresh seed.
----------------------------------------------------------------------
function M.seed_from_string(s)
    local h = 5381
    s = tostring(s or "")
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 2147483647
    end
    return h
end

function M.pile_scatter(self, idx)
    local h = ((self.scatter_seed or 1) + idx * 2654435761) % 2147483647
    local function nxt()
        h = (h * 48271) % 2147483647
        return h / 2147483647
    end
    local ox = (nxt() * 2 - 1) * PILE_OFFSET_X
    local oy = (nxt() * 2 - 1) * PILE_OFFSET_Y
    local rot = (nxt() * 2 - 1) * 32
    return ox, oy, rot
end

function M.animate_to_pile(self, rec, is_player, on_done)
    if not is_player then M.set_face(rec) end
    table.insert(self.played_cards, rec)
    local pile_idx = (self.pile_index_base or 0) + #self.played_cards
    local ox, oy, rot = M.pile_scatter(self, pile_idx)
    local offset = vmath.vector3(ox, oy, 0)
    local z = Z_PILE + #self.played_cards * 0.001
    local target = vmath.vector3(self.CENTER.x + offset.x, self.CENTER.y + offset.y, z)
    rec.pile_offset = offset
    -- Leaving the hand: forget the remembered hand slot so a future return
    -- to a hand (reshuffle -> deck -> draw) always animates from scratch
    -- instead of being skipped by layout_hand's same-slot check.
    rec._hand_target = nil
    -- Cancel any animation still running on this card before forcing it back
    -- to full pile scale — most importantly the opponent-hand shrink tween
    -- (board_layout.lua's layout_hand, started when this card was drawn).
    -- go.set does NOT cancel an in-flight go.animate on the same property;
    -- an uncancelled shrink tween would keep overwriting the scale we set
    -- below on every subsequent frame, silently undoing it and leaving the
    -- card stuck at the smaller opponent-hand size once it's in the pile —
    -- exactly the "draw and play" scale bug (drawing starts the 0.42s
    -- shrink, and playing that same card before it finishes races it).
    go.cancel_animations(rec.id, "scale")
    go.cancel_animations(rec.id, "position")
    go.cancel_animations(rec.id, "euler.z")
    go.set(rec.id, "position.z", Z_FLY)
    go.set(rec.id, "scale", CARD_SCALE)
    local seq = self._seq
    -- Snapshot the reshuffle generation now, before the 0.42s flight starts.
    -- reshuffle_deck (game_flow.lua) / reshuffle_if_needed (tournament4.lua)
    -- both bump self.pile_gen the instant they run, and immediately give the
    -- retained "top" card (which, if it's this very card, can only be the
    -- most-recently-played one) its own correct low z right then. If a
    -- reshuffle happens while THIS card is still mid-flight, applying the
    -- z captured above afterward would stomp that already-correct reset
    -- back to a stale, high value — which is exactly what let the old
    -- discard-pile anchor render above every card played after a reshuffle.
    local my_gen = self.pile_gen or 0
    go.animate(rec.id, "position", go.PLAYBACK_ONCE_FORWARD, target, go.EASING_OUTCUBIC, 0.42, 0, function()
        if seq ~= self._seq then return end
        if (self.pile_gen or 0) == my_gen then
            go.set(rec.id, "position.z", z)
        end
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
-- Pinch-to-view-history: fan the played pile out into a ring, release to
-- snap them home. Ported 1:1 from the Godot CardManager._start/_end_history_view
-- (radial spread, QUART ease-out over 0.4s; restore over 0.2s).
----------------------------------------------------------------------
local MIN_HISTORY_OFFSET = 82      -- target arc spacing (logical px) per card
local HISTORY_VIEW_SCALE = 0.85    -- cards shrink to this fraction while fanned

function M.is_viewing_history(self) return self.is_viewing_history == true end

function M.start_history_view(self)
    if self.is_viewing_history then return end
    local cards = self.played_cards or {}
    local count = #cards
    if count == 0 then return end

    self.is_viewing_history = true
    self.history_restore = {}

    local cx, cy = self.CENTER.x, self.CENTER.y

    -- Radius sized so the cards are evenly spaced around the ring, clamped so the
    -- ring always fits on screen (mirrors the Godot spacing maths).
    local min_screen_dim   = math.min(BL.LOGICAL_W, BL.LOGICAL_H)
    local max_radius       = (min_screen_dim / 2.0) - 110.0
    local radius_spacing   = (count * MIN_HISTORY_OFFSET) / (2 * math.pi)
    local min_hole         = 40.0
    local start_radius     = math.max(radius_spacing, min_hole)
    if start_radius > max_radius then start_radius = max_radius end
    if start_radius < min_hole  then start_radius = min_hole  end

    local angle_step    = (2 * math.pi) / count
    local start_angle   = -math.pi / 2
    local spiral_growth = (start_radius >= max_radius) and 10.0 or 30.0

    local view_scale = BL.CARD_SCALE_F * HISTORY_VIEW_SCALE

    for i = 1, count do
        local rec = cards[i]
        if rec and rec.id then
            -- Snapshot the exact pose so the release animation restores it 1:1.
            self.history_restore[#self.history_restore + 1] = {
                id    = rec.id,
                pos   = go.get_position(rec.id),
                rot   = go.get(rec.id, "euler.z"),
                scale = go.get(rec.id, "scale"),
            }

            local progress = (i - 1) / count
            local radius   = start_radius + progress * spiral_growth
            local angle    = start_angle + (i - 1) * angle_step
            local tx       = cx + math.cos(angle) * radius
            local ty       = cy + math.sin(angle) * radius
            local trot     = math.deg(angle + math.pi / 2)
            local tz       = Z_FLY + 0.1 + i * 0.001  -- ride above the rest of the board

            go.cancel_animations(rec.id, "position")
            go.cancel_animations(rec.id, "euler.z")
            go.cancel_animations(rec.id, "scale")
            go.animate(rec.id, "position", go.PLAYBACK_ONCE_FORWARD, vmath.vector3(tx, ty, tz), go.EASING_OUTQUART, 0.4)
            go.animate(rec.id, "euler.z",  go.PLAYBACK_ONCE_FORWARD, trot, go.EASING_OUTQUART, 0.4)
            go.animate(rec.id, "scale",    go.PLAYBACK_ONCE_FORWARD, vmath.vector3(view_scale, view_scale, 1), go.EASING_OUTQUART, 0.4)
        end
    end
end

function M.end_history_view(self)
    if not self.is_viewing_history then return end
    self.is_viewing_history = false

    for _, data in ipairs(self.history_restore or {}) do
        if data.id then
            go.cancel_animations(data.id, "position")
            go.cancel_animations(data.id, "euler.z")
            go.cancel_animations(data.id, "scale")
            go.animate(data.id, "position", go.PLAYBACK_ONCE_FORWARD, data.pos,   go.EASING_OUTQUAD, 0.2)
            go.animate(data.id, "euler.z",  go.PLAYBACK_ONCE_FORWARD, data.rot,   go.EASING_OUTQUAD, 0.2)
            go.animate(data.id, "scale",    go.PLAYBACK_ONCE_FORWARD, data.scale, go.EASING_OUTQUAD, 0.2)
        end
    end
    self.history_restore = {}
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
