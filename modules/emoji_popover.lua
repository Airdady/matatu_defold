local M = {}

local LOGICAL_W = 1280
local LOGICAL_H = 720
local C_SCORE_LBL = vmath.vector4(0.61, 0.64, 0.68, 1.0)
local C_TEXT = vmath.vector4(0.95, 0.97, 0.95, 1.0)
local C_GOLD = vmath.vector4(1.0, 0.84, 0.35, 1.0)
local GAME = "/controller#game_logic"

local EMOJI_SERIES = {
    { name = "joy",        anim = "face_with_tears_of_joy",       sounds = { {id="snd_laugh_mzeei", lbl="Laugh Mzeei"}, {id="snd_kawedemu", lbl="Kawedemu"}, {id="snd_igoing", lbl="Igoing"}, {id="snd_avuga_obula", lbl="Avuga Obula"} } },
    { name = "tongue",     anim = "face_with_tongue",             sounds = { {id="snd_kawedemu", lbl="Kawedemu"}, {id="snd_mbooko", lbl="Mbooko"}, {id="snd_kasongo", lbl="Kasongo"}, {id="snd_towedde", lbl="Towedde"}, {id="snd_towedde_alt", lbl="Towedde Alt"} } },
    { name = "hot",        anim = "hot_face",                     sounds = { {id="snd_banamwe", lbl="Banamwe"}, {id="snd_oh_my_god", lbl="Oh My God"}, {id="snd_abarongo", lbl="Abarongo"}, {id="snd_eheh", lbl="Eheh"}, {id="snd_i_wonder", lbl="I Wonder"} } },
    { name = "money",      anim = "money_mouth_face",             sounds = { {id="snd_kigozi", lbl="Kigozi"}, {id="snd_olyaa", lbl="Olyaa"}, {id="snd_connecting", lbl="Connecting"} } },
    { name = "party",      anim = "partying_face",                sounds = { {id="snd_bamukubye", lbl="Bamukubye"}, {id="snd_omukwomu", lbl="Omukwomu"}, {id="snd_kigozi", lbl="Kigozi"}, {id="snd_kawedemu", lbl="Kawedemu"}, {id="snd_towedde", lbl="Towedde"}, {id="snd_towedde_alt", lbl="Towedde Alt"} } },
    { name = "sleep",      anim = "sleeping_face",                sounds = { {id="snd_snoring", lbl="Snoring"} } },
    { name = "thumbsdown", anim = "thumbs_down",                  sounds = { {id="snd_i_cant_accept_that", lbl="I Can't Accept That"}, {id="snd_togenda_kuba", lbl="Togenda Kuba"}, {id="snd_tokirizibwa", lbl="Tokirizibwa"} } },
    { name = "wave",       anim = "waving_hand_animated_default", sounds = { {id="snd_goodbye", lbl="Goodbye"} } },
}

local EMOJI_VALID = {}
for _, e in ipairs(EMOJI_SERIES) do EMOJI_VALID[e.name] = true end
local EMOJI_MAX_SOUNDS = 6

local CELL_SIZE = 64
local THUMB_SCALE = 1.3
local FLY_SIZE = 96

-- Top-left destination in absolute screen space (where opponent emoji lands)
local DEST_X = 70
local DEST_Y = LOGICAL_H - 70

local function play_sound(sound_id)
    if not sound_id or sound_id == "" then return end
    msg.post("/controller#" .. sound_id, "play_sound")
end

local function box(pos, size, color, pivot)
    local n = gui.new_box_node(pos, size)
    gui.set_color(n, color)
    if pivot then gui.set_pivot(n, pivot) end
    return n
end

local function label(pos, text, size, color, align)
    local n = gui.new_text_node(pos, text)
    gui.set_font(n, "body")
    gui.set_scale(n, vmath.vector3(size / 24, size / 24, 1.0))
    gui.set_color(n, color or C_TEXT)
    gui.set_pivot(n, align or gui.PIVOT_CENTER)
    return n
end

local function hit(node, action)
    if not node then return false end
    return gui.is_enabled(node) and gui.pick_node(node, action.x, action.y)
end

