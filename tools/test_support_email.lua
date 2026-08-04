-- SUPPORT IS EMAIL, EXCLUSIVELY.
--
--   Run: lua tools/test_support_email.lua
--
-- Migrated off WhatsApp. The note being replaced argued for WhatsApp on a real
-- ground — a mailto: link opens nothing at all on a phone with no mail client
-- configured, and the tap looks like a dead button — so the address is also
-- SHOWN, not only linked. That is the part worth pinning: the link is the
-- convenience, the visible address is the guarantee.
local dir = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local function slurp(rel)
    local f = assert(io.open(dir .. "../" .. rel, "r"))
    local s = f:read("*a"); f:close(); return s
end

local failures = 0
local function check(label, cond, why)
    if cond then print("  PASS " .. label)
    else failures = failures + 1; print("  FAIL " .. label .. (why and ("  <- " .. why) or "")) end
end

local cfg   = slurp("modules/config.lua")
local lobby = slurp("main/lobby.gui_script")
-- Assertions about behaviour read code, not the prose explaining it — this
-- file's own comments mention WhatsApp throughout.
local function code(s) return (s:gsub("%-%-[^\n]*", "")) end
local cfg_code, lobby_code = code(cfg), code(lobby)

print("")
print("THE ADDRESS IS CONFIGURED, AND THE NUMBER IS GONE")
check("there is a support email", cfg_code:match('M%.SUPPORT_EMAIL%s*=%s*"[^"]+@[^"]+"'))
check("and a display form of it", cfg_code:match('M%.SUPPORT_EMAIL_DISPLAY%s*=%s*"[^"]+"'))
check("the WhatsApp support number is gone",
    not cfg_code:find("SUPPORT_WHATSAPP", 1, true),
    "a constant nothing reads is the next person's confusion")

print("")
print("CONTACT OPENS MAIL")
local contact = lobby_code:match('elseif b%.id == "contact_open" then(.-)elseif b%.id ==') or ""
check("contact builds a mailto:", contact:find('"mailto:"', 1, true))
check("addressed from config, not hardcoded",
    contact:find("config%.SUPPORT_EMAIL"))
check("with a subject and a body", contact:find("?subject=", 1, true) and contact:find("&body=", 1, true))
check("and it does NOT open wa.me",
    not contact:find("wa.me", 1, true),
    "support has moved; a second channel is a channel nobody watches")
check("the diagnostic block survives the move",
    contact:find("Account ID: ", 1, true) and contact:find("config%.APP_VERSION"),
    "support still needs to know who is writing")

print("")
print("AND THE ADDRESS IS READABLE EVEN IF THE LINK DOES NOTHING")
check("the address is shown on screen too",
    contact:find("toast%.info") and contact:find("SUPPORT_EMAIL_DISPLAY"),
    "a mailto: on a phone with no mail client is a button that does nothing")
check("shown BEFORE the link is attempted",
    (contact:find("toast%.info") or math.huge) < (contact:find("sys%.open_url") or 0),
    "after open_url, a client that takes over the screen means it is never seen")

print("")
print("THE BODY IS ENCODED FOR MAIL, NOT FOR WHATSAPP")
-- The previous encoder deliberately STRIPPED the CR, because WhatsApp drew it
-- as a visible box. Mail wants the opposite: RFC 6068 says a mailto body is
-- CRLF, and a bare LF arrives as one run-on line in some clients.
local enc = lobby_code:match("local function url_encode%(str%)(.-)\nend") or ""
check("newlines become CRLF", enc:find('gsub%("\\n", "\\r\\n"%)'))
check("and everything unsafe is percent-encoded", enc:find("%%%%%%02X"))

print("")
if failures > 0 then print(string.format("%d FAILED", failures)); os.exit(1) end
print("all passed")
