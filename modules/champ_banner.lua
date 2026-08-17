-- THE CHAMPIONSHIP INVITE, WHICH IS NOT THE SAME KIND OF THING AS A GAME REQUEST.
--
-- Every other invite on this strip is a match: somebody wants to play, you say
-- yes or no, nothing changes if you ignore it. A championship invite to a
-- player who has not joined is an OFFER — it costs a one-off entry, it buys a
-- run at a ladder, and there is a real prize at the end of it. Dressing that as
-- one more row in the same grey strip asks the player to make a purchase
-- decision from a notification.
--
-- So it gets its own surface. Same inline strip, same slot, same ten seconds —
-- and nothing else about it the same:
--
--   a plate that FADES TO ONE CORNER, warm gold at the right and dying out to
--     the left, so the eye lands on the prize rather than on the avatar
--   the GRAND PRIZE on a plaque of its own, in gold, at title size, with a
--     SHIMMER sweeping across it
--   a button that names its own price — JOIN FOR 500, not JOIN
--
-- WHY THIS IS A MODULE AND NOT TWO COPIES
--
-- The same invite is drawn by two surfaces: online.gui_script inline while the
-- player is on the online screen, incoming.gui_script's global overlay
-- everywhere else. They already share their layout constants and a test that
-- checks the two agree, precisely because a difference between them means one
-- request looks like two. A design this specific would not survive being
-- written twice, so it is written once and called twice.
--
-- Nothing here touches `self` or msg.post: the caller passes a ctx of the four
-- things Defold makes it own (a node tracker, the ui module, the screen box,
-- and how to register a button), so the drawing can be reasoned about — and
-- the geometry tested — without booting a screen.

local M = {}

-- Taller than the ordinary 92px strip. The prize plaque needs vertical room to
-- read as a plaque rather than as a third line of text, and the buttons drop
-- below the copy instead of sitting beside it.
M.HEIGHT = 132

-- ── palette ─────────────────────────────────────────────────────────────────
-- Near-black, warmer than the ordinary strip's blue-grey so the two do not
-- read as the same surface at a glance.
local PLATE      = vmath.vector4(0.055, 0.045, 0.035, 0.985)
-- The corner the plate fades INTO. Deep amber rather than yellow: at low alpha
-- yellow goes green over a dark plate, which looks like a bug rather than a
-- glow.
local CORNER     = vmath.vector4(0.62, 0.40, 0.03, 1.00)
local RULE       = vmath.vector4(1.00, 0.78, 0.20, 1.00)
local TITLE      = vmath.vector4(1.00, 0.97, 0.90, 1.00)
local SUB        = vmath.vector4(0.72, 0.64, 0.50, 1.00)
local PLAQUE_BG  = vmath.vector4(0.10, 0.08, 0.03, 0.92)
local PLAQUE_BRD = vmath.vector4(1.00, 0.80, 0.24, 0.85)
local PRIZE_GOLD = vmath.vector4(1.00, 0.85, 0.28, 1.00)
local PRIZE_CAP  = vmath.vector4(0.82, 0.68, 0.34, 1.00)
local SHIMMER    = vmath.vector4(1.00, 0.98, 0.86, 1.00)
local JOIN_BG    = vmath.vector4(1.00, 0.74, 0.10, 0.96)
local JOIN_TX    = vmath.vector4(0.12, 0.08, 0.00, 1.00)
local CANCEL_BG  = vmath.vector4(0.16, 0.14, 0.11, 0.90)
local CANCEL_TX  = vmath.vector4(0.78, 0.73, 0.64, 1.00)
local AV_BG      = vmath.vector4(0.13, 0.10, 0.06, 1.00)

-- ── geometry, as offsets from the right edge ────────────────────────────────
-- Same convention as the ordinary strip's, so the two can be checked against
-- each other by the layout test.
M.PLAQUE_X = 300   -- centre of the prize plaque
M.PLAQUE_W = 250
M.PLAQUE_H = 86
M.JOIN_X   = 100   -- centre of the JOIN button
M.JOIN_W   = 176
M.CANCEL_X = 254   -- centre of CANCEL
M.CANCEL_W = 120
M.BTN_H    = 44

-- How many slices the corner fade is built from.
--
-- Defold has no gradient node, and a box takes ONE colour — so a fade is a
-- stack of boxes with stepped alpha, and the only question is how many. Twelve
-- is where the banding stops being visible at this width on a phone; more is
-- invisible and costs nodes on a strip that is rebuilt once a second.
local FADE_STEPS = 12

local function with_a(c, a) return vmath.vector4(c.x, c.y, c.z, c.w * (a or 1)) end