-- Convert a world-space absolute position into local space of a given parent node.
-- For nodes parented directly to the gui root (no parent), world == local.
local function world_to_local(parent_node, world_pos)
    local parent_world = gui.get_position(parent_node)
    return vmath.vector3(
        world_pos.x - parent_world.x,
        world_pos.y - parent_world.y,
        0
    )
end

function M.init(self)
    local btn_size = 140
    local gap = 16
    local p_w = 368
    local GRID_H = 230
    
    -- Margins adjusted to push the button further bottom/right (was 10)
    local MARGIN_RIGHT = 0
    local MARGIN_BOTTOM = -5

    self.GRID_H = GRID_H
    self.p_w = p_w

    self.emoji_btn = box(vmath.vector3(LOGICAL_W - MARGIN_RIGHT - btn_size/2, MARGIN_BOTTOM + btn_size/2, 0), vmath.vector3(btn_size, btn_size, 0), vmath.vector4(1,1,1,1), gui.PIVOT_CENTER)
    gui.set_xanchor(self.emoji_btn, gui.ANCHOR_RIGHT)
    gui.set_yanchor(self.emoji_btn, gui.ANCHOR_BOTTOM)
    pcall(function() gui.set_texture(self.emoji_btn, "emojis"); gui.play_flipbook(self.emoji_btn, hash("emoji_btn")) end)

    self.flight_anchor = box(vmath.vector3(LOGICAL_W - MARGIN_RIGHT - p_w/2, MARGIN_BOTTOM + btn_size + gap, 0), vmath.vector3(1,1,0), vmath.vector4(0,0,0,0), gui.PIVOT_S)
    gui.set_xanchor(self.flight_anchor, gui.ANCHOR_RIGHT)
    gui.set_yanchor(self.flight_anchor, gui.ANCHOR_BOTTOM)

    self.popover_anchor = box(vmath.vector3(LOGICAL_W - MARGIN_RIGHT - p_w/2, MARGIN_BOTTOM + btn_size + gap, 0), vmath.vector3(1,1,0), vmath.vector4(0,0,0,0), gui.PIVOT_S)
    gui.set_xanchor(self.popover_anchor, gui.ANCHOR_RIGHT)
    gui.set_yanchor(self.popover_anchor, gui.ANCHOR_BOTTOM)
    gui.set_enabled(self.popover_anchor, false)

    local pointer_offset_x = p_w/2 - btn_size/2
    self.emoji_pointer = box(vmath.vector3(pointer_offset_x, 0, 0), vmath.vector3(32, 32, 0), vmath.vector4(0.07, 0.08, 0.11, 0.98), gui.PIVOT_CENTER)
    gui.set_rotation(self.emoji_pointer, vmath.vector3(0, 0, 45))
    gui.set_parent(self.emoji_pointer, self.popover_anchor)

    self.popover_bg = box(vmath.vector3(0, 0, 0), vmath.vector3(p_w, GRID_H, 0), vmath.vector4(0.07, 0.08, 0.11, 0.98), gui.PIVOT_S)
    gui.set_parent(self.popover_bg, self.popover_anchor)

    self.clipping_box = box(vmath.vector3(0, 0, 0), vmath.vector3(p_w, GRID_H, 0), vmath.vector4(1,1,1,0), gui.PIVOT_S)
    gui.set_clipping_mode(self.clipping_box, gui.CLIPPING_MODE_STENCIL)
    gui.set_clipping_inverted(self.clipping_box, false)
    gui.set_clipping_visible(self.clipping_box, false)
    gui.set_parent(self.clipping_box, self.popover_bg)

    self.grid_root = box(vmath.vector3(0, 0, 0), vmath.vector3(1, 1, 0), vmath.vector4(1,1,1,0), gui.PIVOT_S)
    gui.set_parent(self.grid_root, self.clipping_box)

    self.sound_root = box(vmath.vector3(p_w, 0, 0), vmath.vector3(1, 1, 0), vmath.vector4(1,1,1,0), gui.PIVOT_S)
    gui.set_parent(self.sound_root, self.clipping_box)

    -- Floating Active Thumbnail (unclipped, uses live animated flipbook)
    self.active_thumb = box(vmath.vector3(0, 0, 0), vmath.vector3(CELL_SIZE, CELL_SIZE, 0), vmath.vector4(1,1,1,1), gui.PIVOT_CENTER)
    gui.set_parent(self.active_thumb, self.popover_anchor)
    gui.set_enabled(self.active_thumb, false)

    self.emoji_cells = {}
    for i, e in ipairs(EMOJI_SERIES) do
        local c, r = (i-1) % 4, math.floor((i-1)/4)
        local px = -126 + c * 84
        local py = 166 - r * 84
        local n = box(vmath.vector3(px, py, 0), vmath.vector3(CELL_SIZE, CELL_SIZE, 0), vmath.vector4(1,1,1,1), gui.PIVOT_CENTER)
        gui.set_parent(n, self.grid_root)
        pcall(function() gui.set_texture(n, "emojis"); gui.play_flipbook(n, hash(e.anim .. "_00")) end)
        self.emoji_cells[i] = { node = n, idx = i, local_pos = vmath.vector3(px, py, 0) }
    end

    self.emoji_sound_title = label(vmath.vector3(-p_w/2 + 24, 30, 0), "SELECT SOUND", 15, C_GOLD, gui.PIVOT_W)
    gui.set_parent(self.emoji_sound_title, self.sound_root)

    self.emoji_back = box(vmath.vector3(p_w/2 - 44, 30, 0), vmath.vector3(60, 36, 0), vmath.vector4(1,1,1,0.08), gui.PIVOT_CENTER)
    gui.set_parent(self.emoji_back, self.sound_root)
    local bx = label(vmath.vector3(0, 0, 0), "BACK", 12, C_SCORE_LBL, gui.PIVOT_CENTER)
    gui.set_parent(bx, self.emoji_back)

    self.emoji_sound_rows = {}
    local row_h = 46
    local row_w = p_w - 40
    for i = 1, EMOJI_MAX_SOUNDS do
        local rbg = box(vmath.vector3(0, 0, 0), vmath.vector3(row_w, row_h-8, 0), vmath.vector4(1,1,1,0.06), gui.PIVOT_CENTER)
        gui.set_parent(rbg, self.sound_root)

        local ricon = box(vmath.vector3(-row_w/2 + 28, 0, 0), vmath.vector3(24, 24, 0), C_GOLD, gui.PIVOT_CENTER)
        pcall(function() gui.set_texture(ricon, "ui"); gui.play_flipbook(ricon, hash("sound")) end)
        pcall(function() gui.set_inherit_alpha(ricon, false) end)
        gui.set_parent(ricon, rbg)

        local rlbl = label(vmath.vector3(-row_w/2 + 52, 0, 0), "", 20, C_TEXT, gui.PIVOT_W)
        gui.set_parent(rlbl, rbg)

        self.emoji_sound_rows[i] = { bg = rbg, lbl = rlbl, icon = ricon }
    end

    self.emoji_open = false
    self.emoji_closing = false
    self.emoji_touch_captured = false
    self.emoji_view = "grid"
    self.emoji_fx = {}
