-- Right sidebar: Profile card, Standing badge, Form, Payments, Battles, Tournaments.
-- Also manages the Battle Creation/Update modal and the Invite Search overlay.

local ws = require("modules.websocket_manager")

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
local BM_TAN = vmath.vector4(0.702, 0.604, 0.467, 1)

-- ── Battle Modal Drawing ──────────────────────────────────────────────────────
local function draw_battle_modal(self, ctx)
    local bm = self.battle_modal
    if not bm then return end

    local track = ctx.track
    local ui    = ctx.ui
    local mkbtn = ctx.mkbtn
    local txtL  = ctx.txtL
    local commas = ctx.commas
    local CX, CY = ctx.CX, ctx.CY

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.8)))
    self.buttons[#self.buttons+1] = { node = dim, id = "bm_block" }

    -- Further reduced the height to perfectly close the empty space gap
    local pw, ph = 500, 410
    track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(pw, ph, 0), ctx.C.COL_BG))
    track(self, ui.btn9(vmath.vector3(CX, CY, 0), vmath.vector3(pw, ph, 0), "container_bg"))

    local l   = CX - pw/2 + 30
    local r   = CX + pw/2 - 30
    local top = CY + ph/2 - 30

    -- Normalise the active type up-front so every branch agrees on it.
    local btype  = tostring(bm.type or "NORMAL"):upper()
    if btype == "ELIMINATION" then btype = "KNOCKOUT" end
    if btype ~= "KNOCKOUT" and btype ~= "PARTY" then btype = "NORMAL" end
    local is_norm  = (btype == "NORMAL")
    local is_knock = (btype == "KNOCKOUT")
    local is_party = (btype == "PARTY")

    local type_word = M.BATTLE_TYPE_LABELS[btype] or "BATTLE"
    local title     = (bm.editing and "UPDATE " or "CREATE ") .. type_word
    txtL(self, l, top - 8, title, "body", ctx.C.COL_WHITE)
    mkbtn(self, "bm_close", vmath.vector3(r - 10, top - 8, 0), vmath.vector3(30, 30, 0), nil, vmath.vector4(0,0,0,0.001))
    track(self, ui.text(vmath.vector3(r - 10, top - 8, 0), "X", "btn_sm", ctx.C.COL_MID))

    -- BATTLE TYPE: three-way segmented control (BATTLE / KNOCKOUT / PARTY).
    -- Battles share the same model / endpoints as tournaments; the backend stores
    -- matchType = "NORMAL" | "KNOCKOUT" | "PARTY".
    local type_y  = top - 50
    txtL(self, l, type_y + 26, "BATTLE TYPE", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
    local seg_gap = 8
    local seg_w   = (pw - 60 - seg_gap * 2) / 3
    local seg_specs = {
        { id = "bm_type_normal", label = "BATTLE",   on = is_norm  },
        { id = "bm_type_knock",  label = "KNOCKOUT", on = is_knock },
        { id = "bm_type_party",  label = "PARTY",    on = is_party },
    }
    local SEL_C, UNSEL_C = vmath.vector4(0.45, 0.14, 0.58, 0.95), vmath.vector4(0.16, 0.16, 0.18, 1)
    local seg0_cx = l + seg_w/2
    for i, s in ipairs(seg_specs) do
        local sx  = seg0_cx + (i - 1) * (seg_w + seg_gap)
        local box = track(self, ui.box(vmath.vector3(sx, type_y - 10, 0), vmath.vector3(seg_w, 40, 0), s.on and SEL_C or UNSEL_C))
        self.buttons[#self.buttons+1] = { node = box, id = s.id }
        track(self, ui.text(vmath.vector3(sx, type_y - 10, 0), s.label, "btn_sm", s.on and ctx.C.COL_WHITE or ctx.C.COL_MID))
    end

    -- ENTRY FEE: NORMAL cycles BATTLE_TIERS (bm.stake_i); PARTY cycles the flat
    -- PARTY_TIERS amounts (bm.elim_i). KNOCKOUT is a STAKED chamber:
    -- it stakes KNOCKOUT_STAKES (bm.estake_i) and caps on KNOCKOUT_CAPS (bm.cap_i).
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

    -- Row 1: NORMAL/PARTY pick an ENTRY FEE (coins); KNOCKOUT picks a STAKE
    -- (one of the KNOCKOUT_STAKES amounts). NORMAL/PARTY cycle their ladders via
    -- bm.stake_i / bm.elim_i; KNOCKOUT cycles KNOCKOUT_STAKES via bm.estake_i.
    local fee_y = top - 120
    txtL(self, l, fee_y + 28, is_knock and "STAKE" or "ENTRY FEE", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
    mkbtn(self, "bm_fee_minus", vmath.vector3(l + 20, fee_y - 8, 0), vmath.vector3(40, 40, 0), "-", "secondary_btn")
    track(self, ui.box(vmath.vector3(CX, fee_y - 8, 0), vmath.vector3(pw - 200, 40, 0), ctx.C.COL_NAMEID_BG))
    track(self, ui.text(vmath.vector3(CX, fee_y - 8, 0),
        is_knock and (commas(estake) .. " COINS") or (commas(amount) .. " COINS"), "body", vmath.vector4(1, 0.8, 0.4, 1)))
    mkbtn(self, "bm_fee_plus", vmath.vector3(r - 20, fee_y - 8, 0), vmath.vector3(40, 40, 0), "+", "secondary_btn")
    if is_norm then
        track(self, ui.text(vmath.vector3(CX, fee_y - 44, 0),
            string.format("Winner Takes: %s + %d Pts", commas(winner_takes), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    elseif is_party then
        track(self, ui.text(vmath.vector3(CX, fee_y - 44, 0),
            "Pooled prize · last player standing wins", "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    else
        track(self, ui.text(vmath.vector3(CX, fee_y - 44, 0),
            "Staked score chamber · charge from the cap", "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    end

    -- Bottom row: PARTY shows a PLAYER COUNT selector; KNOCKOUT shows a SCORE
    -- CAP selector (reach the cap and you're out; charge = cap/2); NORMAL keeps
    -- the GAME FORMAT (BEST OF) stepper.
    local fmt_y = top - 212
    if is_party then
        local players = bm.players or "AUTO"
        txtL(self, l, fmt_y + 28, "PLAYER COUNT", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
        mkbtn(self, "bm_players_minus", vmath.vector3(l + 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y - 8, 0), vmath.vector3(pw - 200, 40, 0), ctx.C.COL_NAMEID_BG))
        local p_txt = (players == "AUTO") and "AUTO" or (tostring(players) .. " PLAYERS")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 8, 0), p_txt, "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_players_plus", vmath.vector3(r - 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 44, 0),
            (players == "AUTO") and "Auto-fill the table as players join" or "Starts once the table is full",
            "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    elseif is_knock then
        txtL(self, l, fmt_y + 28, "SCORE CAP", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
        mkbtn(self, "bm_cap_minus", vmath.vector3(l + 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y - 8, 0), vmath.vector3(pw - 200, 40, 0), ctx.C.COL_NAMEID_BG))
        track(self, ui.text(vmath.vector3(CX, fmt_y - 8, 0), tostring(cap), "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_cap_plus", vmath.vector3(r - 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 44, 0),
            string.format("Charge: %d  ·  reach the cap and you're out", math.floor(cap / 2)), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    else
        txtL(self, l, fmt_y + 28, "GAME FORMAT", "small", vmath.vector4(0.7, 0.7, 0.7, 1))
        mkbtn(self, "bm_fmt_minus", vmath.vector3(l + 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y - 8, 0), vmath.vector3(pw - 200, 40, 0), ctx.C.COL_NAMEID_BG))
        track(self, ui.text(vmath.vector3(CX, fmt_y - 8, 0), "BEST OF " .. fmt.games, "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_fmt_plus", vmath.vector3(r - 20, fmt_y - 8, 0), vmath.vector3(40, 40, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 44, 0),
            string.format("Charge: %s  ·  %d Pts to the winner", commas(fmt.charge), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    end

    if bm.msg then
        track(self, ui.text(vmath.vector3(CX, CY - ph/2 + 102, 0), bm.msg, "small",
            bm.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    local sub_label = bm.submitting and "SUBMITTING..." or title
    mkbtn(self, "bm_submit", vmath.vector3(CX, CY - ph/2 + 46, 0), vmath.vector3(pw - 60, 60, 0), sub_label, "secondary_btn", nil, "btn_md", BM_TAN)
end

-- ── Invite Modal Drawing ──────────────────────────────────────────────────────
local function draw_invite_search(self, ctx)
    local sr = self.invite_search
    if not sr then return end

    local track = ctx.track
    local ui    = ctx.ui
    local CX, CY = ctx.CX, ctx.CY

    track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W * 2, ctx.LOGICAL_H * 2, 0), vmath.vector4(0, 0, 0, 0.78)))
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    local title = sr.found and "OPPONENT FOUND!" or (sr.failed and "NO OPPONENT FOUND" or "SEARCHING FOR OPPONENT")
    local t_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1) or (sr.failed and ctx.C.COL_GOLD or ctx.C.COL_WHITE)
    track(self, ui.text(vmath.vector3(CX, CY + 130, 0), title, "title", t_col))

    if sr.failed then
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), sr.fail_msg or "No one accepted your invite", "small", ctx.C.COL_DIM))
    elseif not sr.found then
        local dots = string.rep(".", 1 + (math.floor((sr.t or 0) * 2) % 3))
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), "inviting a player to your battle" .. dots, "small", ctx.C.COL_DIM))
    else
        track(self, ui.text(vmath.vector3(CX, CY + 96, 0), "get ready…", "small", ctx.C.COL_DIM))
    end

    local u = ws.current_user_data or {}
    local ax, bx, ay = CX - 190, CX + 190, CY - 10

    track(self, ui.box(vmath.vector3(ax, ay, 0), vmath.vector3(124, 124, 0), vmath.vector4(0.10, 0.10, 0.13, 0.9)))
    track(self, ui.avatar(vmath.vector3(ax, ay, 0), vmath.vector3(108, 108, 0), u.avatar or 1))
    track(self, ui.text(vmath.vector3(ax, ay - 86, 0), "YOU", "body", ctx.C.COL_GOLD))
    track(self, ui.text(vmath.vector3(CX, ay, 0), "VS", "title", vmath.vector4(1, 0.4, 0.4, 1)))

    local frame_col = sr.found and vmath.vector4(0.15, 0.85, 0.35, 1)
        or (sr.failed and vmath.vector4(0.85, 0.25, 0.25, 1) or vmath.vector4(0.25, 0.25, 0.30, 1))
    local frame = track(self, ui.box(vmath.vector3(bx, ay, 0), vmath.vector3(124, 124, 0), frame_col))
    local reel  = track(self, ui.avatar(vmath.vector3(bx, ay, 0), vmath.vector3(108, 108, 0), sr.reel_ix or 1))
    self.invite_reel_node = reel
    if sr.failed then
        -- Freeze + dim the slot: drop the reel-node handle so the online update
        -- loop stops cycling avatars into this (now failed) slot.
        gui.set_color(reel, vmath.vector4(0.55, 0.55, 0.55, 1))
        self.invite_reel_node = nil
    end
    local who = sr.found and (sr.opp_name or "PLAYER") or (sr.failed and "—" or "? ? ?")
    track(self, ui.text(vmath.vector3(bx, ay - 86, 0), who, "body", sr.found and ctx.C.COL_WHITE or ctx.C.COL_DIM))

    if sr.found then
        gui.set_scale(frame, vmath.vector3(0.9, 0.9, 1))
        gui.animate(frame, "scale", vmath.vector3(1.12, 1.12, 1), gui.EASING_OUTBACK, 0.35, 0, function()
            pcall(gui.animate, frame, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTSINE, 0.18)
        end)
    elseif sr.failed then
        -- "no opponent" transition: the empty slot shakes and fades back, signalling
        -- the miss before the overlay closes. Run the shake only on the first failed
        -- rebuild so the periodic redraw underneath doesn't restart it each frame.
        if not sr.failed_anim then
            sr.failed_anim = true
            gui.animate(frame, "position.x", bx + 10, gui.EASING_OUTSINE, 0.06, 0, function()
                pcall(gui.animate, frame, "position.x", bx - 8, gui.EASING_INOUTSINE, 0.08, 0, function()
                    pcall(gui.animate, frame, "position.x", bx, gui.EASING_OUTSINE, 0.06)
                end)
            end, gui.PLAYBACK_ONCE_FORWARD)
        end
        gui.set_color(frame, vmath.vector4(0.85, 0.25, 0.25, 0.6))
    else
        -- Native, fully smooth animated timer
        local time_left = math.max(0, 10 - (sr.t or 0))
        local frac = time_left / 10
        local R = 34
        
        local bg = track(self, gui.new_pie_node(vmath.vector3(CX, CY - 140, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(bg, 48)
        pcall(gui.set_inner_radius, bg, R * 0.80)
        gui.set_color(bg, vmath.vector4(0.25, 0.25, 0.25, 0.45))

        local col = time_left <= 3 and ctx.C.COL_RED or ctx.C.COL_CYAN
        local fg = track(self, gui.new_pie_node(vmath.vector3(CX, CY - 140, 0), vmath.vector3(R*2, R*2, 0)))
        gui.set_perimeter_vertices(fg, 48)
        pcall(gui.set_inner_radius, fg, R * 0.80)
        gui.set_rotation(fg, vmath.vector3(0, 0, 90))
        gui.set_fill_angle(fg, frac * 360)
        gui.set_color(fg, col)
        
        -- Native engine tween over properties guarantees 60fps independent of redraw cycle
        if time_left > 0 then
            pcall(gui.animate, fg, "fill_angle", 0, gui.EASING_LINEAR, time_left)
        end
        
        track(self, ui.text(vmath.vector3(CX, CY - 140, 0), tostring(math.ceil(time_left)), "title", col))
    end
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
    local av_size  = 96
    local name_h   = 30
    local stat_h   = 32
    local name_gap = 8
    local list_h   = 160 -- Expanded to fit 4 rows
    local pay_h    = 44
    local gap      = 12
    local prof_h   = math.max(av_size, name_h + name_gap + stat_h)
    local cont_h   = margin + prof_h + gap + list_h + gap + pay_h + margin
    local ccy      = cy - cont_h / 2
    glass(self, vmath.vector3(cx, ccy, 0), vmath.vector3(pw, cont_h, 0), "container_bg")

    local inner_l = cx - pw/2 + margin
    local inner_r = cx + pw/2 - margin
    local top_y   = cy - margin

    -- Avatar Only (Removed floating badge and rings)
    local av_x   = inner_l + av_size/2
    local av_cy  = top_y - prof_h/2
    local rating = (tonumber(u.winRate) or 0) / 10
    local r_col  = rating >= 6 and C.COL_GREEN or (rating >= 4 and C.COL_GOLD or C.COL_RED)
    
    track(self, ui.avatar(vmath.vector3(av_x, av_cy, 0), vmath.vector3(av_size, av_size, 0), u.avatar or 1))

    local info_l  = av_x + av_size/2 + 20
    local info_w  = inner_r - info_l
    local info_cx = (info_l + inner_r) / 2

    -- Name pill
    local name_y = top_y - name_h/2
    track(self, ui.box(vmath.vector3(info_cx, name_y, 0), vmath.vector3(info_w, name_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 10, name_y, string.upper(u.username or "PLAYER"), "body", C.COL_BRIGHT)

    -- Pencil icon → opens the profile screen to edit username/avatar.
    mkbtn(self, "nav_account", vmath.vector3(inner_r - 16, name_y, 0), vmath.vector3(30, 30, 0), nil, vmath.vector4(0,0,0,0))
    local COL_PENCIL = vmath.vector4(1.0, 0.78, 0.18, 1.0)
    -- diagonal pencil body
    local body = track(self, ui.box(vmath.vector3(inner_r - 16, name_y + 1, 0), vmath.vector3(16, 5, 0), COL_PENCIL))
    gui.set_rotation(body, vmath.vector3(0, 0, 45))
    -- pencil tip (dark nib at the lower-left end)
    local tip = track(self, ui.box(vmath.vector3(inner_r - 21, name_y - 4, 0), vmath.vector3(5, 5, 0), C.COL_DIM))
    gui.set_rotation(tip, vmath.vector3(0, 0, 45))

    -- Balance + Points
    local stat_y  = name_y - name_h/2 - name_gap - stat_h/2
    local pts_w   = 115
    local bal_w   = info_w - pts_w - 8
    local bal_cx  = info_l + bal_w/2
    local pts_cx  = inner_r - pts_w/2
    local COL_ORANGE = vmath.vector4(1.0, 0.6, 0.0, 1.0)
    
    track(self, ui.box(vmath.vector3(bal_cx, stat_y, 0), vmath.vector3(bal_w, stat_h, 0), C.COL_STAT_BG))
    txtL(self, info_l + 8, stat_y, "BAL.", "small", COL_ORANGE)
    txtR(self, info_l + bal_w - 6, stat_y, commas(u.balance or 0), "body", COL_ORANGE)
    
    track(self, ui.box(vmath.vector3(pts_cx, stat_y, 0), vmath.vector3(pts_w, stat_h, 0), C.COL_STAT_BG))
    txtL(self, pts_cx - pts_w/2 + 8, stat_y, "PTS.", "small", C.COL_DIM)
    txtR(self, pts_cx + pts_w/2 - 8, stat_y, commas(u.points or 0), "body", C.COL_CYAN)

    -- Combined Stats List (Rating, Position, Reward, Form)
    local pos      = tonumber(u.position) or -1
    local has_rank = pos > 0
    local bw       = pw - margin * 2
    local lcy      = top_y - prof_h - gap - list_h/2

    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw, list_h, 0), C.COL_STAT_BG))
    
    local accent_col = has_rank and C.COL_GOLD or C.COL_DIM
    local row_h = list_h / 4

    -- Dividers
    track(self, ui.box(vmath.vector3(cx, lcy + list_h/4, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
    track(self, ui.box(vmath.vector3(cx, lcy - list_h/4, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))

    -- Row 1: Your Rating
    local r1_y = lcy + list_h/2 - row_h/2
    txtL(self, cx - bw/2 + 12, r1_y, "YOUR RATING", "small", C.COL_DIM)
    txtR(self, cx + bw/2 - 12, r1_y, string.format("%.1f", rating), "body", r_col)

    -- Row 2: Your Position
    local r2_y = lcy + list_h/2 - row_h*1.5
    txtL(self, cx - bw/2 + 12, r2_y, "YOUR POSITION", "small", C.COL_DIM)
    txtR(self, cx + bw/2 - 12, r2_y, has_rank and ("#"..pos) or "UNRANKED", "body", accent_col)

    -- Row 3: Estimated Reward
    local r3_y = lcy + list_h/2 - row_h*2.5
    txtL(self, cx - bw/2 + 12, r3_y, "ESTIMATED REWARD", "small", C.COL_DIM)
    local val = "-"
    if has_rank then
        local prizes = left_M.build_prizes(commas)
        local prize_val = left_M.prize_for_position(prizes, pos, commas)
        if prize_val ~= "" then val = prize_val end
    end
    txtR(self, cx + bw/2 - 12, r3_y, val, "body", C.COL_GREEN)

    -- Row 4: Your Current Form
    local r4_y = lcy + list_h/2 - row_h*3.5
    txtL(self, cx - bw/2 + 12, r4_y, "YOUR CURRENT FORM", "small", C.COL_DIM)

    local form = type(u.recentForm) == "table" and u.recentForm or {}
    local fsz, fgap = 26, 6 
    local fx0 = cx + bw/2 - 12 - fsz/2
    for i = 1, 5 do
        local r  = form[i]
        local bx = fx0 - (i - 1) * (fsz + fgap)
        if r == "W" or r == "L" then
            track(self, ui.box(vmath.vector3(bx, r4_y, 0), vmath.vector3(fsz, fsz, 0),
                r == "W" and vmath.vector4(0.15, 0.70, 0.25, 0.92) or vmath.vector4(0.90, 0.25, 0.25, 0.92)))
            track(self, ui.text(vmath.vector3(bx, r4_y, 0), r, "helvetica_bold", C.COL_WHITE))
        else
            track(self, ui.box(vmath.vector3(bx, r4_y, 0), vmath.vector3(fsz, fsz, 0), vmath.vector4(1, 1, 1, 0.06)))
        end
    end

    -- Make Payments button
    local pay_y = lcy - list_h/2 - gap - pay_h/2
    mkbtn(self, "nav_payments", vmath.vector3(cx, pay_y, 0), vmath.vector3(bw, pay_h, 0), "MAKE PAYMENTS", "primary_btn")

    cy = cy - cont_h - C.BLOCK_GAP

    -- ── Battles panel (three independent types) ───────────────────────────
    -- Layout: header band + 3 rows. Each row is INDEPENDENT — it either shows the
    -- battle's summary with INVITE/EDIT, or a single CREATE button for that type.
    local hdr_band = 36   -- header row (icon + "BATTLES")
    local row_h    = 50   -- per-type row height
    local top_pad  = 10
    local bot_pad  = 10
    local battle_h = top_pad + hdr_band + (row_h * 3) + bot_pad
    local scy = cy - battle_h/2
    glass(self, vmath.vector3(cx, scy, 0), vmath.vector3(pw, battle_h, 0), "container_bg")

    local icon_x = cx - pw/2 + 40
    local hdr_tx = icon_x + 35
    local hdr_y  = cy - top_pad - hdr_band/2

    track(self, ui.image(vmath.vector3(icon_x, hdr_y, 0), vmath.vector3(42, 42, 0), "battle_icon"))
    txtL(self, hdr_tx, hdr_y, "BATTLES", "btn_md", C.COL_WHITE)

    -- Row geometry: text column on the left, buttons hugging the right edge.
    local row_l   = cx - pw/2 + 18      -- left text margin
    local row_r   = cx + pw/2 - 16      -- right edge for buttons
    local pair_w  = 78                  -- width of each INVITE/EDIT button
    local pair_gap = 8
    local create_w = 124                -- width of the single CREATE button
    local rows_top = cy - top_pad - hdr_band   -- y of the top of the first row band

    for ri, T in ipairs(M.BATTLE_TYPES) do
        local row_cy = rows_top - (ri - 0.5) * row_h
        -- Subtle divider above every row except the first.
        if ri > 1 then
            track(self, ui.box(vmath.vector3(cx, rows_top - (ri - 1) * row_h, 0), vmath.vector3(pw - 36, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
        end

        local label = M.BATTLE_TYPE_LABELS[T] or T
        txtL(self, row_l, row_cy + 9, label, "btn_sm", C.COL_WHITE)

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
                detail = string.format("SCORE CAP %d  ~  %s", cap, commas(amt))
            else
                local fmt = tonumber(b.matchFormat) or 3
                detail = string.format("BEST OF %d  ~  %s", fmt, commas(amt))
            end
            txtL(self, row_l, row_cy - 11, detail, "small", C.COL_GREEN)

            local edit_bx   = row_r - pair_w/2
            local invite_bx = edit_bx - pair_w - pair_gap
            mkbtn(self, "nav_invite",    vmath.vector3(invite_bx, row_cy, 0), vmath.vector3(pair_w, 34, 0), "INVITE", "primary_btn",   T, "btn_sm")
            mkbtn(self, "update_battle", vmath.vector3(edit_bx,   row_cy, 0), vmath.vector3(pair_w, 34, 0), "EDIT",   "secondary_btn", T, "btn_sm")
        else
            txtL(self, row_l, row_cy - 11, "Not created yet", "small", C.COL_DIM)
            local create_bx  = row_r - create_w/2
            local create_lbl = (T == "NORMAL") and "+ CREATE" or ("+ " .. label)
            mkbtn(self, "create_battle", vmath.vector3(create_bx, row_cy, 0), vmath.vector3(create_w, 34, 0), create_lbl, "primary_btn", T, "btn_sm")
        end
    end
    cy = cy - battle_h - C.BLOCK_GAP

    -- ── Tournaments panel ─────────────────────────────────────────────────
    local t_h  = 64
    local tcy2 = cy - t_h/2
    track(self, ui.box(vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), C.COL_BG))
    mkbtn(self, "nav_tournaments", vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), nil, "container_bg")
    
    local icon_x = cx - 74
    track(self, ui.image(vmath.vector3(icon_x, tcy2, 0), vmath.vector3(28, 28, 0), "tournament_icon"))
    txtL(self, icon_x + 22, tcy2, "TOURNAMENTS", "btn_md", C.COL_WHITE)

    local nx = cx + pw/2 - 36
    local ny = tcy2
    track(self, ui.box(vmath.vector3(nx, ny, 0), vmath.vector3(44, 18, 0), vmath.vector4(0.15, 0.8, 0.25, 1.0)))
    track(self, ui.box(vmath.vector3(nx, ny + 9, 0), vmath.vector3(44, 1, 0), C.COL_WHITE))
    track(self, ui.text(vmath.vector3(nx, ny, 0), "NEW", "btn_sm", C.COL_WHITE))
    cy = cy - t_h - C.BLOCK_GAP

    -- ── Footer links ──────────────────────────────────────────────────────
    local fx1 = cx - pw/4
    local fx2 = cx + pw/4
    -- Support moved to the main lobby; Themes spans the footer here.
    mkbtn(self, "nav_themes", vmath.vector3(cx, cy - 22, 0), vmath.vector3(pw - 16, 42, 0), "THEMES", "secondary_btn")

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
    if type(mb) ~= "table" or next(mb) == nil then return end

    local stake = (type(mb.stake) == "table") and mb.stake or { amount = tonumber(mb.stakeAmount) or 0, charge = 0 }

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