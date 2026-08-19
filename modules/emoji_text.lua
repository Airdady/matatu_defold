-- emoji_text.lua — split a UTF-8 string into text and emoji, so the marquee
-- can DRAW an emoji instead of the server having to delete it.
--
-- THE PROBLEM THIS EXISTS FOR
--
-- None of fonts/*.font carries emoji glyphs. They are Latin display
-- typefaces built with `all_chars: false`, so Defold falls back to the
-- source TTF's .notdef for anything outside their character set, and .notdef
-- in these faces renders as "~". A single trophy emoji in an announcement
-- therefore arrived on the handset as a tilde, and the backend's answer (see
-- be_matatu's stripEmoji) was to delete every emoji before it was ever sent.
--
-- That is the right call for a font. It is the wrong call for the winners
-- banner, where the ONE thing worth showing next to a name is which country
-- the player is from — and a country, written down, is a flag emoji.
--
-- Worse, flags were the one class stripEmoji did NOT catch. A flag is a pair
-- of regional indicator symbols, and those are not Extended_Pictographic, so
-- the server's guard let them through and they drew as two tildes: the exact
-- failure the guard existed to prevent, produced by the only thing it
-- missed.
--
-- WHAT THIS DOES INSTEAD
--
-- Emoji are not text here, they are pictures, and this module is what tells
-- the two apart. It walks the bytes, decodes codepoints itself (Lua 5.1
-- ships no utf8 library, and Defold builds Lua 5.1 on some targets — see the
-- `goto` incident in online.gui_script), and returns segments:
--
--   { type = "text",  value = "..." }
--   { type = "emoji", kind = "flag",   code  = "UG" }
--   { type = "emoji", kind = "sprite", atlas = "emojis", anim = "partying_face" }
--
-- A renderer draws flags with modules/flag_art and sprites from the emojis
-- atlas. An emoji we have no picture for is DROPPED, which is exactly what
-- the backend used to do for all of them — so the worst case is the old
-- behaviour, never a tilde.
--
-- FLAGS ARE PAIRS, NOT CHARACTERS
--
-- 🇺🇬 is not one codepoint. It is two REGIONAL INDICATOR SYMBOLS, U+1F1FA
-- (U) and U+1F1EC (G), which the platform's own font renders as a flag by
-- ligature. Nothing in a bitmap font will ever do that, which is another
-- reason flags have to be drawn rather than typed. Two consecutive
-- indicators are read here as a country code; a lone one is dropped.
--
-- Pure: no `gui`, no `sys`, no Defold anything. tools/test_emoji_text.lua
-- runs it under stock Lua.

local M = {}

-- ---------------------------------------------------------------------------
-- UTF-8
-- ---------------------------------------------------------------------------

-- Decode the codepoint starting at byte `i`. Returns the codepoint and the
-- index of the next one.
--
-- MALFORMED INPUT IS PASSED THROUGH, NOT REJECTED. A truncated sequence or a
-- stray continuation byte yields the raw byte and advances one — this runs on
-- server-supplied strings and a username with one bad byte in it must still
-- reach the screen, minus that byte's worth of nonsense.
function M.decode(s, i)
    local b = s:byte(i)
    if not b then return nil, i end
    if b < 0x80 then return b, i + 1 end

    local extra, cp
    if b >= 0xF0 then extra, cp = 3, b % 0x08
    elseif b >= 0xE0 then extra, cp = 2, b % 0x10
    elseif b >= 0xC0 then extra, cp = 1, b % 0x20
    else return b, i + 1 end -- continuation byte with no lead: raw

    for k = 1, extra do
        local c = s:byte(i + k)
        if not c or c < 0x80 or c > 0xBF then return b, i + 1 end
        cp = cp * 0x40 + (c % 0x40)
    end
    return cp, i + extra + 1
end

-- ---------------------------------------------------------------------------
-- What counts as an emoji
-- ---------------------------------------------------------------------------
--
-- Deliberately WIDER than the set we can draw. Anything matched here is
-- removed from the text even when it has no picture, because the alternative
-- is a "~". The ranges are the pictographic blocks, plus the joiners and
-- selectors that glue sequences together.
--
-- NOT included, on purpose: •, —, ×, and the currency signs. Those are
-- ordinary punctuation the UI already uses and the fonts already carry.
local function is_pictographic(cp)
    return (cp >= 0x1F000 and cp <= 0x1FAFF)  -- emoji blocks proper
        or (cp >= 0x2600  and cp <= 0x27BF)   -- misc symbols, dingbats
        or (cp >= 0x2B00  and cp <= 0x2BFF)   -- misc symbols & arrows
        or (cp >= 0x1F1E6 and cp <= 0x1F1FF)  -- regional indicators
        or cp == 0x203C or cp == 0x2049       -- ‼ ⁉
        or cp == 0x00A9 or cp == 0x00AE or cp == 0x2122 -- © ® ™
end

-- Zero-width joiner, variation selectors, skin-tone modifiers, keycap. These
-- carry no picture of their own; they only ever modify a neighbour, and left
-- in the text they are more .notdef tildes.
local function is_modifier(cp)
    return cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F or cp == 0x20E3
        or (cp >= 0x1F3FB and cp <= 0x1F3FF)
end

local RI_BASE = 0x1F1E6 -- 🇦

-- ---------------------------------------------------------------------------
-- Which pictures we actually have
-- ---------------------------------------------------------------------------
--
-- Keyed by codepoint. The values name animations that exist in
-- assets/emojis/emojis.atlas — the same eight the in-game emoji popover
-- already uses (modules/emoji_popover.lua), so this adds no art.
--
-- Anything absent from this table is dropped silently. That is a feature: it
-- means the backend can send whatever it likes and the client degrades to
-- the old, safe behaviour instead of showing a fault.
M.SPRITES = {
    [0x1F602] = "face_with_tears_of_joy",        -- 😂
    [0x1F61B] = "face_with_tongue",              -- 😛
    [0x1F975] = "hot_face",                      -- 🥵
    [0x1F911] = "money_mouth_face",              -- 🤑
    [0x1F973] = "partying_face",                 -- 🥳
    [0x1F634] = "sleeping_face",                 -- 😴
    [0x1F44E] = "thumbs_down",                   -- 👎
    [0x1F44B] = "waving_hand_animated_default",  -- 👋
}

M.SPRITE_ATLAS = "emojis"

-- Countries with drawn flags (modules/flag_art). A regional-indicator pair
-- outside this set is dropped rather than drawn as a blank rectangle.
M.FLAGS = { UG = true, NG = true, KE = true }

-- ---------------------------------------------------------------------------
-- Splitting
-- ---------------------------------------------------------------------------

local function push_text(out, buf)
    if #buf > 0 then
        local s = table.concat(buf)
        if #s > 0 then out[#out + 1] = { type = "text", value = s } end
        for k = #buf, 1, -1 do buf[k] = nil end
    end
end

--- Split `str` into text and emoji segments.
---
--- Also understands the explicit escape `{{f:XX}}` — a flag by country code,
--- for any producer that cannot put raw UTF-8 into the payload (or any log
--- pipeline between here and there that mangles it). Both spellings land on
--- the same segment, so the marquee does not care which one the server sent.
function M.split(str)
    local out, buf = {}, {}
    local s = tostring(str or "")
    local i, n = 1, #s

    while i <= n do
        -- {{f:UG}} — checked before decoding, since it is plain ASCII.
        local f_s, f_e, f_code = s:find("^%{%{f:(%a%a)%}%}", i)
        if f_s then
            local code = f_code:upper()
            if M.FLAGS[code] then
                push_text(out, buf)
                out[#out + 1] = { type = "emoji", kind = "flag", code = code }
            end
            i = f_e + 1
        else
            local cp, nxt = M.decode(s, i)
            if not cp then break end

            if cp >= RI_BASE and cp <= 0x1F1FF then
                -- A flag is a PAIR. Peek at the next codepoint and only
                -- consume it if it is an indicator too; a lone indicator is
                -- not a country and is dropped with everything else we
                -- cannot draw.
                local cp2, nxt2 = M.decode(s, nxt)
                if cp2 and cp2 >= RI_BASE and cp2 <= 0x1F1FF then
                    local code = string.char(65 + (cp - RI_BASE))
                             .. string.char(65 + (cp2 - RI_BASE))
                    if M.FLAGS[code] then
                        push_text(out, buf)
                        out[#out + 1] = { type = "emoji", kind = "flag", code = code }
                    end
                    i = nxt2
                else
                    i = nxt
                end
            elseif is_modifier(cp) then
                i = nxt
            elseif is_pictographic(cp) then
                local anim = M.SPRITES[cp]
                if anim then
                    push_text(out, buf)
                    out[#out + 1] = {
                        type = "emoji", kind = "sprite",
                        atlas = M.SPRITE_ATLAS, anim = anim,
                    }
                end
                i = nxt
            else
                buf[#buf + 1] = s:sub(i, nxt - 1)
                i = nxt
            end
        end
    end

    push_text(out, buf)
    return out
end

--- Everything this module would draw, thrown away — the plain-text reading of
--- a string. Used where there is no renderer to hand (a log line, a node that
--- must stay a single text node) and the old delete-it-all behaviour is still
--- the right one.
function M.strip(str)
    local parts = {}
    for _, seg in ipairs(M.split(str)) do
        if seg.type == "text" then parts[#parts + 1] = seg.value end
    end
    -- An emoji sitting between two words leaves a double space behind, the
    -- same collapse the backend's stripEmoji does for the same reason.
    return (table.concat(parts):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Does this string contain anything we would draw as a picture?
function M.has_emoji(str)
    for _, seg in ipairs(M.split(str)) do
        if seg.type == "emoji" then return true end
    end
    return false
end

return M
