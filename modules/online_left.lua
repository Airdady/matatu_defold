-- modules/online_left.lua
-- Left sidebar: Season timer, Standings, Season Bonuses.
-- Called from online.gui_script via M.draw(self, ctx).
-- ctx fields expected: track, txtL, txtR, mkbtn, glass, commas,
--                      get_layout, constants (all color/spacing locals).

local ws = require("modules.websocket_manager")

local M = {}

-- ── Prize helpers (shared by draw and by the right panel's badge) ─────────────

local DEFAULT_PRIZES = {
    { rank = "#1",     amount = "70,000", min_pos = 1,  max_pos = 1  },
    { rank = "#2",     amount = "30,000", min_pos = 2,  max_pos = 2  },
    { rank = "#3",     amount = "10,000", min_pos = 3,  max_pos = 3  },
    { rank = "#4-10",  amount = "5,000",  min_pos = 4,  max_pos = 10 },
    { rank = "#11-20", amount = "1,000",  min_pos = 11, max_pos = 20 },
}

function M.build_prizes(commas_fn)
    local u = ws.current_user_data or {}
    local prizes = u.prizes
    if type(prizes) == "table" and prizes[1] and type(prizes[1].rewards) == "table" and #prizes[1].rewards > 0 then
        local out = {}
        for _, reward in ipairs(prizes[1].rewards) do
            local coins  = tonumber(reward.coins)  or 0
            local points = tonumber(reward.points) or 0
            local amount, suffix
            if coins > 0 then amount, suffix = commas_fn(coins), ""
            elseif points > 0 then amount, suffix = commas_fn(points), " PTS"
            else amount, suffix = "0", "" end

            local range = tostring(reward.range or "")
            local lo, hi = range:match("^(%d+)%-(%d+)$")
            if lo then lo, hi = tonumber(lo), tonumber(hi)
            else lo = tonumber(range) or 9999; hi = lo end
            out[#out+1] = { rank = "#"..range, amount = amount, suffix = suffix, min_pos = lo, max_pos = hi }
        end
        return out
    end
    local out = {}
    for i, p in ipairs(DEFAULT_PRIZES) do
        out[i] = { rank = p.rank, amount = p.amount, suffix = "", min_pos = p.min_pos, max_pos = p.max_pos }
    end
    return out
end

function M.active_tier_index(prizes, pos)
    if not pos or pos <= 0 then return -1 end
    for i, p in ipairs(prizes) do
        if pos >= p.min_pos and pos <= p.max_pos then return i end
    end
    return -1
end

function M.prize_for_position(prizes, pos, commas_fn)
    if not pos or pos <= 0 then return "" end
    local idx = M.active_tier_index(prizes, pos)
    if idx and idx > 0 and prizes[idx] then
        local p = prizes[idx]
        if p.suffix == " PTS" then return p.amount .. " Pts" end
        return p.amount .. " Coins"
    end
    return ""
end

-- ── draw ─────────────────────────────────────────────────────────────────────

function M.draw(self, ctx)
    local C         = ctx.C          -- color/spacing constants table
    local track     = ctx.track
    local txtL      = ctx.txtL
    local txtR      = ctx.txtR
    local glass     = ctx.glass
    local commas    = ctx.commas
    local get_layout = ctx.get_layout

    local _, _, div_lx = get_layout()
    local pw = (div_lx - ctx.EDGE_L) - (C.SIDE_MARGIN * 2)
    local cx = (ctx.EDGE_L + div_lx) / 2
    local cy = ctx.EDGE_T - 16
    local ctx_ui = ctx.ui

    -- The back button (nav_lobby) and the "SEASON ENDS IN" countdown that
    -- used to share a row here have both moved off this panel — the back
    -- button now lives in the ONLINE screen's center header
    -- (modules/online_center.lua) and the countdown lives in the lobby
    -- header (main/lobby.gui_script) — so the Standings container starts
    -- right at the top of the panel with no reserved row above it.

    -- Global Container Padding/Spacing Logic
    -- pad_top increased and title_space decreased to push title down toward the table
    local pad_top = 28 
    local pad_bot = 16
    local title_space = C.SECTION_GAP + 4 + C.HDR_H_TABLE 
    
    -- Shrink the inner content width to leave 16px padding on both sides
    local inner_pw = pw - 32

    local prizes = M.build_prizes(commas)
    local rank = (ws.current_user_data and ws.current_user_data.rank) or {}

    -- ── Standings Container ──────────────────────────────────────────────────
    local num_standings = math.min(#rank, 5)
    local s_list_h = (num_standings > 0) and (num_standings * C.ROW_H_LG) or 40
    local s_cont_h = pad_top + title_space + s_list_h + pad_bot

    -- Draw Container Background centered dynamically around the content height
    glass(self, vmath.vector3(cx, cy - s_cont_h/2, 0), vmath.vector3(pw, s_cont_h, 0), "container_bg")

    cy = cy - pad_top
    local s_title = txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy, "STANDINGS", "body", C.COL_BRIGHT)
    gui.set_scale(s_title, vmath.vector3(0.82, 0.82, 1))
    
    cy = cy - title_space

    -- Give the POSITION column a fixed, generous amount of space (100 pixels)
    local name_x = cx - inner_pw/2 + C.INNER_PAD + 100

    -- Column header uses inner_pw
    track(self, ctx_ui.box(vmath.vector3(cx, cy + C.HDR_H_TABLE/2, 0), vmath.vector3(inner_pw, C.HDR_H_TABLE, 0), C.COL_GLASS))
    track(self, ctx_ui.box(vmath.vector3(cx, cy + 1, 0), vmath.vector3(inner_pw, 1, 0), C.COL_BORDER))
    txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy + C.HDR_H_TABLE/2, "POSITION", "small", C.COL_DIM)
    txtL(self, name_x,                        cy + C.HDR_H_TABLE/2, "PLAYER",   "small", C.COL_DIM)
    txtR(self, cx + inner_pw/2 - C.INNER_PAD, cy + C.HDR_H_TABLE/2, "POINTS",   "small", C.COL_DIM)

    local shown = 0
    local row_h = C.ROW_H_LG 
    for _, r in ipairs(rank) do
        if shown >= 5 then break end
        shown = shown + 1
        local me = r.active
        local pos_int = tonumber(r.position) or 99
        local tier_col = C.TIER_COLORS[M.active_tier_index(prizes, pos_int)] or C.TIER_DIM

        local bg_col = me and C.ROW_YOU or ((shown % 2 == 0) and C.ROW_EVEN or C.ROW_ODD)
        
        -- Rows use inner_pw
        track(self, ctx_ui.box(vmath.vector3(cx, cy - row_h/2, 0), vmath.vector3(inner_pw, row_h, 0), bg_col))
        track(self, ctx_ui.box(vmath.vector3(cx - inner_pw/2 + 2, cy - row_h/2, 0), vmath.vector3(3, row_h, 0), tier_col))
        
        -- Using 'body' font and applying a 0.9 scale just like the Season Bonuses table
        local rnk_t = txtL(self, cx - inner_pw/2 + C.INNER_PAD + 4, cy - row_h/2, "#"..tostring(r.position or shown), "body", me and C.COL_WHITE or C.COL_DIM)
        local ply_t = txtL(self, name_x,                             cy - row_h/2, me and "YOU" or string.upper(r.username or "PLAYER"), "body", me and C.COL_WHITE or C.COL_BRIGHT)
        local pts_t = txtR(self, cx + inner_pw/2 - C.INNER_PAD,      cy - row_h/2, commas(r.points or 0), "body", me and C.COL_GOLD or C.COL_MID)
        
        gui.set_scale(rnk_t, vmath.vector3(0.9, 0.9, 1))
        gui.set_scale(ply_t, vmath.vector3(0.9, 0.9, 1))
        gui.set_scale(pts_t, vmath.vector3(0.9, 0.9, 1))

        cy = cy - row_h
    end

    if shown == 0 then
        track(self, ctx_ui.text(vmath.vector3(cx, cy - 20, 0), "Standings load when live", "small", C.COL_DIM))
        cy = cy - 40
    end

    cy = cy - pad_bot - C.BLOCK_GAP

    -- ── Season Bonuses Container ──────────────────────────────────────────────
    local num_bonuses = #prizes
    local b_list_h = num_bonuses * C.ROW_H_LG
    local b_cont_h = pad_top + title_space + b_list_h + pad_bot

    -- Draw Container Background
    glass(self, vmath.vector3(cx, cy - b_cont_h/2, 0), vmath.vector3(pw, b_cont_h, 0), "container_bg")

    cy = cy - pad_top
    local b_title = txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy, "SEASON BONUSES", "body", C.COL_BRIGHT)
    gui.set_scale(b_title, vmath.vector3(0.82, 0.82, 1))
    
    cy = cy - title_space

    track(self, ctx_ui.box(vmath.vector3(cx, cy + C.HDR_H_TABLE/2, 0), vmath.vector3(inner_pw, C.HDR_H_TABLE, 0), C.COL_GLASS))
    track(self, ctx_ui.box(vmath.vector3(cx, cy + 1, 0), vmath.vector3(inner_pw, 1, 0), C.COL_BORDER))
    txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy + C.HDR_H_TABLE/2, "RANK",  "small", C.COL_DIM)
    txtR(self, cx + inner_pw/2 - C.INNER_PAD, cy + C.HDR_H_TABLE/2, "PRIZE", "small", C.COL_DIM)

    local my_pos = tonumber((ws.current_user_data or {}).position) or -1
    local active = M.active_tier_index(prizes, my_pos)
    local row_h_bonus = C.ROW_H_LG

    for i, p in ipairs(prizes) do
        local tier_col = C.TIER_COLORS[math.min(i, #C.TIER_COLORS)]
        local is_active = (i == active)

        local bg_col = is_active
            and vmath.vector4(tier_col.x, tier_col.y, tier_col.z, 0.25)
            or ((i % 2 == 0) and C.ROW_EVEN or C.ROW_ODD)

        track(self, ctx_ui.box(vmath.vector3(cx, cy - row_h_bonus/2, 0), vmath.vector3(inner_pw, row_h_bonus, 0), bg_col))
        local accent_w = is_active and 4 or 3
        track(self, ctx_ui.box(vmath.vector3(cx - inner_pw/2 + accent_w/2, cy - row_h_bonus/2, 0), vmath.vector3(accent_w, row_h_bonus, 0), tier_col))

        local rnk = txtL(self, cx - inner_pw/2 + C.INNER_PAD + 4, cy - row_h_bonus/2, p.rank, "body", is_active and C.COL_WHITE or C.COL_BRIGHT)
        local amt = txtR(self, cx + inner_pw/2 - C.INNER_PAD,     cy - row_h_bonus/2, p.amount..(p.suffix or ""), "body", is_active and tier_col or C.COL_GOLD)
        gui.set_scale(rnk, vmath.vector3(0.9, 0.9, 1)); gui.set_scale(amt, vmath.vector3(0.9, 0.9, 1))
        cy = cy - row_h_bonus
    end

    cy = cy - pad_bot - C.BLOCK_GAP
    -- Updated footer text
    track(self, ctx_ui.text(vmath.vector3(cx, cy, 0), "Get more points to rank high", "small", C.COL_DIM))
end

return M