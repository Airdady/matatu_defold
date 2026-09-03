-- WHAT A WIN RATE IS WORTH, SAID IN A WORD RATHER THAN A NUMBER.
--
-- Every surface that showed an opponent's standing showed it as "WR 48%", and
-- a percentage is the wrong shape for the glance it gets. It arrives on a strip
-- that is on screen for ten seconds, next to a decision to accept or decline,
-- and it asks the player to hold four tiers of context in their head to know
-- whether 48 is good. Nobody does that in ten seconds; they read the number,
-- learn nothing from it, and press ACCEPT anyway.
--
-- A tier says the same thing in one word and one colour: BEGINNER, PRO, MASTER,
-- GRANDMASTER. The bands are fixed, so the same player wears the same badge
-- everywhere, and the colour carries the meaning even when the word is too
-- small to read at arm's length.
--
-- WHY THIS IS A MODULE.
--
-- Five surfaces ask the question — the incoming dialog, the outgoing dialog,
-- the online screen's inline invite strip, the global overlay's strip, and the
-- game-over panel. modules/championship.lua exists for exactly the same reason
-- (one tournament must not be a championship on one screen and an ordinary
-- match on the next), and this follows it: one table of bands, one table of
-- colours, one width rule, called from everywhere.
--
-- NO vmath IN HERE, deliberately. championship.lua is runnable under plain Lua
-- so its rules can be tested without booting a gui_script, and the tests in
-- tools/ depend on that. Colours are therefore plain {r, g, b, a} arrays and
-- M.v4() turns one into a vmath.vector4 at the call site, inside Defold.
local M = {}

-- THE BANDS.
--
-- Written as the product asked for them — inclusive min, inclusive max — even
-- though the lookup below only ever reads `min`. The max is kept because it is
-- what makes the table readable as a specification, and because the tests
-- assert the two ends of every band.
--
-- Note the gaps: 44.9 to 45.0, 49.9 to 50.0, 54.9 to 55.0. A win rate of 44.95
-- falls in none of them. Selecting by "the highest band whose min it clears"
-- closes those gaps downward rather than answering nil for a real rate — see
-- M.tier.
--
-- THE NAMES ARE A LADDER, NOT A THESAURUS.
--
-- They were AMATEUR / CONTENDER / PRO / LEGEND, which mixes two vocabularies:
-- CONTENDER is boxing, LEGEND is marketing, and neither tells a player what
-- comes next. These are the ranks a card player already knows, and each one
-- plainly outranks the one below it — which is the only job a tier name has.
--
-- PRO moved DOWN a band to make room. That is deliberate: a player sitting at
-- 52% who was PRO yesterday is MASTER today, so nobody was demoted by the
-- rename.
--
-- The floor is BEGINNER rather than AMATEUR. Same band, same colour, same
-- players — but AMATEUR is a judgement about somebody who may simply be new,
-- and this is the badge a player wears for their first several games. BEGINNER
-- says where they are on the ladder instead of how good they are not.
--
-- The word is only half the change: the server stores this tier as a column
-- (services/playerTier.ts), so accounts written before the rename still say
-- AMATEUR until User.ts's ensureSkillTierRenamed sweeps them at boot.
M.TIERS = {
    { key = "beginner",    label = "BEGINNER",    min = 0.0,  max = 44.9  },
    { key = "pro",         label = "PRO",         min = 45.0, max = 49.9  },
    -- GRANDMASTER STARTS AT 54, NOT 55, and MASTER ends one point earlier to
    -- match. Lowered deliberately: the top band was narrow enough that players
    -- on 54-point-something wore MASTER while beating most of the people they
    -- met. Nothing else about the ladder moves.
    --
    -- services/rankTier.ts on the server carries the same table and was
    -- changed with this. The two must not drift — a player badged GRANDMASTER
    -- here who is matched as a MASTER there is a bug invisible from either
    -- side alone.
    { key = "master",      label = "MASTER",      min = 50.0, max = 53.9  },
    { key = "grandmaster", label = "GRANDMASTER", min = 54.0, max = 100.0 },
}

