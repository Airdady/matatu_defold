-- WHEN THE NEXT ROUND IS ALLOWED TO START, DRIVEN ON A FAKE CLOCK.
--
--   Run: lua tools/test_round_timing.lua
--
-- Asked for: the cards flip, and only then — plus a beat — may the queue run
-- the next game; and for knockout specifically, flip, then the hands are
-- counted, then the round-complete banner is displayed for two seconds, and
-- THEN the new round is initialized.
--
-- The order was already right. The timing was not, and in a way that does not
-- show up by reading either file alone:
--
--   The banner (round_story_ui) ran 0.42 in + 1.35 hold + 0.30 out ~= 2.1s and
--   posted "round_story_done" at the end, which releases the round. But
--   game_flow ALSO ran its own timer.delay(1.5) to release it, described in
--   the source as a "safety net for the odd case that message never arrives".
--   1.5 < 2.1, so the net always won. The net was the primary path, every
--   time, and the round was released with the result still on screen.
--
-- So the fix is not only "make it 2 seconds" — it is to make the banner's own
-- clock the one that decides, and to put the fallback AFTER it where a
-- fallback belongs. These assert both, and the knockout ordering around them.
--
-- The banner is driven for real here (stubbed gui/timer, fake clock) rather
-- than asserting on its constants, because the constants only matter if the
-- animation actually uses them.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end
local function check_true(label, cond, why)
    if not cond then failures = failures + 1 end
    print(string.format("  %s %s%s", cond and "PASS" or "FAIL", label,
        cond and "" or ("  <- " .. tostring(why or ""))))
end

-- ── a clock we control ─────────────────────────────────────────────────────
local now, pending = 0, {}
local function at(delay, fn) table.insert(pending, { t = now + delay, fn = fn }) end
local function advance(to)
    while true do
        table.sort(pending, function(a, b) return a.t < b.t end)
        local nxt = pending[1]
        if not nxt or nxt.t > to then break end
        table.remove(pending, 1)
        now = nxt.t
        nxt.fn()
    end
    now = to
end

-- ── enough Defold to load and run the banner ───────────────────────────────
vmath = {
    vector3 = function(a, b, c) return { a or 0, b or 0, c or 0 } end,
    vector4 = function(a, b, c, d) return { a or 0, b or 0, c or 0, w = d or 0 } end,
}
timer = { delay = function(d, _, fn) at(d, fn) end }

local posted = {}
msg = { post = function(_, id) table.insert(posted, id) end }

gui = {
    EASING_OUTBACK = 1, EASING_INSINE = 2, EASING_OUTSINE = 3,
    PIVOT_CENTER = 0,
    new_box_node = function() return {} end,
    new_text_node = function() return {} end,
    set_color = function() end, set_pivot = function() end, set_font = function() end,
    set_scale = function() end, set_text = function() end, set_enabled = function() end,
    set_adjust_mode = function() end, set_parent = function() end, set_shadow = function() end,
    get_color = function() return { w = 0 } end,
    cancel_animation = function() end,
    -- gui.animate(node, prop, to, easing, duration, delay, cb)
    animate = function(_, _, _, _, duration, delay, cb)
        if cb then at((duration or 0) + (delay or 0), cb) end
    end,
}

local RS = require("modules.round_story_ui")

print("the round-complete banner is displayed for two seconds")
check("hold", RS.HOLD, 2.00)
check_true("and the hold is what the player actually reads",
    RS.HOLD > RS.SHOW_IN and RS.HOLD > RS.SHOW_OUT,
    "the in/out flourishes should not dominate the read")

-- Drive the real M.show and watch for round_story_done.
local self_ = {}
RS.build(self_, 1280, 720)
posted = {}
now = 0; pending = {}
RS.show(self_, { won = true, p_score = 1, o_score = 0 }, "OPPONENT")

