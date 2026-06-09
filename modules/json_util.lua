--- json_util.lua
-- JSON encode (+ a decode that prefers Defold's built-in `json.decode`, with a
-- pure-Lua fallback so the networking modules can also be unit-tested off-engine).

local M = {}

-- ── encode ──────────────────────────────────────────────────────────────────
local ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function escape_str(s)
	return (s:gsub('[%z\1-\31\\"]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end))
end

local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then
			return false
		end
		n = n + 1
	end
	return n == #t
end

local function encode_value(v, out)
	local tv = type(v)
	if v == nil then
		out[#out + 1] = "null"
	elseif tv == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			out[#out + 1] = "null"
		elseif math.floor(v) == v then
			out[#out + 1] = string.format("%d", v)
		else
			out[#out + 1] = string.format("%.14g", v)
		end
	elseif tv == "string" then
		out[#out + 1] = '"' .. escape_str(v) .. '"'
	elseif tv == "table" then
		if next(v) == nil then
			out[#out + 1] = "{}"
		elseif is_array(v) then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then
					out[#out + 1] = ","
				end
				encode_value(v[i], out)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for k, val in pairs(v) do
				if not first then
					out[#out + 1] = ","
				end
				first = false
				out[#out + 1] = '"' .. escape_str(tostring(k)) .. '":'
				encode_value(val, out)
			end
			out[#out + 1] = "}"
		end
	else
		out[#out + 1] = "null"
	end
end

function M.encode(value)
	local out = {}
	encode_value(value, out)
	return table.concat(out)
end

-- ── decode ──────────────────────────────────────────────────────────────────
-- Minimal recursive-descent JSON parser (fallback for non-Defold environments).
local function parse_fallback(str)
	local pos = 1
	local parse_value

	local function skip_ws()
		local _, e = str:find("^[ \t\r\n]+", pos)
		if e then
			pos = e + 1
		end
	end

	local function parse_string()
		pos = pos + 1 -- opening quote
		local buf = {}
		while pos <= #str do
			local c = str:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(buf)
			elseif c == "\\" then
				local nxt = str:sub(pos + 1, pos + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if nxt == "u" then
					local hex = str:sub(pos + 2, pos + 5)
					local code = tonumber(hex, 16) or 63
					buf[#buf + 1] = (code < 128) and string.char(code) or "?"
					pos = pos + 6
				else
					buf[#buf + 1] = map[nxt] or nxt
					pos = pos + 2
				end
			else
				buf[#buf + 1] = c
				pos = pos + 1
			end
		end
		error("unterminated string")
	end

	local function parse_number()
		local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
		local num = tonumber(str:sub(s, e))
		pos = e + 1
		return num
	end

	parse_value = function()
		skip_ws()
		local c = str:sub(pos, pos)
		if c == "{" then
			pos = pos + 1
			local obj = {}
			skip_ws()
			if str:sub(pos, pos) == "}" then
				pos = pos + 1
				return obj
			end
			while true do
				skip_ws()
				local key = parse_string()
				skip_ws()
				pos = pos + 1 -- colon
				obj[key] = parse_value()
				skip_ws()
				local sep = str:sub(pos, pos)
				pos = pos + 1
				if sep == "}" then
					break
				end
			end
			return obj
		elseif c == "[" then
			pos = pos + 1
			local arr = {}
			skip_ws()
			if str:sub(pos, pos) == "]" then
				pos = pos + 1
				return arr
			end
			while true do
				arr[#arr + 1] = parse_value()
				skip_ws()
				local sep = str:sub(pos, pos)
				pos = pos + 1
				if sep == "]" then
					break
				end
			end
			return arr
		elseif c == '"' then
			return parse_string()
		elseif c == "t" then
			pos = pos + 4
			return true
		elseif c == "f" then
			pos = pos + 5
			return false
		elseif c == "n" then
			pos = pos + 4
			return nil
		else
			return parse_number()
		end
	end

	local ok, result = pcall(parse_value)
	if ok then
		return result
	end
	return nil
end

function M.decode(str)
	if str == nil or str == "" then
		return nil
	end
	-- Prefer Defold's built-in JSON decoder when present.
	if _G.json and _G.json.decode then
		local ok, result = pcall(_G.json.decode, str)
		if ok then
			return result
		end
	end
	local ok, result = pcall(parse_fallback, str)
	if ok then
		return result
	end
	return nil
end

return M
