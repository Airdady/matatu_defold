-- modules/lobby/tiles.lua — the two tile shapes the lobby grid is built from.
--
-- M.mode  : a headline mode tile (PLAY ONLINE, TEAM CUPS, QUICK PLAY, ...)
-- M.util  : a small utility button (RULES, SHARE, HELP, THEME, CONTACT)
--
-- Both draw the same textured slice-9 panel as the stake tiles, so the whole
-- lobby is one material.

local ui = require("modules.ui")
local T  = require("modules.lobby.theme")
local D  = require("modules.lobby.draw")

local M = {}

function M.mode(self, cfg)
    local x, y, w, h = cfg.x, cfg.y, cfg.w, cfg.h
    local disabled = cfg.disabled

    -- The tile container is the textured slice-9 panel from the ui atlas —
    -- the same artwork the stake tiles use (ui.panel9 + "container_bg", see
    -- online_center.lua). It replaces the two flat layered boxes that used to
    -- fake a 1px border, so every mode tile reads as part of one system.
    local panel = D.track(self, ui.panel9(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0), "container_bg"))
    if disabled then gui.set_color(panel, vmath.vector4(0.45, 0.45, 0.45, 1)) end

    local accent_col = disabled and T.DISABLED or cfg.accent

    -- Left Accent Line
    local acc_w = 3
    local acc_h = h - 24
    local acc_x = x - w/2 + 8
    local n_acc = D.track(self, ui.box(vmath.vector3(acc_x, y, 0), vmath.vector3(acc_w, acc_h, 0), accent_col))
    D.set_pivot(n_acc, gui.PIVOT_W)

    -- Top Left Text
    local tl_y = y + h/2 - 28
    local n_tl = D.track(self, ui.text(vmath.vector3(acc_x + 16, tl_y, 0), cfg.top_left, "small", accent_col))
    D.set_pivot(n_tl, gui.PIVOT_W)

    -- Camera recording blink effect for the LIVE tag (suppressed when disabled)
    if cfg.blink_tl and not disabled then
        gui.animate(n_tl, "color.w", 0.1, gui.EASING_LINEAR, 0.8, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
    end

    if cfg.top_left_2 then
        local tl2_col = disabled and T.DISABLED or T.DARKRED
        local n_tl2 = D.track(self, ui.text(vmath.vector3(acc_x + 16 + 55, tl_y, 0), cfg.top_left_2, "small", tl2_col))
        D.set_pivot(n_tl2, gui.PIVOT_W)
    end

    -- Center Text (Anchored slightly below center or dynamic based on CTA)
    local title_y = (cfg.cta_label or cfg.badge_label or cfg.child_buttons) and (y + 15) or (y + 8)
    
    local title_col = disabled and T.DISABLED or T.CREAM
    local n_title = D.track(self, ui.text(vmath.vector3(acc_x + 16, title_y, 0), cfg.title, "title", title_col))
    D.set_pivot(n_title, gui.PIVOT_W)
    pcall(gui.set_scale, n_title, vmath.vector3(1.15, 1.15, 1))

    if cfg.sub then
        local n_sub = D.track(self, ui.text(vmath.vector3(acc_x + 16, title_y - 32, 0), cfg.sub, "small", T.MUTED))
        D.set_pivot(n_sub, gui.PIVOT_W)
    end

    -- Season countdown block (PLAY ONLINE tile only) — sits in the gap
    -- between the subtitle and the CTA pill: a big "ends in" countdown with
    -- the actual day-of-week/time it ends underneath, visible to guests too.
    if cfg.season_countdown then
        local sy = title_y - 62
        local n_slabel = D.track(self, ui.text(vmath.vector3(acc_x + 16, sy, 0), "SEASON ENDS IN", "small", T.MUTED))
        D.set_pivot(n_slabel, gui.PIVOT_W)

        local scount_col = disabled and T.DISABLED or T.GOLD
        local n_scount = D.track(self, ui.text(vmath.vector3(acc_x + 16, sy - 30, 0), cfg.season_countdown, "subtitle2", scount_col))
        D.set_pivot(n_scount, gui.PIVOT_W)
        pcall(gui.set_scale, n_scount, vmath.vector3(1.15, 1.15, 1))

        if cfg.season_deadline then
            local n_sdead = D.track(self, ui.text(vmath.vector3(acc_x + 16, sy - 62, 0), cfg.season_deadline, "small", T.MUTED))
            D.set_pivot(n_sdead, gui.PIVOT_W)
        end
    end

    -- Child action buttons — omitted entirely when the tile is disabled so
    -- none of their individual hit regions are registered either.
    if cfg.child_buttons and not disabled then
        local n_children = #cfg.child_buttons
        local cbtn_h      = 46
        local cbtn_gap    = 12
        local avail_w     = (x + w/2 - 20) - (acc_x + 16)
        local cbtn_w      = math.floor((avail_w - cbtn_gap * (n_children - 1)) / n_children)
        local cby         = y - h/2 + 50
        local cbx0        = acc_x + 16 + cbtn_w/2
        for i, cb in ipairs(cfg.child_buttons) do
            local cbx = cbx0 + (i - 1) * (cbtn_w + cbtn_gap)
            D.btn(self, cb.id, vmath.vector3(cbx, cby, 0), vmath.vector3(cbtn_w, cbtn_h, 0), cb.label, cb.style, cb.data)
        end
    elseif cfg.cta_label then
        -- Narrow enough to sit inside the smaller offline tiles too, which
        -- are roughly a third of the grid rather than half of it.
        local cta_w, cta_h = math.min(160, math.max(96, w - 40)), 46
        -- Right-anchored (the child-button row and the badge below stay left
        -- aligned): PLAY NOW sits at the tile's trailing edge so it reads as
        -- the tile's action rather than as another label in the left stack.
        local cta_x = x + w/2 - 16 - cta_w/2
        local cta_y = y - h/2 + 50
        local cta_bg = disabled and T.DISABLED or T.RED
        local cta_fg = disabled and T.MUTED or vmath.vector4(0.05, 0.05, 0.05, 1)
        D.track(self, ui.box(vmath.vector3(cta_x, cta_y, 0), vmath.vector3(cta_w, cta_h, 0), cta_bg))
        D.track(self, ui.text(vmath.vector3(cta_x, cta_y, 0), cfg.cta_label, "body", cta_fg))
    elseif cfg.badge_label then
        local badge_w, badge_h = 160, 46
        local badge_x = acc_x + 16 + badge_w/2
        local badge_y = y - h/2 + 50
        -- Muted/darker styling for a non-clickable badge look
        D.track(self, ui.box(vmath.vector3(badge_x, badge_y, 0), vmath.vector3(badge_w, badge_h, 0), T.DARKRED))
        D.track(self, ui.text(vmath.vector3(badge_x, badge_y, 0), cfg.badge_label, "body", T.CREAM))
    end

    -- Invisible hit node — omitted when tile is disabled so taps fall through.
    if cfg.btn_id and not disabled then
        local hit = D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0), T.TRANSP))
        self.buttons[#self.buttons + 1] = { node = hit, id = cfg.btn_id, data = cfg.btn_data }
    end

    -- A SECOND, independent action sitting beside the CTA — a different way of
    -- doing the tile's job rather than a variation on it. Signing in by phone
    -- number is the case this exists for: it is not "PLAY NOW but slower", it
    -- is the other credential, and burying it behind a Google failure meant
    -- players only ever reached it by being unable to reach anything else.
    --
    -- Registered AFTER the tile's own hit node on purpose. The lobby picks
    -- buttons back to front, so anything added earlier would be swallowed by
    -- the full-tile hit region that covers it.
    if cfg.alt_cta_label and cfg.alt_cta_id and not disabled then
        -- Wider than the CTA and anchored to the same right edge, so the two
        -- line up as one stack of actions. The extra width is not decoration:
        -- the CTA's 160 is sized for "PLAY NOW", and a label naming the other
        -- credential does not fit in it at the caption font.
        local alt_w, alt_h = math.min(210, math.max(120, w - 40)), 40
        local alt_x = x + w/2 - 16 - alt_w/2
        -- ABOVE the CTA, not below it. The CTA already sits 50px off the tile
        -- floor and is 46 tall, which leaves 27px underneath — not enough for
        -- a tappable second row. Stacking upwards keeps both inside the tile
        -- and leaves PLAY NOW where players already look for it.
        local alt_y = y - h/2 + 50 + 46
        -- Outlined rather than filled, so the primary CTA stays the primary
        -- CTA. Two solid pills would read as a choice between equals, and for
        -- a player whose Google sign-in works it is not one.
        D.track(self, ui.box(vmath.vector3(alt_x, alt_y, 0), vmath.vector3(alt_w, alt_h, 0), T.GOLD))
        D.track(self, ui.box(vmath.vector3(alt_x, alt_y, 0), vmath.vector3(alt_w - 3, alt_h - 3, 0), T.DARK))
        local n_alt = D.track(self, ui.text(vmath.vector3(alt_x, alt_y, 0), cfg.alt_cta_label, "small", T.CREAM))
        pcall(gui.set_scale, n_alt, vmath.vector3(0.8, 0.8, 1))
        local alt_hit = D.track(self, ui.box(vmath.vector3(alt_x, alt_y, 0), vmath.vector3(alt_w, alt_h, 0), T.TRANSP))
        self.buttons[#self.buttons + 1] = { node = alt_hit, id = cfg.alt_cta_id }
    end
end

-- ---------------------------------------------------------------------------
-- Utility square-tile builder
-- ---------------------------------------------------------------------------
function M.util(self, cfg)
    local x, y, w, h = cfg.x, cfg.y, cfg.w, cfg.h
    local disabled = cfg.disabled

    -- Same textured panel as the mode tiles, so the whole lobby is one
    -- material. Deliberately no per-button accent colour: RULES / SHARE /
    -- HELP / THEME / CONTACT each used to carry their own hue, which put five
    -- unrelated colours along the bottom of the screen for no informational
    -- gain. Disabled state is carried by the greyed label alone.
    local panel = D.track(self, ui.panel9(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0), "container_bg"))
    if disabled then gui.set_color(panel, vmath.vector4(0.55, 0.55, 0.55, 1)) end

    -- Centered Label (greyed when disabled)
    D.track(self, ui.text(vmath.vector3(x, y + 2, 0), cfg.label, "body", disabled and T.DISABLED or T.CREAM))

    -- Sub-label (e.g. lock hint) when disabled
    if disabled and cfg.locked_hint then
        local n = D.track(self, ui.text(vmath.vector3(x, y - 16, 0), cfg.locked_hint, "small", T.DISABLED))
        D.set_pivot(n, gui.PIVOT_CENTER)
    end

    local hit = D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0), T.TRANSP))
    self.buttons[#self.buttons + 1] = { node = hit, id = disabled and (cfg.disabled_id or "noop") or cfg.btn_id }
end


return M
