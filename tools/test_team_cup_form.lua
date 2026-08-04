-- THE TEAM CUP FORM: AN ENTRY FEE, AND AN EDIT THAT REMEMBERS EVERYTHING.
--
--   Run: lua tools/test_team_cup_form.lua
--
-- Two asks.
--
-- 1. An entry fee checkbox on CREATE. Tick it, set an amount, and players pay
--    that to join. It was never built.
--
-- 2. The UPDATE form should open pre-populated with what the cup actually is,
--    including the members already added.
--
-- The second one matters more than it looks. This form SAVES every field it
-- holds on every save — so a field the seed does not restore is not merely
-- displayed wrong, it is silently overwritten with its default by the act of
-- editing something else. owner_plays was exactly that: never seeded, so an
-- owner who had opted into their own cup found the box unticked every time
-- they opened it, and saving to add a member quietly took them off the bracket
-- they had built.
--
-- The form is a hand-drawn Defold GUI that needs the whole engine to run, so
-- this reads its source. The fee arithmetic is exercised directly.

local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local f = assert(io.open(dir .. "../main/team_tournament.gui_script", "r"))
local src = f:read("*a"); f:close()

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

print("the create form offers an entry fee")
check_true("there is a checkbox for it",
    src:find('checkbox%(self, "fee_toggle"') ~= nil, "no fee checkbox on the form")
check_true("with an amount stepper behind it",
    src:find('btn%(self, "fee_minus"') and src:find('btn%(self, "fee_plus"'),
    "no way to set the amount")
check_true("shown only when the box is ticked",
    src:find("if f%.fee_on then") ~= nil, "the amount row should follow the checkbox")
check_true("and it says where the money goes",
    src:find("It goes into the prize") ~= nil,
    "a fee the player cannot reason about is a surprise charge")

print("")
print("and sends it")
check_true("on create", src:find("entryFee%s*= f%.fee_on and f%.fee or 0") ~= nil, "create payload")
check_true("on update", src:find("entryFee = f%.fee_on and f%.fee or 0") ~= nil, "update payload")
check_true("unticked sends 0, not the last amount typed",
    src:find("f%.fee_on and f%.fee or 0") ~= nil,
    "an untick must actually clear the charge")

print("")
print("the edit form opens as the cup actually is")
local seed = src:match("if type%(seed%) == \"table\" and seed%._id then(.-)\n        end")
check_true("the seed block exists", seed ~= nil, "no edit seeding")
for _, field in ipairs({
    { "name",        "f%.name%s*=" },
    { "grand prize", "f%.prize%s*=" },
    { "max players", "f%.max_players%s*=" },
    { "invite code", "f%.code%s*=" },
    { "games per level", "f%.gpl_i%s*=" },
    { "members already invited", "f%.existing%[#f%.existing %+ 1%]" },
    { "entry fee",   "f%.fee%s*=" },
    { "fee locked",  "f%.fee_locked%s*=" },
    { "owner plays", "f%.owner_plays%s*=" },
}) do
    check_true("restores " .. field[1], seed and seed:find(field[2]) ~= nil,
        "unseeded fields are SAVED as their defaults")
end

print("")
print("a fee already paid cannot be edited away")
check_true("the stepper is inert when locked",
    src:find("local fee_editable = not f%.fee_locked") ~= nil, "no lock on the stepper")
check_true("and it says why",
    src:find("Players have already paid") ~= nil, "silently inert is worse than refused")

print("")
print("ticked but empty is refused")
check_true("validate catches it",
    src:find("if f%.fee_on and f%.fee <= 0 then") ~= nil,
    "a cup that claims to charge and does not")

-- ── the fee arithmetic, run ────────────────────────────────────────────────
print("")
print("the stepper arithmetic")

local FEE_STEP = tonumber(src:match("local FEE_STEP = math%.max%(1, math%.floor%(PRIZE_STEP / (%d+)%)%)"))
check_true("the step is a fraction of the prize step, not the prize step",
    FEE_STEP == 10,
    "one player's entry is not the size of the whole pot")

-- Mirrors the handlers, so the clamping is exercised rather than described.
local STEP, MAX = 50, 1000000
local fee, fee_on = 0, false
local function toggle()
    fee_on = not fee_on
    if fee_on and fee <= 0 then fee = STEP end
    if not fee_on then fee = 0 end
end
local function minus() fee = math.max(0, fee - STEP) end
local function plus()  fee = math.min(MAX, fee + STEP) end

