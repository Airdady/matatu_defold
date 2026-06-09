--- bitops.lua
-- Portable 32-bit bitwise ops. Defold ships LuaJIT's BitOp ("bit") on device;
-- standard Lua 5.3+ has native operators. We pick whichever is available so the
-- same AES code runs in the Defold runtime and in local test harnesses.
--
-- The 5.3 operator variants are wrapped in load()'d strings so this file still
-- *parses* under Lua 5.1 / LuaJIT (which would otherwise reject `&`, `~`, ...).

local M = {}

local ok, bitlib = pcall(require, "bit")
if ok and bitlib then
	M.band = bitlib.band
	M.bor = bitlib.bor
	M.bxor = bitlib.bxor
	M.bnot = bitlib.bnot
	M.lshift = bitlib.lshift
	M.rshift = bitlib.rshift
else
	M.band = load("return function(a,b) return (a & b) & 0xFFFFFFFF end")()
	M.bor = load("return function(a,b) return (a | b) & 0xFFFFFFFF end")()
	M.bxor = load("return function(a,b) return (a ~ b) & 0xFFFFFFFF end")()
	M.bnot = load("return function(a) return (~a) & 0xFFFFFFFF end")()
	M.lshift = load("return function(a,n) return (a << n) & 0xFFFFFFFF end")()
	M.rshift = load("return function(a,n) return (a >> n) & 0xFFFFFFFF end")()
end

return M
