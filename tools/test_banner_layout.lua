-- THE INVITE STRIP'S RIGHT-HAND SIDE MUST NOT OVERLAP ITSELF.
--
-- Four things share that space, all laid out as offsets from the right edge:
-- the H2H block, the CHAMPIONSHIP badge, DECLINE and ACCEPT. Nothing measures
-- text at build time, so a badge that is one constant too wide simply draws on
-- top of the H2H form squares — and it looks fine in every screenshot that
-- happens to be of an invite with no head-to-head history.
--
-- The gap between H2H and the buttons is 75px on an ordinary invite, which is
-- narrower than the word CHAMPIONSHIP. That is why the H2H anchor shifts left
-- when the badge is present, and why the shift has to be checked rather than
-- trusted: it is the difference between a badge in a gap and a badge over a
-- number.
--
-- Both banner files are read directly, because the two surfaces draw the SAME
-- invite — the online screen inline, the global overlay everywhere else — and
-- the whole point of the shared figures is that they cannot drift apart.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end

local function constants(path)
  local f = assert(io.open(here .. "/../" .. path))
  local src = f:read("*a"); f:close()
  local c = {}
  for name, value in src:gmatch("local (BAN_[%w_]+)%s*=%s*(%-?%d+)") do
    c[name] = tonumber(value)
  end
  -- The two buttons are positional literals in the draw call, not constants.
  c.DECLINE_X = tonumber(src:match("[mEDGE]*%.?R?_?R? ?%- ?(%d+), cy, 0%), vmath%.vector3%(120, 46"))
  return c, src
end

-- Geometry of the pieces, as x-ranges measured LEFTWARD from the right edge.
-- Larger number = further left.
local function ranges(c)
  local r = {}
  -- Buttons: ACCEPT centred at R-90, DECLINE at R-225, both 120 wide.
  r.accept  = { 90 + 60, 90 - 60 }
  r.decline = { 225 + 60, 225 - 60 }
  -- Badge, centred on its own offset.
  r.badge   = { c.BAN_CHAMP_X + c.BAN_CHAMP_W / 2, c.BAN_CHAMP_X - c.BAN_CHAMP_W / 2 }
  -- draw_h2h_row draws five 22px form squares at anchor-64+(i-1)*28+11, so the
  -- rightmost edge lands at anchor+70. Mirrors the loop in both files.
  r.h2h_plain = { nil, c.BAN_H2H_X - 70 }
  r.h2h_champ = { nil, c.BAN_H2H_X_CHAMP - 70 }
  return r
end

-- `left` and `right` are offsets from the right edge, so "a is left of b" means
-- a's right-hand offset is GREATER than b's left-hand offset.
local function clear_of(a_right_offset, b_left_offset)
  return a_right_offset > b_left_offset
end

for _, path in ipairs({ "main/online.gui_script", "main/incoming.gui_script" }) do
  local c, src = constants(path)
  local r = ranges(c)
  local tag = path:match("([^/]+)$")

  check(tag .. ": badge constants present",
    c.BAN_CHAMP_X and c.BAN_CHAMP_W and c.BAN_H2H_X and c.BAN_H2H_X_CHAMP)

  -- The badge sits between the H2H block and DECLINE, touching neither.
  -- Widths come from championship.badge_width; the reserved slot must hold the
  -- widest label, since every pill is centred on the same point.
  check(tag .. ": the reserved slot holds the widest label",
    c.BAN_CHAMP_W >= 12 * 11,
    ("slot %d vs CHAMPIONSHIP %d"):format(c.BAN_CHAMP_W, 12 * 11))

  check(tag .. ": badge clears DECLINE",
    clear_of(r.badge[2], r.decline[1]),
    ("badge left edge R-%d vs decline R-%d"):format(r.badge[2], r.decline[1]))

  check(tag .. ": badge clears the H2H row",
    clear_of(r.h2h_champ[2], r.badge[1]),
    ("h2h right edge R-%d vs badge R-%d"):format(r.h2h_champ[2], r.badge[1]))

  -- The reason the shift exists at all: without it there is not room.
  check(tag .. ": the unshifted layout genuinely could NOT fit the badge",
    not clear_of(r.h2h_plain[2], r.badge[1]),
    "if this passes, the shift is unnecessary and should be removed")

  -- An ordinary invite must be untouched by any of this.
  check(tag .. ": ordinary invites keep the original H2H anchor", c.BAN_H2H_X == 430)

  -- No brackets, as asked.
  check(tag .. ": badge text has no brackets", not src:find("%[CHAMPIONSHIP%]"))

  -- Every kind championship.kind can return needs a colour here. draw_badge
  -- returns early on a kind the palette does not name, so a missing entry is an
  -- invisible badge rather than a crash — exactly the sort of thing that ships.
  for _, kind in ipairs({ "CHAMPIONSHIP", "KNOCKOUT", "BATTLE" }) do
    check(tag .. ": " .. kind .. " has a badge colour",
      src:find(kind .. "%s*=%s*{ bg") ~= nil)
  end

  -- Drawn on the buttons' own centre line, which is what "vertically centred"
  -- means on this strip.
  check(tag .. ": inline badge is on the cy centre line",
    src:find("BAN_CHAMP_X, cy, BAN_CHAMP_H") ~= nil)

  -- ONE badge per strip. There used to be a second, centred on the top rule,
  -- saying the same thing in a second place.
  local badge_draws = 0
  for _ in src:gmatch("draw_badge%(self, [db]%.badge") do badge_draws = badge_draws + 1 end
  check(tag .. ": exactly one badge is drawn", badge_draws == 1,
    ("found %d"):format(badge_draws))
  check(tag .. ": nothing draws a badge on the top rule",
    src:find("draw_badge%(self, [db]%.badge, [mCX]+[%.%w]*, top") == nil
    and src:find("draw_badge%(self, [db]%.badge, CX, cy %+ 44") == nil)

  -- Both surfaces get their description from the ONE shared function, so a
  -- knockout cannot read as a score cap on one strip and a best-of on the other.
  check(tag .. ": description comes from championship.format_text",
    src:find("champ%.format_text") ~= nil)
  check(tag .. ": and neither file builds its own",
    src:find('"Best of "') == nil and src:find('"SCORE CAP "') == nil)

  -- There is no such thing as a single game on this strip: it only ever shows
  -- tournament, battle and knockout invites.
  check(tag .. ": never says Single game", src:find("Single game") == nil)

  -- A BATTLE request with no tournament payload to read is still a battle.
  check(tag .. ": a bare BATTLE request still gets a badge",
    src:find('kind = kind or "BATTLE"') ~= nil)

  -- The badge field must NOT be called `kind`. incoming.gui_script's dialog
  -- table already carries a `kind` ("incoming") that selects the draw path, and
  -- a second `kind` in the same constructor silently wins — which would send
  -- every plain game request down the wrong path. Caught exactly that way.
  check(tag .. ": badge is carried as `badge`", src:find("%.badge") ~= nil)
  check(tag .. ": and nothing re-uses `kind` for it",
    src:find("kind%s*=%s*d%.kind") == nil and src:find("^%s*kind%s*=%s*kind,") == nil)
end

-- The two files must agree, or the same invite is laid out two ways.
local a = constants("main/online.gui_script")
local b = constants("main/incoming.gui_script")
for _, k in ipairs({ "BAN_CHAMP_X", "BAN_CHAMP_W", "BAN_CHAMP_H", "BAN_H2H_X", "BAN_H2H_X_CHAMP" }) do
  check("both surfaces agree on " .. k, a[k] == b[k], ("%s vs %s"):format(tostring(a[k]), tostring(b[k])))
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
