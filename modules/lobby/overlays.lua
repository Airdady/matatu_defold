-- modules/lobby/overlays.lua — every full-screen panel the lobby puts over
-- its grid: the first-run tutorial, the Akira consent/install flow, the AI
-- series picker, the offline tournament picker, the team-cup menu and the
-- join-by-code dialog.
--
-- These only DRAW and register buttons; lobby.gui_script's handle() still
-- owns what a tap does. Split out because they were 362 lines of one file
-- that had nothing to do with the lobby grid itself.

local ui        = require("modules.ui")
local app_state = require("modules.app_state")
local akira     = require("modules.akira")
local GameMode  = require("modules.game_mode")
local T         = require("modules.lobby.theme")
local D         = require("modules.lobby.draw")

local M = {}

M.INSTALL_DURATION = 2.8
M.INSTALL_STEPS = {
    { at = 0.00, label = "Downloading Akira core..."     },
    { at = 0.40, label = "Calibrating card instincts..."  },
    { at = 0.75, label = "Linking Akira to your seat..."  },
}
local INSTALL_STEPS = M.INSTALL_STEPS

-- Game-specific copy comes from modules/game_mode.lua so the tutorial matches
-- whichever game this build targets (Whot / Matatu / Kadi).
local TUTORIAL_PAGES = {
    { t = "WELCOME TO " .. GameMode.TITLE, lines = { GameMode.TAGLINE, "Match, attack, and be the first to", "empty your hand to win!" } },
    { t = "GAME MODES", lines = { "PLAY ONLINE  —  live coin matches", "QUICK PLAY  —  practice vs the AI", "BATTLE AI  —  best-of series", "TOURNAMENT  —  bracket of players" } },
    { t = "HOW TO PLAY", lines = GameMode.def().how_to },
    { t = "SPECIAL CARDS", lines = GameMode.def().specials },
    { t = "WIN & CLIMB", lines = { "Empty your hand to win the round.", "Earn POINTS to climb the weekly rank.", "Prizes are paid every Wednesday midday", "and Saturday midnight (EAT)." } },
    { t = "YOU'RE READY!", lines = { "Tap PLAY ONLINE to challenge real", "players, or QUICK PLAY to practice.", "Good luck — and have fun!" } },
}
M.TUTORIAL_PAGES = TUTORIAL_PAGES

function M.tutorial_seen()
    local ok, data = pcall(sys.load, sys.get_save_file("matatu_defold", "tutorial"))
    return ok and type(data) == "table" and data.seen == true
end

function M.mark_tutorial_seen()
    pcall(sys.save, sys.get_save_file("matatu_defold", "tutorial"), { seen = true })
end

