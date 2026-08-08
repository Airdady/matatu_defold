-- THE INVITE BANNER'S COUNTDOWN BAR MOVING IN STEPS.
--
--   Run: lua tools/test_banner_progress.lua
--
-- Reported: "the inline top banner display, the linear progress for tournament
-- acceptance, is not moving smoothly."
--
-- It was drawn at whatever width the last REBUILD happened to catch:
--
--   b.time_left = (b.time_left or 10) - dt        -- continuous
--   local cur_sec = math.floor(...)
--   if cur_sec ~= b._last_sec then
--       b._last_sec = cur_sec
--       need_rebuild = true                        -- once a SECOND
--   end
--
-- so over a ten-second invite the bar advanced in ten visible steps of 10%
-- instead of sliding.
--
-- Rebuilding every frame is not the answer — rebuild() deletes and recreates
-- every node on the screen, which is exactly why that throttle existed. The
-- bar is ONE node, so it is stashed at draw time and resized in place at frame
-- rate. And since nothing else on the banner changes between rebuilds (there
-- is no seconds text), the per-second rebuild it depended on now buys nothing
-- and is gone.
--
-- The sizing runs for real here against a recording gui stub.
local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then
        print("  PASS " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label .. (why and ("  <- " .. why) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- apply_banner_bar, lifted out of the gui_script and run.
--
-- It is a `local function` inside online.gui_script and cannot be required, so
-- the source is extracted and loaded with a gui stub. Extracted rather than
-- retyped on purpose: a copy would drift, and this fails loudly if the
-- function is renamed or moved.
local src = slurp("main/online.gui_script")
local body = src:match("(local function apply_banner_bar%(b%).-\nend)\n")

print("")
print("THE FUNCTION IS THERE AND WAS ACTUALLY LOADED")
check("apply_banner_bar was found in the source", body ~= nil,
    "a rename would make every assertion below vacuous")

local sizes, colors = {}, {}
local env = {
    math = math, pcall = pcall, tostring = tostring, type = type,
    COL_RED   = { x = 0.90, y = 0.25, z = 0.25 },
    COL_GREEN = { x = 0.15, y = 0.70, z = 0.25 },
    vmath = {
        vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
        vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
    },
    gui = {
        set_size  = function(n, v) sizes[n] = v end,
        set_color = function(n, v) colors[n] = v end,
    },
}
local chunk = assert(load(body .. "\nreturn apply_banner_bar", "apply_banner_bar", "t", env))
local apply = chunk()

local NODE = "bar-node"
local function banner(time_left, max_time, alpha)
    return {
        time_left = time_left,
        max_time = max_time or 10,
        _bar = { node = NODE, w = 1280, alpha = alpha or 1 },
    }
end

-- ---------------------------------------------------------------------------
print("")
print("THE WIDTH FOLLOWS time_left CONTINUOUSLY")

apply(banner(10))
check("full at the start", sizes[NODE].x == 1280)
apply(banner(0))
check("empty at the end", sizes[NODE].x == 0)
apply(banner(5))
check("half way is half way", sizes[NODE].x == 640)

-- The point of the whole exercise: a fraction of a second must move it.
apply(banner(9.98))
local a = sizes[NODE].x
apply(banner(9.96))
local b = sizes[NODE].x
check("two frames apart give two different widths", a ~= b,
    string.format("%.3f vs %.3f — if these were equal the bar would step", a, b))
check("and it is a SMALL difference, not a tenth of the bar",
    math.abs(a - b) < 10,
    string.format("moved %.2fpx in one frame", math.abs(a - b)))

-- What the old behaviour looked like, for contrast: floor to the second first
-- and the same two frames collapse onto one width.
check("flooring to the second is what made it step",
    (function()
        local function stepped(t) return 1280 * (math.floor(t) / 10) end
        return stepped(9.98) == stepped(9.96)
    end)())

print("")
print("AND IT NEVER LEAVES THE BAR")
apply(banner(-3))
check("a countdown past zero clamps to empty", sizes[NODE].x == 0,
    "expiry is handled a frame later; the bar must not go negative")
apply(banner(30, 10))
check("more time than the window clamps to full", sizes[NODE].x == 1280)
apply(banner(nil))
check("a missing time_left is treated as none left", sizes[NODE].x == 0)

check("a banner with no stashed node does nothing, quietly",
    (function()
        local ok = pcall(apply, { time_left = 5, max_time = 10 })
        return ok
    end)(),
    "the handle dies with the next clear(); a frame landing there must not throw")
check("and neither does nothing at all",
    (function() local ok = pcall(apply, nil); return ok end)())

print("")
print("THE COLOUR TURNS AT THE SAME MOMENT THE WIDTH DOES")
apply(banner(5))
check("green with time to spare", colors[NODE].x == 0.15)
apply(banner(2.9))
check("red under 30%", colors[NODE].x == 0.90,
    "it used to change only on a rebuild, so it lagged the bar by up to a second")
apply(banner(3.0))
check("and exactly at 30% it is still green", colors[NODE].x == 0.15)

apply(banner(5, 10, 0.4))
check("the banner's fade alpha is carried through", colors[NODE].w == 0.4,
    "banners slide and fade; a bar at full opacity over a fading banner shows the seam")

-- ---------------------------------------------------------------------------
print("")
print("THE WIRING")

local code = src:gsub("%-%-[^\n]*", "")

check("the bar node is stashed at draw time", code:find("b%._bar = { node = fill"))
check("anchored west, so a resize grows from the left edge",
    code:find("gui%.set_pivot%(fill, gui%.PIVOT_W%)"),
    "otherwise it would need repositioning every frame too, and the two could disagree")
-- CALL sites only. `local function apply_banner_bar(b)` matches a bare
-- "apply_banner_bar(b)" too, so counting occurrences said 2 even with the
-- update() call deleted — the check passed while the bug was reintroduced.
local calls = select(2, code:gsub("[^%w_]apply_banner_bar%(b%)", ""))
    - select(2, code:gsub("function apply_banner_bar%(b%)", ""))
check("it is called twice: once at draw, once per frame", calls == 2,
    "got " .. tostring(calls) .. " call site(s)")

-- And specifically from inside the countdown loop in update(), which is the
-- one that makes it smooth.
check("update() sizes it on the same tick that decrements the clock",
    code:match("b%.time_left = %(b%.time_left or 10%) %- dt.-apply_banner_bar%(b%)") ~= nil)
check("and draw_banner sizes it too, so a rebuild starts correct",
    code:match("b%._bar = { node = fill.-apply_banner_bar%(b%)") ~= nil)

check("the per-second rebuild is gone",
    not code:find("b%._last_sec"),
    "it existed only to move this bar, and moved it in steps")
check("but an EXPIRED banner still rebuilds",
    code:match("expired.-need_rebuild = true") ~= nil,
    "the banner has to actually leave the screen")

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
