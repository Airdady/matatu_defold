-- WHERE EVERYTHING SITS INSIDE A MODE TILE.
--
-- Pulled out of tiles.lua as plain arithmetic so the spacing can be checked
-- rather than eyeballed. Two things were wrong and neither was visible by
-- reading the code that produced them.
--
-- THE TAG ROW WAS SPACED FOR ONE WORD
--
-- The second tag was drawn at a fixed +55px from the first, whatever the first
-- one said. That is comfortable for "LIVE" and too narrow for "ONLINE" and
-- "OFFLINE", so "ONLINE TEAM" and "OFFLINE …" ran together while "LIVE MULTI
-- PLAYER" looked fine — which is why it read as a problem with one tile rather
-- than with the rule. The gap is now measured from the first tag.
--
-- THE STACK FLOATED OFF THE CENTRE
--
-- Every row was positioned relative to the tile's midpoint, so a taller tile
-- put ALL of its extra height above the title as dead space and none of it
-- where the content actually is. On the real lobby geometry that came to 116px
-- of nothing between the tag row and PLAY ONLINE, while at the bottom the
-- season deadline line ended up level with the PLAY NOW pill.
--
-- Anchoring the stack under the tag row instead means a taller tile spends its
-- extra room on the content, which is the whole reason PLAY ONLINE is the big
-- tile. The season block also gets a real gap above it rather than sharing the
-- subtitle's line spacing.
local M = {}

-- ── the tag row ─────────────────────────────────────────────────────────────

--- Space between the two tags. Not a full space character — these are separate
--- nodes in different colours and read as two labels, not one phrase.
M.TAG_GAP = 14

--- Fallback width per character at the "small" font.
---
--- Only used when gui.get_text_metrics_node is unavailable, which off a device
--- means the test harness. Deliberately a slight OVER-estimate: too wide only
--- pushes the second tag further right, while too narrow is the bug this
--- replaces.
M.EST_CHAR_W = 9

--- How wide the first tag is, measured if possible and estimated if not.
function M.tag_width(label, measured)
    if type(measured) == "number" and measured > 0 then return measured end
    return #tostring(label or "") * M.EST_CHAR_W
end

--- x for the second tag, given the first tag's x.
function M.second_tag_x(first_x, label, measured)
    return first_x + M.tag_width(label, measured) + M.TAG_GAP
end

-- ── the vertical stack ──────────────────────────────────────────────────────

M.TAG_DROP     = 28   -- tag row, below the tile's top edge
M.TITLE_DROP   = 52   -- title, below the tag row
M.SUB_DROP     = 34   -- subtitle, below the title
M.SEASON_GAP   = 52   -- SEASON ENDS IN, below the subtitle — its own gap, so
                      -- the countdown reads as a separate block and not as a
                      -- third line of the subtitle
M.SEASON_LINE  = 34   -- between the season block's own three lines
M.CTA_H        = 46
M.CTA_LIFT     = 50   -- CTA centre, above the tile's floor

--- Every y in the tile, top to bottom.
---
--- One function so the rows cannot drift apart: they were seven separate
--- expressions, each correct on its own, and the one that mattered — whether
--- the last line of the season block clears the CTA — was not written down
--- anywhere.
function M.rows(y, h)
    local top     = y + h / 2
    local bottom  = y - h / 2
    local tag     = top - M.TAG_DROP
    local title   = tag - M.TITLE_DROP
    local sub     = title - M.SUB_DROP
    local season  = sub - M.SEASON_GAP
    return {
        top             = top,
        bottom          = bottom,
        tag             = tag,
        title           = title,
        sub             = sub,
        season_label    = season,
        season_count    = season - M.SEASON_LINE,
        season_deadline = season - M.SEASON_LINE * 2,
        cta             = bottom + M.CTA_LIFT,
        cta_top         = bottom + M.CTA_LIFT + M.CTA_H / 2,
    }
end

return M
