-- modules/incoming_budget.lua
-- How long the incoming-request overlay is allowed to hold the app's input.
--
-- THE FREEZE THIS EXISTS FOR
--
-- The full incoming dialog claims "incoming" (priority 100) in the modal
-- registry, and every screen in the app opens its on_input with
-- `if app_state.input_blocked() then return false end`. So while that claim is
-- held, NOTHING anywhere responds — by design, because a challenge has ten
-- seconds on it and an opponent waiting.
--
-- Ten seconds is fine. The problem is that the ten seconds restart.
-- open_dialog replaces a live dialog with the newly arrived request and gives
-- it a fresh countdown, so a player being spammed with challenges — or sitting
-- in a busy tournament lobby where invites arrive every few seconds — holds
-- that claim continuously. The dialog is visibly changing, so it does not look
-- stuck; the app underneath simply stops accepting input, indefinitely, and
-- the only way out is force-quitting.
--
-- The rule here is a ceiling on the CLAIM, not on any one request. Each
-- request still gets its own countdown. But once the overlay has been blocking
-- for BUDGET_SECONDS without a break, it stops using the blocking surface and
-- falls back to the top banner, which is non-modal: the player can still see
-- every invite and still accept any of them, and the rest of the app works.
--
-- Degrading rather than dropping is the point. Refusing to show the requests
-- would lose them; showing them without the scrim costs nothing but the
-- interruption, which is exactly what is misbehaving.
local M = {}

-- The longest the app may be input-dead in one continuous stretch. A single
-- dialog runs 10s, so this permits two back-to-back challenges at full
-- strength and demotes from the third on.
M.BUDGET_SECONDS = 25

-- How long we keep using the non-blocking banner afterwards. Long enough to
-- outlast the burst that caused it — a cooldown shorter than the gap between
-- arrivals would flip straight back to blocking on the next one.
M.COOLDOWN_SECONDS = 20

function M.new()
    return { held = 0, cooldown = 0 }
end

-- Which surface a newly arrived request should use.
--   wants_banner  the request is a tournament / battle / cup invite, which is
--                 always non-modal regardless of any of this.
function M.surface(state, wants_banner)
    if wants_banner then return "banner" end
    if ((state or {}).cooldown or 0) > 0 then return "banner" end
    return "dialog"
end

-- One frame. `showing` is nil, "dialog" or "banner".
-- Returns "demote" when a blocking dialog has outstayed the budget and the
-- caller must convert it to a banner and release the claim.
function M.tick(state, dt, showing)
    if type(state) ~= "table" then return nil end
    dt = tonumber(dt) or 0
    state.cooldown = math.max(0, (state.cooldown or 0) - dt)

    if showing == "dialog" then
        state.held = (state.held or 0) + dt
        if state.held >= M.BUDGET_SECONDS then
            state.held = 0
            state.cooldown = M.COOLDOWN_SECONDS
            return "demote"
        end
    elseif showing == nil then
        -- Nothing on screen: the burst is over and the next challenge gets the
        -- full treatment again.
        --
        -- Deliberately NOT reset while a banner is up. A burst that alternates
        -- dialog and banner would otherwise hand back a fresh 25 seconds of
        -- blocking every time a tournament invite happened to land in the
        -- middle of it, which is the exact traffic pattern that froze the app.
        state.held = 0
    end
    return nil
end

return M
