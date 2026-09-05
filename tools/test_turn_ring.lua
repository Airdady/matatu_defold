-- THE TURN RING MUST NEVER BE ENABLED AND INVISIBLE.
--
--   Run: lua5.3 tools/test_turn_ring.lua
--
-- hud_ui.update has three phases and each is entered by a latch:
--
--   COUNTDOWN  time left. Ticks down, green to orange to red.
--   GRACE      the countdown reached zero and the server has not acted yet.
--              A second full round, in purple, on the opponent's ring.
--   EXPIRED    grace spent. A full red ring, breathing.
--
-- Two of those latches were only ever set by the countdown CROSSING zero, and
-- the countdown branch is guarded on `timer_remaining > 0`. So a clock that
-- ARRIVED at zero entered none of them: the ring was enabled, drawn at a fill
-- angle of zero, and left there — and a pie node with no fill angle draws
-- nothing at all. Enabled and invisible, until the next state arrived, which
-- on a board waiting for the other player is never.
--
-- Every lapsed deadline produces that state, and they are not rare. A server
-- restart hands back a turn deadline from before the outage; a reconnect
-- resumes from a state the client cached before it dropped; a phone coming
-- back from the background has been away longer than a turn. game.script
-- carries two comments describing this exact symptom and works around it by
-- hunting for a fresher state first — this is the reason it had to.
local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"
package.path = ROOT .. "?.lua;" .. package.path

local SIM = dofile(ROOT .. "tools/defold_sim.lua")
SIM.install_gui_stub()

local hud = require("modules.hud_ui")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(("  FAIL %s (got %s, want %s)"):format(label, tostring(got), tostring(want)))
    end
end
local function ok(label, cond, detail)
    check(label .. (detail and ("  [" .. detail .. "]") or ""), cond and true or false, true)
end
local function near(label, got, want)
    ok(label .. (" (%s ~ %s)"):format(tostring(got), tostring(want)),
       type(got) == "number" and math.abs(got - want) < 1e-6)
end

-- A board with both rings and the opponent's name label, which is what the
-- grace phase borrows.
local function board()
    return {
        p_timer = gui.new_pie_node(vmath.vector3(0, 0, 0), vmath.vector3(92, 92, 0)),
        o_timer = gui.new_pie_node(vmath.vector3(0, 0, 0), vmath.vector3(92, 92, 0)),
        o_avatar_name = gui.new_text_node(vmath.vector3(0, 0, 0), "OPPONENT"),
        opp_display_name = "OPPONENT",
    }
end
local NOW = function() return socket.gettime() * 1000.0 end

----------------------------------------------------------------------
print("A LIVE DEADLINE COUNTS DOWN, WHICH IS THE CASE THAT ALWAYS WORKED")
----------------------------------------------------------------------
do
    local b = board()
    hud.start_timer(b, true, 35, NOW() + 20000, 10)
    ok("the player's ring is up", b.p_timer.enabled)
    ok("...and the opponent's is not", b.o_timer.enabled == false)
    near("it shows the time that is actually left", b.p_timer.fill, (20 / 35) * 360)
    ok("counting down, not in grace", b.timer_grace == false and b.timer_expired == false)

    hud.update(b, 1.0)
    ok("and it ticks", b.timer_remaining < 20)
end

----------------------------------------------------------------------
print("A DEADLINE THAT HAS ALREADY LAPSED IS DRAWN, NOT SWALLOWED")
----------------------------------------------------------------------
-- This is the restart: the state carries a turn deadline from before the
-- outage, so there is nothing left to count the moment it arrives.
do
    local b = board()
    hud.start_timer(b, true, 35, NOW() - 60000, 10)

    ok("the ring is up", b.p_timer.enabled)
    -- THE BUG, STATED AS THE THING THAT MUST NOT HAPPEN: enabled with no fill
    -- is a ring that is drawn and cannot be seen.
    ok("...and it is NOT enabled-but-empty", b.p_timer.fill > 0)
    near("a spent clock shows a FULL ring", b.p_timer.fill, 360)
    ok("...having latched into a phase update() will keep drawing",
        b.timer_grace or b.timer_expired)
    check("grace first, because the server may still act", b.timer_grace, true)

    -- And it keeps being drawn, frame after frame, rather than freezing.
    hud.update(b, 1.0)
    ok("it is still up a second later", b.p_timer.enabled)
    ok("...and still filled", b.p_timer.fill > 0)