local function commas(n)
    return (tostring(math.floor(tonumber(n) or 0)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--- The label on the button that spends the coins.
--
-- "JOIN FOR 500", not "JOIN". A button that takes money should say how much on
-- its face — the fee line under it is the explanation, not the disclosure, and
-- a player who reads only the button must still know the price.
--
-- Falls back to a bare JOIN when there is no fee to name, which is what an
-- older server sends.
function M.join_label(fee)
    local n = tonumber(fee) or 0
    if n <= 0 then return "JOIN" end
    return "JOIN FOR " .. commas(n)
end

--- The plate, fading from solid on the left into warm gold at the right edge.
--
-- Drawn as FADE_STEPS vertical slices whose alpha ramps up towards the corner,
-- laid over the flat plate. The ramp is squared so the glow stays out of the
-- left two-thirds entirely rather than washing the whole strip — a fade that
-- is visible everywhere is not a fade to a corner.
local function draw_corner_fade(ctx, cx, cy, w, h, a)
    local track, ui = ctx.track, ctx.ui
    track(ui.box(vmath.vector3(cx, cy, 0), vmath.vector3(w, h, 0), with_a(PLATE, a)))

    local slice_w = w / FADE_STEPS
    local left = cx - w / 2
    for i = 1, FADE_STEPS do
        local t = i / FADE_STEPS          -- 0 at the left edge, 1 at the right
        local strength = t * t * t        -- cubed: nothing until the last third
        if strength > 0.01 then
            track(ui.box(
                vmath.vector3(left + (i - 0.5) * slice_w, cy, 0),
                vmath.vector3(slice_w + 1, h, 0),
                with_a(CORNER, a * strength * 0.55)))
        end
    end
end

--- Draw the whole banner.
--
-- ctx = {
--   track  = function(node) -> node    register for teardown
--   ui     = the ui module
--   box    = { L, R, CX }              the strip's horizontal extent
--   button = function(kind, node)      kind is "accept" or "decline"
-- }
-- d   = { title, desc, avatar, prize, entry_fee, time_left, max_time }
--
-- Returns the animation handle for M.animate: the shimmer node and the
-- countdown fill, both of which move every frame rather than once a second.
function M.draw(ctx, d, cy, a)
    local track, ui, box = ctx.track, ctx.ui, ctx.box
    a = a or 1
    local w = box.R - box.L
    local top, bot = cy + M.HEIGHT / 2, cy - M.HEIGHT / 2

    draw_corner_fade(ctx, box.CX, cy, w, M.HEIGHT, a)

    -- Gold rule along the top, so the strip is separated from whatever is above
    -- it by something that belongs to this design rather than the cyan the
    -- ordinary banner uses.
    track(ui.box(vmath.vector3(box.CX, top, 0), vmath.vector3(w, 3, 0), with_a(RULE, a)))

    -- ── left: who, and what for ──
    local av_x = box.L + 46
    track(ui.box(vmath.vector3(av_x, cy + 6, 0), vmath.vector3(58, 58, 0), with_a(AV_BG, a)))
    gui.set_color(
        track(ui.avatar(vmath.vector3(av_x, cy + 6, 0), vmath.vector3(52, 52, 0), d.avatar or 1)),
        vmath.vector4(1, 1, 1, a))

    gui.set_pivot(track(ui.text(vmath.vector3(box.L + 86, cy + 34, 0),
        "GLOBAL CHAMPIONSHIP", "small", with_a(RULE, a))), gui.PIVOT_W)
    gui.set_pivot(track(ui.text(vmath.vector3(box.L + 86, cy + 8, 0),
        tostring(d.title or "A PLAYER"), "body", with_a(TITLE, a))), gui.PIVOT_W)
    gui.set_pivot(track(ui.text(vmath.vector3(box.L + 86, cy - 16, 0),
        tostring(d.desc or ""), "small", with_a(SUB, a))), gui.PIVOT_W)

    -- ── centre-right: the prize, on a plaque of its own ──
    local shimmer_node, shimmer_span
    local prize = tonumber(d.prize) or 0
    if prize > 0 then
        local px = box.R - M.PLAQUE_X
        local py = cy + 10
        track(ui.box(vmath.vector3(px, py, 0),
            vmath.vector3(M.PLAQUE_W + 4, M.PLAQUE_H + 4, 0), with_a(PLAQUE_BRD, a)))
        track(ui.box(vmath.vector3(px, py, 0),
            vmath.vector3(M.PLAQUE_W, M.PLAQUE_H, 0), with_a(PLAQUE_BG, a)))

        -- THE SHIMMER. A narrow bright bar that sweeps across the plaque and
        -- off its right edge, over and over. Created once here and MOVED every
        -- frame by M.animate — rebuilding the strip sixty times a second to
        -- slide one bar is not a trade worth making, which is the same reason
        -- the countdown fill is handled this way.
        --
        -- Clipped to the plaque by construction rather than by a stencil: the
        -- sweep is confined to the plaque's own x-range, so it never runs out
        -- over the copy on the left.
        shimmer_span = { left = px - M.PLAQUE_W / 2, right = px + M.PLAQUE_W / 2, y = py }
        shimmer_node = track(ui.box(vmath.vector3(shimmer_span.left, py, 0),
            vmath.vector3(26, M.PLAQUE_H - 6, 0), with_a(SHIMMER, a * 0.13)))

        track(ui.text(vmath.vector3(px, py + 24, 0), "GRAND PRIZE", "small", with_a(PRIZE_CAP, a)))
        track(ui.text(vmath.vector3(px, py - 12, 0), commas(prize), "title", with_a(PRIZE_GOLD, a)))
    end

    -- ── buttons, below the copy rather than beside it ──
    local by = bot + M.BTN_H / 2 + 10

    local cancel = track(ui.box(vmath.vector3(box.R - M.CANCEL_X, by, 0),
        vmath.vector3(M.CANCEL_W, M.BTN_H, 0), with_a(CANCEL_BG, a)))
    ctx.button("decline", cancel)
    track(ui.text(vmath.vector3(box.R - M.CANCEL_X, by, 0), "CANCEL", "btn_md", with_a(CANCEL_TX, a)))

    local join = track(ui.box(vmath.vector3(box.R - M.JOIN_X, by, 0),
        vmath.vector3(M.JOIN_W, M.BTN_H, 0), with_a(JOIN_BG, a)))
    ctx.button("accept", join)
    track(ui.text(vmath.vector3(box.R - M.JOIN_X, by, 0),
        M.join_label(d.entry_fee), "btn_md", with_a(JOIN_TX, a)))

    -- The price again, in words, under the button that charges it. The label
    -- carries the number; this says what KIND of charge it is — once, ever,
    -- rather than per match.
    if (tonumber(d.entry_fee) or 0) > 0 then
        gui.set_pivot(track(ui.text(vmath.vector3(box.R - M.PLAQUE_X, by, 0),
            "One-time join fee", "small", with_a(SUB, a))), gui.PIVOT_CENTER)
    end

    -- Countdown along the bottom edge, same mechanism as the ordinary strip.
    track(ui.box(vmath.vector3(box.CX, bot, 0), vmath.vector3(w, 3, 0), with_a(CANCEL_BG, a)))
    local fill = track(ui.box(vmath.vector3(box.L, bot, 0), vmath.vector3(0, 3, 0), with_a(RULE, a)))

    return {
        shimmer = shimmer_node,
        span = shimmer_span,
        fill = fill,
        w = w,
        left = box.L,
        y = bot,
        alpha = a,
        t = 0,
    }
end

-- How long one shimmer sweep takes, and how long it waits before the next.
-- Slow enough to read as a sheen rather than a strobe on a strip that is only
-- on screen for ten seconds.
local SWEEP_SECONDS = 1.6
local SWEEP_PAUSE   = 0.9

--- Advance the shimmer and the countdown. Called every frame.
function M.animate(anim, dt, time_left, max_time)
    if not anim then return end

    if anim.fill then
        local frac = math.max(0, math.min(1, (time_left or 0) / (max_time or 10)))
        local w = anim.w * frac
        gui.set_size(anim.fill, vmath.vector3(w, 3, 0))
        gui.set_position(anim.fill, vmath.vector3(anim.left + w / 2, anim.y, 0))
    end

    if anim.shimmer and anim.span then
        anim.t = (anim.t or 0) + (dt or 0)
        local cycle = SWEEP_SECONDS + SWEEP_PAUSE
        local phase = anim.t % cycle
        if phase > SWEEP_SECONDS then
            -- Resting between sweeps: parked at the left edge and invisible,
            -- rather than sitting lit at the end of its run.
            gui.set_color(anim.shimmer, vmath.vector4(SHIMMER.x, SHIMMER.y, SHIMMER.z, 0))
        else
            local p = phase / SWEEP_SECONDS
            local x = anim.span.left + p * (anim.span.right - anim.span.left)
            gui.set_position(anim.shimmer, vmath.vector3(x, anim.span.y, 0))
            -- Brightest in the middle of the pass and faded at both ends, so
            -- it does not pop into existence at the plaque's left edge.
            local ease = math.sin(p * math.pi)
            gui.set_color(anim.shimmer,
                vmath.vector4(SHIMMER.x, SHIMMER.y, SHIMMER.z, 0.16 * ease * (anim.alpha or 1)))
        end
    end
end

return M