-- THE COLOURS, AND WHY THEY ARE NOT A RED-TO-GREEN RAMP.
--
-- The thing being coloured is the OPPONENT's standing, and red-amber-green is
-- already spoken for on these surfaces: the H2H form squares are green for a
-- win and red for a loss, and the countdown bar goes red as it runs out. A
-- second red on the same strip meaning "this player is weak" would collide with
-- both.
--
-- So it climbs cool-to-warm instead, the way rank colours do everywhere else:
-- slate, blue, teal, gold. Gold is the only one with dark text on it, because
-- it is the only one bright enough that light text on it would not read — and
-- being the odd one out is the point at the top of a ladder.
M.COLORS = {
    beginner     = { bg = { 0.30, 0.34, 0.40, 1.00 }, tx = { 0.84, 0.88, 0.94, 1.00 } },
    pro         = { bg = { 0.16, 0.42, 0.72, 1.00 }, tx = { 0.92, 0.96, 1.00, 1.00 } },
    master      = { bg = { 0.06, 0.55, 0.45, 1.00 }, tx = { 0.90, 1.00, 0.97, 1.00 } },
    grandmaster = { bg = { 0.95, 0.72, 0.10, 1.00 }, tx = { 0.16, 0.10, 0.00, 1.00 } },
}

--- The colours for a tier named by WORD, as the server sends it.
--
-- WHY THIS EXISTS AND IS NOT JUST A TABLE LOOKUP.
--
-- The bands above are keyed the way the CLIENT names them, and the client
-- renamed its bottom band to BEGINNER. The SERVER's enum did not move with it:
-- services/playerTier.ts still stores and sends AMATEUR, and it is the word
-- that arrives on every online-list row and every search-roster entry.
--
-- A plain COLORS[word:lower()] therefore returns nil for the single most
-- common tier there is, and the badge silently vanishes for most players —
-- the exact drift playerTier.ts's own header warns about, arriving from the
-- one direction it did not think to guard.
--
-- So the old name is accepted as an alias. Aliasing rather than renaming
-- either end is deliberate: the server's value is already stored on live
-- accounts, and a client that only understood the new word would badge
-- nobody until every one of them was rewritten.
--
-- nil in, nil out, and nil for a word from neither vocabulary — callers draw
-- nothing rather than guessing, the same rule M.tier follows.
M.ALIASES = {
    amateur = "beginner",   -- be_matatu services/playerTier.ts SkillTier
}

function M.colors_for(tier_word)
    if tier_word == nil then return nil end
    local key = string.lower(tostring(tier_word))
    key = M.ALIASES[key] or key
    local c = M.COLORS[key]
    if not c then return nil end
    return { key = key, bg = c.bg, tx = c.tx }
end

--- The tier a win rate falls in, or nil when there is no win rate to read.
--
-- nil in, nil out — and the callers all draw nothing for nil rather than
-- guessing BEGINNER. A player the server sent no rating for has not been shown
-- to be bad at this; badging them as the bottom tier would be inventing a fact
-- about a stranger, and it would fire for every player on a build whose server
-- does not send ratings at all.
--
-- Zero, on the other hand, IS a win rate: a player with games played and no
-- wins is a BEGINNER, and that must not be confused with "unknown".
--
-- Returns a fresh flat table rather than a reference into M.TIERS, so a caller
-- that stores it cannot mutate the band definitions for everybody else.
function M.tier(winrate)
    local wr = tonumber(winrate)
    if not wr then return nil end

    -- Scan downward and take the first band it clears. Bands are contiguous by
    -- this rule even where their written maxima leave a tenth of a point
    -- between them, and anything above 100 or below 0 lands on an end band
    -- rather than falling off the table.
    local found = M.TIERS[1]
    for i = #M.TIERS, 1, -1 do
        if wr >= M.TIERS[i].min then found = M.TIERS[i]; break end
    end

    local col = M.COLORS[found.key]
    return {
        key   = found.key,
        label = found.label,
        min   = found.min,
        max   = found.max,
        bg    = col.bg,
        tx    = col.tx,
    }
