local ws       = require("modules.websocket_manager")
local config   = require("modules.config")
local GameMode = require("modules.game_mode")

local TAB_QUICK   = 1
local TAB_BATTLES = 2

local M = {}

-- ── Drawing Logic ─────────────────────────────────────────────────────────
function M.draw(self, ctx)
    -- Initialize default stake on the first draw, using this game's own
    -- default amount (GameMode.DEFAULT_STAKE_AMOUNT: matatu=200, whot=100,
    -- kadi=10) instead of a literal that only exists in Matatu's table.
    if not self._stake_initialized then
        self._stake_initialized = true
        if config.STAKE_LEVELS then
            for idx, lvl in pairs(config.STAKE_LEVELS) do
                if lvl.amount == GameMode.DEFAULT_STAKE_AMOUNT then
                    self.stake_index = idx
                    break
                end
            end
        end
        self.list_scroll = 0
    end

    local C          = ctx.C
    local track      = ctx.track
    local txtL       = ctx.txtL
    local txtR       = ctx.txtR
    local commas     = ctx.commas
    local get_layout = ctx.get_layout
    local ui         = ctx.ui

    local _, _, div_lx, div_rx = get_layout()
    local center_cx = (div_lx + div_rx) / 2
    local content_l = div_lx + C.CENTER_PAD
    local content_r = div_rx - C.CENTER_PAD
    local list_w    = content_r - content_l
    local cx        = center_cx

    local top = ctx.EDGE_T

    -- ── Header bar ────────────────────────────────────────────────────────
    local hdr_h = 72
    local hcy   = top - hdr_h/2
    track(self, ui.box(vmath.vector3(center_cx, hcy, 0), vmath.vector3(list_w, hdr_h, 0), C.COL_HEADER_BG))
    track(self, ui.box(vmath.vector3(center_cx, hcy - hdr_h/2 + 1, 0), vmath.vector3(list_w, 1, 0), C.COL_BORDER))

    -- Back-to-lobby now lives as a full text button below Season Bonuses in
    -- the left panel (modules/online_left.lua) instead of this bare "<" icon.
    local title_l = content_l
    txtL(self, title_l, hcy + 16,  "AVAILABLE PLAYERS", "body", C.COL_BRIGHT)

    -- First-time visitor this session: type the hint out character by
    -- character (self._tap_hint_active/_t driven by online.gui_script's
    -- init()/update()) so it visibly draws the eye instead of just being
    -- one more static line of text on a screen they've never seen before.
    local HINT_TEXT = "Tap a player to request a game. If they decline, try another!"
    local hint_shown = HINT_TEXT
    if self._tap_hint_active then
        local n = math.floor((self._tap_hint_t or 0) / 0.035)
        if n >= #HINT_TEXT then
            self._tap_hint_active = false
        else
            hint_shown = string.sub(HINT_TEXT, 1, n) .. "_"
        end
    end

    local helper = txtL(self, title_l, hcy - 12, hint_shown, "small", C.COL_GOLD)
    gui.set_scale(helper, vmath.vector3(1.1, 1.1, 1))

    local cy = top - hdr_h

    -- ── Tabs ──────────────────────────────────────────────────────────────
    local tabw  = (list_w / 2) - 4
    local tab_qx = cx - tabw/2 - 2
    local tab_bx = cx + tabw/2 + 2
    local tab_h  = 44

    local q_col = self.tab == TAB_QUICK   and C.COL_WHITE or C.COL_DIM
    local b_col = self.tab == TAB_BATTLES and C.COL_GOLD  or C.COL_DIM

    local btn_q = track(self, ui.box(vmath.vector3(tab_qx, cy - tab_h/2, 0), vmath.vector3(tabw, tab_h, 0),
        self.tab == TAB_QUICK   and vmath.vector4(0.2,0.2,0.2,1) or vmath.vector4(0.1,0.1,0.1,0.5)))
    local btn_b = track(self, ui.box(vmath.vector3(tab_bx, cy - tab_h/2, 0), vmath.vector3(tabw, tab_h, 0),
        self.tab == TAB_BATTLES and vmath.vector4(0.2,0.2,0.2,1) or vmath.vector4(0.1,0.1,0.1,0.5)))
    self.buttons[#self.buttons+1] = { node = btn_q, id = "tab_quick" }
    self.buttons[#self.buttons+1] = { node = btn_b, id = "tab_battles" }

    track(self, ui.text(vmath.vector3(tab_qx, cy - tab_h/2 - 3, 0), "QUICK PLAY",     "btn_md", q_col))
    track(self, ui.text(vmath.vector3(tab_bx, cy - tab_h/2 - 3, 0), "BATTLE GROUNDS", "btn_md", b_col))

    if self.tab == TAB_QUICK then
        track(self, ui.box(vmath.vector3(tab_qx, cy - tab_h, 0), vmath.vector3(tabw, 2, 0), C.COL_WHITE))
    else
        track(self, ui.box(vmath.vector3(tab_bx, cy - tab_h, 0), vmath.vector3(tabw, 2, 0), C.COL_GOLD))
    end
    
    cy = cy - tab_h - 12

    -- ── Stakes selector (Quick Play only) ────────────────────────────────
    local list_top = cy
    if self.tab == TAB_QUICK then
        local stakes_gap   = 10
        local stake_card_h = 62

        local my_balance  = tonumber((ws.current_user_data or {}).balance) or 0

        -- Paid stake tiers for this game, in order, straight from
        -- config.STAKE_LEVELS (skips the "Free" 0-amount tier, which has no
        -- button here). Was hardcoded to Matatu's UGX amounts
        -- {100,200,500,1000}, so Whot/Kadi builds kept showing UGX values
        -- instead of their own NGN/KES tiers.
        local stakes = {}
        if config.STAKE_LEVELS then
            for _, lvl in ipairs(config.STAKE_LEVELS) do
                if lvl.amount and lvl.amount > 0 then
                    stakes[#stakes+1] = lvl.amount
                end
            end
        end

        local tile_count = math.max(#stakes, 1)
        local st_w       = (list_w - ((tile_count - 1) * stakes_gap)) / tile_count

        for i, st in ipairs(stakes) do
            local sx = content_l + (i - 0.5) * st_w + (i - 1) * stakes_gap
            
            -- Dynamically find the real config index for this stake amount
            local actual_idx = i
            if config.STAKE_LEVELS then
                for c_idx, c_lvl in pairs(config.STAKE_LEVELS) do
                    if c_lvl.amount == st then actual_idx = c_idx; break; end
                end
            end

            local is_active = (self.stake_index == actual_idx)
            local affordable = (my_balance >= st)

            -- Every stake tile uses the same background — no separate *_active
            -- variant for the selected one (selection still shows via text colour).
            track(self, ui.btn9(vmath.vector3(sx, cy - stake_card_h/2, 0), vmath.vector3(st_w, stake_card_h, 0),
                "container_bg"))

            local btn = track(self, ui.box(vmath.vector3(sx, cy - stake_card_h/2, 0), vmath.vector3(st_w, stake_card_h, 0),
                vmath.vector4(0, 0, 0, 0)))
            
            -- Pass the true config index safely so we don't break main logic
            self.buttons[#self.buttons+1] = { node = btn, id = "stake_"..i, data = actual_idx }

            local amt_col = is_active and C.COL_RED or (affordable and C.COL_WHITE or C.COL_DIM)
            local center_y = cy - stake_card_h/2
            
            local coin = track(self, ui.image(vmath.vector3(sx - 24, center_y, 0), vmath.vector3(28, 28, 0), "coin_icon"))
            if not affordable and not is_active then
                gui.set_color(coin, vmath.vector4(0.6, 0.6, 0.6, 0.8))
            end

            local amt_txt = txtL(self, sx - 6, center_y, tostring(st), "body", amt_col)
            gui.set_scale(amt_txt, vmath.vector3(1.2, 1.2, 1))
        end
        
        cy = cy - stake_card_h - 12
        list_top = cy
    end

    -- ── User list ─────────────────────────────────────────────────────────
    local list_bottom = ctx.EDGE_B + 20
    local region_h    = list_top - list_bottom
    local row_h       = C.ROW_H_LIST
    local step        = row_h

    -- Never show player data before the SERVER has actually confirmed our
    -- identity for this connection (ws.is_identified, set only by the
    -- IDENTIFY ack) — ws.online_users/current_user_data are plain in-memory
    -- fields that can be non-empty from a previous session, a locally cached
    -- profile, or a race with an in-flight identify, none of which mean this
    -- connection is actually authenticated right now.
    local users = ws.is_identified and (ws.get_online_users() or {}) or {}
    local my_id = ws.get_current_user_id()

    local rows = {}
    -- Used to filter out duplicates. Keyed by user id alone for Quick Play
    -- (one row per user); keyed by "id:TYPE" for Battles, since a player can
    -- host several independent battle types (NORMAL/KNOCKOUT/PARTY) at once.
    local seen_users = {}

    -- Filter list: No duplicates, no self, and tab-specific logic
    for _, pu in ipairs(users) do
        if pu._id and pu._id ~= my_id then
            if self.tab == TAB_BATTLES then
                -- A player's `myBattles` map (already broadcast alongside the
                -- legacy singular `myBattle`) can hold one battle per type —
                -- surface a separate row for each one they actually host, so
                -- e.g. Vortex hosting both NORMAL and KNOCKOUT shows up for
                -- both. PARTY stays server-side only (not yet ready for
                -- players), so it's excluded here — including it would add a
                -- confusing extra row for the same bot.
                local battles_map = (type(pu.myBattles) == "table") and pu.myBattles or nil
                local added_any = false
                if battles_map then
                    for _, T in ipairs({ "NORMAL", "KNOCKOUT" }) do
                        local b = battles_map[T]
                        if type(b) == "table" and next(b) ~= nil then
                            local key = pu._id .. ":" .. T
                            if not seen_users[key] then
                                seen_users[key] = true
                                local row_pu = {}
                                for k, v in pairs(pu) do row_pu[k] = v end
                                row_pu.myBattle = b
                                rows[#rows+1] = row_pu
                                added_any = true
                            end
                        end
                    end
                end
                -- Fallback for payloads without a `myBattles` map — behave
                -- exactly as before (a single row using the legacy field).
                if not added_any and pu.myBattle then
                    local key = pu._id .. ":legacy"
                    if not seen_users[key] then
                        seen_users[key] = true
                        rows[#rows+1] = pu
                    end
                end
            else
                -- Quick play: show players (one row per user)
                if not seen_users[pu._id] then
                    seen_users[pu._id] = true
                    rows[#rows+1] = pu
                end
            end
        end
    end

    local content_h  = #rows * step
    local max_scroll = 0
    if content_h > region_h then
        -- Add slight padding to the max scroll to give breathing room at the bottom list margin
        max_scroll = content_h - region_h + 20
    end
    
    -- Ensure scroll stays within bounds dynamically while scrolling
    self.list_scroll = math.max(0, math.min(self.list_scroll or 0, max_scroll))

    if #rows == 0 then
        local msg = "Connecting..."
        if not ws.is_identified then
            msg = "Sign in to see online players"
        elseif ws.socket_connected then
            msg = self.tab == TAB_BATTLES and "No open battles right now" or "No opponents online right now"
        end
        track(self, ui.text(vmath.vector3(cx, list_top - region_h/2, 0), msg, "body", C.COL_DIM))
        self.list_region = nil
        return
    end

    self.list_region = { top = list_top, bottom = list_bottom, left = content_l, right = content_r, x = cx }

    -- MATH FIX: Used + self.list_scroll here instead of subtraction. Positive scroll offset follows natural UI rules.
    local y = list_top - row_h/2 + self.list_scroll
    for i, pu in ipairs(rows) do
        local row_cy = y - (i-1) * step
        if row_cy + row_h/2 >= list_bottom and row_cy - row_h/2 <= list_top then
            local playing = pu.gameId and pu.gameId ~= ""
            local is_ai   = pu.isAI or tostring(pu._id or ""):find("^ai_bot")

            local rowcol = (i % 2 == 0)
                and vmath.vector4(0.10, 0.08, 0.06, 0.9)
                or  vmath.vector4(0.10, 0.08, 0.06, 0.35)
            local frame = track(self, ui.box(vmath.vector3(cx, row_cy, 0), vmath.vector3(list_w, row_h, 0), rowcol))

            local name_x   = content_l + C.INNER_PAD
            local name_col = playing and vmath.vector4(0.5,0.5,0.5,1) or C.COL_WHITE
            txtL(self, name_x, row_cy, string.upper(pu.username or "PLAYER"), "body", name_col)

            local badge_x = content_l + 200
            if is_ai then
                txtL(self, badge_x, row_cy, "AI", "body", vmath.vector4(0.3, 1.0, 0.5, 1.0))
                badge_x = badge_x + 36
            end
            if playing then
                track(self, ui.box(vmath.vector3(badge_x + 6, row_cy, 0), vmath.vector3(6, 6, 0), C.COL_RED))
                txtL(self, badge_x + 16, row_cy, "PLAYING", "small", vmath.vector4(1.0, 0.5, 0.5, 1.0))
                badge_x = badge_x + 84
            end

            -- KNOCKOUT badge sits next to the name when this battle is a
            -- knockout-type battle (vs a normal head-to-head battle). Legacy
            -- "ELIMINATION" battles still count as KNOCKOUT.
            local pu_mt = (type(pu.myBattle) == "table") and tostring(pu.myBattle.matchType or ""):upper() or ""
            if self.tab == TAB_BATTLES and (pu_mt == "KNOCKOUT" or pu_mt == "ELIMINATION") then
                local bw = 36
                local bh = 20
                local bx = badge_x + bw/2
                
                -- Outer border for "real badge" look
                track(self, ui.box(vmath.vector3(bx, row_cy, 0), vmath.vector3(bw + 2, bh + 2, 0), vmath.vector4(0.8, 0.5, 0.9, 0.9)))
                -- Inner fill
                track(self, ui.box(vmath.vector3(bx, row_cy, 0), vmath.vector3(bw, bh, 0), vmath.vector4(0.45, 0.14, 0.58, 1.0)))
                -- Centered text perfectly aligned in the box
                track(self, ui.text(vmath.vector3(bx, row_cy, 0), "KO", "small", vmath.vector4(1.0, 0.9, 1.0, 1.0)))
            end

            local info_x = content_r - C.INNER_PAD

            if self.tab == TAB_BATTLES and pu.myBattle then
                local mb  = pu.myBattle
                local amt = tonumber((mb.stake or {}).amount) or tonumber(mb.stakeAmount) or 0
                local fmt = tonumber(mb.matchFormat) or 3
                -- "NO JOKERS" is a Matatu-only ruleset concept (CLASSIC vs
                -- JOKERS); Whot/Kadi have no such toggle, so never show it
                -- outside a Matatu build.
                local rules = mb.rules
                local is_classic = false
                if GameMode.is_matatu() then
                    if type(rules) == "string" then is_classic = rules:upper() == "CLASSIC"
                    elseif type(rules) == "table" then
                        for _, r in ipairs(rules) do if tostring(r):upper() == "CLASSIC" then is_classic = true end end
                    end
                end
                if is_classic then
                    local jx = info_x - 160 -- Shifted slightly left to accommodate the larger "body" text
                    track(self, ui.box(vmath.vector3(jx, row_cy, 0), vmath.vector3(70, 18, 0), vmath.vector4(0.3, 0.1, 0.1, 0.8)))
                    track(self, ui.text(vmath.vector3(jx, row_cy, 0), "NO JOKERS", "small", C.COL_RED))
                end
                -- Used "body" here instead of "small" to match Quick Play font size.
                -- KNOCKOUT is a score-cap chamber, so it shows its SCORE CAP
                -- (with the stake) rather than a BEST OF format. Legacy
                -- "ELIMINATION" battles are treated as KNOCKOUT here too.
                local mb_mt = tostring(mb.matchType or ""):upper()
                local detail
                if mb_mt == "KNOCKOUT" or mb_mt == "ELIMINATION" then
                    detail = string.format("CAP %d  ~  %s", tonumber(mb.scoreCap) or 200, commas(amt))
                else
                    detail = string.format("BEST OF %d ~ %s", fmt, commas(amt))
                end
                txtR(self, info_x, row_cy, detail, "body", C.COL_GOLD)
            else
                local s_amt = tonumber((pu.stake or {}).amount) or 0
                txtR(self, info_x, row_cy, s_amt == 0 and "FREE" or commas(s_amt), "body", C.COL_BRIGHT)
            end

            if not playing then
                self.buttons[#self.buttons+1] = { node = frame, id = "challenge", data = pu, row = true }
            end
        end
    end
end

return M