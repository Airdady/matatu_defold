local ws            = require("modules.websocket_manager")
local search_clock = require("modules.search_clock")
local dialog_search = require("modules.dialog_search")
local tournament_window = require("modules.tournament_window")
local GameMode      = require("modules.game_mode")
local app_state     = require("modules.app_state")
local toast         = require("modules.toast")

local M = {}

-- HOW LONG A SEARCH RUNS WHEN THE SERVER HAS NOT SAID YET.
--
-- The real figure arrives on GAME_SEARCH_STARTED (be_matatu's settleAfterMs:
-- twelve seconds for a championship ladder, eight for a battle or a chamber).
-- This is only what the dialog opens with in the moment before that lands, and
-- it is the LONGEST of them deliberately — a countdown that is too long merely
-- waits, while one that is too short tells a player nobody wanted to play them
-- while the server is still choosing.
M.SEARCH_WINDOW_FALLBACK = 12

-- How far past the window the local give-up sits. The window already contains
-- its own grace for answers in flight; this is the separate allowance for the
-- server never answering at all.
M.SEARCH_FAILSAFE_GRACE = 3


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

-- SCORE CAP ladder — one ladder for every game. Keep in lockstep with
-- KNOCKOUT_SCORE_CAPS in be_matatu's common/constants/gameConfig.ts and with
-- the offline copy in modules/lobby/overlays.lua.
--
-- It used to be three per-game ladders that had already drifted: MATATU listed
-- 100/200/300/500 here but 200/300/500 offline and on the server, and KADI
-- still read 5/10/15/25 — stake amounts, not score caps, so a Kadi chamber
-- claimed to eliminate you at 5 points.
M.KNOCKOUT_CAPS = { 100, 200, 250, 300 }

-- Per-round charge by cap. NOT cap/2: that only matches on the first two
-- rungs (250 would be 125 and 300 would be 150). The server prices from the
-- same table — see KNOCKOUT_CHARGE_BY_CAP — so a mismatch here shows the
-- player one price and bills them another.
M.KNOCKOUT_CHARGE_BY_CAP = { [100] = 50, [200] = 100, [250] = 150, [300] = 200 }

function M.knockout_charge(cap)
    return M.KNOCKOUT_CHARGE_BY_CAP[tonumber(cap) or 0] or M.KNOCKOUT_CHARGE_BY_CAP[100]
end

-- Which entry of the ladder above a fresh KNOCKOUT starts on: the first, 100,
-- for every game. Callers must use this rather than a hardcoded index.
M.KNOCKOUT_DEFAULT_CAP_I = 1

-- KNOCKOUT is a STAKED score-cap chamber: players put up one of these stake
-- amounts, and the per-round charge comes from M.KNOCKOUT_CHARGE_BY_CAP.
local KNOCKOUT_STAKES_BY_GAME = {
    MATATU = { 1000, 2000 },
    WHOT   = { 500,  1000 },
    KADI   = { 50,   100  },
}
M.KNOCKOUT_STAKES = KNOCKOUT_STAKES_BY_GAME[GameMode.GAME] or KNOCKOUT_STAKES_BY_GAME.MATATU

-- PARTY uses its own flat entry-fee ladder (the stepper just cycles these).
--
-- Every rung has to be one the server will actually honour. partyRules.ts puts
-- the floor at 200 UGX and the ceiling at 500, converted per game by
-- UGX_CONVERSION_RATES (whot x0.4, kadi x0.04) — so 80..200 in naira and 8..20
-- in shillings. The old ladders sat mostly OUTSIDE those: a matatu player
-- picking 100 was silently charged 200, and every whot and kadi rung was below
-- its floor and clamped up. The stepper showed one number and the balance
-- moved by another.
-- TWO RUNGS, NOT THREE. The entry is a ladder on the server and 300 was never
-- on it: partyRules.ts snapped anything off-ladder to the nearest rung, so a
-- matatu player picking 300 was charged 200 and a whot player picking 120 was
-- charged 80. The stepper showed one number and the balance moved by another,
-- which is the same class of bug the note above describes and the same fix —
-- offer only what the server will honour.
local PARTY_TIERS_BY_GAME = {
    MATATU = { 200, 500 },
    WHOT   = { 80,  200 },   -- x0.4
    KADI   = { 8,   20  },   -- x0.04
}
M.PARTY_TIERS = PARTY_TIERS_BY_GAME[GameMode.GAME] or PARTY_TIERS_BY_GAME.MATATU

-- HOW A PARTY IS WON. Mirrors PartyMode in be_matatu's partyRules.ts.
--   NORMAL    play it out; when somebody goes out the rest are counted
--   SCORECAP  a running total per player, cross the cap and you're out
-- HOW A PARTY IS WON. Mirrors PartyMode in be_matatu's partyRules.ts.
--   NORMAL    one deal; when somebody goes out the rest are counted
--   SCORECAP  a running total per player, carried across deals — cross the cap
--             and you are out, and the survivors are re-dealt until one is left
M.PARTY_MODES = { "NORMAL", "SCORECAP" }

-- The SAME ladder KNOCKOUT uses, deliberately — see the note on M.KNOCKOUT_CAPS.
-- Kept as its own name so a future change to one mode cannot silently move the
-- other, and so this reads as a decision rather than as a coincidence.
M.PARTY_CAPS = { 100, 200, 250, 300 }
M.PARTY_DEFAULT_CAP_I = 2 -- 200, matching PARTY_DEFAULT_SCORE_CAP on the server

function M.party_mode_of(bm)
    return (tostring((bm or {}).pmode or "NORMAL"):upper() == "SCORECAP") and "SCORECAP" or "NORMAL"
end

function M.party_cap_of(bm)
    local i = (bm or {}).pcap_i or M.PARTY_DEFAULT_CAP_I
    if i < 1 then i = 1 elseif i > #M.PARTY_CAPS then i = #M.PARTY_CAPS end
    return M.PARTY_CAPS[i]
end

-- The three independent battle types. Internal keys map to display labels.
M.BATTLE_TYPES = { "NORMAL", "KNOCKOUT", "PARTY" }
M.BATTLE_TYPE_LABELS = { NORMAL = "BATTLE", KNOCKOUT = "KNOCKOUT", PARTY = "PARTY" }

-- ---------------------------------------------------------------------------
-- THE OPEN BADGE'S HEARTBEAT
--
-- WHY IT IS NOT gui.animate, WHICH IS WHAT EVERYTHING ELSE HERE USES.
--
-- Two reasons, and the second one is fatal on its own.
--
-- 1. rebuild() deletes and recreates every node on this screen, and a fresh
--    node has no animation on it. Rebuilds are not rare: an incoming-request
--    banner rebuilds once a second, a socket burst up to twelve times a
--    second, and the savings promo rebuilds EVERY FRAME while it types itself
--    out. A looping tween restarted sixty times a second never leaves the
--    start of its first ease — the badge would sit at rest, perfectly still,
--    which is the opposite of the thing being asked for.
--
-- 2. PLAYBACK_LOOP_PINGPONG oscillates between the value the node HAD when the
--    animation started and the target. So it cannot be seeded to the right
--    phase to survive those restarts: seed it at 1.03 and it breathes between
--    1.03 and 1.06 instead of 1.00 and 1.06. Phase continuity and correct
--    amplitude are mutually exclusive with that playback mode.
--
-- So the scale is written straight into the node from a monotonic clock, once
-- a frame, which is the pattern this screen already uses for the season
-- countdown a few hundred lines down and for exactly the same reason. It costs
-- one cosine and one set_scale, it cannot drift out of phase, and a rebuild in
-- the middle of a breath is invisible because the next frame recomputes the
-- same value from the same clock.

--- How long one full in-and-out takes.
M.BADGE_PULSE_PERIOD = 1.0

--- How far it swells. Six percent is enough to catch the eye at the edge of
--- vision and small enough that a still frame looks like no animation at all,
--- which is what keeps it gentle rather than nagging.
M.BADGE_PULSE_AMOUNT = 0.06

--- The scale multiplier at a given moment. Pure, so the shape can be checked
--- without a screen.
--
-- A raised cosine: it leaves 1.0 and returns to it with zero velocity, so
-- there is no corner at either end of the breath. A triangle wave would tick.
function M.badge_pulse_scale(clock)
    local t = tonumber(clock)
    if t == nil then return 1 end
    local p = (t % M.BADGE_PULSE_PERIOD) / M.BADGE_PULSE_PERIOD
    return 1 + M.BADGE_PULSE_AMOUNT * (0.5 - 0.5 * math.cos(p * 2 * math.pi))
end

--- Breathe the badge, if there is one and it is open.
--
-- Called every frame by the host. Safe when the node has been deleted by a
-- rebuild that has not run draw() yet, and safe when the badge says CLOSED —
-- CLOSED is a fact and sits still; OPEN is an invitation with a clock on it.
function M.pulse_badge(self, clock)
    local n = self and self.tourn_badge_node
    if not n then return false end
    local k = M.badge_pulse_scale(clock)
    local ok = pcall(gui.set_scale, n, vmath.vector3(k, k, 1))
    if not ok then self.tourn_badge_node = nil end
    return ok
end