end

--- The tier's label, or nil. Shorthand for the common case.
function M.label(winrate)
    local t = M.tier(winrate)
    return t and t.label or nil
end

-- HOW WIDE THE PILL HAS TO BE.
--
-- Nothing in the Defold GUI measures text at build time, so a pill is sized
-- from its character count — the same rule, and the same 11px figure, that
-- championship.badge_width uses. That is not a coincidence to be tidied away:
-- the rank pill and the CHAMPIONSHIP / KNOCKOUT / BATTLE pill appear on the
-- same invite strip, at the same height, in the same font, and two different
-- width rules would show up immediately as two different paddings.
--
-- The floor is lower than championship's 66 because the shortest label here is
-- PRO, and a three-letter word in a 66px pill is mostly padding.
--
-- PAD_X IS THE BUG THIS FIXES. The width was the character estimate and
-- nothing else, so the word ran to both edges of its own pill: at 11px a
-- character the estimate is close enough to the real glyph run that there was
-- no gap left over, and every badge read as text with a coloured rectangle
-- jammed against it. The padding is added on both sides, so it is 2 * PAD_X in
-- total, and the floor still applies underneath — a short label gets the wider
-- of "its text plus padding" and MIN_W rather than one or the other.
--
-- IT WAS 8, AND 8 IS TOO MUCH HERE. That figure was chosen against AMATEUR and
-- PRO; the longest labels are GRANDMASTER at eleven characters and now
-- BEGINNER at eight, and 16px of padding on top of an eleven-character
-- estimate makes a pill wide enough to push the head-to-head block along the
-- invite strip. 5 keeps a visible gap either side of the word — which is all
-- the padding was ever for — and takes 6px off every pill: GRANDMASTER goes
-- 137 -> 131, and BEGINNER lands at 98 against AMATEUR's old 93, so the extra
-- letter costs 5px rather than the 11 it would have.
M.CHAR_W = 11
M.PAD_X  = 5
M.MIN_W  = 52

function M.width(label)
    local w = #tostring(label or "") * M.CHAR_W + 2 * M.PAD_X
    return w > M.MIN_W and w or M.MIN_W
end

--- The pill width for a win rate directly, or 0 when there is no badge to draw.
function M.badge_width(winrate)
    local t = M.tier(winrate)
    return t and M.width(t.label) or 0
end

--- Draw the pill, centred on (x, y), and return the width it took.
--
-- Takes the same shape of ctx modules/champ_banner.lua takes — a node tracker
-- and the ui module — for the same reason: four of the five surfaces that draw
-- this badge live in gui_scripts that each keep their own node list, and none
-- of them should have to know how a rank pill is put together. Returns 0 and
-- draws nothing when there is no rating, so a caller can lay out around it with
-- one number whether or not it appeared.
--
-- The game-over panel does NOT use this: it scales every label from a native
-- font size of its own (see its FONT_BASE) rather than drawing at the atlas
-- size, so it builds the two nodes itself from M.tier and M.width.
function M.draw(ctx, winrate, x, y, h, a)
    local t = M.tier(winrate)
    if not t then return 0 end
    local w = M.width(t.label)
    ctx.track(ctx.ui.box(vmath.vector3(x, y, 0), vmath.vector3(w, h or 22, 0), M.v4(t.bg, a)))
    ctx.track(ctx.ui.text(vmath.vector3(x, y, 0), t.label, "small", M.v4(t.tx, a)))
    return w
end

--- A colour array as a vmath.vector4, optionally faded.
--
-- Only ever called from inside a gui_script, which is why the module can stay
-- vmath-free for the tests: nothing at require time touches it.
function M.v4(c, a)
    return vmath.vector4(c[1], c[2], c[3], c[4] * (a or 1))
end

return M