toggle()
check("ticking on opens at one step, not zero", fee, STEP)
plus(); plus()
check("plus adds a step", fee, STEP * 3)
minus()
check("minus takes one off", fee, STEP * 2)
for _ = 1, 10 do minus() end
check("and never goes below zero", fee, 0)
fee = MAX; plus()
check("nor above the server ceiling", fee, MAX)
fee = STEP * 4; toggle()
check("unticking clears the amount", fee, 0)
check("and the box is off", fee_on, false)

-- ── every control that changes something must repaint ──────────────────────
--
-- THE REPORTED BUG. The fee handlers changed f.fee_on / f.fee and then fell
-- straight to `return true` without asking for a redraw. The value moved in
-- memory, the screen never followed, and the box stayed unticked however many
-- times it was tapped — drawn, hittable, and repainting nothing. Which is
-- exactly what "looks disabled" describes.
--
-- Checked for EVERY value handler, not just the fee ones, because the failure
-- is invisible by reading: the handler looks complete and does its job.
print("")
print("every control repaints after it changes something")

local loop = src:match("for i = #self%.buttons, 1, %-1 do(.*)\n    end\n\n    %-%- A tap that hit nothing")
check_true("the tap loop was found", loop ~= nil, "cannot check handlers without it")

-- Slice the if/elseif chain into one branch per id.
local branches = {}
if loop then
    local ids = {}
    for id in loop:gmatch('b%.id == "([%w_]+)"') do ids[#ids + 1] = id end
    for i, id in ipairs(ids) do
        local from = loop:find('b%.id == "' .. id .. '"')
        local to = ids[i + 1] and loop:find('b%.id == "' .. ids[i + 1] .. '"') or #loop
        branches[id] = loop:sub(from, to)
    end
end

-- Handlers that CHANGE state the form draws. Each must repaint, by rebuilding
-- now or marking for this frame's redraw.
for _, id in ipairs({ "fee_toggle", "fee_minus", "fee_plus", "owner_plays",
                      "prize_minus", "prize_plus", "players_minus", "players_plus",
                      "gpl", "invite_del" }) do
    local b = branches[id]
    check_true(id .. " repaints",
        b and (b:find("mark_dirty%(self%)") or b:find("rebuild%(self%)")),
        "changes a value the form displays but never redraws — the control looks dead")
end

print("")
print("and typing does not rebuild the whole form per character")
check_true("the text handler marks instead of rebuilding",
    src:match('if action_id == hash%("text"%) then(.-)return true'):find("mark_dirty%(self%)"),
    "rebuild() deletes and recreates every node; per keystroke that is the lag")
check_true("so does held backspace",
    src:match('hash%("backspace"%).-then(.-)return true'):find("mark_dirty%(self%)"),
    "key repeat fires every frame")
check_true("and the redraw is drained once a frame",
    src:find("if self%._dirty then rebuild%(self%) end") ~= nil,
    "marking without draining means it never repaints at all")
check_true("rebuild clears the flag it is draining",
    src:match("local function rebuild%(self%)(.-)clear%(self%)"):find("self%._dirty = false"),
    "otherwise every frame rebuilds forever")

-- ── step 1 will not let you past a bad form ────────────────────────────────
print("")
print("step 1 refuses to advance when it is not valid")

local vs = src:match("local function validate_settings%(self%)(.-)\nend")
check_true("the settings validator exists", vs ~= nil, "no step-1 validation")
for _, rule in ipairs({
    { "a prize is required",        "A grand prize amount is required" },
    { "affordable",                 "Insufficient balance" },
    { "code length",                "Invite code must be" },
    { "code characters",            "letters and numbers" },
    { "player count in range",      "Players must be between" },
    { "fee ticked but empty",       "untick it for a free cup" },
    { "fee not above the prize",    "more than the whole prize" },
    { "room for everyone invited",  "raise the max above" },
}) do
    check_true("checks " .. rule[1], vs and vs:find(rule[2], 1, true) ~= nil, rule[2])
end

local nxt = src:match('b%.id == "step_next" then(.-)elseif')
check_true("NEXT runs it",
    nxt and nxt:find("validate_settings%(self%)"), "no check before advancing")
check_true("and does NOT advance when it fails",
    nxt and nxt:match("if err then(.-)else"):find("set_msg")
        and not nxt:match("if err then(.-)else"):find("f%.step = 2"),
    "the step must stay put on an error")
check_true("advancing only happens in the else",
    nxt and nxt:match("else(.-)end"):find("f%.step = 2"), "advance is unguarded")

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
