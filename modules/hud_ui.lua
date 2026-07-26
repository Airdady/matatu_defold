local M = {}

local AVATAR_CONTAINER_SIZE = 80
local AVATAR_BG_COLOR  = vmath.vector4(0, 0, 0, 0)
local TIMER_RADIUS = 46

local C_WHITE     = vmath.vector4(1.0, 1.0, 1.0, 1.0)
local C_T_GREEN   = vmath.vector4(0.13, 0.77, 0.37, 0.6)
local C_T_ORANGE  = vmath.vector4(0.96, 0.62, 0.04, 0.6)
local C_T_RED     = vmath.vector4(0.94, 0.27, 0.27, 0.6)

-- Expired-turn pulse. Once the countdown reaches zero the ring does NOT
-- disappear: it snaps to a full red circle and breathes until the turn
-- actually resolves (the opponent's move lands, the AI covers the seat, the
-- round ends...). A vanished ring read as "the game froze"; a full pulsing
-- one reads as "time's up, still waiting". Driven from M.update rather than
-- gui.animate so it stops the instant the timer is restarted or stopped, with
-- no stray looping animation left running on the node.
local EXPIRED_PULSE_SPEED     = 4.0  -- radians/sec => ~1.6s per full breath
local EXPIRED_PULSE_MIN_ALPHA = 0.28
local EXPIRED_PULSE_MAX_ALPHA = 0.85

local function box(pos, size, color, pivot)
    local n = gui.new_box_node(pos, size)
    gui.set_color(n, color)
    if pivot then gui.set_pivot(n, pivot) end
    return n
end

local function label(pos, text, size, color, align, font_name)
    local n = gui.new_text_node(pos, text)
    gui.set_font(n, font_name or "body")
    local base_size = (font_name == "subtitle2") and 36 or 24
    gui.set_scale(n, vmath.vector3(size / base_size, size / base_size, 1.0))
    gui.set_color(n, color or C_WHITE)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

local function build_network_badge(parent, pos)
    local bg = box(pos, vmath.vector3(80, 24, 0), vmath.vector4(0.1, 0.1, 0.1, 0.6), gui.PIVOT_CENTER)
    gui.set_parent(bg, parent)
    local bars = {}
    for i = 1, 3 do
        local h = i * 4 + 4
        local bar = box(vmath.vector3(-32 + (i * 6), -12 + h/2, 0), vmath.vector3(4, h, 0), C_T_GREEN, gui.PIVOT_CENTER)
        gui.set_parent(bar, bg)
        bars[i] = bar
    end
    local lbl = label(vmath.vector3(-5, 0, 0), "Good", 12, C_T_GREEN, gui.PIVOT_W, "subtitle2")
    gui.set_parent(lbl, bg)
    return { bg = bg, bars = bars, lbl = lbl }
end

function M.build(self, logical_w, logical_h)
    self.hud_root = box(vmath.vector3(120, logical_h/2, 0), vmath.vector3(160, 680, 0), vmath.vector4(0, 0, 0, 0), gui.PIVOT_CENTER)
    gui.set_xanchor(self.hud_root, gui.ANCHOR_LEFT)
    gui.set_yanchor(self.hud_root, gui.ANCHOR_NONE)

    self.o_net = build_network_badge(self.hud_root, vmath.vector3(0, 335, 0))
    self.o_avatar_bg = box(vmath.vector3(0, 275, 0), vmath.vector3(AVATAR_CONTAINER_SIZE, AVATAR_CONTAINER_SIZE, 0), AVATAR_BG_COLOR, gui.PIVOT_CENTER)
    gui.set_parent(self.o_avatar_bg, self.hud_root)

    self.o_timer = gui.new_pie_node(vmath.vector3(0, 0, 0), vmath.vector3(TIMER_RADIUS*2, TIMER_RADIUS*2, 0))
    gui.set_rotation(self.o_timer, vmath.vector3(0, 0, 90))
    gui.set_parent(self.o_timer, self.o_avatar_bg)
    gui.set_enabled(self.o_timer, false)

    self.o_avatar_img = box(vmath.vector3(0, 0, 0), vmath.vector3(AVATAR_CONTAINER_SIZE, AVATAR_CONTAINER_SIZE, 0), C_WHITE, gui.PIVOT_CENTER)
    gui.set_parent(self.o_avatar_img, self.o_avatar_bg)
    pcall(function() gui.set_texture(self.o_avatar_img, "avatars"); gui.play_flipbook(self.o_avatar_img, hash("avatar_1")) end)

    self.o_avatar_name = label(vmath.vector3(0, 215, 0), "Opponent", 18, C_WHITE, gui.PIVOT_CENTER, "subtitle2")
    gui.set_parent(self.o_avatar_name, self.hud_root)

    self.p_net = build_network_badge(self.hud_root, vmath.vector3(0, -215, 0))
    self.p_avatar_bg = box(vmath.vector3(0, -275, 0), vmath.vector3(AVATAR_CONTAINER_SIZE, AVATAR_CONTAINER_SIZE, 0), AVATAR_BG_COLOR, gui.PIVOT_CENTER)
    gui.set_parent(self.p_avatar_bg, self.hud_root)

    self.p_timer = gui.new_pie_node(vmath.vector3(0, 0, 0), vmath.vector3(TIMER_RADIUS*2, TIMER_RADIUS*2, 0))
    gui.set_rotation(self.p_timer, vmath.vector3(0, 0, 90))
    gui.set_parent(self.p_timer, self.p_avatar_bg)
    gui.set_enabled(self.p_timer, false)

    self.p_avatar_img = box(vmath.vector3(0, 0, 0), vmath.vector3(AVATAR_CONTAINER_SIZE, AVATAR_CONTAINER_SIZE, 0), C_WHITE, gui.PIVOT_CENTER)
    gui.set_parent(self.p_avatar_img, self.p_avatar_bg)
    pcall(function() gui.set_texture(self.p_avatar_img, "avatars"); gui.play_flipbook(self.p_avatar_img, hash("avatar_1")) end)

    self.p_balance = label(vmath.vector3(0, -335, 0), "Bal: 0", 14, vmath.vector4(1, 0.85, 0.4, 1.0), gui.PIVOT_CENTER, "body")
    gui.set_parent(self.p_balance, self.hud_root)
    gui.set_enabled(self.p_balance, false)
