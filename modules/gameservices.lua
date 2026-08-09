-- gameservices.lua
-- Thin Lua-side guard around the `gameservices` native extension
-- (gameservices/src/gameservices.cpp — Google Play Core in-app update +
-- OneSignal): the extension only registers itself on Android, so
-- `_G.gameservices` is nil in the
-- editor and on every other platform. Every function here degrades to a
-- silent no-op there instead of the rest of the app having to know whether
-- the native module exists before touching it.

local M = {}

-- Resolved once. nil outside Android.
local ext = _G.gameservices

M.available = ext ~= nil

-- Kicks off Google Play's in-app update check (Module_methods -> CheckUpdate
-- in gameservices.cpp). Per InAppUpdateDefold.java this forces the
-- IMMEDIATE update flow whenever a newer version is available on Play —
-- the update_required.gui_script server-driven blocking modal stays as an
-- independent fallback for players this native check never reaches (not on
-- Android, Play Store not the install source, etc).
--
-- Safe to call more than once per app run (bootstrap + lobby init both call
-- this — belt-and-suspenders in case Play Services isn't warmed up yet at
-- the very first call).
function M.check_update()
    if not M.available then return end
    local ok, err = pcall(ext.check_update)
    if not ok then
        print("[gameservices] check_update failed: " .. tostring(err))
    end
end

return M
