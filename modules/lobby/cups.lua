-- modules/lobby/cups.lua — the right-hand rail listing open team cups.
--
-- Owns everything about that column: fetching the list, finding the caller's
-- own cup, and rendering the windowed, scrollable card stack. Split out of
-- lobby.gui_script's rebuild(), where it was ~140 lines of the largest
-- function in the file.

local ui       = require("modules.ui")
local ws       = require("modules.websocket_manager")
local api      = require("modules.api_service")
local GameMode = require("modules.game_mode")
local T        = require("modules.lobby.theme")
local D        = require("modules.lobby.draw")

local M = {}

-- The one cup this player owns, if any. Read off the rail's own list rather
-- than from a separate request: the list already carries isOwner/started/
-- members for every open cup, so the tile and the rail can never disagree.
function M.my_owned_cup(self)
    for _, t in ipairs(self.team_cups or {}) do
        if t.isOwner then return t end
    end
    return nil
end

-- Pull the open team cups for the rail. Cheap endpoint (cards only, no
-- playersProgress), refreshed on screen entry rather than polled.
function M.load(self, on_loaded)
    if self.team_cups_loading then return end
    self.team_cups_loading = true
    local uid = tostring((ws.current_user_data or {})._id or "")
    api.list_active_team_tournaments(uid, function(res)
        self.team_cups_loading = false
        self.team_cups = ((res or {}).data or {}).tournaments or {}
        self.team_cups_off = 0
        -- Unlike the other screens, lobby has no self._active flag — gating on
        -- one would silently never repaint, leaving the rail stuck on
        -- "Loading..." forever. self.nodes is the real signal that the screen
        -- is currently built.
        if self.nodes and on_loaded then on_loaded(self) end
    end)
end

-- Reserve the rail's width out of the grid. Returns the width to use, whether
-- there is room for it at all, and the resulting left edge.
function M.reserve(grid_l, grid_r)
    local avail_w = grid_r - grid_l
    local w = math.floor(math.max(T.RAIL_MIN_W, math.min(T.RAIL_MAX_W, avail_w * T.RAIL_SHARE)))
    local show = avail_w >= (T.RAIL_MIN_W + T.TILES_MIN_W)
    return w, show, show and (grid_r - w) or nil
end