end

function M.setup_avatars(self, message)
    local o_name = (message.op_info and message.op_info.username) or (message.op_info and message.op_info.name) or "Opponent"
    if string.len(o_name) > 10 then o_name = string.sub(o_name, 1, 10) .. "..." end
    o_name = string.upper(o_name)
    self.opp_display_name = o_name

    if self.o_avatar_name then gui.set_text(self.o_avatar_name, o_name) end

    gui.set_enabled(self.p_balance, true)
    local bal = (message.my_info and message.my_info.balance) or 0
    if self.p_balance then gui.set_text(self.p_balance, "Bal: " .. tostring(bal)) end
    self.my_id = (message.my_info and message.my_info.id) or ""

    local p_av = (message.my_info and message.my_info.avatar) or 1
    local o_av = (message.op_info and message.op_info.avatar) or 1
    pcall(function() gui.play_flipbook(self.p_avatar_img, hash("avatar_" .. tostring(p_av))) end)
    pcall(function() gui.play_flipbook(self.o_avatar_img, hash("avatar_" .. tostring(o_av))) end)
end

function M.start_timer(self, is_player, duration, expires_at_ms)
    self.total_duration = duration or 30.0
    self.is_player_turn = is_player
    self.alert_played = false
    -- A response arrived (or a new turn began): drop the expired pulse so the
    -- fresh countdown starts from a clean full-alpha ring rather than
    -- inheriting whatever alpha the breathing animation was mid-way through.
    self.timer_expired = false
    self.pulse_t = 0

    if expires_at_ms and expires_at_ms > 0 then
        local now_ms = socket.gettime() * 1000.0
        local remaining = (expires_at_ms - now_ms) / 1000.0
        self.timer_remaining = math.max(0, math.min(remaining, self.total_duration))
    else
        self.timer_remaining = self.total_duration
    end

    if is_player then
        if self.p_timer then
            gui.set_fill_angle(self.p_timer, (self.timer_remaining / self.total_duration) * 360)
            gui.set_color(self.p_timer, C_T_GREEN)
            gui.set_enabled(self.p_timer, true)
        end
        if self.o_timer then gui.set_enabled(self.o_timer, false) end
    else
        if self.o_timer then
            gui.set_fill_angle(self.o_timer, (self.timer_remaining / self.total_duration) * 360)
            gui.set_color(self.o_timer, C_T_GREEN)
            gui.set_enabled(self.o_timer, true)
        end
        if self.p_timer then gui.set_enabled(self.p_timer, false) end
    end
end

function M.stop_timers(self)
    if self.p_timer then gui.set_enabled(self.p_timer, false) end
    if self.o_timer then gui.set_enabled(self.o_timer, false) end
    self.timer_remaining = 0
    -- Clear the latch too: without this the pulse branch would immediately
    -- re-enable the ring it was just asked to hide.
    self.timer_expired = false
    self.pulse_t = 0
end

-- Fully hide the persistent avatar + turn-timer chrome. Used when the board is
-- torn down (leaving the game) so nothing from the HUD — most visibly the
-- current player's timer ring and its square avatar container — lingers on top
-- of other screens. A fresh game re-shows it via set_t4_mode / setup_avatars.
function M.hide_player_chrome(self)
    local nodes = {
        self.p_avatar_bg, self.o_avatar_bg, self.o_avatar_name,
        self.p_balance, self.p_timer, self.o_timer,
    }
    -- pairs, not ipairs: ipairs stops dead at the first nil, so if any node
    -- earlier in this list hadn't been built yet, everything after it —
    -- including both timer rings — silently stayed visible. That was latent
    -- before; now that the expired ring re-enables itself every frame, a
    -- missed hide would leave a pulsing timer stranded over the next screen.
    for _, n in pairs(nodes) do if n then gui.set_enabled(n, false) end end
    if self.p_net and self.p_net.bg then gui.set_enabled(self.p_net.bg, false) end
    if self.o_net and self.o_net.bg then gui.set_enabled(self.o_net.bg, false) end
    -- Same reason as stop_timers: the pulse branch re-enables the ring every
    -- frame, so tearing the board down has to drop the latch or the timer
    -- would reappear over whatever screen comes next.
    self.timer_expired = false
    self.pulse_t = 0
