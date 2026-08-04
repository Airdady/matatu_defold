-- WHAT THE ONLINE LOBBY'S RIGHT PANEL SHOWS, AND HOW BIG.
--
--   Run: lua tools/test_online_lobby_panels.lua
--
-- Two requests: remove the component sitting just after ONLINE TOURNAMENTS,
-- because team cups are managed from the main lobby exclusively; and the
-- tournament icon is too big.
--
-- The component was the TEAM TOURNAMENTS row, whose only control was VIEW
-- BRACKET. Its own comment already conceded the point — creating happens on
-- the main lobby, and the row existed "purely as quick return access".
--
-- Removing the row makes the modal it opened unreachable: that button was the
-- modal's only way in, and its advance/drop handlers were only reachable from
-- inside the modal. So the modal goes too. A screen you cannot open is not
-- neutral — it is code that reads as live and can never run.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local right = slurp("modules/online_right.lua")
local online = slurp("main/online.gui_script")

-- Comments stripped for the "is it gone" checks: the commit that removed the
-- row explains what used to be there, and a search for the old label finds
-- that explanation and reports the row as still present. What matters is
-- whether anything DRAWS it.
local function code_of(src)
    return (src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end
local right_code  = code_of(right)
local online_code = code_of(online)

print("the team tournaments row is gone")
check_true("no TEAM TOURNAMENTS label",
    right_code:find("TEAM TOURNAMENTS") == nil, "the row is still drawn")
check_true("no VIEW BRACKET button",
    right_code:find("VIEW BRACKET") == nil, "its control is still there")

print("")
print("and so is everything only it could reach")
for _, dead in ipairs({
    { "the bracket modal",      "draw_team_bracket_modal" },
    { "its state",              "team_bracket_modal" },
    { "its opener",             "open_team_bracket" },
    { "its refresh",            "refresh_team_bracket" },
    { "the advance override",   "tbr_advance" },
    { "the drop override",      "tbr_drop" },
    { "its row constant",       "MAX_BRACKET_ROWS" },
}) do
    check_true(dead[1] .. " is gone from the panel",
        right_code:find(dead[2], 1, true) == nil, dead[2] .. " left behind")
end

check_true("and the lobby has no handlers for it either",
    online_code:find("tbr_", 1, true) == nil
        and online_code:find("nav_team_bracket", 1, true) == nil,
    "a handler for a button that is never drawn can never fire")

print("")
print("the tournaments row survives — only the team row went")
check_true("TOURNAMENTS is still drawn", right:find('"TOURNAMENTS"') ~= nil,
    "the wrong panel was removed")
check_true("and still navigates", right:find('"nav_tournaments"') ~= nil, "lost its button")

print("")
print("the tournament icon is smaller than it was")
local size = tonumber(right:match("local T_ICON = (%d+)"))
check_true("it has a named size", size ~= nil, "still a bare number")
check("smaller than the old 48", size < 48, true)

-- The battle rows above it use 48 and read correctly, so this must not grow
-- back to match them by "consistency" — the artwork fills more of its box.
check_true("battle row icons are untouched at 48",
    right:find("vmath%.vector3%(48, 48, 0%), icon_name") ~= nil,
    "only the tournament icon was meant to change")
check_true("and it is not shrunk into illegibility",
    size and size >= 28, "too small to read as an icon")

-- The label offset has to follow the icon, or the gap it needed becomes a hole.
check_true("the label is positioned from the icon size",
    right:find("icon_x %+ T_ICON / 2 %+ 12") ~= nil,
    "a fixed offset leaves a hole when the icon shrinks")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