end

function M.close(self)
    if not self.emoji_open and not self.emoji_closing then return end
    
    self.emoji_open = false
    self.emoji_closing = true
    
    gui.cancel_animation(self.popover_anchor, "scale")
    gui.animate(self.popover_anchor, "scale", vmath.vector3(0.01, 0.01, 1), gui.EASING_INBACK, 0.2, 0, function()
        gui.set_enabled(self.popover_anchor, false)
        gui.set_size(self.popover_bg, vmath.vector3(self.p_w, self.GRID_H, 0))
        gui.set_size(self.clipping_box, vmath.vector3(self.p_w, self.GRID_H, 0))
        gui.set_position(self.grid_root, vmath.vector3(0, 0, 0))
        gui.set_position(self.sound_root, vmath.vector3(self.p_w, 0, 0))
        gui.set_enabled(self.active_thumb, false)
        self.emoji_closing = false
        
        -- Notify the main game controller that the popover has closed AFTER animation
        msg.post(GAME, "emoji_state", { open = false })
    end)
end

function M.reset(self)
    gui.set_enabled(self.popover_anchor, false)
    self.emoji_open = false
    self.emoji_closing = false
    
    -- Notify the main game controller to unlock screen touches
    msg.post(GAME, "emoji_state", { open = false })
    
    for k, n in pairs(self.emoji_fx or {}) do
        pcall(gui.delete_node, n)
        self.emoji_fx[k] = nil
    end