function M.tutorial(self)
    if not self.tutorial_active then return end
    local page  = self.tut_page or 1
    local data  = TUTORIAL_PAGES[page]
    if not data then return end
    local total = #TUTORIAL_PAGES

    local scrim = D.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H, vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "tut_block" }

    local pw, ph = 600, 400
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.DARK))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw - 2, ph - 2, 0), T.TILE))
    
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY + ph / 2 - 2, 0), vmath.vector3(pw, 4, 0), T.RED))

    D.track(self, ui.text(vmath.vector3(T.CX, T.CY + ph / 2 - 22, 0), string.format("STEP %d OF %d", page, total), "small", vmath.vector4(1, 1, 1, 0.38)))
    D.text_sh(self, vmath.vector3(T.CX, T.CY + ph / 2 - 56, 0), data.t, "title", T.CREAM, 2, -2)

    local ly = T.CY + 70
    for _, line in ipairs(data.lines) do
        D.track(self, ui.text(vmath.vector3(T.CX, ly, 0), line, "small", T.CREAM))
        ly = ly - 28
    end

    local dgap = 22
    local dx0  = T.CX - ((total - 1) * dgap) / 2
    local dy   = T.CY - ph / 2 + 62
    for i = 1, total do
        local sz = (i == page) and 12 or 7
        D.track(self, ui.box(vmath.vector3(dx0 + (i - 1) * dgap, dy, 0), vmath.vector3(sz, sz, 0), (i == page) and T.RED or vmath.vector4(1, 1, 1, 0.24)))
    end

    local skb = D.track(self, ui.btn9(vmath.vector3(T.CX - pw / 2 + 52, T.CY + ph / 2 - 22, 0), vmath.vector3(88, 32, 0), "secondary_btn"))
    D.track(self, ui.text(vmath.vector3(T.CX - pw / 2 + 52, T.CY + ph / 2 - 24, 0), "SKIP", "small", T.MUTED))
    self.buttons[#self.buttons + 1] = { node = skb, id = "tut_skip" }

    local by = T.CY - ph / 2 + 30
    if page > 1 then
        local bkb = D.track(self, ui.btn9(vmath.vector3(T.CX - 88, by, 0), vmath.vector3(148, 44, 0), "secondary_btn"))
        D.text_sh(self, vmath.vector3(T.CX - 88, by - 1, 0), "BACK", "body", T.CREAM, 1, -1)
        self.buttons[#self.buttons + 1] = { node = bkb, id = "tut_back" }
    end
    local nxb = D.track(self, ui.btn9(vmath.vector3(T.CX + 88, by, 0), vmath.vector3(148, 44, 0), "primary_btn"))
    D.text_sh(self, vmath.vector3(T.CX + 88, by - 1, 0), (page == total) and "START" or "NEXT", "body", T.CREAM, 1, -1)
    self.buttons[#self.buttons + 1] = { node = nxb, id = "tut_next" }
end

function M.consent(self)
    if not self.consent_active then return end
    local phase = self.consent_phase or "ask"

    local scrim = D.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H, vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "consent_block" }

    local pw, ph = 680, 470
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw - 2, ph - 2, 0), T.TILE))
    
    local strip_col = (phase == "done") and T.CONSENT_DONE or T.CONSENT_ACCENT
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY + ph / 2 - 3, 0), vmath.vector3(pw, 6, 0), strip_col))

    local av_y = T.CY + ph / 2 - 84
    local frame_col = (phase == "done") and T.CONSENT_DONE or T.CONSENT_ACCENT
    D.track(self, ui.box(vmath.vector3(T.CX, av_y, 0), vmath.vector3(104, 104, 0), frame_col))
    D.track(self, ui.box(vmath.vector3(T.CX, av_y, 0), vmath.vector3(100, 100, 0), T.CONSENT_DARK))
    local av = D.track(self, ui.avatar(vmath.vector3(T.CX, av_y, 0), vmath.vector3(92, 92, 0), akira.avatar()))
    
    if phase == "installing" then
        gui.animate(av, "scale", vmath.vector3(1.07, 1.07, 1), gui.EASING_INOUTSINE, 0.45, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
    elseif phase == "done" then
        gui.set_scale(av, vmath.vector3(0.85, 0.85, 1))
        gui.animate(av, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.4)
    end

    if phase == "ask" then
        D.track(self, ui.text(vmath.vector3(T.CX, av_y - 78, 0), "MEET AKIRA - YOUR AI HELPER", "subtitle2", T.CREAM, 26 / 34))
        local lines = { "Akira plays your turns whenever you go offline", "or run out of time, so you never lose your", "entry tokens. Install Akira to protect your games." }
        local ly = av_y - 122
        for _, line in ipairs(lines) do
            D.track(self, ui.text(vmath.vector3(T.CX, ly, 0), line, "body", T.CONSENT_BODY, 19 / 28))
            ly = ly - 32
        end
        local by = T.CY - ph / 2 + 60
        local inst = D.track(self, ui.box(vmath.vector3(T.CX + 140, by, 0), vmath.vector3(248, 58, 0), T.CONSENT_ACCENT))
        D.track(self, ui.text(vmath.vector3(T.CX + 140, by - 2, 0), "INSTALL AKIRA", "subtitle2", T.CONSENT_DARK, 20 / 34))
        self.buttons[#self.buttons + 1] = { node = inst, id = "consent_install" }
        local later = D.track(self, ui.box(vmath.vector3(T.CX - 140, by, 0), vmath.vector3(248, 58, 0), T.CONSENT_NEUTRAL))
        D.track(self, ui.text(vmath.vector3(T.CX - 140, by - 2, 0), "NOT NOW", "subtitle2", T.CONSENT_BODY, 20 / 34))
        self.buttons[#self.buttons + 1] = { node = later, id = "consent_later" }

    elseif phase == "installing" then
        D.track(self, ui.text(vmath.vector3(T.CX, av_y - 78, 0), "INSTALLING AKIRA", "subtitle2", T.CREAM, 26 / 34))
        local bar_w = 480
        local bar_y = av_y - 130
        D.track(self, ui.box(vmath.vector3(T.CX, bar_y, 0), vmath.vector3(bar_w, 10, 0), T.CONSENT_NEUTRAL))
        local fill = ui.box(vmath.vector3(T.CX - bar_w / 2, bar_y, 0), vmath.vector3(1, 10, 0), T.CONSENT_ACCENT)
        gui.D.set_pivot(fill, gui.PIVOT_W)
        D.track(self, fill)
        self._install_fill   = fill
        self._install_bar_w  = bar_w
        self._install_pct    = D.track(self, ui.text(vmath.vector3(T.CX, bar_y - 34, 0), "0%", "subtitle2", T.CONSENT_ACCENT, 20 / 34))
        self._install_status = D.track(self, ui.text(vmath.vector3(T.CX, bar_y - 68, 0), INSTALL_STEPS[1].label, "body", T.CONSENT_BODY, 17 / 28))

    else -- done
        D.track(self, ui.text(vmath.vector3(T.CX, av_y - 78, 0), "AKIRA INSTALLED", "subtitle2", T.CONSENT_DONE, 26 / 34))
        D.track(self, ui.text(vmath.vector3(T.CX, av_y - 118, 0), "Akira now guards your seat whenever you", "body", T.CONSENT_BODY, 19 / 28))
        D.track(self, ui.text(vmath.vector3(T.CX, av_y - 150, 0), "drop or time out. Good luck out there!", "body", T.CONSENT_BODY, 19 / 28))
        local by = T.CY - ph / 2 + 60
        local done_btn = D.track(self, ui.box(vmath.vector3(T.CX, by, 0), vmath.vector3(248, 58, 0), T.CONSENT_DONE))
        D.track(self, ui.text(vmath.vector3(T.CX, by - 2, 0), "DONE", "subtitle2", T.CONSENT_DARK, 20 / 34))
        self.buttons[#self.buttons + 1] = { node = done_btn, id = "consent_done" }
    end
end

function M.ai_select(self)
    local scrim = D.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H, vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dialog_block" }

    local pw, ph = 720, 420
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw-2, ph-2, 0), T.TILE))
    
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY + ph / 2 - 2, 0), vmath.vector3(pw, 4, 0), T.GOLD))

    D.text_sh(self, vmath.vector3(T.CX, T.CY + ph / 2 - 44, 0), "BATTLE AI", "title", T.CREAM, 2, -2)
    D.track(self, ui.text(vmath.vector3(T.CX, T.CY + ph / 2 - 76, 0), "Choose your series length", "small", T.MUTED))

    local opts = {
        { label = "Best of 3", desc = "First to 2 wins" },
        { label = "Best of 5", desc = "First to 3 wins" },
        { label = "Best of 7", desc = "First to 4 wins" },
        { label = "Best of 9", desc = "First to 5 wins" },
    }
    local opt_w, opt_h = 138, 96
    local opt_y, opt_x0 = T.CY + 20, T.CX - (opt_w * 1.5 + 20 * 1.5)
    local cur = app_state.ai_series or 3

    for i, o in ipairs(opts) do
        local ox = opt_x0 + (i - 1) * (opt_w + 20)
        local active = (cur == (i * 2 + 1))
        
        D.track(self, ui.box(vmath.vector3(ox, opt_y, 0), vmath.vector3(opt_w, opt_h, 0), T.BORDER))
        D.track(self, ui.box(vmath.vector3(ox, opt_y, 0), vmath.vector3(opt_w-2, opt_h-2, 0), active and vmath.vector4(0.20, 0.10, 0.06, 1) or T.TILE))
        
        if active then D.track(self, ui.box(vmath.vector3(ox, opt_y + opt_h / 2 - 2, 0), vmath.vector3(opt_w - 6, 3, 0), T.GOLD)) end
        
        D.text_sh(self, vmath.vector3(ox, opt_y + 14, 0), o.label, "body", active and T.GOLD or T.CREAM, 1, -1)
        D.track(self, ui.text(vmath.vector3(ox, opt_y - 16, 0), o.desc, "small", T.MUTED))
        
        local hit = D.track(self, ui.box(vmath.vector3(ox, opt_y, 0), vmath.vector3(opt_w, opt_h, 0), T.TRANSP))
        self.buttons[#self.buttons + 1] = { node = hit, id = "ai_series", data = i * 2 + 1 }
    end

    local sb_y = T.CY - 128
    local sb = D.track(self, ui.btn9(vmath.vector3(T.CX, sb_y, 0), vmath.vector3(296, 60, 0), "primary_btn"))
    D.text_sh(self, vmath.vector3(T.CX, sb_y + 3, 0), "START BATTLE", "body", T.CREAM, 2, -2)
    D.track(self, ui.text(vmath.vector3(T.CX, sb_y - 20, 0), "vs " .. GameMode.BOT, "small", T.MUTED))
    self.buttons[#self.buttons + 1] = { node = sb, id = "start_ai" }

    local bkb = D.track(self, ui.btn9(vmath.vector3(T.CX - pw / 2 + 50, T.CY + ph / 2 - 24, 0), vmath.vector3(78, 32, 0), "secondary_btn"))
    D.track(self, ui.text(vmath.vector3(T.CX - pw / 2 + 50, T.CY + ph / 2 - 26, 0), "< BACK", "small", T.CREAM))
    self.buttons[#self.buttons + 1] = { node = bkb, id = "back_to_lobby" }
end

function M.tournament(self)
    local scrim = D.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H, vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dialog_block" }

    local pw, ph = 720, 470
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw-2, ph-2, 0), T.TILE))
    
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY + ph / 2 - 2, 0), vmath.vector3(pw, 4, 0), T.GOLD))

    D.text_sh(self, vmath.vector3(T.CX, T.CY + ph / 2 - 44, 0), "4-PLAYER TABLE", "title", T.CREAM, 2, -2)
    D.track(self, ui.text(vmath.vector3(T.CX, T.CY + ph / 2 - 76, 0), "1 human + 3 AI  ·  choose a mode", "small", T.MUTED))

    local modes = {
        { id = "bracket", label = "QUICK BRACKET",      desc = "Most cards out each deal"      },
        { id = "chamber", label = "ELIMINATION CHAMBER", desc = "Hit the score cap, you're out" },
    }
    local m_w, m_h, m_y = 298, 102, T.CY + 66
    local cur_mode = app_state.t4_mode or "bracket"
    
    for i, m in ipairs(modes) do
        local mx = T.CX - (m_w + 22) / 2 + (i - 1) * (m_w + 22)
        local active = (cur_mode == m.id)
        
        D.track(self, ui.box(vmath.vector3(mx, m_y, 0), vmath.vector3(m_w, m_h, 0), T.BORDER))
        D.track(self, ui.box(vmath.vector3(mx, m_y, 0), vmath.vector3(m_w-2, m_h-2, 0), active and vmath.vector4(0.20, 0.10, 0.06, 1) or T.TILE))
        
        if active then D.track(self, ui.box(vmath.vector3(mx, m_y + m_h / 2 - 2, 0), vmath.vector3(m_w - 6, 3, 0), T.GOLD)) end
        
        D.text_sh(self, vmath.vector3(mx, m_y + 16, 0), m.label, "body", active and T.GOLD or T.CREAM, 1, -1)
        D.track(self, ui.text(vmath.vector3(mx, m_y - 16, 0), m.desc, "small", T.MUTED))
        
        local hit = D.track(self, ui.box(vmath.vector3(mx, m_y, 0), vmath.vector3(m_w, m_h, 0), T.TRANSP))
        self.buttons[#self.buttons + 1] = { node = hit, id = "t4_mode", data = m.id }
    end

    local is_chamber = (cur_mode == "chamber")
    local thr_y = T.CY - 64
    D.track(self, ui.text(vmath.vector3(T.CX, thr_y + 38, 0), is_chamber and "SCORE CAP  —  reach it and you're eliminated" or "Score cap (Elimination Chamber only)", "small", is_chamber and T.CREAM or T.MUTED))
    
    -- Offline score-cap ladder, per game. Whot hands score far lower than
    -- Matatu's (face value, Stars doubled, Whot = 20), so it runs a tighter
    -- ladder opening at 100. Keep in lockstep with KNOCKOUT_CAPS_BY_GAME in
    -- modules/online_right.lua and the backend's KNOCKOUT_SCORE_CAPS_BY_GAME.
    local CAPS_BY_GAME = {
        MATATU = { 200, 300, 500 },
        WHOT   = { 100, 150, 200 },
        KADI   = { 100, 150, 200 },
    }
    local caps = CAPS_BY_GAME[GameMode.GAME] or CAPS_BY_GAME.MATATU
    local cap_w = 118
    local cur_cap = app_state.chamber_threshold or caps[1]
    
    for i, cap in ipairs(caps) do
        local cx_ = T.CX - (cap_w + 14) + (i - 1) * (cap_w + 14)
        local active = is_chamber and (cur_cap == cap)
        
        D.track(self, ui.btn9(vmath.vector3(cx_, thr_y, 0), vmath.vector3(cap_w, 48, 0), "secondary_btn"))
        if active then D.track(self, ui.box(vmath.vector3(cx_, thr_y + 21, 0), vmath.vector3(cap_w - 6, 3, 0), T.GOLD)) end
        
        D.text_sh(self, vmath.vector3(cx_, thr_y - 2, 0), tostring(cap), "body", active and T.GOLD or (is_chamber and T.CREAM or T.MUTED), 1, -1)
        
        if is_chamber then
            local hit = D.track(self, ui.box(vmath.vector3(cx_, thr_y, 0), vmath.vector3(cap_w, 48, 0), T.TRANSP))
            self.buttons[#self.buttons + 1] = { node = hit, id = "chamber_threshold", data = cap }
        end
    end

    local fb_y = T.CY - 166
    local fb = D.track(self, ui.btn9(vmath.vector3(T.CX, fb_y, 0), vmath.vector3(318, 60, 0), "primary_btn"))
    D.text_sh(self, vmath.vector3(T.CX, fb_y + 3, 0), "START", "body", T.CREAM, 2, -2)
    D.track(self, ui.text(vmath.vector3(T.CX, fb_y - 20, 0), is_chamber and ("First to " .. tostring(cur_cap) .. " leaves the table") or "Last player standing wins", "small", T.MUTED))
    self.buttons[#self.buttons + 1] = { node = fb, id = "start_tournament" }

    local bkb = D.track(self, ui.btn9(vmath.vector3(T.CX - pw / 2 + 50, T.CY + ph / 2 - 24, 0), vmath.vector3(78, 32, 0), "secondary_btn"))
    D.track(self, ui.text(vmath.vector3(T.CX - pw / 2 + 50, T.CY + ph / 2 - 26, 0), "< BACK", "small", T.CREAM))
    self.buttons[#self.buttons + 1] = { node = bkb, id = "back_to_lobby" }
end

-- Small 2-option menu opened from the TEAM CUPS banner: any
-- signed-in player can create one (funding its grand prize from their own
-- balance) or join an existing one by invitation code.
function M.team_menu(self)
    local scrim = D.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H, vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dialog_block" }

    local pw, ph = 520, 320
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw - 2, ph - 2, 0), T.TILE))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY + ph / 2 - 2, 0), vmath.vector3(pw, 4, 0), T.TEAM))

    D.text_sh(self, vmath.vector3(T.CX, T.CY + ph / 2 - 40, 0), "TEAM CUPS", "title", T.CREAM, 2, -2)
    D.track(self, ui.text(vmath.vector3(T.CX, T.CY + ph / 2 - 70, 0), "Any player can create one, or join with a code", "small", T.MUTED))

    local opt_w, opt_h = 220, 96
    local create_x = T.CX - opt_w/2 - 12
    local join_x   = T.CX + opt_w/2 + 12
    local opt_y = T.CY - 10

    D.track(self, ui.box(vmath.vector3(create_x, opt_y, 0), vmath.vector3(opt_w, opt_h, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(create_x, opt_y, 0), vmath.vector3(opt_w - 2, opt_h - 2, 0), T.TILE))
    D.text_sh(self, vmath.vector3(create_x, opt_y + 12, 0), "CREATE", "body", T.CREAM, 1, -1)
    D.track(self, ui.text(vmath.vector3(create_x, opt_y - 16, 0), "Fund a prize, invite your team", "small", T.MUTED))
    local create_hit = D.track(self, ui.box(vmath.vector3(create_x, opt_y, 0), vmath.vector3(opt_w, opt_h, 0), T.TRANSP))
    self.buttons[#self.buttons + 1] = { node = create_hit, id = "team_menu_create" }

    D.track(self, ui.box(vmath.vector3(join_x, opt_y, 0), vmath.vector3(opt_w, opt_h, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(join_x, opt_y, 0), vmath.vector3(opt_w - 2, opt_h - 2, 0), T.TILE))
    D.text_sh(self, vmath.vector3(join_x, opt_y + 12, 0), "JOIN BY CODE", "body", T.CREAM, 1, -1)
    D.track(self, ui.text(vmath.vector3(join_x, opt_y - 16, 0), "Enter a code your owner shared", "small", T.MUTED))
    local join_hit = D.track(self, ui.box(vmath.vector3(join_x, opt_y, 0), vmath.vector3(opt_w, opt_h, 0), T.TRANSP))
    self.buttons[#self.buttons + 1] = { node = join_hit, id = "team_menu_join" }

    local bkb = D.track(self, ui.btn9(vmath.vector3(T.CX - pw / 2 + 50, T.CY + ph / 2 - 24, 0), vmath.vector3(78, 32, 0), "secondary_btn"))
    D.track(self, ui.text(vmath.vector3(T.CX - pw / 2 + 50, T.CY + ph / 2 - 26, 0), "< BACK", "small", T.CREAM))
    self.buttons[#self.buttons + 1] = { node = bkb, id = "back_to_lobby" }
end

-- Join a player-created Team Cup by the invitation code its owner
-- shared. Codes are alphanumeric (see be_matatu's createTeamTournament, which
-- uppercases/strips them to 3-16 [A-Z0-9] chars). The code is typed on the
-- DEVICE keyboard rather than a hand-drawn key grid, matching the create
-- screen: tapping the field raises the platform IME and characters arrive as
-- "text" / "backspace" input actions.
local TEAM_CODE_MAX = 16
M.TEAM_CODE_MAX = TEAM_CODE_MAX

-- Three-border recipe shared with profile and the team cup screen:
-- accent ring, outer bevel, mid bevel, fill.
local function tj_framed3(self, x, y, w, h, accent, fill)
    D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w + 6, h + 6, 0), accent))
    D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w + 3, h + 3, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0), T.DARK))
    D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w - 3, h - 3, 0), fill))
