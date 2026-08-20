-- modules/lobby/season.lua — the header's season countdown.
--
-- Pure date arithmetic plus one entry point (M.update), split out of
-- lobby.gui_script: none of this touches nodes or layout, and it was the
-- single largest block in that file with nothing to do with drawing.

local ws = require("modules.websocket_manager")
-- The date arithmetic and the fallback cadence moved to modules/season_clock,
-- which the Season Bonuses countdown also reads. Three surfaces were each
-- carrying their own copy of the Wednesday-midday / Saturday-midnight
-- schedule, which is three chances for one of them to disagree with the
-- server about when the money moves.
local clock = require("modules.season_clock")

local M = {}

local WEEKDAY_NAMES = { "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" }
local EAT_OFFSET = clock.EAT_OFFSET -- Africa/Nairobi, UTC+3, no DST

-- end_epoch is a true UTC unix timestamp. Always render it in EAT — the
-- prize/season cadence is fixed to Africa/Nairobi regardless of the
-- player's device timezone — via the "+3h then read as UTC" trick
-- (season_clock uses the same one for the fallback cadence), rather than
-- os.date's un-prefixed form, which follows the device's own local timezone.
local function format_season_deadline(end_epoch)
    local t = os.date("!*t", end_epoch + EAT_OFFSET)
    local h12 = t.hour % 12
    if h12 == 0 then h12 = 12 end
    local ampm = t.hour < 12 and "AM" or "PM"
    return string.format("ENDS %s %d:%02d %s EAT", WEEKDAY_NAMES[t.wday] or "?", h12, t.min, ampm)
end

function M.update(self)
    local end_epoch = clock.end_epoch(ws.current_season_status)
    -- The header's countdown stays VERBOSE: this is the surface whose whole
    -- job is the countdown, so the ticking second is the point. The minimal
    -- two-unit form belongs where the clock is a glance beside something else
    -- — see the Season Bonuses title row in modules/online_left.lua.
    self.season_text = clock.verbose(math.max(0, end_epoch - os.time()))
    self.season_deadline_text = format_season_deadline(end_epoch)
end


return M