-- ---------------------------------------------------------------------------
-- MEASURING TEXT ONCE, NOT ONCE PER REBUILD.
--
-- gui.get_text_metrics_from_node LAYS THE STRING OUT. It is the right tool —
-- nothing in Defold measures text at build time — but this row is redrawn on
-- every rebuild of the screen, and the strings it measures are fixed:
-- "TOURNAMENTS", and one of "OPEN" or "CLOSED". Laying the same three strings
-- out over and over, up to sixty times a second, buys nothing.
--
-- Keyed by font and text. Scale is not in the key because every caller here
-- draws at 1; a caller that scaled would need it, which is why this stays
-- local to this module rather than becoming a general helper.
local TEXT_METRICS = {}

local function measure(node, text, font, fallback_w)
    local key = font .. "\0" .. text
    local hit = TEXT_METRICS[key]
    if hit then return hit.w, hit.drop end

    local w, drop
    local ok = pcall(function()
        local m = gui.get_text_metrics_from_node(node)
        local sc = gui.get_scale(node)
        w = m.width * sc.x
        -- THE OPTICAL DROP. A text node's pivot is the centre of its LINE BOX
        -- — ascent plus descent — not the centre of the ink. The descent is
        -- space reserved for the tails of g, j, p, q, y, and an all-caps word
        -- has none, so centring the line box puts the letters high.
        --
        -- The exact correction is (ascent - descent - capHeight) / 2, and
        -- Defold reports ascent and descent but never cap height. Half a
        -- descent is the upper end of that range — it assumes capitals reach
        -- the full ascent — and it overshot in practice. A quarter is the
        -- middle, which is the most these metrics can justify.
        drop = ((m.max_descent or 0) * sc.y) / 4
    end)
    if not ok or not w or w <= 0 then w = fallback_w end
    if not drop or drop <= 0 then drop = 1.5 end

    TEXT_METRICS[key] = { w = w, drop = drop }
    return w, drop
end

-- Battle types the UI is allowed to SHOW.
--
-- PARTY IS UNMOUNTED, NOT DELETED. This one list is the whole switch: it feeds
-- the lobby's right-hand battle rows (each with its own INVITE and EDIT) and
-- the type picker inside the battle maker, so dropping the word from it takes
-- party off both surfaces and nothing else.
--
-- Everything behind it stays exactly where it is — PARTY_TIERS, PARTY_MODES,
-- PARTY_CAPS, the is_party branches through the maker, battle_of_type, the
-- "N PLAYERS" detail row, the party icon in ui.atlas, and the four-seat table
-- on the server (be_matatu common/services/partyRules.ts and
-- matatu/websocket/handlers/party.ts). Put the word back and all of it
-- returns.
--
-- Deleting a feature in order to hide it is how you find out, six weeks later,
-- which half of it something else depended on. It is also the honest state of
-- this one: the maker and the invite flow are finished, the four-seat GAME is
-- not, so the entry points come down until it is.
--
-- PARTY IS BACK. The sentence above — "the maker and the invite flow are
-- finished, the four-seat GAME is not" — is what kept it down, and the game
-- now exists: a seat order the turn engine steps round, a deal for two to
-- four, a settlement that pays a pot to a finishing ORDER, seats the board can
-- actually draw (party_board.lua), and an open-table list the lobby sees.
--
-- EDIT still means what it meant: it configures this battle's entry, mode and
-- cap. INVITE now means something different for a party than for the other two
-- — see start_invite_search. A party is not searched for, it is OPENED, and
-- the lobby fills it.
M.BATTLE_TYPES_VISIBLE = { "NORMAL", "KNOCKOUT", "PARTY" }

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
local C_HINT     = vmath.vector4(0.600, 0.600, 0.600, 1.0) -- hint line under a control
local C_SEG_OFF  = vmath.vector4(0.160, 0.160, 0.180, 1.0) -- unselected segment

-- ── Battle modal layout ──────────────────────────────────────────────────────
--
-- ONE VERTICAL RHYTHM, AND IT USED TO HAVE THREE.
--
-- Every row of this form is the same three things — a small label, a control,
-- and a hint line — and each was positioned by its own hand-picked offset.
-- BATTLE TYPE sat 140px above ENTRY FEE while ENTRY FEE sat 130 above the row
-- under it, so the form read as a stack of unrelated widgets rather than as
-- one thing to fill in. Worse, a PARTY set to SCORE CAP grew a FOURTH row that
-- nothing had left room for: its hint landed on the error line and crowded the
-- submit button.
--
-- The offsets are named constants now, applied identically to every row.
-- Both offsets are measured from the control's CENTRE, and a control is
-- CTRL_H tall, so the real clearance either side is the offset minus 26 minus
-- half a line of "small" text — about 7px at these numbers. Shrink either one
-- and the caption starts touching the box it belongs to.
local ROW_LABEL_DY = 42  -- label sits this far above its control
local ROW_HINT_DY  = 42  -- hint sits this far below it
local CTRL_H       = 52  -- every control on this form is this tall

-- A [-] [ value ] [+] stepper, centred on `cx`.
--
-- There were four copies of this inline — entry fee, knockout cap, party cap,
-- game format — identical apart from the two button ids and the value they
-- showed. Four copies is why the party cap ended up as the only one drawn at a
-- different size than its neighbours: nothing tied them together.
--
-- `box_w` is the value field alone; the stepper's real footprint is that plus
-- a button on each side, which stepper_width() answers for a caller laying two
-- controls out side by side.
local function stepper_width(box_w, btn)
    btn = btn or CTRL_H
    return box_w + 2 * (btn + 8)
end

local function stepper(self, ctx, cx, y, box_w, value, value_color, id_minus, id_plus, btn)
    btn = btn or CTRL_H
    local gap = box_w / 2 + btn / 2 + 8
    ctx.mkbtn(self, id_minus, vmath.vector3(cx - gap, y, 0), vmath.vector3(btn, btn, 0), "-", "secondary_btn")
    ctx.track(self, ctx.ui.box(vmath.vector3(cx, y, 0), vmath.vector3(box_w, CTRL_H, 0), ctx.C.COL_NAMEID_BG))
    ctx.track(self, ctx.ui.text(vmath.vector3(cx, y, 0), value, "body", value_color))
    ctx.mkbtn(self, id_plus, vmath.vector3(cx + gap, y, 0), vmath.vector3(btn, btn, 0), "+", "secondary_btn")
end

-- A row of mutually-exclusive segments, centred on `cx`.
local function segments(self, ctx, cx, y, seg_w, seg_gap, specs)
    local n = #specs
    for i, sp in ipairs(specs) do
        local sx  = cx + (i - (n + 1) / 2) * (seg_w + seg_gap)
        local box = ctx.track(self, ctx.ui.box(vmath.vector3(sx, y, 0), vmath.vector3(seg_w, CTRL_H, 0),
            sp.on and C_VICTORY or C_SEG_OFF))
        self.buttons[#self.buttons + 1] = { node = box, id = sp.id }
        ctx.track(self, ctx.ui.text(vmath.vector3(sx, y, 0), sp.label, "btn_md",
            sp.on and C_BTN_TEXT or ctx.C.COL_WHITE))
    end
end

-- A battle row's detail line, in two colours: the RULE, then the STAKE.
--
-- Both used to be one dim-grey string four spaces apart — "CAP 200    200" —
-- so the row read as a single run of digits and its two numbers were easy to
-- read as each other. The rule is white; the stake is gold, which is already
-- this UI's "there is money in this" colour (the prize table, the season
-- deadline, the H2H line).
--
-- WHY IT MEASURES.
--
-- Nothing in Defold measures text at BUILD time, but this runs at draw time,
-- where gui.get_text_metrics_from_node does — the announcement marquee lays
-- its whole ticker out this way. The metric is the UNSCALED font size, so it
-- is multiplied by the node's own scale before it is used as an advance.
--
-- The pcall is not decoration: a failed measurement must leave the two apart,
-- not stacked on top of each other. The fallback is the same character-count
-- estimate rank_badge.width uses, which is wide rather than tight — a gap
-- slightly too big is invisible, and one slightly too small is two strings
-- printed over one another.
local DETAIL_GAP = 18
local DETAIL_FALLBACK_CHAR_W = 9

local function detail_line(self, ctx, x, y, rule, stake)
    local C = ctx.C
    local n = ctx.txtL(self, x, y, rule, "small", C.COL_WHITE)

    local w
    local ok = pcall(function()
        local m = gui.get_text_metrics_from_node(n)
        local sc = gui.get_scale(n)
        w = m.width * sc.x
    end)
    if not ok or not w or w <= 0 then w = #rule * DETAIL_FALLBACK_CHAR_W end

    ctx.txtL(self, x + w + DETAIL_GAP, y, stake, "small", C.COL_GOLD)
end