end

local function emoji_show_grid(self)
    gui.cancel_animation(self.popover_anchor, "scale")
    self.emoji_closing = false
    self.emoji_open = true
    self.emoji_view = "grid"
    
    -- Notify the main game controller to block card/deck touches
    msg.post(GAME, "emoji_state", { open = true })

    gui.set_size(self.popover_bg, vmath.vector3(self.p_w, self.GRID_H, 0))
    gui.set_size(self.clipping_box, vmath.vector3(self.p_w, self.GRID_H, 0))
    gui.set_position(self.grid_root, vmath.vector3(0, 0, 0))
    gui.set_position(self.sound_root, vmath.vector3(self.p_w, 0, 0))
    gui.set_enabled(self.active_thumb, false)

    gui.set_scale(self.popover_anchor, vmath.vector3(0.01, 0.01, 1))
    gui.set_enabled(self.popover_anchor, true)
    gui.animate(self.popover_anchor, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.3)
end

local function transition_to_sounds(self, cell)
    self.emoji_view = "sounds"
    local e = EMOJI_SERIES[cell.idx]
    self.emoji_sel = cell.idx

    -- Use the live animated flipbook so the thumbnail keeps animating
    pcall(function()
        gui.set_texture(self.active_thumb, "emojis")
        gui.play_flipbook(self.active_thumb, hash(e.anim))
    end)
    gui.set_position(self.active_thumb, cell.local_pos)
    gui.set_scale(self.active_thumb, vmath.vector3(1, 1, 1))
    gui.set_color(self.active_thumb, vmath.vector4(1, 1, 1, 1))
    gui.set_enabled(self.active_thumb, true)

    local num_sounds = #e.sounds
    local row_h = 46
    local target_h = math.max(self.GRID_H, 60 + (num_sounds * row_h) + 20)

    gui.animate(self.popover_bg, "size.y", target_h, gui.EASING_INOUTSINE, 0.3)
    gui.animate(self.clipping_box, "size.y", target_h, gui.EASING_INOUTSINE, 0.3)

    gui.animate(self.grid_root, "position.x", -self.p_w, gui.EASING_INOUTSINE, 0.3)
    gui.set_position(self.sound_root, vmath.vector3(self.p_w, 0, 0))
    gui.animate(self.sound_root, "position.x", 0, gui.EASING_INOUTSINE, 0.3)

    local offset_pos = vmath.vector3(-self.p_w/2, target_h, 0)
    gui.animate(self.active_thumb, "position", offset_pos, gui.EASING_OUTBACK, 0.4)
    gui.animate(self.active_thumb, "scale", vmath.vector3(THUMB_SCALE, THUMB_SCALE, 1), gui.EASING_OUTBACK, 0.4)

    for i, row in ipairs(self.emoji_sound_rows) do
        local snd = e.sounds[i]
        if snd then
            gui.set_text(row.lbl, snd.lbl)
            gui.set_position(row.bg, vmath.vector3(0, target_h - 30 - (i-1)*row_h, 0))
            gui.set_enabled(row.bg, true)
            gui.set_scale(row.bg, vmath.vector3(0.8, 0.8, 1))
            gui.animate(row.bg, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.3, 0.08 + i * 0.05)
        else
            gui.set_enabled(row.bg, false)
        end
    end
end

local function transition_to_grid(self)
    self.emoji_view = "grid"

    gui.animate(self.popover_bg, "size.y", self.GRID_H, gui.EASING_INOUTSINE, 0.3)
    gui.animate(self.clipping_box, "size.y", self.GRID_H, gui.EASING_INOUTSINE, 0.3)

    gui.animate(self.sound_root, "position.x", self.p_w, gui.EASING_INOUTSINE, 0.3)
    gui.animate(self.grid_root, "position.x", 0, gui.EASING_INOUTSINE, 0.3)

    local target_pos = self.emoji_cells[self.emoji_sel].local_pos
    gui.animate(self.active_thumb, "position", target_pos, gui.EASING_INOUTSINE, 0.3)
    gui.animate(self.active_thumb, "scale", vmath.vector3(1, 1, 1), gui.EASING_INOUTSINE, 0.3, 0, function()
        gui.set_enabled(self.active_thumb, false)
    end)
