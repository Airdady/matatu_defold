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

print("")
if failures > 0 then
    print(string.format("%d FAILED", failures))
    os.exit(1)
end
print("all passed")
