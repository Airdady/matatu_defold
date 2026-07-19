local ws            = require("modules.websocket_manager")
local dialog_search = require("modules.dialog_search")
local GameMode      = require("modules.game_mode")
local app_state     = require("modules.app_state")

local M = {}

-- Battle/Knockout/Party stake ladders, per game's own local currency
-- (UGX/NGN/KES) — mirrors modules/config.lua's STAKE_LEVELS_BY_GAME
-- conversion ratio (NGN ~= UGX * 0.5, KES ~= UGX * 0.05, rounded to clean
-- denominations), which itself matches be_matatu's
-- SETTLEMENT_STAKE_LEVELS_BY_GAME. These ladders were previously flat UGX
-- numbers applied unconverted to Whot/Kadi builds too.

-- Battle stakes cap out at the top tier (the higher UGX 5000 / 10000 tiers
-- were removed for Matatu; other games' top tiers scale down accordingly).
local BATTLE_TIERS_BY_GAME = {
    MATATU = {
        { amount = 500,   formats = { { games = 3, charge = 75,  points = 9 } } },
        { amount = 1000,  formats = { { games = 3, charge = 75,  points = 9 }, { games = 5, charge = 125, points = 15 } } },
        { amount = 2000,  formats = { { games = 3, charge = 75,  points = 9 }, { games = 5, charge = 125, points = 15 },
                                      { games = 7, charge = 175, points = 21 }, { games = 9, charge = 225, points = 27 } } },
    },
    WHOT = {
        { amount = 250,   formats = { { games = 3, charge = 40,  points = 9 } } },
        { amount = 500,   formats = { { games = 3, charge = 40,  points = 9 }, { games = 5, charge = 65,  points = 15 } } },
        { amount = 1000,  formats = { { games = 3, charge = 40,  points = 9 }, { games = 5, charge = 65,  points = 15 },
                                      { games = 7, charge = 90,  points = 21 }, { games = 9, charge = 115, points = 27 } } },
    },
    KADI = {
        { amount = 25,    formats = { { games = 3, charge = 4,  points = 9 } } },
        { amount = 50,    formats = { { games = 3, charge = 4,  points = 9 }, { games = 5, charge = 7,  points = 15 } } },
        { amount = 100,   formats = { { games = 3, charge = 4,  points = 9 }, { games = 5, charge = 7,  points = 15 },
                                      { games = 7, charge = 9,  points = 21 }, { games = 9, charge = 12, points = 27 } } },
    },
}
M.BATTLE_TIERS = BATTLE_TIERS_BY_GAME[GameMode.GAME] or BATTLE_TIERS_BY_GAME.MATATU

-- KNOCKOUT uses a flat low-stake ladder as its SCORE CAP (charge = cap/2).
local KNOCKOUT_CAPS_BY_GAME = {
    MATATU = { 100, 200, 300, 500 },
    WHOT   = { 50,  100, 150, 250 },
    KADI   = { 5,   10,  15,  25  },
}
M.KNOCKOUT_CAPS = KNOCKOUT_CAPS_BY_GAME[GameMode.GAME] or KNOCKOUT_CAPS_BY_GAME.MATATU

-- KNOCKOUT is a STAKED score-cap chamber: players put up one of these stake
-- amounts, and the charge is derived from the score cap (cap/2).
local KNOCKOUT_STAKES_BY_GAME = {
    MATATU = { 1000, 2000 },
    WHOT   = { 500,  1000 },
    KADI   = { 50,   100  },
}
M.KNOCKOUT_STAKES = KNOCKOUT_STAKES_BY_GAME[GameMode.GAME] or KNOCKOUT_STAKES_BY_GAME.MATATU

-- PARTY uses its own flat entry-fee ladder (the stepper just cycles these).
local PARTY_TIERS_BY_GAME = {
    MATATU = { 100, 200, 500 },
    WHOT   = { 50,  100, 250 },
    KADI   = { 5,   10,  25  },
}
M.PARTY_TIERS = PARTY_TIERS_BY_GAME[GameMode.GAME] or PARTY_TIERS_BY_GAME.MATATU

-- The three independent battle types. Internal keys map to display labels.
M.BATTLE_TYPES = { "NORMAL", "KNOCKOUT", "PARTY" }
M.BATTLE_TYPE_LABELS = { NORMAL = "BATTLE", KNOCKOUT = "KNOCKOUT", PARTY = "PARTY" }

-- Battle types the UI is allowed to SHOW. PARTY is kept out of view again
-- for further improvement before launch — ALL of its code (tiers, is_party
-- branches, resolution, submission, and the server-side Vortex PARTY
-- hosting) is retained. Re-enable it by simply adding "PARTY" back here.
M.BATTLE_TYPES_VISIBLE = { "NORMAL", "KNOCKOUT" }

-- Resolve the battle a user holds for a given type T ∈ {NORMAL,KNOCKOUT,PARTY}.
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
    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons+1] = { node = dim, id = "bm_block" }
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    local btype  = tostring(bm.type or "NORMAL"):upper()
    if btype == "ELIMINATION" then btype = "KNOCKOUT" end
    if btype ~= "KNOCKOUT" and btype ~= "PARTY" then btype = "NORMAL" end
    local is_norm  = (btype == "NORMAL")
    local is_knock = (btype == "KNOCKOUT")
    local is_party = (btype == "PARTY")

    local type_word = M.BATTLE_TYPE_LABELS[btype] or "BATTLE"
    local title     = (bm.editing and "UPDATE " or "CREATE ") .. type_word

    track(self, ui.text(vmath.vector3(CX, CY + 260, 0), title, "title", ctx.C.COL_WHITE))
    -- Increased close button size
    mkbtn(self, "bm_close", vmath.vector3(CX + 340, CY + 260, 0), vmath.vector3(56, 56, 0), "X", "secondary_btn")

    -- BATTLE TYPE
    local type_y  = CY + 150
    track(self, ui.text(vmath.vector3(CX, type_y + 46, 0), "BATTLE TYPE", "small", C_NEUTRAL))
    local seg_w   = 170
    local seg_gap = 14
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
        -- Taller segment box (52px)
        local box = track(self, ui.box(vmath.vector3(sx, type_y, 0), vmath.vector3(seg_w, 52, 0), s.on and C_VICTORY or UNSEL_C))
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
    track(self, ui.text(vmath.vector3(CX, fee_y + 46, 0), is_knock and "STAKE" or "ENTRY FEE", "small", C_NEUTRAL))
    local step_w = 280
    -- Taller stepper buttons (52x52)
    mkbtn(self, "bm_fee_minus", vmath.vector3(CX - step_w/2 - 34, fee_y, 0), vmath.vector3(52, 52, 0), "-", "secondary_btn")
    track(self, ui.box(vmath.vector3(CX, fee_y, 0), vmath.vector3(step_w, 52, 0), ctx.C.COL_NAMEID_BG))
    track(self, ui.text(vmath.vector3(CX, fee_y, 0),
        is_knock and (commas(estake) .. " COINS") or (commas(amount) .. " COINS"), "body", C_CHAMPION))
    mkbtn(self, "bm_fee_plus", vmath.vector3(CX + step_w/2 + 34, fee_y, 0), vmath.vector3(52, 52, 0), "+", "secondary_btn")

    if is_norm then
        track(self, ui.text(vmath.vector3(CX, fee_y - 42, 0),
            string.format("Winner Takes: %s + %d Pts", commas(winner_takes), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    elseif is_party then
        track(self, ui.text(vmath.vector3(CX, fee_y - 42, 0),
            "Pooled prize · last player standing wins", "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    else
        track(self, ui.text(vmath.vector3(CX, fee_y - 42, 0),
            "Staked score chamber · charge from the cap", "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    end

    -- FORMAT / PLAYERS / CAP
    local fmt_y = CY - 120
    if is_party then
        local players = bm.players or "AUTO"
        track(self, ui.text(vmath.vector3(CX, fmt_y + 46, 0), "PLAYER COUNT", "small", C_NEUTRAL))
        mkbtn(self, "bm_players_minus", vmath.vector3(CX - step_w/2 - 34, fmt_y, 0), vmath.vector3(52, 52, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y, 0), vmath.vector3(step_w, 52, 0), ctx.C.COL_NAMEID_BG))
        local p_txt = (players == "AUTO") and "AUTO" or (tostring(players) .. " PLAYERS")
        track(self, ui.text(vmath.vector3(CX, fmt_y, 0), p_txt, "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_players_plus", vmath.vector3(CX + step_w/2 + 34, fmt_y, 0), vmath.vector3(52, 52, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 42, 0),
            (players == "AUTO") and "Auto-fill the table as players join" or "Starts once the table is full",
            "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    elseif is_knock then
        track(self, ui.text(vmath.vector3(CX, fmt_y + 46, 0), "SCORE CAP", "small", C_NEUTRAL))
        mkbtn(self, "bm_cap_minus", vmath.vector3(CX - step_w/2 - 34, fmt_y, 0), vmath.vector3(52, 52, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y, 0), vmath.vector3(step_w, 52, 0), ctx.C.COL_NAMEID_BG))
        track(self, ui.text(vmath.vector3(CX, fmt_y, 0), tostring(cap), "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_cap_plus", vmath.vector3(CX + step_w/2 + 34, fmt_y, 0), vmath.vector3(52, 52, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 42, 0),
            string.format("Charge: %d  ·  reach the cap and you're out", math.floor(cap / 2)), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    else
        track(self, ui.text(vmath.vector3(CX, fmt_y + 46, 0), "GAME FORMAT", "small", C_NEUTRAL))
        mkbtn(self, "bm_fmt_minus", vmath.vector3(CX - step_w/2 - 34, fmt_y, 0), vmath.vector3(52, 52, 0), "-", "secondary_btn")
        track(self, ui.box(vmath.vector3(CX, fmt_y, 0), vmath.vector3(step_w, 52, 0), ctx.C.COL_NAMEID_BG))
        track(self, ui.text(vmath.vector3(CX, fmt_y, 0), "BEST OF " .. fmt.games, "body", ctx.C.COL_WHITE))
        mkbtn(self, "bm_fmt_plus", vmath.vector3(CX + step_w/2 + 34, fmt_y, 0), vmath.vector3(52, 52, 0), "+", "secondary_btn")
        track(self, ui.text(vmath.vector3(CX, fmt_y - 42, 0),
            string.format("Charge: %s  ·  %d Pts to the winner", commas(fmt.charge), fmt.points), "small", vmath.vector4(0.6, 0.6, 0.6, 1)))
    end

    if bm.msg then
        track(self, ui.text(vmath.vector3(CX, CY - 200, 0), bm.msg, "small",
            bm.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    -- Increased submit button height (68px)
    local sub_label = bm.submitting and "WAITING..." or title
    local sub_y = CY - 260
    local s_btn = track(self, ui.box(vmath.vector3(CX, sub_y, 0), vmath.vector3(380, 68, 0), C_VICTORY))
    self.buttons[#self.buttons+1] = { node = s_btn, id = "bm_submit" }
    track(self, ui.text(vmath.vector3(CX, sub_y, 0), sub_label, "btn_lg", C_BTN_TEXT))
end

-- ── Savings Info Modal Drawing ────────────────────────────────────────────────
local function draw_savings_info(self, ctx)
    if not self.savings_info_open then return end

    local track = ctx.track
    local ui    = ctx.ui
    local mkbtn = ctx.mkbtn
    local C     = ctx.C
    local CX, CY = ctx.CX, ctx.CY

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.75)))
    self.buttons[#self.buttons+1] = { node = dim, id = "savings_info_block" }

    local panel_w, panel_h = 440, 380
    track(self, ui.panel9(vmath.vector3(CX, CY, 0), vmath.vector3(panel_w, panel_h, 0), "container_bg"))

    local top = CY + panel_h / 2
    track(self, ui.text(vmath.vector3(CX, top - 40, 0), "Savings", "title", C.COL_GOLD))

    local body_lines = {
        "Savings are long-term coins earned from",
        "Half-Week Season rewards. Unlike your",
        "regular balance, Savings never reset and",
        "build up over time — cash them in during",
        "special redemption events.",
    }
    for i, line in ipairs(body_lines) do
        track(self, ui.text(vmath.vector3(CX, top - 96 - (i - 1) * 26, 0), line, "small", C.COL_WHITE))
    end

    local st = ws.current_savings_status or {}
    local redemption_str = format_redemption_date(st.nextRedemptionDate)
    if redemption_str ~= "" then
        track(self, ui.text(vmath.vector3(CX, top - 226, 0), "Next redemption: " .. redemption_str, "small", C.COL_GOLD))
    end

    -- Compact period-progress bar (how far through the current 6-month cycle).
    local pct = math.max(0, math.min(100, tonumber(st.periodProgressPercent) or 0))
    track(self, ui.text(vmath.vector3(CX, top - 252, 0), "SAVINGS PERIOD PROGRESS", "small", C.COL_DIM))
    local bar_w, bar_h, bar_y = panel_w - 64, 14, top - 274
    local COL_SAVINGS = vmath.vector4(0.20, 0.75, 0.55, 1.0)
    track(self, ui.box(vmath.vector3(CX, bar_y, 0), vmath.vector3(bar_w, bar_h, 0), vmath.vector4(1, 1, 1, 0.08)))
    if pct > 0 then
        local fill_w = bar_w * (pct / 100)
        track(self, ui.box(vmath.vector3(CX - bar_w/2 + fill_w/2, bar_y, 0), vmath.vector3(fill_w, bar_h, 0), COL_SAVINGS))
    end
    track(self, ui.text(vmath.vector3(CX, top - 296, 0), pct .. "% complete", "small", C.COL_WHITE))

    local by = CY - panel_h / 2 + 46
    mkbtn(self, "savings_info_close", vmath.vector3(CX, by, 0), vmath.vector3(220, 56, 0), "CLOSE", "primary_btn")
end

-- ── Savings helpers (backend-driven config, with a safe fallback while the
-- first SAVINGS_STATUS round-trip hasn't landed yet) ────────────────────────
local MONTH_NAMES = {"January","February","March","April","May","June","July","August","September","October","November","December"}
local function format_redemption_date(iso)
    local y, m, d = tostring(iso or ""):match("(%d+)-(%d+)-(%d+)")
    if not y then return "" end
    return string.format("%s %d, %s", MONTH_NAMES[tonumber(m)] or m, tonumber(d), y)
end

local function exchange_bounds()
    local cfg = (ws.current_savings_status or {}).exchangeConfig
    if type(cfg) == "table" then
        return tonumber(cfg.min) or 100, tonumber(cfg.max) or 5000, tonumber(cfg.step) or 100
    end
    return 100, 5000, 100
end

local function autocharge_amounts()
    local list = (ws.current_savings_status or {}).autoChargeAmounts
    if type(list) == "table" and #list > 0 then return list end
    return { 2, 5, 10, 25 }
end

-- ── Savings Add Modal Drawing ──────────────────────────────────────────────────

local function draw_savings_add(self, ctx)
    if not self.savings_add_open then return end
    local sa = self.savings_add
    if not sa then return end

    local track  = ctx.track
    local ui     = ctx.ui
    local mkbtn  = ctx.mkbtn
    local C      = ctx.C
    local commas = ctx.commas
    local CX, CY = ctx.CX, ctx.CY

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.75)))
    self.buttons[#self.buttons+1] = { node = dim, id = "savings_add_block" }

    local panel_w, panel_h = 480, 680
    track(self, ui.panel9(vmath.vector3(CX, CY, 0), vmath.vector3(panel_w, panel_h, 0), "container_bg"))

    local top = CY + panel_h / 2
    track(self, ui.text(vmath.vector3(CX, top - 36, 0), "Add to Savings", "title", C.COL_GOLD))

    local COL_SAVINGS = vmath.vector4(0.20, 0.75, 0.55, 1.0)
    local UNSEL_C     = vmath.vector4(0.16, 0.16, 0.18, 1)

    -- ── Period progress (backend-driven: periodProgressPercent/nextRedemptionDate) ──
    local st = ws.current_savings_status or {}
    local pct = math.max(0, math.min(100, tonumber(st.periodProgressPercent) or 0))
    local redemption_str = format_redemption_date(st.nextRedemptionDate)
    local progress_label = (redemption_str ~= "")
        and ("SAVINGS PERIOD · redeems " .. redemption_str)
        or "SAVINGS PERIOD PROGRESS"
    track(self, ui.text(vmath.vector3(CX, top - 64, 0), progress_label, "small", C.COL_DIM))
    local bar_w, bar_h, bar_y = panel_w - 64, 14, top - 84
    track(self, ui.box(vmath.vector3(CX, bar_y, 0), vmath.vector3(bar_w, bar_h, 0), vmath.vector4(1, 1, 1, 0.08)))
    if pct > 0 then
        local fill_w = bar_w * (pct / 100)
        track(self, ui.box(vmath.vector3(CX - bar_w/2 + fill_w/2, bar_y, 0), vmath.vector3(fill_w, bar_h, 0), COL_SAVINGS))
    end
    track(self, ui.text(vmath.vector3(CX, top - 104, 0), pct .. "% complete", "small", C.COL_WHITE))

    -- ── Section A: Exchange to Savings now ────────────────────────────────
    local sec_a_y = top - 146
    track(self, ui.text(vmath.vector3(CX, sec_a_y, 0), "EXCHANGE TO SAVINGS NOW", "small", C.COL_DIM))

    local emin, emax = exchange_bounds()
    local bal = tonumber((ws.current_user_data or {}).balance) or 0
    local lo, hi = emin, math.max(emin, math.min(emax, bal))
    sa.exchange_amount = math.max(lo, math.min(hi, sa.exchange_amount or lo))

    local step_w, step_y = 240, sec_a_y - 48
    mkbtn(self, "savings_exchange_minus", vmath.vector3(CX - step_w/2 - 34, step_y, 0), vmath.vector3(52, 52, 0), "-", "secondary_btn")
    track(self, ui.box(vmath.vector3(CX, step_y, 0), vmath.vector3(step_w, 52, 0), C.COL_NAMEID_BG))
    track(self, ui.text(vmath.vector3(CX, step_y, 0), commas(sa.exchange_amount) .. " COINS", "body", COL_SAVINGS))
    mkbtn(self, "savings_exchange_plus", vmath.vector3(CX + step_w/2 + 34, step_y, 0), vmath.vector3(52, 52, 0), "+", "secondary_btn")

    local confirm_y = step_y - 56
    self.savings_exchange_btn_pos = { x = CX, y = confirm_y }
    local confirm_label = sa.exchanging and "EXCHANGING..." or "CONFIRM EXCHANGE"
    mkbtn(self, "savings_exchange_confirm", vmath.vector3(CX, confirm_y, 0), vmath.vector3(280, 52, 0), confirm_label, "primary_btn", nil, "btn_md", C.COL_WHITE)

    if sa.msg then
        track(self, ui.text(vmath.vector3(CX, confirm_y - 36, 0), sa.msg, "small",
            sa.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    -- Divider
    local div_y = confirm_y - 74
    track(self, ui.box(vmath.vector3(CX, div_y, 0), vmath.vector3(panel_w - 56, 2, 0), vmath.vector4(1, 1, 1, 0.12)))

    -- ── Section B: Auto-charge per game ────────────────────────────────────
    local sec_b_y = div_y - 34
    track(self, ui.text(vmath.vector3(CX, sec_b_y, 0), "AUTO-CHARGE PER GAME", "small", C.COL_DIM))

    local toggle_y = sec_b_y - 48
    local seg_w, seg_gap = 110, 12
    local off_x = CX - seg_w/2 - seg_gap/2
    local on_x  = CX + seg_w/2 + seg_gap/2
    local off_box = track(self, ui.box(vmath.vector3(off_x, toggle_y, 0), vmath.vector3(seg_w, 48, 0), (not sa.autocharge_enabled) and C_VICTORY or UNSEL_C))
    self.buttons[#self.buttons+1] = { node = off_box, id = "savings_autocharge_off" }
    track(self, ui.text(vmath.vector3(off_x, toggle_y, 0), "OFF", "btn_md", (not sa.autocharge_enabled) and C_BTN_TEXT or C.COL_WHITE))
    local on_box = track(self, ui.box(vmath.vector3(on_x, toggle_y, 0), vmath.vector3(seg_w, 48, 0), sa.autocharge_enabled and C_VICTORY or UNSEL_C))
    self.buttons[#self.buttons+1] = { node = on_box, id = "savings_autocharge_on" }
    track(self, ui.text(vmath.vector3(on_x, toggle_y, 0), "ON", "btn_md", sa.autocharge_enabled and C_BTN_TEXT or C.COL_WHITE))

    local amt_y = toggle_y - 60
    if sa.autocharge_enabled then
        track(self, ui.text(vmath.vector3(CX, amt_y + 34, 0), "AMOUNT PER GAME", "small", C.COL_DIM))
        local amt_w, amt_gap = 96, 10
        local amounts = autocharge_amounts()
        local n = #amounts
        for i, amt in ipairs(amounts) do
            local ax = CX + (i - (n + 1) / 2) * (amt_w + amt_gap)
            local on = (sa.autocharge_amount == amt)
            local box = track(self, ui.box(vmath.vector3(ax, amt_y, 0), vmath.vector3(amt_w, 48, 0), on and C_VICTORY or UNSEL_C))
            self.buttons[#self.buttons+1] = { node = box, id = "savings_autocharge_amt_" .. tostring(amt) }
            track(self, ui.text(vmath.vector3(ax, amt_y, 0), tostring(amt), "btn_md", on and C_BTN_TEXT or C.COL_WHITE))
        end
    end

    local save_y = amt_y - 62
    local save_label = sa.saving and "SAVING..." or "SAVE"
    mkbtn(self, "savings_autocharge_save", vmath.vector3(CX, save_y, 0), vmath.vector3(220, 52, 0), save_label, "primary_btn", nil, "btn_md", C.COL_WHITE)

    if sa.settings_msg then
        track(self, ui.text(vmath.vector3(CX, save_y - 36, 0), sa.settings_msg, "small",
            sa.settings_msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    local close_y = CY - panel_h / 2 + 32
    mkbtn(self, "savings_add_close", vmath.vector3(CX, close_y, 0), vmath.vector3(220, 52, 0), "CLOSE", "secondary_btn")
end

-- ── Invite Modal Drawing ──────────────────────────────────────────────────────
local function draw_invite_search(self, ctx)
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

    -- ── User Info Container (Redesigned Profile Card) ─────────────────────
    local margin   = 18
    local av_size  = 84 -- Bigger Avatar
    local stat_h   = 36 -- Chunkier currency rows
    local header_h = 130 -- Covers Avatar, Name, and tightly-packed Balances
    local list_h   = 80 -- Position & Form list
    local pay_h    = 56 -- Massive touch target for payments
    local gap      = 16
    local cont_h   = margin + header_h + gap + list_h + gap + pay_h + margin
    local ccy      = cy - cont_h / 2

    glass(self, vmath.vector3(cx, ccy, 0), vmath.vector3(pw, cont_h, 0), "container_bg")

    local inner_l = cx - pw/2 + margin
    local inner_r = cx + pw/2 - margin
    local top_y   = cy - margin

    -- Layout: Avatar to the left, Info & Balances grouped vertically on the right
    local av_x    = inner_l + av_size/2
    local av_cy   = top_y - av_size/2
    track(self, ui.avatar(vmath.vector3(av_x, av_cy, 0), vmath.vector3(av_size, av_size, 0), u.avatar or 1))

    -- Text Area right of Avatar
    local info_l  = av_x + av_size/2 + 16
    local info_w  = inner_r - info_l
    local info_cx = info_l + info_w/2

    -- Username Pill & Edit Button
    local name_h = 32
    local name_y = top_y - name_h/2
    track(self, ui.box(vmath.vector3(info_cx, name_y, 0), vmath.vector3(info_w, name_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 12, name_y, string.upper(u.username or "PLAYER"), "body", C.COL_BRIGHT)

    mkbtn(self, "nav_account", vmath.vector3(inner_r - 18, name_y, 0), vmath.vector3(36, 36, 0), nil, vmath.vector4(0,0,0,0))
    local acc_edit = track(self, ui.image(vmath.vector3(inner_r - 18, name_y, 0), vmath.vector3(20, 20, 0), "edit"))
    gui.set_color(acc_edit, C.COL_WHITE)

    -- Balances Matrix (Tucked tightly under the Username with darker bg)
    local r1_y      = name_y - name_h/2 - 12 - stat_h/2
    local r2_y      = r1_y - stat_h/2 - 8 - stat_h/2
    
    local bw        = pw - (margin * 2)
    local bal_w     = (info_w - 8) / 2
    local pts_w     = bal_w
    local bal_cx    = info_l + bal_w/2
    local pts_cx    = inner_r - pts_w/2
    local COL_ORANGE  = vmath.vector4(1.0, 0.6, 0.0, 1.0)
    local COL_SAVINGS = vmath.vector4(0.20, 0.75, 0.55, 1.0)

    -- Row 1: BAL | PTS (Using C.COL_NAMEID_BG for darker backdrop)
    track(self, ui.box(vmath.vector3(bal_cx, r1_y, 0), vmath.vector3(bal_w, stat_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 8, r1_y, "BAL.", "small", COL_ORANGE)
    txtR(self, bal_cx + bal_w/2 - 8, r1_y, commas(u.balance or 0), "body", COL_ORANGE)
    -- Remember where the BAL figure sits so the deposit coin shower
    -- (main/coins.gui_script's coin_deposit) can fly coins right into it.
    app_state.bal_display_pos = { x = bal_cx, y = r1_y }

    track(self, ui.box(vmath.vector3(pts_cx, r1_y, 0), vmath.vector3(pts_w, stat_h, 0), C.COL_NAMEID_BG))
    txtL(self, inner_r - pts_w + 8, r1_y, "PTS.", "small", C.COL_CYAN)
    txtR(self, inner_r - 8, r1_y, commas(u.points or 0), "body", C.COL_CYAN)

    -- Row 2: SAVINGS (Aligned seamlessly under BAL/PTS)
    track(self, ui.box(vmath.vector3(info_cx, r2_y, 0), vmath.vector3(info_w, stat_h, 0), C.COL_NAMEID_BG))
    txtL(self, info_l + 8, r2_y, "SAVINGS BAL", "small", COL_SAVINGS)
    txtR(self, inner_r - 80, r2_y, commas(u.savingCoins or 0), "body", COL_SAVINGS)

    -- Savings Interactive Icons
    local sav_info_pos = vmath.vector3(inner_r - 20, r2_y, 0)
    local sav_add_pos  = vmath.vector3(inner_r - 54, r2_y, 0)
    track(self, ui.pie(sav_info_pos, 14, vmath.vector4(0.15, 0.15, 0.15, 0.65)))
    mkbtn(self, "savings_info", sav_info_pos, vmath.vector3(28, 28, 0), "i", vmath.vector4(0, 0, 0, 0), nil, "btn_md", C.COL_WHITE)
    track(self, ui.pie(sav_add_pos, 14, vmath.vector4(0.15, 0.15, 0.15, 0.65)))
    mkbtn(self, "savings_add", sav_add_pos, vmath.vector3(28, 28, 0), "+", vmath.vector4(0, 0, 0, 0), nil, "btn_md", COL_SAVINGS)

    -- Stats List (Position & Form)
    local lcy = top_y - header_h - gap - list_h/2
    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw, list_h, 0), C.COL_STAT_BG))

    local pos      = tonumber(u.position) or -1
    local has_rank = pos > 0
    local accent_col = has_rank and C.COL_GOLD or C.COL_DIM
    local row_h_list = list_h / 2

    -- Divider
    track(self, ui.box(vmath.vector3(cx, lcy, 0), vmath.vector3(bw - 24, 1, 0), vmath.vector4(1, 1, 1, 0.05)))

    -- Row 1: Your Position
    local r1_y_list = lcy + row_h_list/2
    txtL(self, cx - bw/2 + 12, r1_y_list, "YOUR POSITION", "small", C.COL_DIM)
    txtR(self, cx + bw/2 - 12, r1_y_list, has_rank and ("#"..pos) or "UNRANKED", "body", accent_col)

    -- Row 2: Your Current Form
    local r2_y_list = lcy - row_h_list/2
    txtL(self, cx - bw/2 + 12, r2_y_list, "YOUR CURRENT FORM", "small", C.COL_DIM)

    local form = type(u.recentForm) == "table" and u.recentForm or {}
    local fsz, fgap = 26, 6 
    local fx0 = cx + bw/2 - 12 - fsz/2
    for i = 1, 5 do
        local r  = form[i]
        local bx = fx0 - (i - 1) * (fsz + fgap)
        if r == "W" or r == "L" then
            track(self, ui.box(vmath.vector3(bx, r2_y_list, 0), vmath.vector3(fsz, fsz, 0),
                r == "W" and vmath.vector4(0.15, 0.70, 0.25, 0.92) or vmath.vector4(0.90, 0.25, 0.25, 0.92)))
            track(self, ui.text(vmath.vector3(bx, r2_y_list, 0), r, "body", C.COL_WHITE))
        else
            track(self, ui.box(vmath.vector3(bx, r2_y_list, 0), vmath.vector3(fsz, fsz, 0), vmath.vector4(1, 1, 1, 0.06)))
        end
    end

    -- Make Payments Button (Massive Target)
    local pay_y = lcy - list_h/2 - gap - pay_h/2
    mkbtn(self, "nav_payments", vmath.vector3(cx, pay_y, 0), vmath.vector3(bw, pay_h, 0), "MAKE PAYMENTS", "primary_btn", nil, "btn_lg")

    cy = cy - cont_h - (C.BLOCK_GAP + 8)

    -- ── Battles panel (Taller, Roomier rows) ──────────────────────────────
    local row_h    = 88 -- Significantly larger rows
    local top_pad  = 16
    local bot_pad  = 16
    local list_types = M.BATTLE_TYPES_VISIBLE
    local battle_h = top_pad + (row_h * #list_types) + bot_pad
    local scy = cy - battle_h/2
    glass(self, vmath.vector3(cx, scy, 0), vmath.vector3(pw, battle_h, 0), "container_bg")

    local rows_top = cy - top_pad
    local row_l    = cx - pw/2 + 20
    local row_r    = cx + pw/2 - 20

    for ri, T in ipairs(list_types) do
        local row_cy = rows_top - (ri - 0.5) * row_h
        if ri > 1 then
            track(self, ui.box(vmath.vector3(cx, rows_top - (ri - 1) * row_h, 0), vmath.vector3(pw - 40, 1, 0), vmath.vector4(1, 1, 1, 0.05)))
        end

        local icon_name = (T == "NORMAL") and "battle_icon" or (T == "KNOCKOUT" and "knockout" or "party")
        local icon_x = row_l + 24
        local type_icon = track(self, ui.image(vmath.vector3(icon_x, row_cy, 0), vmath.vector3(48, 48, 0), icon_name))
        gui.set_color(type_icon, C.COL_WHITE)

        local text_x = icon_x + 38
        local label = M.BATTLE_TYPE_LABELS[T] or T
        txtL(self, text_x, row_cy + 12, label, "btn_lg", C.COL_WHITE)

        -- Larger Buttons
        local invite_w = 120
        local btn_h    = 48
        local edit_w   = 48 
        local pair_gap = 12

        local b = M.battle_of_type(u, T)
        if b then
            local amt = battle_amount(b)
            local detail
            if T == "PARTY" then
                local players = b.players or "AUTO"
                local pstr    = (type(players) == "table") and tostring(#players) or tostring(players)
                detail = string.format("%s PLAYERS    %s", pstr, commas(amt))
            elseif T == "KNOCKOUT" then
                local cap = tonumber(b.scoreCap) or 200
                detail = string.format("CAP %d    %s", cap, commas(amt))
            else
                local fmt = tonumber(b.matchFormat) or 3
                detail = string.format("BEST OF %d    %s", fmt, commas(amt))
            end
            -- Grey, small text without the '~'
            txtL(self, text_x, row_cy - 14, detail, "small", C.COL_DIM)

            local edit_bx   = row_r - edit_w/2
            local invite_bx = edit_bx - edit_w/2 - pair_gap - invite_w/2

            mkbtn(self, "nav_invite", vmath.vector3(invite_bx, row_cy, 0), vmath.vector3(invite_w, btn_h, 0), "INVITE", "primary_btn", T, "btn_md")
            
            mkbtn(self, "update_battle", vmath.vector3(edit_bx, row_cy, 0), vmath.vector3(edit_w, btn_h, 0), "", "secondary_btn", T)
            local eicon = track(self, ui.image(vmath.vector3(edit_bx, row_cy, 0), vmath.vector3(24, 24, 0), "edit"))
            gui.set_color(eicon, C.COL_WHITE)
        else
            txtL(self, text_x, row_cy - 14, "Not created yet", "body", C.COL_DIM)
            local create_w = 160
            local create_bx  = row_r - create_w/2
            local create_lbl = "+ CREATE"
            mkbtn(self, "create_battle", vmath.vector3(create_bx, row_cy, 0), vmath.vector3(create_w, btn_h, 0), create_lbl, "primary_btn", T, "btn_md")
        end
    end
    cy = cy - battle_h - (C.BLOCK_GAP + 8)

    -- ── Tournaments panel (Taller button) ─────────────────────────────────
    local t_h  = 72
    local tcy2 = cy - t_h/2
    track(self, ui.box(vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), C.COL_BG))
    mkbtn(self, "nav_tournaments", vmath.vector3(cx, tcy2, 0), vmath.vector3(pw, t_h, 0), nil, "container_bg")
    
    local icon_x = cx - 80
    local t_icon = track(self, ui.image(vmath.vector3(icon_x, tcy2, 0), vmath.vector3(32, 32, 0), "tournament_icon"))
    gui.set_color(t_icon, C.COL_WHITE)
    txtL(self, icon_x + 28, tcy2, "TOURNAMENTS", "btn_lg", C.COL_WHITE)

    local nx = cx + pw/2 - 40
    local ny = tcy2
    track(self, ui.box(vmath.vector3(nx, ny, 0), vmath.vector3(48, 22, 0), vmath.vector4(0.15, 0.8, 0.25, 1.0)))
    track(self, ui.box(vmath.vector3(nx, ny + 11, 0), vmath.vector3(48, 1, 0), C.COL_WHITE))
    track(self, ui.text(vmath.vector3(nx, ny, 0), "NEW", "btn_sm", C.COL_WHITE))
    cy = cy - t_h - C.BLOCK_GAP

    -- ── Draw Extracted Modals on Top ──────────────────────────────────────
    draw_battle_modal(self, ctx)
    draw_invite_search(self, ctx)
    draw_savings_info(self, ctx)
    draw_savings_add(self, ctx)
end

-- ── Input Action Exports for Main Script ─────────────────────────────────────

function M.savings_exchange_confirm(self, rebuild_cb)
    local sa = self.savings_add
    if not sa or sa.exchanging then return end
    local amount = tonumber(sa.exchange_amount) or 0
    if amount <= 0 then return end
    sa.exchanging = true
    sa.msg, sa.msg_ok = nil, nil
    ws.exchange_to_savings(amount)
    rebuild_cb()
end

function M.savings_autocharge_save(self, rebuild_cb)
    local sa = self.savings_add
    if not sa or sa.saving then return end
    sa.saving = true
    sa.settings_msg, sa.settings_msg_ok = nil, nil
    ws.set_savings_auto_charge(sa.autocharge_enabled and true or false, sa.autocharge_amount)
    rebuild_cb()
end

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

    self.invite_search.timer_handle = timer.delay(10, false, function()
        if self.invite_search and not self.invite_search.found then
            M.fail_invite_search(self, app_state, rebuild_cb, "No one accepted your invite")
        end
    end)

    rebuild_cb()
    return true
end

function M.fail_invite_search(self, app_state, rebuild_cb, reason)
    local sr = self.invite_search
    if not sr or sr.found or sr.failed then return end

    if sr.timer_handle then pcall(timer.cancel, sr.timer_handle); sr.timer_handle = nil end

    sr.failed   = true
    sr.fail_msg = reason or "No one accepted your invite"
    app_state.searching_invite = false

    pcall(msg.post, "#snd_suspense", "stop_sound")
    pcall(msg.post, "#snd_fail", "play_sound")

    rebuild_cb()

    timer.delay(1.5, false, function()
        if self.invite_search == sr then
            M.stop_invite_search(self, app_state, rebuild_cb)
        end
    end)
end

function M.stop_invite_search(self, app_state, rebuild_cb)
    if self.invite_search and self.invite_search.timer_handle then
        pcall(timer.cancel, self.invite_search.timer_handle)
    end
    
    self.invite_search = nil
    self.invite_reel_node = nil
    app_state.searching_invite = false
    rebuild_cb()
end

return M