end

-- Crafted button — no slice-9 artwork, so it matches the create screen.
local function tj_btn(self, id, x, y, w, h, label, accent, fill, font)
    tj_framed3(self, x, y, w, h, accent, fill)
    D.text_sh(self, vmath.vector3(x, y + 1, 0), label, font or "body", T.CREAM, 2, -2)
    local hit = D.track(self, ui.box(vmath.vector3(x, y, 0), vmath.vector3(w + 6, h + 6, 0), T.TRANSP))
    self.buttons[#self.buttons + 1] = { node = hit, id = id }
end

function M.team_join(self)
    local tj = self.team_join or { code = "" }
    self.team_join = tj

    local scrim = D.track(self, ui.cover(T.LOGICAL_W, T.LOGICAL_H, vmath.vector4(0, 0, 0, 0.85)))
    self.buttons[#self.buttons + 1] = { node = scrim, id = "dialog_block" }

    -- Without the on-screen key grid the panel only needs room for the field,
    -- so it shrinks and stays clear of the raised system keyboard.
    local pw, ph = 720, 300
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw, ph, 0), T.BORDER))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY, 0), vmath.vector3(pw - 2, ph - 2, 0), T.TILE))
    D.track(self, ui.box(vmath.vector3(T.CX, T.CY + ph / 2 - 2, 0), vmath.vector3(pw, 4, 0), T.TEAM))

    D.text_sh(self, vmath.vector3(T.CX, T.CY + ph / 2 - 40, 0), "JOIN A TEAM CUP", "title", T.CREAM, 2, -2)
    D.track(self, ui.text(vmath.vector3(T.CX, T.CY + ph / 2 - 70, 0), "Enter the invitation code your team owner shared", "small", T.MUTED))

    -- Tappable code field. Focus is signalled by a brighter accent ring plus a
    -- caret, since the platform IME draws no field of its own.
    local code_y = T.CY + 10
    local focused = tj.focus and true or false
    tj_framed3(self, T.CX, code_y, 440, 56, focused and T.GOLD or T.BORDER, T.DARK)
    local shown = tj.code
    if shown == "" then
        D.track(self, ui.text(vmath.vector3(T.CX, code_y, 0), focused and "|" or "TAP TO TYPE CODE", "subtitle2", T.MUTED))
    else
        D.track(self, ui.text(vmath.vector3(T.CX, code_y, 0), focused and (shown .. "|") or shown, "subtitle2", T.CREAM))
    end
    local code_hit = D.track(self, ui.box(vmath.vector3(T.CX, code_y, 0), vmath.vector3(446, 62, 0), T.TRANSP))
    self.buttons[#self.buttons + 1] = { node = code_hit, id = "tj_focus" }

    if tj.msg then
        D.track(self, ui.text(vmath.vector3(T.CX, code_y - 44, 0), tj.msg, "small", tj.msg_ok and vmath.vector4(0.3, 0.9, 0.4, 1) or vmath.vector4(1, 0.35, 0.35, 1)))
    end

    local jb_y = T.CY - ph / 2 + 46
    tj_btn(self, "team_join_submit", T.CX, jb_y, 260, 52,
        tj.submitting and "JOINING..." or "JOIN", T.GOLD, T.TEAM)

    tj_btn(self, "back_to_lobby", T.CX - pw / 2 + 62, T.CY + ph / 2 - 28, 88, 32,
        "< BACK", T.BORDER, T.DARK, "small")
end



return M
