-- Right sidebar: Profile card, Standing badge, Form, Payments, Battles, Tournaments.
-- Also manages the Battle Creation/Update modal and the Invite Search overlay.

local ws            = require("modules.websocket_manager")
local dialog_search = require("modules.dialog_search")

local M = {}

-- Battle stakes cap out at 2000 (the 5000 / 10000 tiers were removed).
M.BATTLE_TIERS = {
    { amount = 500,   formats = { { games = 3, charge = 75,  points = 9 } } },
    { amount = 1000,  formats = { { games = 3, charge = 75,  points = 9 }, { games = 5, charge = 125, points = 15 } } },
    { amount = 2000,  formats = { { games = 3, charge = 75,  points = 9 }, { games = 5, charge = 125, points = 15 },
                                  { games = 7, charge = 175, points = 21 }, { games = 9, charge = 225, points = 27 } } },
}

-- KNOCKOUT uses a flat low-stake ladder as its SCORE CAP (charge = cap/2).
M.KNOCKOUT_CAPS = { 100, 200, 300, 500 }

-- KNOCKOUT is a STAKED score-cap chamber: players put up one of these stake
-- amounts, and the charge is derived from the score cap (cap/2).
M.KNOCKOUT_STAKES = { 1000, 2000 }

-- PARTY uses its own flat entry-fee ladder (the stepper just cycles these).
M.PARTY_TIERS = { 100, 200, 500 }

-- The three independent battle types. Internal keys map to display labels.
M.BATTLE_TYPES = { "NORMAL", "KNOCKOUT", "PARTY" }
M.BATTLE_TYPE_LABELS = { NORMAL = "BATTLE", KNOCKOUT = "KNOCKOUT", PARTY = "PARTY" }

-- Battle types the UI is allowed to SHOW. PARTY is intentionally kept out of
-- view for now while ALL of its code — tiers, is_party branches, resolution and
-- submission — is retained. Re-enable it by simply adding "PARTY" back here.
M.BATTLE_TYPES_VISIBLE = { "NORMAL", "KNOCKOUT" }

-- Resolve the battle a user holds for a given type T ∈ {NORMAL,KNOCKOUT,PARTY}.
-- Prefers the new per-type map u.myBattles[T]; falls back to the legacy single
-- u.myBattle / u.myTournament keyed by its matchType (missing ⇒ NORMAL). A legacy
-- "ELIMINATION" matchType normalises to KNOCKOUT so old battles still resolve.
function M.battle_of_type(u, T)
    u = u or {}
    T = tostring(T or "NORMAL"):upper()
    if T == "ELIMINATION" then T = "KNOCKOUT" end
    local map = u.myBattles
    if type(map) == "table" then
        local b = map[T]
        if type(b) == "table" and next(b) ~= nil then return b end
        if T == "KNOCKOUT" then
            local legacy_b = map["ELIMINATION"]
            if type(legacy_b) == "table" and next(legacy_b) ~= nil then return legacy_b end
        end
        return nil
    end
    local legacy = u.myBattle or u.myTournament
    if type(legacy) == "table" and next(legacy) ~= nil then
        local lt = tostring(legacy.matchType or "NORMAL"):upper()
        if lt == "ELIMINATION" then lt = "KNOCKOUT" end
        if lt == T then return legacy end
    end
    return nil
end

-- Pull a numeric stake amount out of a battle record regardless of shape.
local function battle_amount(b)
    if type(b) ~= "table" then return 0 end
    return tonumber(b.stakeAmount) or tonumber((type(b.stake) == "table" and b.stake.amount) or nil) or 0
end

local INVITE_AVATAR_MAX = 60

-- Game Over inspired palette
local C_VICTORY  = vmath.vector4(0.000, 0.722, 0.831, 1.0) -- Cyan
local C_CHAMPION = vmath.vector4(1.000, 0.843, 0.000, 1.0) -- Gold
local C_BTN_TEXT = vmath.vector4(0.020, 0.090, 0.110, 1.0) -- Dark Cyan
local C_NEUTRAL  = vmath.vector4(0.812, 0.847, 0.863, 1.0) -- Light Grey

