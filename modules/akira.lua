-- modules/akira.lua
-- Akira — the AI helper's single identity, shared by every dialog so the
-- branding stays consistent: the consent/install popover, the in-game
-- takeover notices and the assist banner all show the same name + avatar.
--
-- The avatar is rolled once (randomly) the first time Akira is introduced
-- and persisted with the consent flag, so Akira always "looks the same"
-- on this device.

local M = {}

M.NAME = "Akira"

local SAVE_FILE = sys.get_save_file("matatu_defold", "ai_consent")

local _cache = nil

local function load_state()
	if _cache then return _cache end
	local ok, data = pcall(sys.load, SAVE_FILE)
	_cache = (ok and type(data) == "table") and data or {}
	return _cache
end

local function save_state()
	pcall(sys.save, SAVE_FILE, _cache or {})
end

-- Akira's avatar id (1-60). Rolled once, then stable forever.
function M.avatar()
	local s = load_state()
	if not s.avatar then
		s.avatar = math.random(1, 60)
		save_state()
	end
	return s.avatar
end

-- Has the user completed the Akira install/consent flow?
function M.installed()
	local s = load_state()
	return s.agreed == true
end

function M.set_installed()
	local s = load_state()
	s.agreed = true
	s.avatar = s.avatar or math.random(1, 60)
	save_state()
end

return M
