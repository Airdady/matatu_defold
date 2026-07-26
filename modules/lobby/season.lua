-- modules/lobby/season.lua — the header's season countdown.
--
-- Pure date arithmetic plus one entry point (M.update), split out of
-- lobby.gui_script: none of this touches nodes or layout, and it was the
-- single largest block in that file with nothing to do with drawing.

local ws = require("modules.websocket_manager")

local M = {}

local function days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function parse_iso_utc(str)
    if type(str) ~= "string" then return nil end
    local y, mo, d, h, mi, s = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

local WEEKDAY_NAMES = { "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" }
local EAT_OFFSET = 3 * 3600 -- Africa/Nairobi, UTC+3, no DST

-- end_epoch is a true UTC unix timestamp. Always render it in EAT — the
-- prize/season cadence is fixed to Africa/Nairobi regardless of the
-- player's device timezone — via the same "+3h then read as UTC" trick
-- used for the fallback cadence below, rather than os.date's un-prefixed
-- form (which follows the device's own local timezone).
local function format_season_deadline(end_epoch)
    local t = os.date("!*t", end_epoch + EAT_OFFSET)
    local h12 = t.hour % 12
    if h12 == 0 then h12 = 12 end
    local ampm = t.hour < 12 and "AM" or "PM"
    return string.format("ENDS %s %d:%02d %s EAT", WEEKDAY_NAMES[t.wday] or "?", h12, t.min, ampm)
end

-- Placeholder cadence (Wednesday 12:00 / Saturday 23:59 Africa/Nairobi) used
-- whenever the backend hasn't told us the real per-game boundary yet.
-- SEASON_STATUS is only ever sent to an authenticated client right after
-- IDENTIFY, so guests — and anyone before that round-trip completes — would
-- otherwise see a blank/frozen countdown. Mirrors be_matatu's
-- Prize.DEFAULT_SEASON_SCOPES so it agrees with the real schedule until the
-- live value arrives.
local function fallback_season_end_utc()
    local now_eat = os.time() + EAT_OFFSET
    local t = os.date("!*t", now_eat)
    local seconds_today = t.hour * 3600 + t.min * 60 + t.sec
    local midnight_today_eat = now_eat - seconds_today
    local is_phase_1 = (t.wday >= 1 and t.wday <= 3) or (t.wday == 4 and seconds_today < 43200)
    local target_eat = is_phase_1
        and (midnight_today_eat + (((4 - t.wday) % 7) * 86400) + 43200)
        or (midnight_today_eat + (((7 - t.wday) % 7) * 86400) + 86399)
    return target_eat - EAT_OFFSET
end

function M.update(self)
    local status = ws.current_season_status
    local end_epoch = status and parse_iso_utc(status.endDate)
    if not end_epoch then
        end_epoch = fallback_season_end_utc()
    end
    local diff = math.max(0, end_epoch - os.time())
    self.season_text = diff >= 86400
        and string.format("%dD %02dH %02dM %02dS", math.floor(diff / 86400), math.floor((diff % 86400) / 3600), math.floor((diff % 3600) / 60), diff % 60)
        or string.format("%02dH %02dM %02dS", math.floor(diff / 3600), math.floor((diff % 3600) / 60), diff % 60)
    self.season_deadline_text = format_season_deadline(end_epoch)
end


return M
