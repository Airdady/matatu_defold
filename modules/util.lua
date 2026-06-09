--- util.lua
-- Small helpers: base64 decode/encode and hex<->bytes, all pure Lua so they run
-- identically in Defold and in test harnesses. Bytes are represented as Lua
-- tables of integers 0..255 (1-indexed).

local M = {}

local tunpack = table.unpack or unpack

local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64LOOKUP = {}
for i = 1, #B64CHARS do
	B64LOOKUP[B64CHARS:sub(i, i)] = i - 1
end

--- Decode a base64 string into a byte table (handles padding and whitespace).
function M.base64_to_bytes(str)
	str = str:gsub("[^%w%+%/=]", "")
	local bytes = {}
	local n = #str
	local i = 1
	while i <= n do
		local c1 = B64LOOKUP[str:sub(i, i)] or 0
		local c2 = B64LOOKUP[str:sub(i + 1, i + 1)] or 0
		local c3char = str:sub(i + 2, i + 2)
		local c4char = str:sub(i + 3, i + 3)
		local c3 = B64LOOKUP[c3char] or 0
		local c4 = B64LOOKUP[c4char] or 0

		local triple = c1 * 262144 + c2 * 4096 + c3 * 64 + c4 -- (c1<<18)|(c2<<12)|(c3<<6)|c4
		local b1 = math.floor(triple / 65536) % 256
		local b2 = math.floor(triple / 256) % 256
		local b3 = triple % 256

		bytes[#bytes + 1] = b1
		if c3char ~= "=" and c3char ~= "" then
			bytes[#bytes + 1] = b2
		end
		if c4char ~= "=" and c4char ~= "" then
			bytes[#bytes + 1] = b3
		end
		i = i + 4
	end
	return bytes
end

--- Convert a hex string ("a27a...") into a byte table.
function M.hex_to_bytes(hex)
	local bytes = {}
	for i = 1, #hex, 2 do
		bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16)
	end
	return bytes
end

--- Convert a byte table into a Lua string.
function M.bytes_to_string(bytes)
	-- Chunk to avoid string.char arg limits on very large payloads.
	local parts = {}
	local chunk = {}
	for i = 1, #bytes do
		chunk[#chunk + 1] = bytes[i]
		if #chunk >= 2048 then
			parts[#parts + 1] = string.char(tunpack(chunk))
			chunk = {}
		end
	end
	if #chunk > 0 then
		parts[#parts + 1] = string.char(tunpack(chunk))
	end
	return table.concat(parts)
end

--- Convert a Lua string into a byte table.
function M.string_to_bytes(str)
	local bytes = {}
	for i = 1, #str do
		bytes[i] = str:byte(i)
	end
	return bytes
end

return M