end

function M.update(self, dt)
    local active_pie = self.is_player_turn and self.p_timer or self.o_timer

    -- Expired and still waiting: hold a FULL red ring and pulse it. This runs
    -- outside the countdown branch below, which only ticks while there is time
    -- left — that guard is why the ring used to freeze on its last drawn frame
    -- and then vanish, instead of persisting.
    if self.timer_expired then
        if active_pie then
            self.pulse_t = (self.pulse_t or 0) + dt
            local wave = 0.5 + 0.5 * math.sin(self.pulse_t * EXPIRED_PULSE_SPEED)
            local alpha = EXPIRED_PULSE_MIN_ALPHA
                + (EXPIRED_PULSE_MAX_ALPHA - EXPIRED_PULSE_MIN_ALPHA) * wave
            gui.set_enabled(active_pie, true)
            gui.set_fill_angle(active_pie, 360)
            gui.set_color(active_pie, vmath.vector4(C_T_RED.x, C_T_RED.y, C_T_RED.z, alpha))
        end
        return
    end

    if self.timer_remaining and self.timer_remaining > 0 then
        self.timer_remaining = self.timer_remaining - dt
        if self.timer_remaining < 0 then self.timer_remaining = 0 end

        local progress = math.min(1.0, self.timer_remaining / self.total_duration)

        if active_pie then
            gui.set_fill_angle(active_pie, progress * 360)
            local c = C_T_RED
            if self.timer_remaining > self.total_duration / 2.0 then
                c = C_T_GREEN
            elseif self.timer_remaining > 5.0 then
                local t = 1.0 - ((self.timer_remaining - 5.0) / (self.total_duration / 2.0 - 5.0))
                c = vmath.lerp(t, C_T_GREEN, C_T_ORANGE)
            else
                local t = 1.0 - (self.timer_remaining / 5.0)
                c = vmath.lerp(t, C_T_ORANGE, C_T_RED)
            end
            gui.set_color(active_pie, c)

            if self.timer_remaining <= 10.0 and self.timer_remaining > 0 and self.is_player_turn and not self.alert_played then
                self.alert_played = true
                msg.post("/controller#snd_alert", "play_sound")
            end
        end

        -- Crossing zero: latch into the pulsing state and notify once. The
        -- notify stays inside this branch (rather than the pulse branch) so it
        -- can only ever fire on the single frame the countdown ran out, no
        -- matter how long the wait for a response then lasts.
        if self.timer_remaining <= 0 then
            self.timer_expired = true
            self.pulse_t = 0
            if self.is_player_turn and not self.is_t4_mode then
                msg.post("/controller#game_logic", "timer_expired")
            end
        end
    end
end

function M.update_network_quality(self, message)
    local badge = (message.user_id == self.my_id) and self.p_net or self.o_net
    if not badge then return end
    local ms = message.latency_ms or 0
    local txt, col = "Good", C_T_GREEN
    local active_bars = 3
    
    if ms >= 500 then 
        txt, col = "Poor", C_T_RED
        active_bars = 1
    elseif ms >= 200 then 
        txt, col = "Fair", vmath.vector4(0.98, 0.75, 0.14, 1.0) 
        active_bars = 2
    end

    gui.set_text(badge.lbl, txt)
    gui.set_color(badge.lbl, col)
    
    if badge.bars then
        for i = 1, 3 do
            local bar_color = (i <= active_bars) and col or vmath.vector4(0.3, 0.3, 0.3, 1.0)
            gui.set_color(badge.bars[i], bar_color)
        end
    end
end

function M.set_t4_mode(self, on)
    if on then
        if self.p_avatar_bg then gui.set_enabled(self.p_avatar_bg, false) end
        if self.o_avatar_bg then gui.set_enabled(self.o_avatar_bg, false) end
        if self.o_avatar_name then gui.set_enabled(self.o_avatar_name, false) end
        if self.p_net and self.p_net.bg then gui.set_enabled(self.p_net.bg, false) end
        if self.o_net and self.o_net.bg then gui.set_enabled(self.o_net.bg, false) end
        if self.p_balance then gui.set_enabled(self.p_balance, false) end
    else
        if self.p_avatar_bg then gui.set_enabled(self.p_avatar_bg, true) end
        if self.o_avatar_bg then gui.set_enabled(self.o_avatar_bg, true) end
        if self.o_avatar_name then gui.set_enabled(self.o_avatar_name, true) end
        if self.p_net and self.p_net.bg then gui.set_enabled(self.p_net.bg, true) end
        if self.o_net and self.o_net.bg then gui.set_enabled(self.o_net.bg, true) end
        if self.p_balance then gui.set_enabled(self.p_balance, true) end
    end
end

return M