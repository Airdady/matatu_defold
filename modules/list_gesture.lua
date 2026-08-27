-- IS THIS A TAP OR A SCROLL? DECIDED ON THE WAY UP, NEVER ON THE WAY DOWN.
--
-- The lobby's player list dispatched its rows on action.pressed — the moment
-- a finger LANDED. So every attempt to scroll the list challenged whoever
-- happened to be under the thumb; the drag was recognised a frame later, long
-- after the request had gone out. There is no way to fix that at the moment
-- of the press, because at that moment the two gestures are identical.
--
-- So a press decides nothing. It starts a gesture, and the gesture is read at
-- the release:
--
--   travelled more than SLOP   -> a scroll, and the row is never acted on
--   travelled less             -> a tap, on the row under the finger
--
-- Kept apart from any one screen because the same list appears in the lobby,
-- the tournaments screen and the standings roster, and a rule about what
-- counts as a tap should not be re-derived three times.
local M = {}

-- HOW FAR A FINGER MAY TRAVEL AND STILL COUNT AS A TAP.
--
-- Logical units in a 720-tall design, so 12 is about 1.7% of the screen —
-- roughly a fifth of a list row.
--
-- The lobby's old figure was 6, under a millimetre of thumb travel on a
-- phone. It barely mattered there, because rows fired on touch-down and the
-- slop only decided whether to swallow the release afterwards. Now that it
-- decides whether the row acts at all, it has to survive the wobble in an
-- ordinary tap.
M.SLOP = 12

--- How long a gesture may live without a release before it is abandoned.
--
-- A release is not guaranteed to arrive. A touch interrupted by a system
-- gesture, a notification shade, a second finger, or the app being sent to the
-- background can end without one — and a gesture left live afterwards is a
-- gesture that swallows the next press. See M.expired.
M.MAX_AGE = 4

--- Begin a gesture at y. Nothing is decided here, by design.
---
--- `now` is optional and only used for the staleness check; a caller with no
--- clock simply never expires one, which is what happened before this existed.
function M.press(g, y, now)
    g.y0, g.last, g.dragging, g.started = y, y, false, now
    return "held"
end

--- Has this gesture outlived any touch that could still be down?
function M.expired(g, now)
    if type(g) ~= "table" or g.last == nil then return false end
    if not g.started or not now then return false end
    return (now - g.started) > M.MAX_AGE
end

--- How far to scroll for this move, which is ZERO until the gesture is
--- definitely a scroll.
---
-- The list used to follow every pixel of jitter, so it crept under a finger
-- that was only tapping and the row drifted out from under it. Holding still
-- below the slop is what makes the release point trustworthy.
function M.move(g, y)
    if not g.last then return 0 end
    if not g.dragging and math.abs(y - (g.y0 or y)) > M.SLOP then
        g.dragging = true
    end
    if not g.dragging then return 0 end
    local d = y - g.last
    g.last = y
    return d
end

--- "tap", "scroll", or nil when no gesture was in progress.
function M.release(g)
    if not g.last then return nil end
    local dragged = g.dragging
    M.cancel(g)
    return dragged and "scroll" or "tap"
end

--- Abandon a gesture. Used when the list goes away underneath one — a dialog
--- opened, a banner arrived, the tab changed — so that a release arriving
--- afterwards is not read as a tap on whatever now occupies that point.
function M.cancel(g)
    g.y0, g.last, g.dragging = nil, nil, false
end

function M.active(g)
    return g.last ~= nil
end

return M
