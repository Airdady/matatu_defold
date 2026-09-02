-- modules/online_left.lua
-- Left sidebar: Season timer, Standings, Season Bonuses.
-- Called from online.gui_script via M.draw(self, ctx).
-- ctx fields expected: track, txtL, txtR, mkbtn, glass, commas,
--                      get_layout, constants (all color/spacing locals).

local ws = require("modules.websocket_manager")
local clock = require("modules.season_clock")

local M = {}

-- ── Prize helpers (shared by draw and by the right panel's badge) ─────────────

-- NO HARDCODED PRIZE TABLE.
--
-- There used to be one here: 70,000 / 30,000 / 10,000 / 5,000 / 1,000, shown
-- whenever the payload did not match the exact shape build_prizes expects. It
-- was a THIRD set of numbers — the database has `rewards` and
-- `standingsPrizes`, and this agreed with neither — presented to players as
-- the prize table, indistinguishable from the real thing because a plausible
-- list of amounts looks exactly like a plausible list of amounts.
--
-- An empty panel is the honest answer when the server has not said yet. It is
-- also self-correcting: the table appears the moment IDENTIFY lands, which is
-- seconds, whereas a wrong number stays wrong until somebody notices it.

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
    -- Nothing usable from the server yet. Show nothing rather than invent it.
    return {}
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

-- WHAT COLOUR THE SEASON DEADLINE IS.
--
-- GOLD by default. This is the one number on the panel that is not a prize
-- and not a rank, and in dim grey it read as a caption on the title rather
-- than as a thing worth acting on. Gold is already this UI's "there is money
-- in this" colour — the prize amounts in the table below it are gold, and so
-- is the H2H line on the invite strip — so a gold deadline says plainly that
-- it belongs to the prizes beside it.
--
-- RED in the final hour, where the seconds field stops being decoration. A
-- countdown that looks identical at four days and at forty seconds is wasting
-- the one moment it actually matters.
--
-- DIM once it has passed: ENDED is not urgent, it is over, and leaving it red
-- would keep shouting about a deadline nobody can still make.
--
-- Lives here rather than at each call site because there are two — the build
-- in M.draw below, and the once-a-second tick in online.gui_script that
-- repaints the same node — and a colour rule that disagrees between them
-- would show up as a label that changes colour only when the panel happens
-- to rebuild.
function M.clock_color(C, seconds)
    local state = clock.urgency(seconds)
    if state == "ended" then return C.COL_DIM end
    if state == "final_hour" then return C.COL_RED end
    return C.COL_GOLD
end

-- ── draw ─────────────────────────────────────────────────────────────────────

function M.draw(self, ctx)
    local C         = ctx.C          -- color/spacing constants table
    local track     = ctx.track
    local txtL      = ctx.txtL
    local txtR      = ctx.txtR
    local glass     = ctx.glass
    local commas    = ctx.commas
    local mkbtn     = ctx.mkbtn
    local get_layout = ctx.get_layout

    local _, _, div_lx = get_layout()
    local pw = (div_lx - ctx.EDGE_L) - (C.SIDE_MARGIN * 2)
    local cx = (ctx.EDGE_L + div_lx) / 2
    local cy = ctx.EDGE_T - 16
    local ctx_ui = ctx.ui

    -- The "SEASON ENDS IN" countdown that used to share a row here now
    -- lives in the lobby header (main/lobby.gui_script) — so the Standings
    -- container starts right at the top of the panel with no reserved row
    -- above it. The back-to-lobby button (nav_lobby) lives at the BOTTOM of
    -- this panel instead, below Season Bonuses — see the end of this
    -- function — rather than as a bare "<" icon in the center header.

    -- Global Container Padding/Spacing Logic
    -- pad_top increased and title_space decreased to push title down toward the table
    local pad_top = 28 
    local pad_bot = 16
    local title_space = C.SECTION_GAP + 4 + C.HDR_H_TABLE 
    
    -- Shrink the inner content width to leave 16px padding on both sides
    local inner_pw = pw - 32

    local prizes = M.build_prizes(commas)
    local rank = (ws.current_user_data and ws.current_user_data.rank) or {}

    -- Where this player sits in the ladder. Read once and used twice: the
    -- STANDINGS title row prints it, and the Season Bonuses table below
    -- highlights the prize tier it falls in.
    local my_pos = tonumber((ws.current_user_data or {}).position) or -1

    -- ── Standings Container ──────────────────────────────────────────────────
    local num_standings = math.min(#rank, 5)
    local s_list_h = (num_standings > 0) and (num_standings * C.ROW_H_LG) or 40
    local s_cont_h = pad_top + title_space + s_list_h + pad_bot

    -- Draw Container Background centered dynamically around the content height
    glass(self, vmath.vector3(cx, cy - s_cont_h/2, 0), vmath.vector3(pw, s_cont_h, 0), "container_bg")

    cy = cy - pad_top
    local s_title = txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy, "STANDINGS", "body", C.COL_BRIGHT)
    gui.set_scale(s_title, vmath.vector3(0.82, 0.82, 1))

    -- WHERE YOU ARE IN THIS TABLE, on the far right of the same row.
    --
    -- It lived in the right panel's profile card, in a two-row stats box under
    -- the balances, a panel's width away from the standings it is a position
    -- IN. The table below this title shows the top five and nothing else, so a
    -- player outside it had their own rank on the opposite side of the screen
    -- from the only thing that gives it meaning.
    --
    -- This is the same move, and the same reasoning, as the season countdown
    -- on the SEASON BONUSES title row further down: the one number a table
    -- does not contain goes on that table's own title row.
    --
    -- Gold when ranked, dim when not. UNRANKED rather than "#-1" or a blank:
    -- having no position yet is a fact, and the five rows under this one are
    -- about to show people who do have one.
    txtR(self, cx + inner_pw/2 - C.INNER_PAD, cy,
        (my_pos > 0) and ("YOU  #" .. my_pos) or "UNRANKED", "small",
        (my_pos > 0) and C.COL_GOLD or C.COL_DIM)

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
    -- One row's height even when there are none, so the panel keeps its shape
    -- and holds the "waiting" line below instead of collapsing to a bare title
    -- that reads as a broken container.
    local b_list_h = math.max(num_bonuses, 1) * C.ROW_H_BONUS
    local b_cont_h = pad_top + title_space + b_list_h + pad_bot

    -- Draw Container Background
    glass(self, vmath.vector3(cx, cy - b_cont_h/2, 0), vmath.vector3(pw, b_cont_h, 0), "container_bg")

    cy = cy - pad_top
    local b_title = txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy, "SEASON BONUSES", "body", C.COL_BRIGHT)
    gui.set_scale(b_title, vmath.vector3(0.82, 0.82, 1))

    -- HOW LONG THESE PRIZES ARE STILL WORTH PLAYING FOR, on the far right of
    -- the same row.
    --
    -- The table underneath says what each rank is paid; the one thing it does
    -- not say is when the ranking closes, and that is the number that decides
    -- whether a player has time to climb. It used to be available only in the
    -- lobby header, a screen away from the prizes it applies to.
    --
    -- Every unit, down to the second, and the word LEFT: "4D 05H 12M 07S
    -- LEFT". There is room for the whole thing on this row, and a countdown
    -- that silently changes which fields it shows is harder to read at a
    -- glance than one that always shows the same four. LEFT is what makes it
    -- a countdown rather than a timestamp — a bare clock beside a title could
    -- as easily be how long the season has been running.
    --
    -- Gold, and red in the last hour — see M.clock_color above.
    --
    -- Kept on `self` because rebuild() destroys every node it made: the tick
    -- in online.gui_script's update() writes straight into this node rather
    -- than rebuilding the whole panel once a second, and re-reads it from
    -- here after each rebuild.
    local secs_left = clock.remaining(ws.current_season_status)
    self.bonus_clock_node = txtR(self, cx + inner_pw/2 - C.INNER_PAD, cy,
        clock.full(secs_left), "small", M.clock_color(C, secs_left))

    -- No availability pill on the title row: season bonuses are live, and the
    -- badge that used to sit here was contradicting the real table beneath it.

    cy = cy - title_space

    track(self, ctx_ui.box(vmath.vector3(cx, cy + C.HDR_H_TABLE/2, 0), vmath.vector3(inner_pw, C.HDR_H_TABLE, 0), C.COL_GLASS))
    track(self, ctx_ui.box(vmath.vector3(cx, cy + 1, 0), vmath.vector3(inner_pw, 1, 0), C.COL_BORDER))
    txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy + C.HDR_H_TABLE/2, "RANK",  "small", C.COL_DIM)
    txtR(self, cx + inner_pw/2 - C.INNER_PAD, cy + C.HDR_H_TABLE/2, "PRIZE", "small", C.COL_DIM)

    local active = M.active_tier_index(prizes, my_pos)
    local row_h_bonus = C.ROW_H_BONUS

    if num_bonuses == 0 then
        -- The server has not sent the table yet. Said plainly rather than
        -- filled in with invented amounts, which is what this panel used to do
        -- — and a wrong prize table is worse than a late one, because nothing
        -- about it looks wrong.
        local waiting = txtL(self, cx - inner_pw/2 + C.INNER_PAD, cy - row_h_bonus/2,
            "Loading prizes...", "body", C.COL_DIM)
        gui.set_scale(waiting, vmath.vector3(0.9, 0.9, 1))
    end

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

    -- ── Back to Lobby ────────────────────────────────────────────────────────
    -- Moved here from the ONLINE screen's center header (modules/
    -- online_center.lua used to draw a bare "<" icon button there) — pinned
    -- to the extreme bottom of the panel instead of stacking right under
    -- Season Bonuses, with a centered text label and no icon glyph.
    local back_h  = 56
    local back_cy = ctx.EDGE_B + 20 + back_h / 2
    track(self, ctx_ui.box(vmath.vector3(cx, back_cy, 0), vmath.vector3(pw, back_h, 0), C.COL_BG))
    mkbtn(self, "nav_lobby", vmath.vector3(cx, back_cy, 0), vmath.vector3(pw, back_h, 0), nil, "container_bg")
    track(self, ctx_ui.text(vmath.vector3(cx, back_cy, 0), "BACK TO LOBBY", "btn_lg", C.COL_WHITE))
end

return M