advance(RS.SHOW_IN + RS.HOLD - 0.01)
check("still on screen just before the hold is up", #posted, 0)

advance(RS.TOTAL + 0.001)
check("released once it has fully gone", posted[1], "round_story_done")
check_true("and TOTAL is the whole of in+hold+out",
    math.abs(RS.TOTAL - (RS.SHOW_IN + RS.HOLD + RS.SHOW_OUT)) < 1e-9, RS.TOTAL)

-- ── game_flow's timers, read from source ───────────────────────────────────
-- game_flow pulls in the whole game (go, factory, sockets, the websocket
-- manager) at load, so its waits are checked at the source level.
print("")
print("the queue is not released before the banner has been read")

local f = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../modules/game_flow.lua", "r")
local src = f:read("*a"); f:close()

local function has(pat) return src:find(pat) ~= nil end

check_true("the waits come from the banner's own clock, not restated numbers",
    has("local NEXT_ROUND_AFTER_BANNER = RoundStory%.SHOW_IN %+ RoundStory%.HOLD"),
    "NEXT_ROUND_AFTER_BANNER must derive from RoundStory")
check_true("knockout releases the round on that wait",
    has("timer%.delay%(NEXT_ROUND_AFTER_BANNER, false, function%(%)"),
    "knockout branch should use the derived wait")
check_true("and it still forces past the knockout story lock",
    has("M%.finish_round_transition%(self, true%)"),
    "_knockout_story_locked blocks the unforced call, so knockout has no other path")

check_true("the fallback sits AFTER the banner, not before it",
    has("local NEXT_ROUND_FALLBACK = RoundStory%.TOTAL %+ 0%.5"),
    "a net that fires first is not a net, it is the primary path")
check_true("tournament rounds use the fallback for their timer",
    has("timer%.delay%(NEXT_ROUND_FALLBACK, false, function%(%) M%.finish_round_transition%(self%) end%)"),
    "tournament branch should defer to round_story_done")

check_true("the old flat 1.5s releases are gone",
    not has("timer%.delay%(1%.5, false"),
    "1.5s undercut the banner and silently became the primary path")

check_true("an ordinary game over waits a beat before anything queued runs",
    has("local NEW_GAME_AFTER_FLIP = 2%.0")
        and has("timer%.delay%(NEW_GAME_AFTER_FLIP, false, function%(%)"),
    "this used to release the queue in the same frame as the modal")

-- ── the knockout order itself ──────────────────────────────────────────────
print("")
print("knockout order: flip -> count -> banner -> next round")

-- FIRST occurrence of each, not "the next one after the previous step".
-- Searching forward from the previous step cannot see a stage that has moved
-- EARLIER than it — counting hoisted in front of the flip still satisfies
-- "there is a count somewhere after the flip", which is not the claim.
-- ...and skipping DEFINITIONS. Each of these is a `local function foo(...)`
-- declared above the chain that calls it, so a bare name search finds where it
-- was written, not where it runs. The three callback-taking stages happen to
-- be distinguishable by their call shape (`foo(function()`), but
-- final_resolution takes no argument and reads identically either way.
local function first_call(pat)
    local from = 1
    while true do
        local i = src:find(pat, from)
        if not i then return nil end
        if not src:sub(math.max(1, i - 20), i - 1):find("function%s+$") then return i end
        from = i + 1
    end
end

local flip     = first_call("flip_ai_hand%(function%(%)")
local sweep    = first_call("sweep_played_cards%(function%(%)")
local count    = first_call("count_next_player%(1, function%(%)")
local resolve  = first_call("final_resolution%(%)")

check_true("the flip opens the chain", flip ~= nil, "flip_ai_hand")
check_true("the played cards are swept after the flip", sweep and sweep > flip, sweep)
check_true("the hands are counted after that", count and count > sweep, count)
check_true("and the banner/next round comes last",
    resolve and resolve > count, resolve)

-- The fallback must genuinely be slack, not a tie that depends on ordering
-- within a frame.
check_true("the fallback has real slack over the banner",
    (RS.TOTAL + 0.5) - RS.TOTAL >= 0.5, "slack")
check_true("and the knockout release lands while the banner is still up",
    (RS.SHOW_IN + RS.HOLD) < RS.TOTAL,
    "the round is released as the banner starts leaving, not before it arrives")

-- game.script's watchdog force-releases a stuck transition; it must stay well
-- clear of the real sequence or it will fire during a normal round.
local g = io.open((debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../main/game.script", "r")
local gsrc = g:read("*a"); g:close()
local watchdog = tonumber(gsrc:match("round_story_deadline = socket%.gettime%(%) %+ ([%d%.]+)"))
check_true("the stuck-transition watchdog still sits clear of the sequence",
    watchdog and watchdog > RS.TOTAL + 2.0,
    "watchdog=" .. tostring(watchdog) .. " total=" .. tostring(RS.TOTAL))

-- ── the next round is not built during the transition ──────────────────────
--
-- The reported symptom: "it initializes the new game, THEN does the flipping
-- and counting". The server now pushes the next round the instant the last one
-- is decided, so it arrives mid-reveal as a matter of course — and the only
-- gate was round_story_active, which is not set until final_resolution, i.e.
-- after the flip and the count have already run. So the state sailed through
-- and rebuilt the board underneath the reveal. On the way past, it also
-- cleared pending_game_over_data, so for that round the flip and count never
-- ran at all.
print("")
print("the next round is parked until the transition has finished")

local function ghas(pat) return gsrc:find(pat) ~= nil end

check_true("the transition is flagged the moment the server says the round ended",
    gsrc:match("ws_game_over.-round_transition_busy = true") ~= nil,
    "must start at ws_game_over, not at end_game")
check_true("and the gate covers it, not just the banner",
    ghas("if self%.round_story_active or self%.round_transition_busy then"),
    "round_story_active alone begins after the flip and the count")
check_true("the parked state is kept, not dropped",
    ghas("self%._pending_next_state = state"), "park")
check_true("finish_round_transition is what clears the flag",
    src:find("self%.round_transition_busy = false") ~= nil
        and src:find("round_transition_finished") ~= nil,
    "game_flow must release it when the round has finished ending")
check_true("and the script builds the parked round on that signal",
    ghas('message_id == hash%("round_transition_finished"%)'), "handler")
check_true("but not while the banner is still up",
    gsrc:match('round_transition_finished".-if not self%.round_story_active then') ~= nil,
    "whichever of the two finishes last should do the build")

-- Holding a round back is only safe if something always lets it go.
check_true("a parked round always has a way out",
    ghas("_pending_next_deadline") and ghas("watchdog released a parked next round"),
    "otherwise a transition that never reports finishing strands the round")

local park_deadline = tonumber(gsrc:match("_pending_next_deadline = socket%.gettime%(%) %+ ([%d%.]+)"))
check_true("and that backstop sits behind every normal path",
    park_deadline and watchdog and park_deadline > watchdog and park_deadline > RS.TOTAL,
    "park=" .. tostring(park_deadline) .. " story_watchdog=" .. tostring(watchdog))

-- The watchdogs call start_new_online_game from update(), which sits ABOVE its
-- definition. Without a forward declaration that call compiles to a global
-- lookup that is always nil, so the net threw instead of firing. Checked by
-- compiling, because it is invisible by reading.
print("")
print("the watchdogs can actually call what they call")

local compiled = io.popen("luac -l -l -p -- '"
    .. (debug.getinfo(1, "S").source:match("@(.*/)") or "./")
    .. "../main/game.script' 2>/dev/null")
local dump = compiled and compiled:read("*a") or ""
if compiled then compiled:close() end

if dump == "" then
    print("  SKIP  luac unavailable")
else
    check_true("start_new_online_game is never reached as a nil global",
        not dump:find('_ENV "start_new_online_game"'),
        "GETTABUP _ENV means the call resolves to nil at runtime")
    check_true("it is forward-declared above the watchdogs",
        ghas("^local start_new_online_game$") or ghas("\nlocal start_new_online_game\n"),
        "forward declaration missing")
end

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
