-- THE ONE EMOJI THE SERVER'S EMOJI GUARD NEVER CAUGHT.
--
--   Run: lua tools/test_emoji_text.lua
--
-- The weekly winners marquee wants to say which country each champion is
-- from. A country, written down, is a flag emoji — and none of fonts/*.font
-- has a glyph for one, so Defold draws the missing glyph, which in these
-- faces is "~".
--
-- be_matatu's stripEmoji was supposed to be the guard against that. It never
-- caught a flag: a flag is a PAIR of regional indicator symbols, and those
-- are not Extended_Pictographic, so the one emoji class the banner actually
-- needed was also the only one that slipped through and drew as tildes.
--
-- modules/emoji_text.lua moves the decision to the client and changes what
-- it is. An emoji is not text to be typed; it is a picture to be drawn.
-- Flags come from modules/flag_art (geometry, not artwork — three of the
-- world's flags are stripes), the eight faces already in the emojis atlas
-- come from there, and anything with no picture is dropped exactly as before.
--
-- What is checked here:
--   * UTF-8 decoding, done by hand because Lua 5.1 has no utf8 library
--   * a flag is a PAIR of regional indicators, and a lone one is not a flag
--   * emoji we can draw survive; emoji we cannot are removed, never "~"
--   * modifiers (ZWJ, variation selectors, skin tones) never reach the text
--   * {{f:UG}} and the raw 🇺🇬 produce the same segment
--   * flag_art's parts are in unit space and drop their emblem when small

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

for name in pairs(package.loaded) do
    if name:match("^modules%.") then package.loaded[name] = nil end
end
package.path = ROOT .. "?.lua;" .. package.path

local E = require("modules.emoji_text")
local FA = require("modules.flag_art")

-- Raw UTF-8 for the three flags, spelled out in bytes so this file does not
-- depend on the editor that saved it having preserved them.
local function ri(letter)
    -- U+1F1E6 + (letter - 'A'), encoded as 4-byte UTF-8.
    local cp = 0x1F1E6 + (string.byte(letter) - 65)
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end
local FLAG_UG = ri("U") .. ri("G")
local FLAG_NG = ri("N") .. ri("G")
local FLAG_KE = ri("K") .. ri("E")
local FLAG_ZW = ri("Z") .. ri("W") -- a real flag we have no picture for

-- 4-byte UTF-8 for an arbitrary codepoint, for the sprite cases.
local function u4(cp)
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end

local function kinds(segs)
    local out = {}
    for _, s in ipairs(segs) do
        out[#out + 1] = (s.type == "text") and ("t:" .. s.value) or (s.kind .. ":" .. (s.code or s.anim))
    end
    return table.concat(out, "|")
end

print("\n== UTF-8 decoding ==")
do
    local cp, nxt = E.decode("A", 1)
    check("ascii codepoint", cp, 65)
    check("ascii advances one byte", nxt, 2)

    cp, nxt = E.decode(FLAG_UG, 1)
    check("regional indicator U decodes", cp, 0x1F1FA)
    check("4-byte sequence advances four", nxt, 5)

    -- "é" as 2-byte UTF-8: a username can carry one and must survive.
    cp, nxt = E.decode("\195\169", 1)
    check("2-byte codepoint decodes", cp, 0xE9)
    check("2-byte advances two", nxt, 3)

    -- A truncated sequence must not hang or index past the end.
    cp, nxt = E.decode("\240\159", 1)
    check("truncated sequence yields raw byte", cp, 0xF0)
    check("truncated sequence still advances", nxt, 2)
end

print("\n== flags are pairs ==")
do
    check("UG flag becomes one flag segment", kinds(E.split(FLAG_UG)), "flag:UG")
    check("NG flag", kinds(E.split(FLAG_NG)), "flag:NG")
    check("KE flag", kinds(E.split(FLAG_KE)), "flag:KE")

    -- A country with no drawn flag is dropped, not rendered blank.
    check("unknown country dropped", kinds(E.split("a" .. FLAG_ZW .. "b")), "t:ab")

    -- A LONE indicator is not a country. It used to be tempting to map one
    -- letter to something; it means nothing on its own and must vanish.
    check("lone indicator dropped", kinds(E.split("x" .. ri("U") .. "y")), "t:xy")

    -- Two flags back to back must not consume each other's letters: the
    -- middle pair here (G,N) is NOT a flag, and reading greedily left to
    -- right is what keeps UG and NG intact.
    check("adjacent flags stay separate",
        kinds(E.split(FLAG_UG .. FLAG_NG)), "flag:UG|flag:NG")
end

print("\n== text is preserved around emoji ==")
do
    check("text before and after",
        kinds(E.split("1. " .. FLAG_UG .. " Ronny")), "t:1. |flag:UG|t: Ronny")
    check("plain text is one segment",
        kinds(E.split("no emoji here")), "t:no emoji here")
    check("empty string yields nothing", #E.split(""), 0)
    check("nil is not an error", #E.split(nil), 0)

    -- Currency and punctuation the UI already uses must NOT be treated as
    -- emoji — stripping "•" or "₦" would break every existing announcement.
    check("bullet survives", kinds(E.split("a \226\128\162 b")), "t:a \226\128\162 b")
    check("naira sign survives", kinds(E.split("\226\130\166 500")), "t:\226\130\166 500")
end

print("\n== sprites we have, and emoji we do not ==")
do
    check("partying face becomes a sprite",
        kinds(E.split(u4(0x1F973))), "sprite:partying_face")
    check("money mouth face becomes a sprite",
        kinds(E.split(u4(0x1F911))), "sprite:money_mouth_face")
    check("sprite carries its atlas", E.split(u4(0x1F973))[1].atlas, "emojis")

    -- 🏆 (U+1F3C6) is pictographic and we have no picture: it must be
    -- removed, because leaving it in is the tilde this whole module exists
    -- to stop.
    check("trophy with no sprite is dropped",
        kinds(E.split("top" .. u4(0x1F3C6) .. "ten")), "t:topten")
end

print("\n== modifiers never reach the text ==")
do
    -- Variation selector 16 after an emoji, and a bare ZWJ.
    local VS16 = "\239\184\143" -- U+FE0F
    local ZWJ  = "\226\128\141" -- U+200D
    check("variation selector dropped", kinds(E.split("a" .. VS16 .. "b")), "t:ab")
    check("zwj dropped", kinds(E.split("a" .. ZWJ .. "b")), "t:ab")
    check("skin tone dropped", kinds(E.split("a" .. u4(0x1F3FD) .. "b")), "t:ab")
end

print("\n== the {{f:XX}} escape is the same thing ==")
do
    check("escape becomes a flag segment", kinds(E.split("{{f:UG}}")), "flag:UG")
    check("escape is case insensitive", kinds(E.split("{{f:ng}}")), "flag:NG")
    check("escape and raw agree",
        kinds(E.split("{{f:KE}}")), kinds(E.split(FLAG_KE)))
    check("unknown escape country dropped", kinds(E.split("a{{f:ZW}}b")), "t:ab")
    -- The avatar token belongs to the announcement's own markup and must
    -- pass straight through untouched.
    check("avatar token untouched", kinds(E.split("{{a:5}}")), "t:{{a:5}}")
end

print("\n== strip() is the old behaviour, kept ==")
do
    check("strip removes a flag", E.strip("Ronny " .. FLAG_UG), "Ronny")
    check("strip collapses the gap left behind",
        E.strip("a " .. FLAG_UG .. " b"), "a b")
    check("strip leaves plain text alone", E.strip("plain text"), "plain text")
    check("has_emoji true for a flag", E.has_emoji(FLAG_NG), true)
    check("has_emoji false for plain text", E.has_emoji("nothing here"), false)
end

print("\n== flag_art geometry ==")
do
    check("UG resolves from a game name", FA.code("matatu"), "UG")
    check("NG resolves from a currency", FA.code("NGN"), "NG")
    check("KE resolves from a country name", FA.code("Kenya"), "KE")
    check("unknown code is nil", FA.code("Atlantis"), nil)
    check("nil input is nil", FA.code(nil), nil)

    check("nigeria has three bands", #FA.parts("NG"), 3)
    -- Nothing on Nigeria's flag is a detail, so a tiny draw keeps all three.
    check("nigeria keeps every band when small", #FA.parts("NG", 10), 3)

    check("uganda full has six bands, disc and crane", #FA.parts("UG"), 8)
    check("uganda drops the crane when small", #FA.parts("UG", 12), 7)
    check("kenya drops shield and spears when small", #FA.parts("KE", 12), 5)
    check("unknown flag draws nothing", #FA.parts("ZW"), 0)

    -- Every part must sit inside the unit box, or it draws outside the flag.
    local out_of_bounds = 0
    for code in pairs(FA.FLAGS) do
        for _, p in ipairs(FA.parts(code)) do
            if p.x < 0 or p.y < 0 or p.x + p.w > 1.0001 or p.y + p.h > 1.0001 then
                out_of_bounds = out_of_bounds + 1
            end
        end
    end
    check("no part escapes the unit box", out_of_bounds, 0)

    -- The stripes must actually cover the flag: a gap shows the background
    -- through, which on the marquee is the red ribbon.
    local ug_stripe_area = 0
    for _, p in ipairs(FA.parts("UG", 10)) do
        if p.kind == "rect" then ug_stripe_area = ug_stripe_area + p.w * p.h end
    end
    check("uganda's stripes tile the whole flag",
        math.abs(ug_stripe_area - 1) < 0.001, true)
end

print("")
if failures == 0 then
    print(string.format("ALL %d CHECKS PASSED", checks))
else
    print(string.format("%d of %d CHECKS FAILED", failures, checks))
    os.exit(1)
end