end

local function show_emoji_anim(self, name, fly, local_start_pos, start_scale)
    if not EMOJI_VALID[name] then name = "joy" end

    local anim_id = "face_with_tears_of_joy"
    for _, e in ipairs(EMOJI_SERIES) do
        if e.name == name then anim_id = e.anim; break end
    end

    local key = fly and "send" or "recv"
    self.emoji_fx = self.emoji_fx or {}
    if self.emoji_fx[key] then pcall(gui.delete_node, self.emoji_fx[key]); self.emoji_fx[key] = nil end

    -- Absolute screen-space destination: top-left corner area
    local dest_world = vmath.vector3(DEST_X, DEST_Y, 0)

    local n

    if fly then
        -- Node is parented to flight_anchor; convert destination to flight_anchor local space
        local anchor_world = gui.get_position(self.flight_anchor)
        local dest_local = vmath.vector3(
            dest_world.x - anchor_world.x,
            dest_world.y - anchor_world.y,
            0
        )

        if local_start_pos then
            n = box(local_start_pos, vmath.vector3(FLY_SIZE, FLY_SIZE, 0), vmath.vector4(1,1,1,1), gui.PIVOT_CENTER)
        else
            -- Default start: same position as emoji_btn in flight_anchor local space
            local btn_world = gui.get_position(self.emoji_btn)
            local btn_local = vmath.vector3(
                btn_world.x - anchor_world.x,
                btn_world.y - anchor_world.y,
                0
            )
            n = box(btn_local, vmath.vector3(FLY_SIZE, FLY_SIZE, 0), vmath.vector4(1,1,1,1), gui.PIVOT_CENTER)
        end

        gui.set_parent(n, self.flight_anchor)
        pcall(function() gui.set_texture(n, "emojis"); gui.play_flipbook(n, hash(anim_id)) end)
        self.emoji_fx[key] = n
        local function done()
            pcall(gui.delete_node, n)
            if self.emoji_fx[key] == n then self.emoji_fx[key] = nil end
        end

        -- Bounce the emoji button
        gui.set_scale(self.emoji_btn, vmath.vector3(1.15, 1.15, 1))
        gui.animate(self.emoji_btn, "scale", vmath.vector3(1.0, 1.0, 1), gui.EASING_OUTELASTIC, 0.6)

        -- Flight duration: a brisk arc. Kept short on purpose — a long flight
        -- means the multi-frame emoji flipbook is resampled for many extra
        -- frames while it travels, which was dragging the card/emoji FPS down.
        local fly_duration = 1.0
        local fade_delay  = fly_duration - 0.3   -- fade starts near the end, close to top-left

        if start_scale then
            local s0 = type(start_scale) == "number" and vmath.vector3(start_scale, start_scale, 1) or start_scale
            gui.set_scale(n, s0)
            -- Gentle pop, then chain the shrink to avoid overlapping animations
            gui.animate(n, "scale", vmath.vector3(s0.x * 1.3, s0.y * 1.3, 1), gui.EASING_OUTBACK, 0.25, 0, function()
                gui.animate(n, "scale", vmath.vector3(0.5, 0.5, 1), gui.EASING_INOUTSINE, fly_duration - 0.25)
            end)
            -- Slow arc to top-left
            gui.animate(n, "position", dest_local, gui.EASING_INOUTSINE, fly_duration, 0.1)
            -- Fade out only when almost at destination
            gui.animate(n, "color.w", 0.0, gui.EASING_INSINE, 0.35, fade_delay, done)
        else
            gui.set_scale(n, vmath.vector3(0.1, 0.1, 1))
            -- Bloom up, then chain the shrink to avoid overlapping animations
            gui.animate(n, "scale", vmath.vector3(3.0, 3.0, 1), gui.EASING_OUTELASTIC, 0.4, 0, function()
                gui.animate(n, "scale", vmath.vector3(0.5, 0.5, 1), gui.EASING_INOUTSINE, fly_duration - 0.4)
            end)
            -- Slow arc to top-left
            gui.animate(n, "position", dest_local, gui.EASING_INOUTSINE, fly_duration, 0.1)
            -- Fade out only when almost at destination
            gui.animate(n, "color.w", 0.0, gui.EASING_INSINE, 0.4, fade_delay, done)
        end
    else
        -- Received emoji: appears at top-left, pops, then fades
        n = box(dest_world, vmath.vector3(FLY_SIZE, FLY_SIZE, 0), vmath.vector4(1,1,1,1), gui.PIVOT_CENTER)
        pcall(function() gui.set_texture(n, "emojis"); gui.play_flipbook(n, hash(anim_id)) end)
        self.emoji_fx[key] = n
        local function done()
            pcall(gui.delete_node, n)
            if self.emoji_fx[key] == n then self.emoji_fx[key] = nil end
        end

        gui.set_scale(n, vmath.vector3(0.3, 0.3, 1))
        gui.animate(n, "scale", vmath.vector3(1.2, 1.2, 1), gui.EASING_OUTBACK, 0.3)
        gui.animate(n, "color.w", 0.0, gui.EASING_INSINE, 0.5, 1.1, done)
    end
