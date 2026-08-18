-- THE SMALLEST AMOUNT A WITHDRAWAL CAN BE, AND WHY THE CLIENT HAS TO KNOW IT.
--
-- Reported: a player tried to withdraw 1200 and had their account SUSPENDED for
-- a high win rate. 1200 is below the smallest tier the payment provider will
-- carry — the request could never have succeeded under any circumstances — so
-- the only thing that should ever have happened is a one-line refusal.
--
-- The backend now checks the amount before it checks the player (see
-- be_matatu's withdrawMoney and sendPayment). This is the near half: a request
-- that cannot succeed should not leave the handset at all.
--
-- WHY method.min WAS NOT ENOUGH
--
-- The screen gated on `amount >= method.min`, taken straight from the payments
-- config the server sends. Two ways that lets a doomed amount through:
--
--   the field is absent   `tonumber(nil) or 0` is 0, so EVERY amount passes
--   the field is wrong    nothing reconciles it against the fee tiers sitting
--                         right beside it in the same config
--
-- The tiers are the authoritative structure — they are the table the provider
-- actually prices against, and the backend derives its own floor from exactly
-- the same shape. So the floor is the STRICTER of the two: the declared
-- minimum and the lowest tier. A config that forgets one is still held to the
-- other.
--
-- Pure and separate from payments.gui_script because that file needs the Defold
-- engine to load, and "is this amount withdrawable" is a claim worth proving.

local M = {}

local function num(v)
    local n = tonumber(v)
    return (n and n > 0) and n or 0
end

--- Is this a withdrawal (SELL / WITHDRAW), as opposed to a deposit?
--
-- The floor below only applies to money going OUT. A deposit has its own
-- minimum and no fee tiers to reconcile against.
function M.is_withdraw(method)
    local t = tostring((type(method) == "table" and method.type) or ""):upper()
    return t:find("SELL") ~= nil or t:find("WITHDRAW") ~= nil
end

--- The lowest amount any fee tier will carry, or 0 if there are no tiers.
function M.tier_floor(method)
    if type(method) ~= "table" or type(method.charges) ~= "table" then return 0 end
    local lowest = nil
    for _, tier in ipairs(method.charges) do
        local mn = num(tier and tier.min)
        if mn > 0 and (lowest == nil or mn < lowest) then lowest = mn end
    end
    return lowest or 0
end

--- The smallest amount this method will accept.
--
-- The stricter of the declared minimum and the lowest fee tier, so a config
-- missing either one is still held to the other. A deposit is judged on its
-- declared minimum alone — its `charges` are a flat fee table, not a ladder of
-- withdrawable bands, and reading a floor out of them would refuse deposits
-- the server is happy to take.
function M.minimum(method)
    local declared = num(type(method) == "table" and method.min or nil)
    if not M.is_withdraw(method) then return declared end
    local floor = M.tier_floor(method)
    return (floor > declared) and floor or declared
end

--- May this amount be submitted, and if not, what should the player be told?
--
-- Returns ok, message. The message is the whole point of this returning a
-- reason at all: below the minimum the PAY button used to do NOTHING — no
-- toast, no text, no state change — because the branch that would have
-- explained it did not exist. A player tapping a button that silently ignores
-- them concludes the app is broken, which is worse than the refusal.
function M.check(method, amount, commas)
    local amt = tonumber(amount) or 0
    local min = M.minimum(method)
    local fmt = commas or tostring

    if amt <= 0 then
        return false, "Enter an amount first."
    end
    if min > 0 and amt < min then
        local what = M.is_withdraw(method) and "withdraw" or "buy"
        return false, "The minimum you can " .. what .. " is " .. fmt(min) .. "."
    end
    return true, nil
end

return M