-- Render the rail. `rail_l`/`RAIL_W` come from M.reserve above.
function M.draw(self, rail_l, RAIL_W, grid_t)
    local rail_cx = rail_l + RAIL_W / 2
    -- Full height: the rail runs the whole usable column rather than
    -- starting below the header band, so it fits noticeably more cups.
    -- Nothing else draws there — the header's right edge is grid_r, which
    -- was already pulled left of the rail above.
    local rail_t  = T.EDGE_T - T.PADDING
    local rail_b  = T.EDGE_B + T.PADDING
    local rail_h  = rail_t - rail_b

    D.track(self, ui.box(vmath.vector3(rail_cx, rail_b + rail_h / 2, 0),
        vmath.vector3(RAIL_W, rail_h, 0), vmath.vector4(0, 0, 0, 0.42)))
    D.track(self, ui.box(vmath.vector3(rail_cx, rail_t - 1, 0),
        vmath.vector3(RAIL_W, 3, 0), T.TEAM))

    local hy = rail_t - 22
    D.text_sh(self, vmath.vector3(rail_cx, hy, 0), "OPEN TEAM CUPS", "small", T.CREAM, 1, -1)
    hy = hy - 22

    local list = self.team_cups or {}
        local view_t  = hy - 4
    local view_b  = rail_b + 10
    local view_h  = view_t - view_b
    local per_page = math.max(1, math.floor((view_h + T.CARD_GAP) / (T.CARD_H + T.CARD_GAP)))

    if self.team_cups_loading then
        D.track(self, ui.text(vmath.vector3(rail_cx, view_t - 24, 0), "Loading...", "small", T.MUTED))
    elseif #list == 0 then
        D.track(self, ui.text(vmath.vector3(rail_cx, view_t - 24, 0), "No open cups yet.", "small", T.MUTED))
        D.track(self, ui.text(vmath.vector3(rail_cx, view_t - 44, 0), "Create one to get started.", "small", T.MUTED))
    else
        -- Windowed render: only the cards in view are built, so a long
        -- list costs the same as a short one and nothing needs clipping.
        local max_off = math.max(0, #list - per_page)
        self.team_cups_off = math.max(0, math.min(max_off, self.team_cups_off or 0))
        local off = self.team_cups_off

        for i = 1, per_page do
            local t = list[off + i]
            if not t then break end
            local cy_ = view_t - (i - 1) * (T.CARD_H + T.CARD_GAP) - T.CARD_H / 2

            local card_w = RAIL_W - 16
            local card_l = rail_cx - card_w / 2
            D.track(self, ui.panel9(vmath.vector3(rail_cx, cy_, 0),
                vmath.vector3(card_w, T.CARD_H, 0), "container_bg"))

            local tx      = card_l + 14
            local card_t  = cy_ + T.CARD_H / 2
            local card_b  = cy_ - T.CARD_H / 2

            -- Row 1: name, with a state pill right-aligned beside it.
            local joined  = tonumber(t.members) or 0
            local cap     = tonumber(t.maxPlayers) or 0
            local mine    = t.hasJoined or t.isOwner
            local pill_txt, pill_col
            if t.isOwner        then pill_txt, pill_col = "YOURS",   T.GOLD
            elseif t.hasJoined  then pill_txt, pill_col = "JOINED",  T.TEAM
            elseif t.isFull     then pill_txt, pill_col = "FULL",    T.DISABLED
            elseif t.started    then pill_txt, pill_col = "RUNNING", T.TEAM
            else                     pill_txt, pill_col = "OPEN",    T.GOLD end

            local n = D.track(self, ui.text(vmath.vector3(tx, card_t - 18, 0),
                tostring(t.name or "Team Cup"):sub(1, 16), "body", T.CREAM))
            D.set_pivot(n, gui.PIVOT_W)

            local pl = D.track(self, ui.text(vmath.vector3(card_l + card_w - 14, card_t - 18, 0),
                pill_txt, "small", pill_col))
            D.set_pivot(pl, gui.PIVOT_E)

            -- Row 2: the prize, the reason to care about this card.
            local pz = D.track(self, ui.text(vmath.vector3(tx, card_t - 42, 0),
                D.commas(t.grandPrize or 0) .. " " .. tostring(GameMode.CURRENCY_CODE or ""),
                "subtitle2", T.GOLD))
            D.set_pivot(pz, gui.PIVOT_W)

            -- Row 3: a fill bar makes "how full" readable at a glance in a
            -- way a bare "3/8" does not.
            local bar_w = card_w - 28
            local bar_y = card_t - 62
            D.track(self, ui.box(vmath.vector3(card_l + 14 + bar_w / 2, bar_y, 0),
                vmath.vector3(bar_w, 5, 0), T.DARK))
            if cap > 0 and joined > 0 then
                local fw = math.max(3, math.floor(bar_w * math.min(1, joined / cap)))
                local fb = D.track(self, ui.box(vmath.vector3(card_l + 14 + fw / 2, bar_y, 0),
                    vmath.vector3(fw, 5, 0), t.isFull and T.DISABLED or T.GOLD))
                D.set_pivot(fb, gui.PIVOT_CENTER)
            end

            -- Row 4: member count on the left, the action on the right.
            local mb = D.track(self, ui.text(vmath.vector3(tx, card_b + 20, 0),
                string.format("%d/%d players", joined, cap), "small", T.MUTED))
            D.set_pivot(mb, gui.PIVOT_W)

            -- A cup you are already in offers STANDINGS instead of a dead
            -- "JOINED" label, so every card in the list does something.
            local bw, bh = 92, 32
            local bx = card_l + card_w - 14 - bw / 2
            if t.isOwner then
                -- The cup's owner runs it from here: START it while it is
                -- still gathering players, and DELETE it either way (the
                -- backend refunds the escrowed prize). Two narrower buttons
                -- so both fit the card's action row.
                local ow, gap = 68, 6
                local o2x = card_l + card_w - 14 - ow / 2
                local o1x = o2x - ow - gap
                D.btn(self, "team_cup_delete", vmath.vector3(o1x, card_b + 20, 0),
                    vmath.vector3(ow, bh, 0), "DELETE", "secondary_btn", t._id)
                if t.started then
                    D.btn(self, "team_cup_standings", vmath.vector3(o2x, card_b + 20, 0),
                        vmath.vector3(ow, bh, 0), "TABLE", "secondary_btn", t._id)
                else
                    D.btn(self, "team_cup_start", vmath.vector3(o2x, card_b + 20, 0),
                        vmath.vector3(ow, bh, 0), "START", "primary_btn", t._id)
                end
            elseif mine then
                D.btn(self, "team_cup_standings", vmath.vector3(bx, card_b + 20, 0),
                    vmath.vector3(bw, bh, 0), "TABLE", "secondary_btn", t._id)
            elseif t.isFull then
                D.track(self, ui.box(vmath.vector3(bx, card_b + 20, 0), vmath.vector3(bw, bh, 0), T.DARK))
                D.track(self, ui.text(vmath.vector3(bx, card_b + 20, 0), "FULL", "small", T.MUTED))
            else
                D.btn(self, "team_cup_join", vmath.vector3(bx, card_b + 20, 0),
                    vmath.vector3(bw, bh, 0), "JOIN", "primary_btn", t.invitationCode)
            end
        end

        if max_off > 0 then
            -- Explicit arrows in addition to drag, so the list is usable
            -- without discovering the gesture.
            local ax = rail_cx + (RAIL_W - 20) / 2 - 16
            if off > 0 then
                D.btn(self, "team_cup_up", vmath.vector3(ax, rail_t - 22, 0),
                    vmath.vector3(26, 22, 0), "^", "secondary_btn")
            end
            if off < max_off then
                D.btn(self, "team_cup_down", vmath.vector3(ax, view_b + 12, 0),
                    vmath.vector3(26, 22, 0), "v", "secondary_btn")
            end
            D.track(self, ui.text(vmath.vector3(rail_cx - (RAIL_W - 20) / 2 + 12, view_b + 12, 0),
                string.format("%d-%d of %d", off + 1,
                    math.min(#list, off + per_page), #list), "small", T.MUTED))
            D.set_pivot(self.nodes[#self.nodes], gui.PIVOT_W)
        end
    end

    -- Drag surface, added last so it sits under the card buttons above.
    local drag = D.track(self, ui.box(vmath.vector3(rail_cx, rail_b + rail_h / 2, 0),
        vmath.vector3(RAIL_W, rail_h, 0), T.TRANSP))
    self.team_rail_node = drag
    self.team_rail_step = T.CARD_H + T.CARD_GAP

end

return M