end

local function emoji_send(self, idx, sound_data, local_start_pos, start_scale)
    local e = EMOJI_SERIES[idx]
    if not e then return end

    -- Do NOT disable active_thumb here; let it keep animating until the popover closes
    M.close(self)

    show_emoji_anim(self, e.name, true, local_start_pos, start_scale)

    local selected_sound_id = sound_data and sound_data.id or (e.sounds[1] and e.sounds[1].id or "")

    play_sound(selected_sound_id)
    msg.post(GAME, "send_emoji", { emoji = e.name, sound = selected_sound_id })
end

function M.on_message(self, message_id, message)
    if message_id == hash("emoji_received") then
        if not message.is_me then
            show_emoji_anim(self, message.emoji or "joy", false)
            play_sound(message.sound)
        end
    end
end

function M.on_input(self, action_id, action)
    if action_id ~= hash("touch") then return false end

    -- Keep swallowing input if touch gesture is captured and not released
    if self.emoji_touch_captured and not action.pressed then
        if action.released then self.emoji_touch_captured = false end
        return true
    end

    -- Actively swallow ALL touches while open OR while closing animation plays
    if self.emoji_open or self.emoji_closing then
        if action.pressed and self.emoji_open then
            self.emoji_touch_captured = true

            if self.emoji_btn and hit(self.emoji_btn, action) then
                M.close(self)
                return true
            end

            if hit(self.popover_bg, action) then
                if self.emoji_view == "grid" then
                    for _, cell in ipairs(self.emoji_cells) do
                        if hit(cell.node, action) then
                            local e = EMOJI_SERIES[cell.idx]
                            if #e.sounds <= 1 then
                                emoji_send(self, cell.idx, e.sounds[1], cell.local_pos, CELL_SIZE / FLY_SIZE)
                            else
                                transition_to_sounds(self, cell)
                            end
                            return true
                        end
                    end
                elseif self.emoji_view == "sounds" then
                    if hit(self.emoji_back, action) then
                        transition_to_grid(self)
                        return true
                    end
                    for i, row in ipairs(self.emoji_sound_rows) do
                        if gui.is_enabled(row.bg) and hit(row.bg, action) then
                            local current_pos = gui.get_position(self.active_thumb)
                            local current_scale = gui.get_scale(self.active_thumb).x
                            emoji_send(self, self.emoji_sel, EMOJI_SERIES[self.emoji_sel].sounds[i], current_pos, (CELL_SIZE * current_scale) / FLY_SIZE)
                            return true
                        end
                    end
                end
                return true
            end

            -- Clicked outside popover_bg, close popover.
            M.close(self)
            return true
        end
        return true 
    end

    if action.pressed then
        if self.emoji_btn and hit(self.emoji_btn, action) then
            emoji_show_grid(self)
            self.emoji_touch_captured = true
            return true
        end
    end

    return false
end

return M