-- ── Battle Modal Drawing ──────────────────────────────────────────────────────
local function draw_battle_modal(self, ctx)
    local bm = self.battle_modal
    if not bm then return end

    local track = ctx.track
    local ui    = ctx.ui
    local mkbtn = ctx.mkbtn
    local commas = ctx.commas
    local CX, CY = ctx.CX, ctx.CY

    -- Fullscreen intercept block and radial gradient backdrop 
    -- (Replaces the flat grey modal box and container_bg image)
    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons+1] = { node = dim, id = "bm_block" }
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    -- Normalise the active type up-front so every branch agrees on it.
    local btype  = tostring(bm.type or "NORMAL"):upper()
    if btype == "ELIMINATION" then btype = "KNOCKOUT" end
    if btype ~= "KNOCKOUT" and btype ~= "PARTY" then btype = "NORMAL" end
    local is_norm  = (btype == "NORMAL")
    local is_knock = (btype == "KNOCKOUT")
    local is_party = (btype == "PARTY")

    local type_word = M.BATTLE_TYPE_LABELS[btype] or "BATTLE"
    local title     = (bm.editing and "UPDATE " or "CREATE ") .. type_word

    -- Main Title
    track(self, ui.text(vmath.vector3(CX, CY + 240, 0), title, "title", ctx.C.COL_WHITE))
    mkbtn(self, "bm_close", vmath.vector3(CX + 340, CY + 240, 0), vmath.vector3(50, 50, 0), "X", "secondary_btn")

    -- BATTLE TYPE: segmented control. Only the VISIBLE types are drawn (PARTY is
    -- hidden but its code is retained), and the row recentres to however many
    -- segments remain.
    local type_y  = CY + 140
    track(self, ui.text(vmath.vector3(CX, type_y + 42, 0), "BATTLE TYPE", "small", C_NEUTRAL))
    local seg_w   = 160
    local seg_gap = 12
    local SEG_META = {
        NORMAL   = { id = "bm_type_normal", label = "BATTLE"   },
        KNOCKOUT = { id = "bm_type_knock",  label = "KNOCKOUT" },
        PARTY    = { id = "bm_type_party",  label = "PARTY"    },
    }
    local seg_specs = {}
    for _, T in ipairs(M.BATTLE_TYPES_VISIBLE) do
        local meta = SEG_META[T]
        if meta then seg_specs[#seg_specs+1] = { id = meta.id, label = meta.label, on = (btype == T) } end
    end
    local UNSEL_C = vmath.vector4(0.16, 0.16, 0.18, 1)
    local seg_n = #seg_specs
    for i, s in ipairs(seg_specs) do
        local sx  = CX + (i - (seg_n + 1) / 2) * (seg_w + seg_gap)
        local box = track(self, ui.box(vmath.vector3(sx, type_y, 0), vmath.vector3(seg_w, 46, 0), s.on and C_VICTORY or UNSEL_C))
        self.buttons[#self.buttons+1] = { node = box, id = s.id }
        track(self, ui.text(vmath.vector3(sx, type_y, 0), s.label, "btn_md", s.on and C_BTN_TEXT or ctx.C.COL_WHITE))
    end

    -- DATA GATHERING
    local amount, fmt, winner_takes, estake, cap
    if is_norm then
        local tier = M.BATTLE_TIERS[bm.stake_i] or M.BATTLE_TIERS[1]
        local fmts = tier.formats
        if bm.fmt_i > #fmts then bm.fmt_i = #fmts end
        fmt          = fmts[bm.fmt_i] or fmts[1]
        amount       = tier.amount
        winner_takes = tier.amount * 2 - fmt.charge
    elseif is_knock then
        local si = bm.estake_i or 1
        if si < 1 then si = 1 elseif si > #M.KNOCKOUT_STAKES then si = #M.KNOCKOUT_STAKES end
        bm.estake_i = si
        estake = M.KNOCKOUT_STAKES[si]
        local ci = bm.cap_i or 2
        if ci < 1 then ci = 1 elseif ci > #M.KNOCKOUT_CAPS then ci = #M.KNOCKOUT_CAPS end
        bm.cap_i = ci
        cap = M.KNOCKOUT_CAPS[ci]
    else
        local ei = bm.elim_i or 1
        if ei < 1 then ei = 1 elseif ei > #M.PARTY_TIERS then ei = #M.PARTY_TIERS end
        bm.elim_i = ei
        amount = M.PARTY_TIERS[ei]
    end

    -- ENTRY FEE / STAKE
    local fee_y = CY + 10
    track(self, ui.text(vmath.vector3(CX, fee_y + 42, 0), is_knock and "STAKE" or "ENTRY FEE", "small", C_NEUTRAL))
    local step_w = 260
    mkbtn(self, "bm_fee_minus", vmath.vector3(CX - step_w/2 - 30, fee_y, 0), vmath.vector3(46, 46, 0), "-", "secondary_btn")
    track(self, ui.box(vmath.vector3(CX, fee_y, 0), vmath.vector3(step_w, 46, 0), ctx.C.COL_NAMEID_BG))
    track(self, ui.text(vmath.vector3(CX, fee_y, 0),
        is_knock and (commas(estake) .. " COINS") or (commas(amount) .. " COINS"), "body", C_CHAMPION))
    mkbtn(self, "bm_fee_plus", vmath.vector3(CX + step_w/2 + 30, fee_y, 0), vmath.vector3(46, 46, 0), "+", "secondary_btn")

    if is_norm then
        track(self, ui.text(vmath.vector3(CX, fee_y - 38, 0),
            string.format("Winner Takes: %s + %d Pts", commas(winner_takes), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    elseif is_party then
        track(self, ui.text(vmath.vector3(CX, fee_y - 38, 0),
            "Pooled prize · last player standing wins", "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    else
        track(self, ui.text(vmath.vector3(CX, fee_y - 38, 0),
            "Staked score chamber · charge from the cap", "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    end

    -- FORMAT / PLAYERS / CAP
    local fmt_y = CY - 110
    if is_party then
        local players = bm.players or "AUTO"
        track(self, ui.text(vmath.vector3(CX, fmt_y + 42, 0), "PLAYER COUNT", "small", C_NEUTRAL))
        mkbtn(self, "bm_players_minus", vmath.vector3(CX - step_w/2 - 30, fmt_y, 0), vmath.vector3(46, 46, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y, 0), vmath.vector3(step_w, 46, 0), ctx.C.COL_NAMEID_BG))
        local p_txt = (players == "AUTO") and "AUTO" or (tostring(players) .. " PLAYERS")
        track(self, ui.text(vmath.vector3(CX, fmt_y, 0), p_txt, "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_players_plus", vmath.vector3(CX + step_w/2 + 30, fmt_y, 0), vmath.vector3(46, 46, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 38, 0),
            (players == "AUTO") and "Auto-fill the table as players join" or "Starts once the table is full",
            "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    elseif is_knock then
        track(self, ui.text(vmath.vector3(CX, fmt_y + 42, 0), "SCORE CAP", "small", C_NEUTRAL))
        mkbtn(self, "bm_cap_minus", vmath.vector3(CX - step_w/2 - 30, fmt_y, 0), vmath.vector3(46, 46, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y, 0), vmath.vector3(step_w, 46, 0), ctx.C.COL_NAMEID_BG))
        track(self, ui.text(vmath.vector3(CX, fmt_y, 0), tostring(cap), "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_cap_plus", vmath.vector3(CX + step_w/2 + 30, fmt_y, 0), vmath.vector3(46, 46, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 38, 0),
            string.format("Charge: %d  ·  reach the cap and you're out", math.floor(cap / 2)), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    else
        track(self, ui.text(vmath.vector3(CX, fmt_y + 42, 0), "GAME FORMAT", "small", C_NEUTRAL))
        mkbtn(self, "bm_fmt_minus", vmath.vector3(CX - step_w/2 - 30, fmt_y, 0), vmath.vector3(46, 46, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y, 0), vmath.vector3(step_w, 46, 0), ctx.C.COL_NAMEID_BG))
        track(self, ui.text(vmath.vector3(CX, fmt_y, 0), "BEST OF " .. fmt.games, "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_fmt_plus", vmath.vector3(CX + step_w/2 + 30, fmt_y, 0), vmath.vector3(46, 46, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 38, 0),
            string.format("Charge: %s  ·  %d Pts to the winner", commas(fmt.charge), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    end

    if bm.msg then
        track(self, ui.text(vmath.vector3(CX, CY - 180, 0), bm.msg, "small",
            bm.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    -- Primary submission button identical to Game Over styling
    local sub_label = bm.submitting and "WAITING..." or title
    local sub_y = CY - 240
    local s_btn = track(self, ui.box(vmath.vector3(CX, sub_y, 0), vmath.vector3(360, 60, 0), C_VICTORY))
    self.buttons[#self.buttons+1] = { node = s_btn, id = "bm_submit" }
    track(self, ui.text(vmath.vector3(CX, sub_y, 0), sub_label, "btn_lg", C_BTN_TEXT))
end

-- ── Invite Modal Drawing ──────────────────────────────────────────────────────
local function draw_invite_search(self, ctx)
    -- The battle/knockout quick-invite renders the SHARED random-opponent reel
    -- dialog (modules/dialog_search) — the same overlay the tournament map uses.
    dialog_search.draw(self, ctx, self.invite_search, "invite_reel_node")
end


-- ── Main Right Panel Drawing ──────────────────────────────────────────────────
function M.draw(self, ctx, left_M)
    local C          = ctx.C
    local track      = ctx.track
    local txtL       = ctx.txtL
    local txtR       = ctx.txtR
    local mkbtn      = ctx.mkbtn
    local glass      = ctx.glass
    local commas     = ctx.commas
    local get_layout = ctx.get_layout
    local ui         = ctx.ui

    local u = ws.current_user_data or {}
    local _, right_w, _, div_rx = get_layout()
    local pw  = (ctx.EDGE_R - div_rx) - (C.SIDE_MARGIN * 2)
    local cx  = (div_rx + ctx.EDGE_R) / 2
    local cy  = ctx.EDGE_T - 16

    -- ── User info container ───────────────────────────────────────────────
    local margin   = 15
    local av_size  = 64
    local info_h   = 64
    local list_h   = 80
    local pay_h    = 44
    local gap      = 12
    local cont_h   = margin + info_h + gap + list_h + gap + pay_h + margin
    local ccy      = cy - cont_h / 2
    glass(self, vmath.vector3(cx, ccy, 0), vmath.vector3(pw, cont_h, 0), "container_bg")

    local inner_l = cx - pw/2 + margin
    local inner_r = cx + pw/2 - margin
    local top_y   = cy - margin

    -- Avatar Only
    local av_x   = inner_l + av_size/2
    local av_cy  = top_y - av_size/2
    
    track(self, ui.avatar(vmath.vector3(av_x, av_cy, 0), vmath.vector3(av_size, av_size, 0), u.avatar or 1))

    local info_l  = av_x + av_size/2 + 15
    local info_w  = inner_r - info_l
    local info_cx = (info_l + inner_r) / 2

    -- Name pill
    local name_h = 28
    local name_y = top_y - name_h/2
    track(self, ui.box(vmath.vector3(info_cx, name_y, 0), vmath.vector3(info_w, name_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 10, name_y, string.upper(u.username or "PLAYER"), "body", C.COL_BRIGHT)

    -- Edit icon from atlas → opens the profile screen to edit username/avatar.
    mkbtn(self, "nav_account", vmath.vector3(inner_r - 16, name_y, 0), vmath.vector3(30, 30, 0), nil, vmath.vector4(0,0,0,0))
    local acc_edit = track(self, ui.image(vmath.vector3(inner_r - 16, name_y, 0), vmath.vector3(18, 18, 0), "edit"))
    gui.set_color(acc_edit, C.COL_WHITE)

    -- Balance + Points
    local stat_h  = 28
    local stat_y  = name_y - name_h/2 - 4 - stat_h/2
    local pts_w   = 100
    local bal_w   = info_w - pts_w - 6
    local bal_cx  = info_l + bal_w/2
    local pts_cx  = inner_r - pts_w/2
    local COL_ORANGE = vmath.vector4(1.0, 0.6, 0.0, 1.0)
    
    track(self, ui.box(vmath.vector3(bal_cx, stat_y, 0), vmath.vector3(bal_w, stat_h, 0), C.COL_STAT_BG))
    txtL(self, info_l + 8, stat_y, "BAL.", "small", COL_ORANGE)
    txtR(self, info_l + bal_w - 6, stat_y, commas(u.balance or 0), "body", COL_ORANGE)
    
    track(self, ui.box(vmath.vector3(pts_cx, stat_y, 0), vmath.vector3(pts_w, stat_h, 0), C.COL_STAT_BG))
    txtL(self, pts_cx - pts_w/2 + 8, stat_y, "PTS.", "small", C.COL_DIM)
    txtR(self, pts_cx + pts_w/2 - 8, stat_y, commas(u.points or 0), "body", C.COL_CYAN)

    -- Stats List (Position & Form)
    local lcy = top_y - info_h - gap - list_h/2
    local bw  = pw - margin*2
    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw, list_h, 0), C.COL_STAT_BG))

    local pos      = tonumber(u.position) or -1
    local has_rank = pos > 0
    local accent_col = has_rank and C.COL_GOLD or C.COL_DIM
    local row_h = list_h / 2

    -- Divider
    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))

    -- Row 1: Your Position
    local r1_y = lcy + row_h/2
    txtL(self, cx - bw/2 + 12, r1_y, "YOUR POSITION", "small", C.COL_DIM)
    txtR(self, cx + bw/2 - 12, r1_y, has_rank and ("#"..pos) or "UNRANKED", "body", accent_col)

    -- Row 2: Your Current Form
    local r2_y = lcy - row_h/2
    txtL(self, cx - bw/2 + 12, r2_y, "YOUR CURRENT FORM", "small", C.COL_DIM)

    local form = type(u.recentForm) == "table" and u.recentForm or {}
    local fsz, fgap = 26, 6 
    local fx0 = cx + bw/2 - 12 - fsz/2
    for i = 1, 5 do
        local r  = form[i]
        local bx = fx0 - (i - 1) * (fsz + fgap)
        if r == "W" or r == "L" then
            track(self, ui.box(vmath.vector3(bx, r2_y, 0), vmath.vector3(fsz, fsz, 0),
                r == "W" and vmath.vector4(0.15, 0.70, 0.25, 0.92) or vmath.vector4(0.90, 0.25, 0.25, 0.92)))
            track(self, ui.text(vmath.vector3(bx, r2_y, 0), r, "body", C.COL_WHITE))
        else
            track(self, ui.box(vmath.vector3(bx, r2_y, 0), vmath.vector3(fsz, fsz, 0), vmath.vector4(1, 1, 1, 0.06)))
        end
    end

    -- Make Payments button
    local pay_y = lcy - list_h/2 - gap - pay_h/2
    mkbtn(self, "nav_payments", vmath.vector3(cx, pay_y, 0), vmath.vector3(pw - margin*2, pay_h, 0), "MAKE PAYMENTS", "primary_btn")

    cy = cy - cont_h - C.BLOCK_GAP

    -- ── Battles panel (three independent types) ───────────────────────────
    -- Each row is INDEPENDENT — it either shows the battle's summary with 
    -- INVITE/EDIT, or a single CREATE button for that type.
    local row_h    = 74
    local top_pad  = 12
    local bot_pad  = 12
    -- Only the visible battle types get a row (PARTY hidden; code retained).
    local list_types = M.BATTLE_TYPES_VISIBLE
    local battle_h = top_pad + (row_h * #list_types) + bot_pad
    local scy = cy - battle_h/2
    glass(self, vmath.vector3(cx, scy, 0), vmath.vector3(pw, battle_h, 0), "container_bg")

    local rows_top = cy - top_pad
    local row_l    = cx - pw/2 + 16
    local row_r    = cx + pw/2 - 16

    for ri, T in ipairs(list_types) do
        local row_cy = rows_top - (ri - 0.5) * row_h
        -- Subtle divider above every row except the first.
        if ri > 1 then
            track(self, ui.box(vmath.vector3(cx, rows_top - (ri - 1) * row_h, 0), vmath.vector3(pw - 32, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
        end

        local icon_name = (T == "NORMAL") and "battle_icon" or (T == "KNOCKOUT" and "knockout" or "party")
        local icon_x = row_l + 20
        local type_icon = track(self, ui.image(vmath.vector3(icon_x, row_cy, 0), vmath.vector3(42, 42, 0), icon_name))
        gui.set_color(type_icon, C.COL_WHITE)

        local text_x = icon_x + 32
        local label = M.BATTLE_TYPE_LABELS[T] or T
        txtL(self, text_x, row_cy + 10, label, "btn_md", C.COL_WHITE)

        local invite_w = 100
        local btn_h    = 42
        local edit_w   = 42 -- perfectly square inspiration
        local pair_gap = 10

        local b = M.battle_of_type(u, T)
        if b then
            local amt = battle_amount(b)
            local detail
            if T == "PARTY" then
                local players = b.players or "AUTO"
                local pstr    = (type(players) == "table") and tostring(#players) or tostring(players)
                detail = string.format("%s PLAYERS  ~  %s", pstr, commas(amt))
            elseif T == "KNOCKOUT" then
                local cap = tonumber(b.scoreCap) or 200
                detail = string.format("CAP %d  ~  %s", cap, commas(amt))
            else
                local fmt = tonumber(b.matchFormat) or 3
                detail = string.format("BEST OF %d  ~  %s", fmt, commas(amt))
            end
            -- Replaced green with the Game Over light grey (C_NEUTRAL)
            txtL(self, text_x, row_cy - 12, detail, "small", C_NEUTRAL)

            local edit_bx   = row_r - edit_w/2
            local invite_bx = edit_bx - edit_w/2 - pair_gap - invite_w/2

            mkbtn(self, "nav_invite", vmath.vector3(invite_bx, row_cy, 0), vmath.vector3(invite_w, btn_h, 0), "INVITE", "primary_btn", T, "btn_md")
            
            -- Edit button constructed with the edit icon from the atlas
            mkbtn(self, "update_battle", vmath.vector3(edit_bx, row_cy, 0), vmath.vector3(edit_w, btn_h, 0), "", "secondary_btn", T)
            local eicon = track(self, ui.image(vmath.vector3(edit_bx, row_cy, 0), vmath.vector3(20, 20, 0), "edit"))
            gui.set_color(eicon, C.COL_WHITE)
        else
            txtL(self, text_x, row_cy - 12, "Not created yet", "small", C.COL_DIM)
            local create_w = 144
            local create_bx  = row_r - create_w/2
            local create_lbl = "+ CREATE"
            mkbtn(self, "create_battle", vmath.vector3(create_bx, row_cy, 0), vmath.vector3(create_w, btn_h, 0), create_lbl, "primary_btn", T, "btn_md")
        end
    end
    cy = cy - battle_h - C.BLOCK_GAP

    -- ── Tournaments panel ─────────────────────────────────────────────────
    local t_h  = 64
    local tcy2 = cy - t_h/2
    track(self, ui.box(vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), C.COL_BG))
    mkbtn(self, "nav_tournaments", vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), nil, "container_bg")
    
    local icon_x = cx - 74
    local t_icon = track(self, ui.image(vmath.vector3(icon_x, tcy2, 0), vmath.vector3(28, 28, 0), "tournament_icon"))
    gui.set_color(t_icon, C.COL_WHITE)
    txtL(self, icon_x + 22, tcy2, "TOURNAMENTS", "btn_md", C.COL_WHITE)

    local nx = cx + pw/2 - 36
    local ny = tcy2
    track(self, ui.box(vmath.vector3(nx, ny, 0), vmath.vector3(44, 18, 0), vmath.vector4(0.15, 0.8, 0.25, 1.0)))
    track(self, ui.box(vmath.vector3(nx, ny + 9, 0), vmath.vector3(44, 1, 0), C.COL_WHITE))
    track(self, ui.text(vmath.vector3(nx, ny, 0), "NEW", "btn_sm", C.COL_WHITE))
    cy = cy - t_h - C.BLOCK_GAP

    -- Themes moved to the main lobby (THEME utility tile). No footer link here.

    -- ── Draw Extracted Modals on Top ──────────────────────────────────────
    draw_battle_modal(self, ctx)
    draw_invite_search(self, ctx)
end

-- ── Input Action Exports for Main Script ─────────────────────────────────────
function M.bm_submit(self, rebuild_cb)
    local bm = self.battle_modal
    if not bm or bm.submitting then return end

    local btype = tostring(bm.type or "NORMAL"):upper()
    if btype == "ELIMINATION" then btype = "KNOCKOUT" end
    if btype ~= "KNOCKOUT" and btype ~= "PARTY" then btype = "NORMAL" end

    local uid  = ws.get_current_user_id()
    if uid == "" then
        bm.msg, bm.msg_ok = "User ID missing. Please log in.", false
        rebuild_cb(); return
    end

    -- Amount/cap come from the ladder selected by the battle type.
    -- KNOCKOUT: a STAKED score-cap chamber — amount is the KNOCKOUT_STAKES stake
    -- (1000/2000) and scoreCap is the KNOCKOUT_CAPS cap (charge = cap/2).
    -- PARTY: PARTY_TIERS is the entry fee. NORMAL: bracket tier.
    local amount, match_format, score_cap
    if btype == "NORMAL" then
        local tier = M.BATTLE_TIERS[bm.stake_i] or M.BATTLE_TIERS[1]
        local fmt  = tier.formats[math.min(bm.fmt_i or 1, #tier.formats)]
        amount       = tier.amount
        match_format = fmt.games
    elseif btype == "KNOCKOUT" then
        match_format = 1
        amount       = M.KNOCKOUT_STAKES[bm.estake_i or 1] or M.KNOCKOUT_STAKES[1]
        score_cap    = M.KNOCKOUT_CAPS[bm.cap_i or 2] or M.KNOCKOUT_CAPS[2]
    else
        local ei = bm.elim_i or 1
        if ei < 1 then ei = 1 elseif ei > #M.PARTY_TIERS then ei = #M.PARTY_TIERS end
        match_format = 1
        amount       = M.PARTY_TIERS[ei]
    end

    bm.submitting = true; bm.msg, bm.msg_ok = nil, nil; rebuild_cb()

    local payload = { userId = uid, amount = amount, matchFormat = match_format, rules = "JOKERS",
                      matchType = btype }
    if btype == "KNOCKOUT" then payload.scoreCap = score_cap end
    if btype == "PARTY" then payload.players = bm.players or "AUTO" end

    local function on_result(result)
        local cur = self.battle_modal
        if not cur then return end
        cur.submitting = false
        if result.success then
            local data   = result.data or {}
            local battle = data.tournament or data.data or data
            local u      = ws.current_user_data or {}
            -- Store the result per-type so the three rows stay independent, and
            -- keep the legacy single field pointed at the last-touched battle.
            u.myBattles = (type(u.myBattles) == "table") and u.myBattles or {}
            u.myBattles[btype] = battle
            u.myBattle  = battle; ws.current_user_data = u
            cur.msg, cur.msg_ok = bm.editing and "Battle updated successfully!" or "Battle created successfully!", true
            if self._active then rebuild_cb() end
            timer.delay(1.0, false, function()
                if self.battle_modal == cur then
                    self.battle_modal = nil
                    if self._active then rebuild_cb() end
                end
            end)
        else
            cur.msg, cur.msg_ok = result.message or "Request failed", false
            if self._active then rebuild_cb() end
        end
    end

    local api = require("modules.api_service")
    if bm.editing and bm.id and bm.id ~= "" then
        api.update_tournament(bm.id, payload, on_result)
    else
        api.create_tournament(payload, on_result)
    end
end

function M.start_invite_search(self, app_state, rebuild_cb, battle_type)
    local u  = ws.current_user_data or {}
    local mb = M.battle_of_type(u, battle_type or "NORMAL")
    if type(mb) ~= "table" or next(mb) == nil then return false end

    local stake = (type(mb.stake) == "table") and mb.stake or { amount = tonumber(mb.stakeAmount) or 0, charge = 0 }

    -- Can't cover this battle's stake (amount + charge)? Open payments instead of
    -- starting a matchmaking search the server would reject for low balance. Return
    -- false so the caller skips the "searching" sound/animation.
    local need = (tonumber(stake.amount) or 0) + (tonumber(stake.charge) or 0)
    local bal  = tonumber((ws.current_user_data or {}).balance) or 0
    if need > 0 and bal < need then
        msg.post("#controller", "goto_payments")
        return false
    end

    self.invite_search = { active = true, t = 0, reel_ix = math.random(INVITE_AVATAR_MAX), spin_t = 0 }
    app_state.searching_invite = true

    ws.send_game_request({}, stake, {
        gameType     = "TOURNAMENT",
        tournamentId = tostring(mb._id or mb.id or ""),
        rules        = "JOKERS",
        matchType    = (tostring(mb.matchType or battle_type or "NORMAL"):upper()),
    })

    -- Add a 10-second auto-timeout. Instead of closing abruptly, show a clear
    -- "NO OPPONENT FOUND" state, play the fail sound, then close after a short beat.
    self.invite_search.timer_handle = timer.delay(10, false, function()
        if self.invite_search and not self.invite_search.found then
            M.fail_invite_search(self, app_state, rebuild_cb, "No one accepted your invite")
        end
    end)

    rebuild_cb()
    return true
end

-- Transition the invite overlay into the "no opponent found" state: render the
-- NO OPPONENT FOUND message + miss transition, play a playful fail sound, then
-- close after ~1.5s (instead of the overlay just snapping shut).
function M.fail_invite_search(self, app_state, rebuild_cb, reason)
    local sr = self.invite_search
    if not sr or sr.found or sr.failed then return end

    -- Cancel the auto-timeout so it can't fire again on top of this.
    if sr.timer_handle then pcall(timer.cancel, sr.timer_handle); sr.timer_handle = nil end

    sr.failed   = true
    sr.fail_msg = reason or "No one accepted your invite"
    app_state.searching_invite = false

    -- Stop the looping search cue and play a playful fail sting on the controller.
    pcall(msg.post, "#snd_suspense", "stop_sound")
    pcall(msg.post, "#snd_fail", "play_sound")

    rebuild_cb()

    -- Close after a short beat so the player reads the message + sees the transition.
    timer.delay(1.5, false, function()
        if self.invite_search == sr then
            M.stop_invite_search(self, app_state, rebuild_cb)
        end
    end)
end

function M.stop_invite_search(self, app_state, rebuild_cb)
    -- Clean up timer if cancelled early
    if self.invite_search and self.invite_search.timer_handle then
        pcall(timer.cancel, self.invite_search.timer_handle)
    end
    
    self.invite_search = nil
    self.invite_reel_node = nil
    app_state.searching_invite = false
    rebuild_cb()
end

return M