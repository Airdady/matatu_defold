-- flag_art.lua — country flags drawn from primitives, not shipped as images.
--
-- WHY NOT A PNG.
--
-- The three flags this game needs are Uganda, Nigeria and Kenya (matatu ->
-- UG, whot -> NG, kadi -> KE — see be_matatu's COUNTRY_CONFIG). A flag is
-- wanted in two places that have nothing else in common: the scrolling
-- announcement marquee, and the Season Complete results list. Shipping them
-- as artwork means new binaries in assets/, new entries in ui.atlas, and a
-- fixed pixel size baked into whatever resolution was exported — for shapes
-- that are, in two of the three cases, nothing but coloured rectangles.
--
-- So they are described here as geometry in UNIT SPACE and instantiated at
-- whatever size the caller wants. A marquee draws them 22px tall; the season
-- panel draws them 18px tall; neither is resampling a bitmap.
--
-- UNIT SPACE
--
-- Every part is expressed in a 0..1 box with the ORIGIN AT THE BOTTOM-LEFT
-- and +y going up, because that is the direction Defold's gui axes already
-- run and converting once at the draw call is cheaper than reasoning about a
-- flipped y in five separate part tables. `x`/`y` are the part's bottom-left
-- corner, `w`/`h` its size. A flag's own aspect is 3:2 (M.ASPECT), which the
-- caller applies when it picks a width for a chosen height.
--
-- WHAT `detail = true` MEANS
--
-- Uganda's crest and Kenya's shield are emblems with real internal drawing —
-- a grey crowned crane, a Maasai shield over crossed spears. At 20 pixels
-- tall neither resolves into anything but a smudge, and a smudge in the
-- middle of the stripes reads as a rendering fault rather than as a crest.
-- Parts marked `detail` are therefore the ones a small renderer should SKIP:
-- the stripes alone already identify all three flags unambiguously, and they
-- stay clean at any size. M.parts(code, min_px) does the skipping for you.
--
-- This module is pure: it touches `gui` only inside M.draw, and never at
-- require time, so tools/test_flag_art.lua can require it under plain Lua.

local M = {}

-- A flag is half again as wide as it is tall. All three of these are 3:2 by
-- official specification, which is the only reason one constant covers them.
M.ASPECT = 1.5

-- Below this height in pixels, `detail` parts are dropped (see the header).
-- 26px is where a 0.14-unit emblem is still under 4 pixels across — i.e.
-- where it has stopped being a picture of anything.
M.DETAIL_MIN_PX = 26

local BLACK  = { 0.00, 0.00, 0.00 }
local WHITE  = { 1.00, 1.00, 1.00 }
local UG_GOLD = { 0.99, 0.81, 0.09 }
local UG_RED  = { 0.84, 0.11, 0.13 }
local UG_GREY = { 0.55, 0.57, 0.60 } -- the crane, reduced to its silhouette
local NG_GREEN = { 0.00, 0.53, 0.32 }
local KE_RED   = { 0.73, 0.09, 0.13 }
local KE_GREEN = { 0.00, 0.39, 0.16 }

local function rect(x, y, w, h, color, detail)
    return { kind = "rect", x = x, y = y, w = w, h = h, color = color, detail = detail or false }
end

-- Centred circle, given as its bounding box like every other part so the
-- draw call has exactly one coordinate convention to convert.
local function disc(cx, cy, d, color, detail)
    return { kind = "circle", x = cx - d / 2, y = cy - d / 2, w = d, h = d, color = color, detail = detail or false }
end

-- Six equal bands, black/yellow/red/black/yellow/red read from the TOP, with
-- the white crest disc centred. Listed bottom-up because that is the
-- direction y runs.
local UG = {
    rect(0, 0 / 6, 1, 1 / 6, UG_RED),
    rect(0, 1 / 6, 1, 1 / 6, UG_GOLD),
    rect(0, 2 / 6, 1, 1 / 6, BLACK),
    rect(0, 3 / 6, 1, 1 / 6, UG_RED),
    rect(0, 4 / 6, 1, 1 / 6, UG_GOLD),
    rect(0, 5 / 6, 1, 1 / 6, BLACK),
    disc(0.5, 0.5, 0.44, WHITE),
    disc(0.5, 0.5, 0.16, UG_GREY, true), -- the crane, at the only fidelity that survives
}

-- Three equal vertical bands. Nothing to skip: Nigeria's flag has no
-- emblem, so it is exactly as legible at 12px as at 120.
local NG = {
    rect(0 / 3, 0, 1 / 3, 1, NG_GREEN),
    rect(1 / 3, 0, 1 / 3, 1, WHITE),
    rect(2 / 3, 0, 1 / 3, 1, NG_GREEN),
}

-- Black / white fimbriation / red / white fimbriation / green, then the
-- shield. The white bands are thin by specification and they are what stops
-- the black and the red running together into one dark mass at small sizes,
-- so they are NOT details.
local KE = {
    rect(0, 0.00, 1, 0.30, KE_GREEN),
    rect(0, 0.30, 1, 0.05, WHITE),
    rect(0, 0.35, 1, 0.30, KE_RED),
    rect(0, 0.65, 1, 0.05, WHITE),
    rect(0, 0.70, 1, 0.30, BLACK),
    -- The crossed spears, flattened to one bar: at any size where this is
    -- visible at all, two crossed diagonals are three pixels of noise.
    rect(0.20, 0.47, 0.60, 0.06, WHITE, true),
    rect(0.42, 0.14, 0.16, 0.72, WHITE, true),  -- shield, white ground
    rect(0.45, 0.20, 0.10, 0.60, KE_RED, true), -- shield, red field
    rect(0.45, 0.44, 0.10, 0.12, BLACK, true),  -- shield, dark centre band
}

M.FLAGS = { UG = UG, NG = NG, KE = KE }

-- Which flag belongs to which game, mirroring be_matatu's COUNTRY_CONFIG.
-- Kept here rather than in modules/config.lua because it is the flag lookup's
-- own table: config knows about stakes and currencies, not about drawing.
M.BY_GAME = { matatu = "UG", whot = "NG", kadi = "KE" }

-- Normalises anything the server or a payload might hand us into a code this
-- module actually has parts for: "ug", "UGA", "uganda", "matatu", "UGX" all
-- mean UG. Returns nil when there is no match, and every caller treats nil as
-- "draw no flag" rather than as an error — a missing flag must never be the
-- reason a winners list fails to render.
local ALIASES = {
    UG = "UG", UGA = "UG", UGANDA = "UG", UGX = "UG", MATATU = "UG",
    NG = "NG", NGA = "NG", NIGERIA = "NG", NGN = "NG", WHOT = "NG",
    KE = "KE", KEN = "KE", KENYA = "KE", KES = "KE", KADI = "KE",
}

function M.code(v)
    if type(v) ~= "string" then return nil end
    return ALIASES[v:upper()]
end

-- The parts for a flag, with `detail` parts dropped when it is being drawn
-- too small for them to mean anything.
--
-- Returns an EMPTY TABLE, never nil, for an unknown code: the draw loop is
-- then a no-op instead of a nil index, which is the whole point — a country
-- we have no flag for costs a caller nothing and breaks nothing.
function M.parts(code, height_px)
    local flag = M.FLAGS[M.code(code) or ""]
    if not flag then return {} end
    local px = tonumber(height_px)
    local keep_detail = px == nil or px >= M.DETAIL_MIN_PX
    if keep_detail then return flag end
    local out = {}
    for _, p in ipairs(flag) do
        if not p.detail then out[#out + 1] = p end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Defold rendering
-- ---------------------------------------------------------------------------
-- Only this function touches gui.*, and only when called, so requiring the
-- module outside Defold is safe.
--
-- `pos` is the flag's CENTRE. Nodes are returned in creation order so the
-- caller can parent, track and delete them — every screen in this codebase
-- has to remember what it made, since Defold's gui has no child query.
--
-- Circles come from the ui atlas's `circle` sprite tinted to the part colour,
-- which is how the rest of the UI already draws a filled disc (see ui.pie).
function M.draw(pos, height_px, code, opts)
    opts = opts or {}
    local nodes = {}
    local parts = M.parts(code, height_px)
    if #parts == 0 then return nodes end

    local h = height_px
    local w = h * M.ASPECT
    local x0 = pos.x - w / 2
    local y0 = pos.y - h / 2
    local alpha = opts.alpha or 1

    for _, p in ipairs(parts) do
        local size = vmath.vector3(p.w * w, p.h * h, 0)
        -- Unit space measures from a corner; a gui node positions from its
        -- centre, so half the part's own size is added back here.
        local at = vmath.vector3(
            x0 + (p.x + p.w / 2) * w,
            y0 + (p.y + p.h / 2) * h,
            pos.z or 0)
        local n = gui.new_box_node(at, size)
        gui.set_color(n, vmath.vector4(p.color[1], p.color[2], p.color[3], alpha))
        if p.kind == "circle" then
            gui.set_texture(n, "ui")
            pcall(gui.play_flipbook, n, hash("circle"))
        end
        if opts.parent then gui.set_parent(n, opts.parent) end
        nodes[#nodes + 1] = n
    end
    return nodes
end

return M