end

----------------------------------------------------------------------
print("AND IT RUNS THE SAME THREE PHASES, ENTERED FROM THE OTHER SIDE")
----------------------------------------------------------------------
do
    local b = board()
    hud.start_timer(b, false, 35, NOW() - 5000, 10)
    check("the opponent's ring is the one that is up", b.o_timer.enabled, true)
    check("...and the player's is not", b.p_timer.enabled, false)
    -- The grace phase borrows the opponent's label to say what is being waited
    -- for, exactly as it does when the countdown reaches zero on its own.
    check("it says what it is waiting for", gui.get_text(b.o_avatar_name), "RECONNECTING...")

    -- Grace runs out; the red alarm is then earned.
    for _ = 1, 11 do hud.update(b, 1.0) end
    check("grace spent", b.timer_grace, false)
    check("...and the alarm takes over", b.timer_expired, true)
    ok("the ring is still up, full and pulsing", b.o_timer.enabled and b.o_timer.fill == 360)
    local a1 = b.o_timer.color and b.o_timer.color.w
    hud.update(b, 0.2)
    local a2 = b.o_timer.color and b.o_timer.color.w
    ok("...breathing rather than frozen", a1 ~= a2)
end

----------------------------------------------------------------------
print("WITH NO GRACE WINDOW IT GOES STRAIGHT TO THE ALARM")
----------------------------------------------------------------------
-- Offline and chamber turns pass no grace: there is nobody to reconnect, so
-- waiting a second full round would be waiting for nothing.
do
    local b = board()
    hud.start_timer(b, true, 30, NOW() - 1000, 0)
    check("no grace phase", b.timer_grace, false)
    check("the alarm, immediately", b.timer_expired, true)
    near("full ring", b.p_timer.fill, 360)
end

----------------------------------------------------------------------
print("AND A FRESH DEADLINE CLEARS IT AGAIN")
----------------------------------------------------------------------
-- The correction costs nothing: the server's next state calls this with a real
-- deadline and both latches drop at the top of the function.
do
    local b = board()
    hud.start_timer(b, true, 35, NOW() - 60000, 10)
    ok("latched", b.timer_grace)

    hud.start_timer(b, true, 35, NOW() + 35000, 10)
    check("the latch is dropped", b.timer_grace, false)
    check("...and so is the alarm", b.timer_expired, false)
    near("and it counts a whole turn again", b.p_timer.fill, 360)
    ok("...from a real remaining time", b.timer_remaining > 34)
    check("the borrowed label is given back",
        gui.get_text(b.o_avatar_name), "OPPONENT")
end

----------------------------------------------------------------------
print("ZERO EXPIRES-AT STILL MEANS 'A WHOLE TURN', NOT 'SPENT'")
----------------------------------------------------------------------
-- online_handler sends expires_at = 0 for the opponent's turn: it means "no
-- deadline given", and reading it as a lapsed one would put every opponent
-- turn into the red alarm.
do
    local b = board()
    hud.start_timer(b, false, 35, 0, 10)
    check("not spent", b.timer_expired, false)
    check("...nor in grace", b.timer_grace, false)
    near("a full ring, counting", b.o_timer.fill, 360)
    ok("with a whole turn on it", b.timer_remaining > 34)
end

----------------------------------------------------------------------
print("AND STOPPING STILL STOPS IT")
----------------------------------------------------------------------
-- The latches re-enable the ring every frame, so a teardown that left one set
-- would strand a pulsing timer over whatever screen came next.
do
    local b = board()
    hud.start_timer(b, true, 35, NOW() - 60000, 10)
    hud.stop_timers(b)
    ok("both rings are down", b.p_timer.enabled == false and b.o_timer.enabled == false)
    ok("...with nothing latched to bring them back",
        b.timer_grace == false and b.timer_expired == false)
    hud.update(b, 1.0)
    ok("...and a frame later they are still down",
        b.p_timer.enabled == false and b.o_timer.enabled == false)
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