-- ── Battle Modal Drawing ──────────────────────────────────────────────────────
-- Reverted to the original pre-"compact card" layout: plain text/steppers
-- floating directly on the dim backdrop, no bordered container_bg panel.
-- The compact-card redesign (and its several anchoring follow-up fixes) kept
-- causing regressions, so this goes back to the last version that was
-- reliably stable.
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

    track(self, ui.text(vmath.vector3(CX, CY + 252, 0), title, "title", ctx.C.COL_WHITE))
    mkbtn(self, "bm_close", vmath.vector3(CX + 340, CY + 252, 0), vmath.vector3(56, 56, 0), "X", "secondary_btn")

    -- ── The rows ─────────────────────────────────────────────────────────
    -- Four y positions, and every row places its label and hint from the same
    -- two offsets. The form used to grow a fourth row for PARTY + SCORE CAP
    -- that nothing had reserved space for; that row is now laid out INLINE
    -- beside PLAY MODE instead, which is what the horizontal space here was
    -- always for.
    local type_y = CY + 160
    local fee_y  = CY + 50
    local opt_y  = CY - 76
    local msg_y  = CY - 160
    local sub_y  = CY - 230

    -- A row's small caption, and the grey line that explains it.
    local function label(cx, y, str)
        track(self, ui.text(vmath.vector3(cx, y + ROW_LABEL_DY, 0), str, "small", C_NEUTRAL))
    end
    local function hint(y, str, cx)
        track(self, ui.text(vmath.vector3(cx or CX, y - ROW_HINT_DY, 0), str, "small", C_HINT))
    end

    -- BATTLE TYPE
    label(CX, type_y, "BATTLE TYPE")
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
    segments(self, ctx, CX, type_y, 170, 14, seg_specs)

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
        local ci = bm.cap_i or M.KNOCKOUT_DEFAULT_CAP_I
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
    local STEP_W = 280
    label(CX, fee_y, is_knock and "STAKE" or "ENTRY FEE")
    stepper(self, ctx, CX, fee_y, STEP_W,
        commas(is_knock and estake or amount) .. " COINS", C_CHAMPION,
        "bm_fee_minus", "bm_fee_plus")

    if is_norm then
        hint(fee_y, string.format("Winner Takes: %s + %d Pts", commas(winner_takes), fmt.points))
    elseif is_party then
        hint(fee_y, "Pooled prize · last player standing wins")
    else
        hint(fee_y, "Staked score chamber · charge from the cap")
    end

    -- FORMAT / PLAY MODE / CAP
    if is_party then
        -- NO PLAYER-COUNT PICKER.
        --
        -- The table is always AUTO now: it opens, people take chairs for twenty
        -- seconds, and whoever is seated when the clock runs out plays. A
        -- number to choose implied the host could hold the table open for a
        -- fourth who might never come — which is exactly the wait the fixed
        -- window exists to remove. The count is still sent as "AUTO" on submit,
        -- so nothing downstream had to change.
        --
        -- What the host picks instead is HOW the party is won — and, when that
        -- is SCORE CAP, what the cap is. Those are ONE ROW, side by side.
        -- Stacked, the cap was a fourth row on a form built for three: its hint
        -- landed on the error line and pushed the submit button into the bottom
        -- of the screen. Side by side it costs no height at all, and the two
        -- controls belong together anyway — the second only exists because of
        -- what the first is set to.
        local pmode = M.party_mode_of(bm)
        local capped = (pmode == "SCORECAP")

        -- COLUMN CENTRES, MEASURED RATHER THAN GUESSED.
        --
        -- Both columns are laid out from what their controls actually span, so
        -- widening either one cannot silently slide it under the other. Hand-
        -- picked centres are exactly how the old fourth row ended up sitting on
        -- top of the error line.
        --
        -- When there is no cap to show, PLAY MODE keeps the middle to itself
        -- rather than sitting off to one side of an empty half — a lone control
        -- pushed left reads as something having failed to draw.
        local mode_w, mode_gap = capped and 150 or 180, 12
        local mode_span = 2 * mode_w + mode_gap
        local cap_box, cap_btn = 150, 44
        local cap_span = stepper_width(cap_box, cap_btn)
        local col_gap = 60

        local mode_cx, cap_cx = CX, CX
        if capped then
            local left = CX - (mode_span + col_gap + cap_span) / 2
            mode_cx = left + mode_span / 2
            cap_cx  = left + mode_span + col_gap + cap_span / 2
        end

        -- Built from M.PARTY_MODES rather than hardcoded, so the row can only
        -- ever offer modes a table will actually play. Both are honoured now;
        -- if one is ever pulled again this collapses to a single segment
        -- instead of offering a choice that silently becomes the other.
        label(mode_cx, opt_y, "PLAY MODE")
        local mode_segs = {}
        for _, mname in ipairs(M.PARTY_MODES) do
            mode_segs[#mode_segs + 1] = (mname == "SCORECAP")
                and { id = "bm_pmode_cap",    label = "SCORE CAP", on = capped }
                or  { id = "bm_pmode_normal", label = "NORMAL",    on = not capped }
        end
        segments(self, ctx, mode_cx, opt_y, mode_w, mode_gap, mode_segs)

        if capped then
            -- Same ladder and the same wording as a KNOCKOUT chamber, on
            -- purpose: a player who knows what "cap 200" costs them there
            -- should not have to learn a second meaning for it here.
            --
            -- Narrower than the fee stepper above it because it shares the
            -- row: 254px against that one's 400.
            label(cap_cx, opt_y, "SCORE CAP")
            stepper(self, ctx, cap_cx, opt_y, cap_box, tostring(M.party_cap_of(bm)),
                ctx.C.COL_WHITE, "bm_pcap_minus", "bm_pcap_plus", cap_btn)
            hint(opt_y, "Reach the cap and you're out · last player standing wins")
        else
            hint(opt_y, "Play it out · lowest hand when someone goes out wins")
        end
    elseif is_knock then
        label(CX, opt_y, "SCORE CAP")
        stepper(self, ctx, CX, opt_y, STEP_W, tostring(cap), ctx.C.COL_WHITE,
            "bm_cap_minus", "bm_cap_plus")
        -- From the shared table, NOT math.floor(cap/2): the two agree only on
        -- the first two rungs, so a 250 chamber would have advertised a charge
        -- of 125 here while the server billed 150.
        hint(opt_y, string.format("Charge: %d  ·  reach the cap and you're out", M.knockout_charge(cap)))
    else
        label(CX, opt_y, "GAME FORMAT")
        stepper(self, ctx, CX, opt_y, STEP_W, "BEST OF " .. fmt.games, ctx.C.COL_WHITE,
            "bm_fmt_minus", "bm_fmt_plus")
        hint(opt_y, string.format("Charge: %s  ·  %d Pts to the winner", commas(fmt.charge), fmt.points))
    end

    if bm.msg then
        track(self, ui.text(vmath.vector3(CX, msg_y, 0), bm.msg, "small",
            bm.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end

    local sub_label = bm.submitting and "WAITING..." or title
    local s_btn = track(self, ui.box(vmath.vector3(CX, sub_y, 0), vmath.vector3(380, 68, 0), C_VICTORY))
    self.buttons[#self.buttons+1] = { node = s_btn, id = "bm_submit" }
    track(self, ui.text(vmath.vector3(CX, sub_y, 0), sub_label, "btn_lg", C_BTN_TEXT))
end

-- ── Team Tournament Bracket View ─────────────────────────────────────────────
-- Every joined player, and the owner whether or not they're playing, can
-- see who's on which level and how they're doing. The owner additionally
-- gets ADVANCE/DROP overrides per row (see advanceTeamTournamentPlayer/
-- dropTeamTournamentPlayer on the backend — neither can mint the grand
-- prize; that's still only ever awarded through real gameplay).
local MAX_BRACKET_ROWS = 8

local function draw_team_bracket_modal(self, ctx)
    local br = self.team_bracket_modal
    if not br then return end

    local track = ctx.track
    local ui    = ctx.ui
    local mkbtn = ctx.mkbtn
    local txtL  = ctx.txtL
    local commas = ctx.commas
    -- Anchored to the full screen — this dialog's content (a list of player
    -- rows plus ADVANCE/DROP buttons) is wider than the right panel's own
    -- column, so it gets the full screen to work with rather than being
    -- squeezed into that narrower strip.
    local CX, CY = ctx.CX, ctx.CY
    local C     = ctx.C
    local NOTE_C = vmath.vector4(0.6, 0.6, 0.6, 1)

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons+1] = { node = dim, id = "tbr_block" }
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    local panel_w, panel_h = 520, 560
    track(self, ui.panel9(vmath.vector3(CX, CY, 0), vmath.vector3(panel_w, panel_h, 0), "container_bg"))

    local cursor_y = CY + panel_h/2 - 18
    track(self, ui.text(vmath.vector3(CX, cursor_y - 10, 0), "TEAM TOURNAMENT BRACKET", "subtitle2", C.COL_WHITE))
    mkbtn(self, "tbr_close", vmath.vector3(CX + panel_w/2 - 32, cursor_y - 10, 0), vmath.vector3(40, 40, 0), "X", "secondary_btn")
    cursor_y = cursor_y - 34
    track(self, ui.box(vmath.vector3(CX, cursor_y, 0), vmath.vector3(panel_w - 48, 1, 0), vmath.vector4(1, 1, 1, 0.14)))
    cursor_y = cursor_y - 24

    if br.loading then
        track(self, ui.text(vmath.vector3(CX, cursor_y, 0), "Loading...", "small", C_NEUTRAL))
        return
    end
    if br.error then
        track(self, ui.text(vmath.vector3(CX, cursor_y, 0), br.error, "small", vmath.vector4(1, 0.35, 0.35, 1)))
        return
    end

    local data = br.data or {}
    local totalLevels = #(data.levels or {})
    track(self, ui.text(vmath.vector3(CX, cursor_y, 0),
        string.format("%s  ·  %s coins  ·  code %s", data.name or "Team Tournament",
            commas((data.grandPrize or {}).value or 0), data.invitationCode or "?"), "small", C_NEUTRAL))
    cursor_y = cursor_y - 30

    local players = data.players or {}
    -- Highest level first — the closest to winning are the most interesting
    -- to see at a glance.
    table.sort(players, function(a, b) return (a.currentLevel or 1) > (b.currentLevel or 1) end)

    if #players == 0 then
        track(self, ui.text(vmath.vector3(CX, cursor_y, 0), "No players have joined yet.", "small", NOTE_C))
    end

    local row_h = 52
    local is_owner = br.is_owner
    for i = 1, math.min(#players, MAX_BRACKET_ROWS) do
        local p = players[i]
        local py = cursor_y - (i - 0.5) * row_h
        track(self, ui.box(vmath.vector3(CX, py, 0), vmath.vector3(panel_w - 40, row_h - 6, 0), vmath.vector4(1,1,1,0.04)))

        local status_col = (p.status == "completed") and vmath.vector4(1.0, 0.843, 0.0, 1) or C.COL_WHITE
        txtL(self, CX - panel_w/2 + 30, py + 8, tostring(p.username or "Player"), "body", status_col)
        txtL(self, CX - panel_w/2 + 30, py - 12, string.format("Level %d/%d  ·  %s", p.currentLevel or 1, totalLevels, tostring(p.status or "active")), "small", NOTE_C)

        if is_owner then
            local adv_x = CX + panel_w/2 - 130
            local drop_x = CX + panel_w/2 - 60
            mkbtn(self, "tbr_advance", vmath.vector3(adv_x, py, 0), vmath.vector3(60, 34, 0), "ADV", "secondary_btn", p.playerId, "btn_sm")
            mkbtn(self, "tbr_drop", vmath.vector3(drop_x, py, 0), vmath.vector3(60, 34, 0), "DROP", "secondary_btn", p.playerId, "btn_sm")
        end
    end

    if #players > MAX_BRACKET_ROWS then
        track(self, ui.text(vmath.vector3(CX, cursor_y - (MAX_BRACKET_ROWS + 0.5) * row_h, 0),
            string.format("+ %d more player(s)", #players - MAX_BRACKET_ROWS), "small", NOTE_C))
    end

    if br.msg then
        track(self, ui.text(vmath.vector3(CX, CY - panel_h/2 + 30, 0), br.msg, "small",
            br.msg_ok and vmath.vector4(0.3, 1.0, 0.3, 1) or vmath.vector4(1, 0.3, 0.3, 1)))
    end
end

-- ── Savings helpers (backend-driven config, with a safe fallback while the
-- first SAVINGS_STATUS round-trip hasn't landed yet) ────────────────────────
-- Must be defined before draw_savings_info/draw_savings_plans below, which
-- call format_redemption_date — Lua doesn't hoist locals within a chunk, so
-- a forward reference here would resolve to an undefined global and error.
local MONTH_NAMES = {"January","February","March","April","May","June","July","August","September","October","November","December"}
local function format_redemption_date(iso)
    local y, m, d = tostring(iso or ""):match("(%d+)-(%d+)-(%d+)")
    if not y then return "" end
    return string.format("%s %d, %s", MONTH_NAMES[tonumber(m)] or m, tonumber(d), y)
end

-- ── Savings Info Modal Drawing ────────────────────────────────────────────────
-- Deliberately more of a promo/explainer than a plain info popup — a first-
-- time player has never heard of Savings, so this leads with a big coin
-- bundle to grab the eye, then spells out what it is, why it's worth caring
-- about, and how much of the current period is left, before a single clear
-- "I UNDERSTAND" dismiss button (same gradient-card treatment as gameover.gui_script).
local function draw_savings_info(self, ctx)
    if not self.savings_info_open then return end

    local track = ctx.track
    local ui    = ctx.ui
    local txtL  = ctx.txtL
    local mkbtn = ctx.mkbtn
    local C     = ctx.C
    local CX, CY = ctx.CX, ctx.CY
    local COL_SAVINGS = vmath.vector4(0.20, 0.75, 0.55, 1.0)

    -- Type the copy out character by character the first time this dialog is
    -- shown, so a first-time reader's eye is pulled through it instead of it
    -- landing as one wall of text. Every typed string here is plain ASCII —
    -- string.sub() slices by byte, and a multi-byte UTF-8 char (✓, —) cut
    -- mid-sequence would render as garbage, so those stay outside the budget.
    --
    -- MEASURED FROM THE CLOCK, NOT FROM AN ACCUMULATOR SOMEBODY HAS TO TICK.
    --
    -- This read self._savings_type_t, which online.gui_script's update() was
    -- supposed to advance and did not — nothing anywhere assigned it. So the
    -- budget was floor(nil/0.015) = 0 on every frame, typed() returned "" for
    -- every line, and the dialog opened as a coin bundle, two buttons and a
    -- completely empty card. A promo nobody can read is worse than no promo.
    --
    -- Deriving the budget from elapsed wall time removes the whole class of
    -- failure: the only thing update() is still needed for is asking for a
    -- redraw, and if that ever stops the text simply appears complete on the
    -- next draw instead of vanishing.
    local CHAR_INTERVAL = 0.015
    -- Belt: whatever happens, the card is fully readable this long after it
    -- opened. Typing is a flourish; the words are the point.
    local TYPE_GIVE_UP = 3.0

    local now = (socket and socket.gettime and socket.gettime()) or os.time()
    self._savings_type_t0 = self._savings_type_t0 or now
    local elapsed = now - self._savings_type_t0
    if elapsed >= TYPE_GIVE_UP then self._savings_type_done = true end

    local typing = not self._savings_type_done
    local budget = typing and math.floor(elapsed / CHAR_INTERVAL) or math.huge
    local function typed(full)
        if not typing then return full end
        if budget >= #full then
            budget = budget - #full
            return full
        end
        local shown = string.sub(full, 1, math.max(0, budget))
        budget = 0
        return shown
    end

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.78)))
    self.buttons[#self.buttons+1] = { node = dim, id = "savings_info_block" }
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    local panel_w, panel_h = 460, 600
    track(self, ui.panel9(vmath.vector3(CX, CY, 0), vmath.vector3(panel_w, panel_h, 0), "container_bg"))

    local top = CY + panel_h / 2

    -- A big coin bundle peeking out the top of the card — the same "grab
    -- attention first" treatment the game-request dialogs use for their pot.
    -- Kept small enough (+ only a slight peek above the panel) to stay clear
    -- of the top of a 720-tall logical screen.
    local bundle = track(self, gui.new_box_node(vmath.vector3(CX, top + 4, 0), vmath.vector3(100, 100, 0)))
    gui.set_color(bundle, vmath.vector4(1, 1, 1, 1))
    pcall(function() gui.set_texture(bundle, "coins"); gui.play_flipbook(bundle, hash("1000")) end)

    local cy = top - 66
    track(self, ui.text(vmath.vector3(CX, cy, 0), typed("SAVINGS"), "title", C.COL_GOLD))
    cy = cy - 34

    local body_lines = {
        "Savings are long-term coins earned from",
        "Half-Week Season rewards. Unlike your",
        "regular balance, Savings never reset and",
        "build up over time.",
    }
    for _, line in ipairs(body_lines) do
        track(self, ui.text(vmath.vector3(CX, cy, 0), typed(line), "small", C.COL_WHITE))
        cy = cy - 22
    end

    cy = cy - 12
    track(self, ui.box(vmath.vector3(CX, cy, 0), vmath.vector3(panel_w - 64, 1, 0), vmath.vector4(1, 1, 1, 0.14)))
    cy = cy - 26

    track(self, ui.text(vmath.vector3(CX, cy, 0), typed("WHY IT'S WORTH IT"), "small", C.COL_DIM))
    cy = cy - 28

    local advantages = {
        "Never resets or expires, it only grows",
        "Turn on auto-charge to save a little every game",
        "A safety net of coins for later, built up passively",
        "Rewards you just for playing through the Season",
    }
    local bullet_x = CX - panel_w / 2 + 32
    for _, line in ipairs(advantages) do
        -- The checkmark glyph is multi-byte UTF-8, so it's shown in full
        -- immediately (as soon as this row's turn comes up) rather than
        -- being subject to the same byte-sliced typing as the ASCII text.
        local line_text = typed(line)
        if line_text ~= "" then
            txtL(self, bullet_x, cy, "✓", "small", COL_SAVINGS)
        end
        txtL(self, bullet_x + 22, cy, line_text, "small", C.COL_WHITE)
        cy = cy - 24
    end

    cy = cy - 14
    track(self, ui.box(vmath.vector3(CX, cy, 0), vmath.vector3(panel_w - 64, 1, 0), vmath.vector4(1, 1, 1, 0.14)))
    cy = cy - 26

    -- Time-bound: this Season's Savings period, and how far through it we are.
    local st = ws.current_savings_status or {}
    local redemption_str = format_redemption_date(st.nextRedemptionDate)
    if redemption_str ~= "" then
        track(self, ui.text(vmath.vector3(CX, cy, 0), typed("Next redemption: " .. redemption_str), "small", C.COL_GOLD))
        cy = cy - 26
    end

    local pct = math.max(0, math.min(100, tonumber(st.periodProgressPercent) or 0))
    track(self, ui.text(vmath.vector3(CX, cy, 0), typed("SAVINGS PERIOD PROGRESS"), "small", C.COL_DIM))
    cy = cy - 22
    local bar_w, bar_h = panel_w - 64, 14
    track(self, ui.box(vmath.vector3(CX, cy, 0), vmath.vector3(bar_w, bar_h, 0), vmath.vector4(1, 1, 1, 0.08)))
    if pct > 0 then
        local fill_w = bar_w * (pct / 100)
        track(self, ui.box(vmath.vector3(CX - bar_w/2 + fill_w/2, cy, 0), vmath.vector3(fill_w, bar_h, 0), COL_SAVINGS))
    end
    cy = cy - 22
    track(self, ui.text(vmath.vector3(CX, cy, 0), typed(pct .. "% complete"), "small", C.COL_WHITE))

    -- Every line above has now had its turn — once the budget outlasts the
    -- last one, the typing pass is complete; stop ticking it in update().
    if typing and budget > 0 then self._savings_type_done = true end

    local by = CY - panel_h / 2 + 46
    local btn_gap = 12
    local btn_w = (panel_w - 64 - btn_gap) / 2
    mkbtn(self, "savings_try_it", vmath.vector3(CX - btn_w/2 - btn_gap/2, by, 0), vmath.vector3(btn_w, 56, 0), "TRY IT", "primary_btn")
    mkbtn(self, "savings_info_close", vmath.vector3(CX + btn_w/2 + btn_gap/2, by, 0), vmath.vector3(btn_w, 56, 0), "I UNDERSTAND", "secondary_btn")
end

-- ── Tournaments: a full-width row, in flow ──────────────────────────────────
--
-- IT FLOATED, TWICE, AND NEITHER SHAPE WORKED. First as a 76px circle, which
-- carries one glyph: the word TOURNAMENTS came off the control entirely and
-- the OPEN/CLOSED badge had nowhere to sit but half off the bottom edge. Then
-- as an extended bar spanning the right-hand column, which fixed both of those
-- and left the real problem — a floating control covers whatever it is over.
-- This panel scrolls nothing and hides nothing; there was never any content
-- for it to float above, only content for it to sit on top of.
--
-- So it is a row again, drawn IN FLOW after the battles container, at the
-- panel's own full width. What the two floating passes were actually for was
-- the LAYOUT INSIDE it, and that is what survives: the icon, the word, and a
-- badge that is right-aligned and vertically centred rather than clipped to an
-- edge. It is 80 tall rather than the 72 it first shipped at, which is the one
-- thing the "too small" complaint was really about once it stopped being a dot.
--
-- Returns the cursor below itself, like every other block in this panel.
local function draw_tournaments_row(self, ctx, cx, pw, cy)
    local track = ctx.track
    local ui    = ctx.ui
    local mkbtn = ctx.mkbtn
    local C     = ctx.C
    local u     = ws.current_user_data or {}

    local ROW_H = 80   -- a 35pt word and a 40px icon, with air around them
    local PAD   = 20   -- the same inset row_l/row_r use on the battle rows above
    local ICON  = 40
    local GAP   = 14   -- icon → word, and word → badge

    local row_l = cx - pw/2 + PAD
    local row_r = cx + pw/2 - PAD
    local edge_r = cx + pw/2      -- the row background's own right edge
    local rcy   = cy - ROW_H/2

    -- OPEN or CLOSED, from the same daily window the tournament screen greys
    -- its PLAY button on (modules/tournament_window, which both read so the
    -- two cannot drift). Cached for the minute it describes: the answer can
    -- only change on a window boundary, and os.date builds a fresh table every
    -- call — which this does not need on a screen that rebuilds every frame
    -- while the savings promo is typing.
    local now_s = os.time()
    if self._tw_at ~= now_s then
        self._tw_at = now_s
        self._tw_status = tournament_window.status_label(
            u.tournaments, tournament_window.minute_of_day(os.date("*t", now_s)))
    end
    local t_status = self._tw_status

    track(self, ui.box(vmath.vector3(cx, rcy, 0), vmath.vector3(pw, ROW_H, 0), C.COL_BG))
    mkbtn(self, "nav_tournaments", vmath.vector3(cx, rcy, 0),
        vmath.vector3(pw, ROW_H, 0), nil, "container_bg")

    local icon_x = row_l + ICON / 2
    local icon = track(self, ui.image(vmath.vector3(icon_x, rcy, 0),
        vmath.vector3(ICON, ICON, 0), "tournament_icon"))
    gui.set_color(icon, C.COL_WHITE)

    -- THE WORD, LEFT-ALIGNED OFF THE ICON. Its width still has to be MEASURED,
    -- because the badge's left clearance is stated relative to where the word
    -- actually ends, not to a guess about how long "TOURNAMENTS" is at
    -- Teko-Bold 35.
    local title_txt = "TOURNAMENTS"
    local title_x   = icon_x + ICON / 2 + GAP
    local tn = track(self, ui.text(vmath.vector3(title_x, rcy, 0), title_txt, "btn_lg", C.COL_WHITE))
    gui.set_pivot(tn, gui.PIVOT_W)
    local tw = measure(tn, title_txt, "btn_lg", #title_txt * 14)
    local title_right = title_x + tw

    self.tourn_badge_node = nil
    if t_status then
        local is_open = (t_status == "OPEN")
        local badge_col = is_open and vmath.vector4(0.15, 0.8, 0.25, 1.0)
            or vmath.vector4(0.55, 0.16, 0.16, 1.0)

        -- THE BOX IS CREATED FIRST, AND THAT IS NOT A STYLE CHOICE.
        --
        -- Defold draws gui nodes in creation order, so a box made after its
        -- label is a box drawn OVER its label. The badge came out as a solid
        -- green rectangle with nothing in it — the word was there the whole
        -- time, underneath.
        --
        -- Measuring the label in order to size the box is what tempted the
        -- order to be flipped, and it never had to be: the box is made at a
        -- provisional size, the label goes on top of it, and the box is
        -- RESIZED once the label has been measured.
        local BADGE_H = 30
        local badge = track(self, ui.box(vmath.vector3(0, 0, 0),
            vmath.vector3(56, BADGE_H, 0), badge_col))
        local bn = track(self, ui.text(vmath.vector3(0, 0, 0), t_status, "btn_sm", C.COL_WHITE))

        -- btn_sm is Teko-Bold at 25, a condensed face, so roughly eleven
        -- pixels a capital when the measurement is unavailable. Wide rather
        -- than tight: a badge slightly too big is invisible, one slightly too
        -- small clips the word.
        local bw, bdrop = measure(bn, t_status, "btn_sm", #t_status * 11)
        local BADGE_PAD = 13
        local badge_w = math.max(56, bw + BADGE_PAD * 2)

        -- RIGHT-ALIGNED AND VERTICALLY CENTRED — the position it could not
        -- have on a circle. Two constraints, resolved in priority order:
        --
        --   1. NEVER draw past the row's own background. A badge beyond that
        --      edge floats outside its own container, which reads as broken
        --      rather than merely tight.
        --   2. Otherwise, prefer clearing the word by GAP. Normally that costs
        --      nothing — the flush-right position already clears it with room
        --      over — but it is what keeps the badge off the word if either
        --      string or the column ever changes size.
        --
        -- Priority 1 wins when they disagree, so the gap can shrink under a
        -- genuinely tight combination, but the badge can never spill outside
        -- the row to buy more of it back.
        local EDGE_KEEP = 8
        local flush_nx  = row_r - badge_w / 2
        local needed_nx = title_right + GAP + badge_w / 2
        local nx = math.min(math.max(flush_nx, needed_nx), edge_r - EDGE_KEEP - badge_w / 2)

        gui.set_size(badge, vmath.vector3(badge_w, BADGE_H, 0))
        gui.set_position(badge, vmath.vector3(nx, rcy, 0))
        -- The box takes the true centre; the label takes the centre its own
        -- ink sits on, which is a fraction of a descent lower. Nothing else is
        -- drawn there: an early version put a hairline across the badge's top
        -- edge, which read as the word sitting low in its box rather than as a
        -- border.
        gui.set_position(bn, vmath.vector3(nx, rcy - bdrop, 0))

        -- A HEARTBEAT WHILE THE DOOR IS OPEN. CLOSED is a fact and sits still;
        -- OPEN is an invitation with a clock on it, so only one of them has any
        -- reason to move. The host ticks this node once a frame — see
        -- M.pulse_badge and the note above it for why it is not gui.animate.
        if is_open then
            self.tourn_badge_node = badge
            M.pulse_badge(self, self.ui_clock)
        end
    end

    return cy - ROW_H
end

-- EXPORTED so it can be rendered on its own — a headless render of just this
-- row is what pins its geometry (tools/test_tournaments_row.lua) without
-- standing up the whole lobby around it.
M.draw_tournaments_row = draw_tournaments_row

-- ── Savings Plans Modal Drawing ───────────────────────────────────────────────
-- Reached via the info modal's "TRY IT" button. Where draw_savings_info leads
-- with the coin bundle and the "why", this one continues the story into the
-- concrete "how": the two actual paths into Savings (auto-charge per game,
-- or exchange coins now), each illustrated with its own payoff, before a
-- single "GET STARTED" CTA that hands off to the real controls already
-- built on the payments SAVE COINS tab.
local function draw_savings_plans(self, ctx)
    if not self.savings_plans_open then return end

    local track = ctx.track
    local ui    = ctx.ui
    local txtL  = ctx.txtL
    local mkbtn = ctx.mkbtn
    local C     = ctx.C
    local CX, CY = ctx.CX, ctx.CY
    local COL_SAVINGS = vmath.vector4(0.20, 0.75, 0.55, 1.0)

    local dim = track(self, ui.box(vmath.vector3(CX, CY, 0), vmath.vector3(ctx.LOGICAL_W*2, ctx.LOGICAL_H*2, 0), vmath.vector4(0, 0, 0, 0.78)))
    self.buttons[#self.buttons+1] = { node = dim, id = "savings_plans_block" }
    track(self, ui.grad_backdrop(ctx.LOGICAL_W, ctx.LOGICAL_H))

    local panel_w, panel_h = 480, 560
    track(self, ui.panel9(vmath.vector3(CX, CY, 0), vmath.vector3(panel_w, panel_h, 0), "container_bg"))

    local top = CY + panel_h / 2
    local cy = top - 44
    track(self, ui.text(vmath.vector3(CX, cy, 0), "START SAVING", "title", C.COL_GOLD))
    cy = cy - 30
    track(self, ui.text(vmath.vector3(CX, cy, 0), "Two ways in - pick one, or both.", "small", C.COL_WHITE))
    cy = cy - 34

    local card_w, card_h = panel_w - 48, 150
    local card_x = CX

    local function plan_card(headline, lines, cy_top)
        local card_cy = cy_top - card_h / 2
        track(self, ui.box(vmath.vector3(card_x, card_cy, 0), vmath.vector3(card_w, card_h, 0), vmath.vector4(1, 1, 1, 0.05)))
        track(self, ui.box(vmath.vector3(card_x - card_w/2 + 3, card_cy, 0), vmath.vector3(6, card_h, 0), COL_SAVINGS))
        local inner_x = card_x - card_w/2 + 26
        txtL(self, inner_x, cy_top - 24, headline, "body", C.COL_WHITE)
        local ly = cy_top - 52
        for _, line in ipairs(lines) do
            txtL(self, inner_x, ly, line, "small", C.COL_DIM)
            ly = ly - 20
        end
        return cy_top - card_h
    end

    cy = plan_card("EVERY GAME YOU PLAY", {
        "Turn on auto-charge and a small amount",
        "saves itself each game - no extra taps,",
        "it just quietly builds up over time.",
    }, cy)
    cy = cy - 18

    cy = plan_card("RIGHT NOW, IN ONE GO", {
        "Exchange some of today's balance into",
        "Savings whenever you're ahead - lock in",
        "a win before you're tempted to spend it.",
    }, cy)
    cy = cy - 26

    track(self, ui.text(vmath.vector3(CX, cy, 0), "Either way, it's yours whenever redemption opens.", "small", C.COL_GOLD))

    local by = CY - panel_h / 2 + 46
    mkbtn(self, "savings_plans_start", vmath.vector3(CX, by, 0), vmath.vector3(260, 56, 0), "GET STARTED", "primary_btn")
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

    -- Red lock warning, same wording as the SAVE COINS tab in payments — this
    -- dialog is the OTHER way into savings, and a caution shown on only one of
    -- the two surfaces is not a caution. Coins moved in here are locked for the
    -- whole six-month period and only become redeemable on the redemption date
    -- (25 June / 25 December, per the backend's getNextRedemptionDate).
    --
    -- Sits in the gap that was already between "% complete" and the first
    -- section heading, so nothing below it moves.
    local lock_msg = (redemption_str ~= "")
        and ("Locked until " .. redemption_str .. " — savings cannot be redeemed before then")
        or "Locked — savings cannot be redeemed until this period ends"
    track(self, ui.text(vmath.vector3(CX, top - 124, 0), lock_msg, "small", C.COL_RED))

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
    local pay_h    = 56 -- Massive touch target for payments
    local gap      = 16
    local cont_h   = margin + header_h + gap + pay_h + margin
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

    -- THE STATS BOX IS GONE, BOTH ROWS OF IT.
    --
    -- YOUR POSITION went first, to the STANDINGS title row in the left panel,
    -- beside the table it is a position in (modules/online_left.lua). YOUR
    -- CURRENT FORM — the last five results as W/L pills — followed it out, and
    -- it is not going anywhere else: nothing on this screen is about the last
    -- five games, and the box was the only thing between the balances and the
    -- payments button.
    --
    -- The DATA is untouched. websocket_manager still tracks
    -- current_user_data.recentForm off every game-over payload, so putting the
    -- row back is a row of drawing code, not an excavation.
    --
    -- WHAT ITS HEIGHT PAID FOR: the tournaments row below the battles. The two
    -- rows plus their gap were 56 of this panel's 704, and the row cost 80 —
    -- see the note at draw_tournaments_row's call for the whole budget.

    -- Make Payments Button (Massive Target)
    --
    -- FULL WIDTH, and party does not get a slice of it. A party table is
    -- reached through the PARTY row's own INVITE and EDIT below — the same two
    -- buttons every other battle type has — and the open-table panel opens
    -- itself when there is something to see (see online.gui_script's
    -- party_available handling). A third button here would be a third way to
    -- reach a thing that already has two.
    local pay_y = top_y - header_h - gap - pay_h/2
    mkbtn(self, "nav_payments", vmath.vector3(cx, pay_y, 0), vmath.vector3(bw, pay_h, 0), "MAKE PAYMENTS", "primary_btn", nil, "btn_lg")

    -- BLOCK_GAP, not BLOCK_GAP + 8. The +8 was here and after the battles,
    -- and nowhere else in this panel — the team-tournaments block below closes
    -- on a plain BLOCK_GAP. Two spellings of one gap, and this panel has no
    -- vertical room to spend on the difference: see the note above
    -- draw_tournaments_row's call for what the budget actually is.
    cy = cy - cont_h - C.BLOCK_GAP

    -- ── Battles panel (Taller, Roomier rows) ──────────────────────────────
    -- 100, up from 88. The panel freed 56 when the profile card's stats box
    -- went, and this is what it is for: the three mode rows are the tallest
    -- thing on the screen a player actually reads, and they were sized when
    -- this column had a full-width tournaments row under them AND a two-row
    -- stats box above. Twelve more each is 36 of the 54 that was going spare,
    -- and it leaves the tournaments row an 18px margin off the bottom border.
    --
    -- The rows carry their own separation — a hairline between each, and the
    -- content centred in the row — so the height IS the gap between the modes.
    -- There is no spacing constant to raise instead.
    local row_h    = 100
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
            -- TWO VALUES, TWO COLOURS.
            --
            -- This line carries a RULE ("CAP 200", "BEST OF 3") and a STAKE,
            -- and both were the same dim grey four spaces apart — so a row
            -- read as one run of digits and the two numbers on it were easy to
            -- mistake for each other. The rule is white; the stake is gold,
            -- which is already this UI's "there is money in this" colour (the
            -- prize table, the season deadline, the H2H line).
            local rule
            if T == "PARTY" then
                -- THE MODE, NAMED, on the row the host edits and invites from.
                --
                -- The count is always AUTO now, so printing it said "AUTO
                -- PLAYERS" and told nobody anything. What actually differs
                -- between two party tables is how they are won — and until the
                -- server started storing that (partyRules.ts), this row could
                -- only ever draw the NORMAL branch, whatever the host had set.
                --
                -- "CAP 200", not "SCORE CAP 200". The row is a glance, and the
                -- KNOCKOUT row directly above it already says CAP for the same
                -- ladder and the same rule — two spellings of one idea, a line
                -- apart, read as two different things.
                local pmode = M.party_mode_of({ pmode = b.partyMode or b.mode })
                if pmode == "SCORECAP" then
                    local cap = tonumber(b.scoreCap) or M.PARTY_CAPS[M.PARTY_DEFAULT_CAP_I]
                    rule = string.format("CAP %d", cap)
                else
                    rule = "PLAY IT OUT"
                end
            elseif T == "KNOCKOUT" then
                rule = string.format("CAP %d", tonumber(b.scoreCap) or 200)
            else
                rule = string.format("BEST OF %d", tonumber(b.matchFormat) or 3)
            end
            detail_line(self, ctx, text_x, row_cy - 14, rule, commas(amt))

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
    cy = cy - battle_h - C.BLOCK_GAP

    -- ── Tournaments ──────────────────────────────────────────────────────
    --
    -- BACK IN THIS PANEL, below the battles, where it was before two passes at
    -- floating it. See draw_tournaments_row for what those passes were
    -- actually worth — the layout inside the row, not the floating.
    --
    -- THE PANEL HAD TO BE PAID FOR IT, because a row in flow costs height and
    -- a floating one does not. On a 16:9 canvas this column runs from
    -- EDGE_T - 16 down to EDGE_B with 704 usable pixels, and the profile card
    -- plus the battles already spent nearly all of them — the row's first
    -- draft ran 22px below the bottom of the screen.
    --
    -- Two places found it, neither of them this row. The profile card's stats
    -- box went entirely — YOUR POSITION to the standings title in the left
    -- panel, YOUR CURRENT FORM off the screen — which is 56 with its gap. And
    -- the two BLOCK_GAP + 8 gaps became plain BLOCK_GAPs, which is what every
    -- other gap in this panel already was: 16 more.
    --
    -- That is 72 for an 80px row. Most of what was left over then went into
    -- the mode rows above (88 to 100, see row_h), which is what the freed
    -- height was actually for; the row still lands 18 clear of the bottom
    -- border.
    --
    -- SO THE COLUMN IS SPOKEN FOR. The team-tournaments block below overflows
    -- when an account is in one, as it did before this row existed — the row
    -- and the taller modes make the number worse, not the bug. Anything else
    -- added under the battles has to bring its own height with it, and there
    -- is no longer anywhere obvious to take it from.
    cy = draw_tournaments_row(self, ctx, cx, pw, cy) - C.BLOCK_GAP

    -- ── Team Tournaments panel — only shown once this account has actually
    -- created or joined one (tracked client-side since last create/join —
    -- see lobby.gui_script's tc_submit/team_join_submit). Creating one now
    -- happens entirely on the main lobby screen, so there's nothing to do
    -- about team tournaments from here until you're already in one; this
    -- row exists purely as quick return access to VIEW BRACKET.
    local has_team = u.myTeamTournamentId and tostring(u.myTeamTournamentId) ~= ""
    if has_team then
        local team_h  = 72
        local team_cy = cy - team_h/2
        track(self, ui.box(vmath.vector3(cx, team_cy, 0), vmath.vector3(pw, team_h, 0), C.COL_BG))

        local team_icon_x = cx - 80
        local team_icon = track(self, ui.image(vmath.vector3(team_icon_x, team_cy, 0), vmath.vector3(32, 32, 0), "tournament_icon"))
        gui.set_color(team_icon, C.COL_WHITE)
        txtL(self, team_icon_x + 28, team_cy, "TEAM TOURNAMENTS", "btn_lg", C.COL_WHITE)

        local team_btn_w = 180
        local team_bx = cx + pw/2 - team_btn_w/2 - 20
        txtL(self, team_icon_x + 28, team_cy - 14, "Your team tournament", "small", C.COL_DIM)
        mkbtn(self, "nav_team_bracket", vmath.vector3(team_bx, team_cy, 0), vmath.vector3(team_btn_w, 48, 0), "VIEW BRACKET", "primary_btn", nil, "btn_md")
        cy = cy - team_h - C.BLOCK_GAP
    end

    -- ── Draw Extracted Modals on Top ──────────────────────────────────────
    draw_battle_modal(self, ctx)
    draw_team_bracket_modal(self, ctx)
    draw_invite_search(self, ctx)
    draw_savings_info(self, ctx)
    draw_savings_plans(self, ctx)
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
        score_cap    = M.KNOCKOUT_CAPS[bm.cap_i or M.KNOCKOUT_DEFAULT_CAP_I]
                        or M.KNOCKOUT_CAPS[M.KNOCKOUT_DEFAULT_CAP_I]
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
    if btype == "PARTY" then
        -- Always AUTO. The host no longer picks a count: the table fills for
        -- twenty seconds and plays with whoever is seated. Still SENT, because
        -- the server and the lobby row both read it.
        payload.players = "AUTO"
        payload.mode = M.party_mode_of(bm)
        if payload.mode == "SCORECAP" then payload.scoreCap = M.party_cap_of(bm) end
    end

    local function on_result(result)
        local cur = self.battle_modal
        if not cur then return end
        cur.submitting = false
        if result.success then
            local data   = result.data or {}
            local battle = data.tournament or data.data or data

            -- DID THE SERVER ACTUALLY KEEP WHAT WE SENT?
            --
            -- A party carries two fields — how it is won, and the cap — that a
            -- server older than them simply drops: strict mongoose schemas
            -- discard a path they have no field for, and it does so SILENTLY,
            -- with a 200 and a cheerful "Updated successfully". The client then
            -- stored that reply over its own correct knowledge, the row went
            -- back to PLAY IT OUT, and the whole thing was indistinguishable
            -- from the form having failed to remember.
            --
            -- The reply is the evidence, so it is read rather than trusted. If
            -- what comes back is not what went out, say so and leave the modal
            -- open — a "saved!" that did not save is worse than an error.
            if btype == "PARTY" and type(battle) == "table" then
                local echoed_mode = M.party_mode_of({ pmode = battle.partyMode or battle.mode })
                local echoed_cap  = tonumber(battle.scoreCap)
                local want_cap    = tonumber(payload.scoreCap)
                local lost = (echoed_mode ~= payload.mode)
                    or (payload.mode == "SCORECAP" and want_cap and echoed_cap ~= want_cap)
                if lost then
                    cur.msg, cur.msg_ok =
                        "Saved, but the play mode did not stick. This server has not been updated yet.", false
                    if self._active then rebuild_cb() end
                    return
                end
            end

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

function M.open_team_bracket(self, rebuild_cb)
    local u = ws.current_user_data or {}
    local tid = u.myTeamTournamentId
    if not tid or tostring(tid) == "" then return end

    self.team_bracket_modal = { loading = true, is_owner = u.myTeamTournamentIsOwner and true or false }
    rebuild_cb()

    local api = require("modules.api_service")
    api.get_team_tournament_bracket(tid, function(result)
        local cur = self.team_bracket_modal
        if not cur then return end
        cur.loading = false
        if result.success then
            cur.data = result.data
        else
            cur.error = result.message or "Could not load the bracket."
        end
        if self._active then rebuild_cb() end
    end)
end

local function refresh_team_bracket(self, rebuild_cb)
    local br = self.team_bracket_modal
    if not br then return end
    local u = ws.current_user_data or {}
    local tid = u.myTeamTournamentId
    if not tid or tostring(tid) == "" then return end
    local api = require("modules.api_service")
    api.get_team_tournament_bracket(tid, function(result)
        local cur = self.team_bracket_modal
        if not cur then return end
        if result.success then cur.data = result.data end
        if self._active then rebuild_cb() end
    end)
end

function M.tbr_advance(self, player_id, rebuild_cb)
    local br = self.team_bracket_modal
    local u = ws.current_user_data or {}
    local tid = u.myTeamTournamentId
    if not br or not tid or not player_id then return end
    local api = require("modules.api_service")
    api.advance_team_tournament_player(tid, { userId = u._id, playerId = player_id }, function(result)
        local cur = self.team_bracket_modal
        if not cur then return end
        if result.success then
            cur.msg, cur.msg_ok = "Player advanced.", true
            refresh_team_bracket(self, rebuild_cb)
        else
            local err = result.message or "Could not advance this player."
            cur.msg, cur.msg_ok = err, false
            toast.error(err)
            if self._active then rebuild_cb() end
        end
    end)
end

function M.tbr_drop(self, player_id, rebuild_cb)
    local br = self.team_bracket_modal
    local u = ws.current_user_data or {}
    local tid = u.myTeamTournamentId
    if not br or not tid or not player_id then return end
    local api = require("modules.api_service")
    api.drop_team_tournament_player(tid, { userId = u._id, playerId = player_id }, function(result)
        local cur = self.team_bracket_modal
        if not cur then return end
        if result.success then
            cur.msg, cur.msg_ok = "Player dropped.", true
            refresh_team_bracket(self, rebuild_cb)
        else
            local err = result.message or "Could not drop this player."
            cur.msg, cur.msg_ok = err, false
            toast.error(err)
            if self._active then rebuild_cb() end
        end
    end)
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

    -- A PARTY IS NOT SEARCHED FOR, IT IS OPENED.
    --
    -- Every other battle type invites ONE opponent: send_game_request goes out,
    -- the server shortlists whoever is free, and two people are dealt in. That
    -- is the wrong shape for a party and always was — the request lands in
    -- initializeDeck, which is the two-player dealer, so a party invite used to
    -- produce a duel wearing a party label. It never reached party.ts, the pot,
    -- or the four-seat settlement.
    --
    -- The right shape already exists: open a table with this battle's settings
    -- and let the lobby fill it. PARTY_AVAILABLE puts it in front of everybody
    -- eligible within a frame, which is a better invite than a shortlist of one
    -- — and it is the flow the seats, the pot and endPartyGame are built for.
    --
    -- No search dialog either. There is nothing to wait on with a spinner: the
    -- table appears with its own countdown and roster, so the party panel is
    -- what the player should be looking at.
    if tostring(battle_type or ""):upper() == "PARTY" then
        local entry = tonumber(mb.amount) or tonumber(stake.amount) or (M.PARTY_TIERS or { 200 })[1]

        -- Checked against the ENTRY, not the `stake` above. A party battle
        -- carries its price in `amount` and generally has no stake object at
        -- all, so the shared balance check a few lines up compares against
        -- zero and always passes. The server refuses the create either way,
        -- but arriving at a PARTY_ERROR is a worse answer than the top-up
        -- screen every other battle type sends the player to.
        if entry > 0 and bal < entry then
            msg.post("#controller", "goto_payments")
            return false
        end

        ws.party_create(entry, M.party_mode_of(mb), M.party_cap_of(mb))

        -- THE SAME DIALOG A TOURNAMENT USES, not a second one.
        --
        -- From the player's side the two are identical: you opened something,
        -- and you are watching people arrive one at a time. dialog_search
        -- already does exactly that — the roster, the arrival animation, the
        -- per-player sound — so a party feeds it instead of drawing its own.
        -- websocket_manager translates PARTY_ROSTER's seats into the same
        -- `accepted` shape the tournament roster uses.
        --
        -- No cancel_id: a party table cannot be withdrawn once opened (the
        -- entry is committed on the seat), and a Cancel button that cannot
        -- cancel is worse than none.
        self.invite_search = {
            active = true, t = 0, reel_ix = math.random(INVITE_AVATAR_MAX), spin_t = 0,
            stake = { amount = entry, charge = 0 },
            -- THE TABLE'S WINDOW, NOT THE BATTLE SEARCH'S.
            --
            -- This opened on SEARCH_WINDOW_FALLBACK — twelve seconds, the
            -- longest a ladder settles in — while a table is open for twenty.
            -- search_clock never rewinds a countdown that turns out to be too
            -- LOW (see the long note there), so the ring emptied and the digits
            -- hit zero eight seconds before the table closed, then sat at zero
            -- while players were still sitting down. The guess has to be the
            -- longest this search can run, and for a table that is the join
            -- window. PARTY_ROSTER re-aims it at the real closesAt a moment
            -- later, downward, which is the direction that converges smoothly.
            max_time = M.PARTY_JOIN_WINDOW,
            -- And none of it is grace: nobody was invited to a table, so there
            -- are no answers in flight for a tail to be held open for.
            grace_time = 0,
            modal = true,
            party = true,
            subtitle = "opening your table",
        }
        app_state.searching_invite = true
        -- The table does not exist yet, so there is no closesAt to count down
        -- to — the window is the backstop until the first PARTY_ROSTER states
        -- the real deadline and re-arms this against it.
        M.arm_party_failsafe(self, app_state, rebuild_cb, M.PARTY_JOIN_WINDOW)
        rebuild_cb()
        return true
    end

    self.invite_search = {
        active = true, t = 0, reel_ix = math.random(INVITE_AVATAR_MAX), spin_t = 0, stake = stake,
        -- A PLACEHOLDER UNTIL THE SERVER SAYS. GAME_SEARCH_STARTED arrives a
        -- moment later with the real window — eight seconds for a battle or a
        -- chamber, twelve for a ladder — and replaces this. Twelve rather than
        -- the ten the dialog used to default to, so even if that message never
        -- lands the countdown outlives the longest window the server runs
        -- instead of failing while a match is being made.
        max_time = M.SEARCH_WINDOW_FALLBACK,
        -- No cancel_id: the backend has no way to actually withdraw a game
        -- request once sent, so a Cancel button here would lie — the opponent
        -- could still accept it after the player "cancelled".
        modal = true,
    }
    app_state.searching_invite = true

    ws.send_game_request({}, stake, {
        gameType     = "TOURNAMENT",
        tournamentId = tostring(mb._id or mb.id or ""),
        rules        = "JOKERS",
        matchType    = (tostring(mb.matchType or battle_type or "NORMAL"):upper()),
    })

    -- THE GIVE-UP OUTLIVES THE WINDOW, IT DOES NOT MATCH IT.
    --
    -- Ten seconds flat, while the server's window is twelve for a ladder: the
    -- dialog told the player nobody accepted their invite two seconds before
    -- the server picked one of the people who had. This is a backstop for a
    -- server that never answers at all, so it sits beyond the window;
    -- ws_search_window re-arms it against the real figure the moment it lands.
    self.invite_search.timer_handle = timer.delay(
        M.SEARCH_WINDOW_FALLBACK + M.SEARCH_FAILSAFE_GRACE, false, function()
            if self.invite_search and not self.invite_search.found then
                -- No reason passed: fail_invite_search decides what is
                -- true from the shortlist. A caller asserting "nobody
                -- accepted" cannot know that — it is a timer.
                M.fail_invite_search(self, app_state, rebuild_cb, nil)
            end
        end)

    rebuild_cb()
    return true
end

--- TAKING A SEAT AT SOMEBODY ELSE'S TABLE.
--
-- The other half of start_invite_search's PARTY branch. The host opens a table
-- and watches it fill; a guest taps JOIN on the invite strip and watches the
-- same thing — so both end up in the same dialog, fed by the same translated
-- roster, rather than the guest getting a modal list of tables and the host
-- getting a waiting room.
--
-- `closes_at` is the SERVER'S deadline for the table, in epoch milliseconds,
-- and the dialog counts down to it. Not a fixed window: the guest is arriving
-- partway through a twenty-second table, and a fresh twenty-second clock would
-- promise them time the table does not have.
--
-- No balance check here. The listing that produced this strip was filtered by
-- the server against this player's balance, and it is the only side that knows
-- every balance in the lobby; refusing here could only ever disagree with it.
-- A balance that fell in between comes back as a PARTY_ERROR, which is the
-- same path a full table takes.
-- The server's join window, in seconds: PARTY_JOIN_WINDOW_MS in be_matatu's
-- partyRules.ts. Only a backstop — a table states its own closesAt on every
-- roster push and that is what the dialog actually counts down (see
-- M.arm_party_failsafe and the ws_search_roster handler on the online screen).
--
-- Taken from search_clock rather than written again: the countdown module has
-- to know the same figure to guess a party's window correctly, and two copies
-- of it in two files is how the ring came to run on a battle's twelve in the
-- first place.
M.PARTY_JOIN_WINDOW = search_clock.PARTY_WINDOW

--- THE DIALOG MUST NOT OUTLIVE THE TABLE.
--
-- A party search has no Cancel button — the entry is committed on the seat, and
-- a button that cannot cancel is worse than none — so nothing on screen can
-- close this dialog except the server saying the table dealt or was called off.
-- If neither ever arrives (a socket that drops in the twenty seconds the table
-- is open, which is exactly when it costs the most) the player is left in a
-- modal with a spinner and no way out but restarting the app.
--
-- So the dialog carries the table's own deadline plus the grace every other
-- search uses, re-armed by each roster push against the deadline the server
-- just restated. fail_invite_search is what fires: with seats filled it waits
-- out MATCH_START_GRACE first, because a window closing is not the end of the
-- work — the server still has to charge, deal and send.
function M.arm_party_failsafe(self, app_state, rebuild_cb, seconds)
    local sr = self.invite_search
    if not sr or not sr.party or sr.found or sr.failed then return end
    if sr.timer_handle then pcall(timer.cancel, sr.timer_handle) end
    local secs = math.max(1, tonumber(seconds) or M.PARTY_JOIN_WINDOW) + M.SEARCH_FAILSAFE_GRACE
    sr.timer_handle = timer.delay(secs, false, function()
        if self.invite_search == sr and not sr.found then
            -- No reason passed: fail_invite_search decides what is true from
            -- the seats. A caller asserting "nobody sat down" cannot know that
            -- — it is a timer.
            M.fail_invite_search(self, app_state, rebuild_cb, nil)
        end
    end)
end

function M.join_party_search(self, app_state, rebuild_cb, p)
    p = type(p) == "table" and p or {}
    local pid = tostring(p.party_id or "")
    if pid == "" then return false end

    local now_ms  = (socket and socket.gettime and socket.gettime() * 1000) or (os.time() * 1000)
    local closes  = tonumber(p.closes_at) or 0
    local left    = closes > 0 and math.max(1, (closes - now_ms) / 1000) or M.SEARCH_WINDOW_FALLBACK

    ws.party_join(pid)

    self.invite_search = {
        active = true, t = 0, reel_ix = math.random(INVITE_AVATAR_MAX), spin_t = 0,
        stake = { amount = tonumber(p.entry) or 0, charge = 0 },
        -- What the TABLE has left, not a fresh window: a guest arriving twelve
        -- seconds into a twenty-second table has eight, and a ring that starts
        -- full would promise time the table has not got.
        max_time = left,
        grace_time = 0,
        modal = true,
        party = true,
        subtitle = "taking your seat",
    }
    app_state.searching_invite = true

    M.arm_party_failsafe(self, app_state, rebuild_cb, left)
    rebuild_cb()
    return true
end

function M.fail_invite_search(self, app_state, rebuild_cb, reason)
    local sr = self.invite_search
    if not sr or sr.found or sr.failed then return end

    -- A SEARCH WITH PLAYERS ON THE SHORTLIST HAS NOT FAILED.
    --
    -- This is the bug that survived three separate fixes to the countdown,
    -- because it was never in the countdown. The window closing is not the end
    -- of the work: the server still has to charge the entry, deal a deck,
    -- create the game and send it, and that takes real time. The backstop
    -- fired in the middle of it and announced that nobody had accepted — with
    -- the people who HAD accepted still drawn on screen underneath the words.
    --
    -- So the failure path asks the one question it never asked. If somebody
    -- accepted, wait: the server is going to answer, either with a game or
    -- with a cancellation. The wait is bounded, because a genuinely stuck
    -- match must not hold the screen forever — and if it does run out, what it
    -- says is true.
    if search_clock.has_candidates(sr) and not sr.start_grace_used then
        sr.start_grace_used = true
        if sr.timer_handle then pcall(timer.cancel, sr.timer_handle) end
        sr.timer_handle = timer.delay(search_clock.MATCH_START_GRACE, false, function()
            M.fail_invite_search(self, app_state, rebuild_cb, nil)
        end)
        rebuild_cb()
        return
    end

    if sr.timer_handle then pcall(timer.cancel, sr.timer_handle); sr.timer_handle = nil end

    sr.failed   = true
    -- Never "nobody accepted" over a populated shortlist: that is not a
    -- wording problem, it is the dialog reporting the opposite of what it is
    -- showing.
    sr.fail_msg = reason or search_clock.give_up_reason(sr)
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