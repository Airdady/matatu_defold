-- AN OPEN TABLE IS AN INVITE, AND INVITES LIVE ON THE STRIP.
--
--   Run: lua5.4 tools/test_party_invite_strip.lua
--
-- A party used to throw a full-screen PARTY TABLES panel over the lobby the
-- moment somebody opened a table: a modal, unasked for, for something the
-- player had done nothing to receive. Every other invite in this app — a
-- challenge, a tournament, a battle, a knockout, a championship, a cup — is a
-- row at the top of the screen that leaves the app working underneath it.
--
-- Asked for: the party the same way, and the challenge you SEND the same way
-- too. So there are now three kinds of strip and no dialogs left in the invite
-- flow at all.
--
-- The clock is the part worth testing hardest. A game request runs ten seconds
-- and both ends agree on it. A TABLE does not belong to this client: the server
-- closes it at closesAt — twenty seconds after it opened, so a strip that
-- arrives partway through has less than that — and a strip counting its own
-- twenty would either offer a seat at a table that has already dealt or take
-- one away while it was still filling.
--
-- Two halves, following test_incoming_surface.lua: the COPY driven as the real
-- function, lifted out of the gui_script and loaded rather than re-implemented;
-- and the DECISIONS read out of the source, because a .gui_script cannot be
-- required and the things that would regress here are one-line branches.
local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print(("FAIL  %s%s"):format(name, detail and ("  (" .. detail .. ")") or "")) end
end
local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

local function read(path)
  local f = assert(io.open(here .. "/../" .. path))
  local s = f:read("*a"); f:close(); return s
end

local ONLINE   = read("main/online.gui_script")
local SEARCH   = read("modules/dialog_search.lua")
local OVERLAY  = read("main/incoming.gui_script")
local RIGHT    = read("modules/online_right.lua")
local CTRL     = read("main/controller.script")

-- Comments explain the very things these checks look for, so they are stripped
-- before any source is searched. A test a comment can satisfy is a test nobody
-- can trust.
local function code(s) return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")) end
local ONLINE_C, OVERLAY_C, RIGHT_C = code(ONLINE), code(OVERLAY), code(RIGHT)
local SEARCH_C = code(SEARCH)

-- ── THE STRIP ITSELF, BUILT BY THE REAL FUNCTION ────────────────────────────
-- NOW is frozen so the countdown is arithmetic rather than a race with the
-- test runner. The lifted code reads the global `socket`, exactly as the screen
-- does inside Defold.
local NOW = 1700000000
socket = { gettime = function() return NOW end }

local party_banner_of
do
  local commas    = ONLINE:match("(local function commas%(.-end)")
  local ms_left   = ONLINE:match("(local function ms_left%(.-\nend)")
  local fallback  = ONLINE:match("(local PARTY_WINDOW_FALLBACK = %d+)")
  local body      = ONLINE:match("(local function party_banner_of%(.-\nend)")
  assert(commas and ms_left and fallback and body, "could not lift the strip builder")
  party_banner_of = assert(load(table.concat({ commas, ms_left, fallback, body,
    "return party_banner_of" }, "\n")))()
end

local function table_at(over)
  local t = {
    partyId = "p1", hostName = "Mubarak", hostAvatar = 7, entry = 200,
    mode = "NORMAL", seated = 2, closesAt = (NOW * 1000) + 14000,
  }
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end

local b = party_banner_of(table_at())
eq("the strip names the host",            b.title, "PARTY  -  MUBARAK")
eq("...and shows their face, not a stub", b.avatar, 7)
eq("...says how it is won, how full it is and what it costs",
   b.desc, "NORMAL   -   2/4 seated   -   200 Coins")
eq("...is badged as a party",             b.badge, "PARTY")
eq("...offers to JOIN",                   b.accept_label, "JOIN")
-- Not DECLINE. There is no decline for a table: nobody is waiting on this
-- player's answer, and putting a strip away is not turning something down.
eq("...and to put it away, not turn it down", b.decline_label, "LATER")

-- THE CLOCK IS THE SERVER'S.
eq("the countdown is what the TABLE has left, not a window of our own",
   b.time_left, 14)
check("...and the bar is scaled by the same figure", b.max_time == 14)

-- A table already gone, and one whose payload said nothing about a deadline.
eq("a table that has closed reads zero rather than a fresh window",
   party_banner_of(table_at({ closesAt = (NOW * 1000) - 5000 })).time_left, 0)
check("...and its bar is never scaled by zero",
   party_banner_of(table_at({ closesAt = (NOW * 1000) - 5000 })).max_time >= 1,
   "a zero denominator divides the countdown fill by nothing")
eq("a payload with no deadline at all falls back to the server's window",
   party_banner_of(table_at({ closesAt = 0 })).time_left, 20)

-- WHAT THE PLAYER CHOSE IT BY. SCORECAP is the wire name; the maker's own form
-- calls it KNOCKOUT and that is the only word a player has seen.
check("a score-cap table is called what the form called it",
  party_banner_of(table_at({ mode = "SCORECAP" })).desc:find("KNOCKOUT", 1, true) ~= nil,
  party_banner_of(table_at({ mode = "SCORECAP" })).desc)

eq("a free table says so rather than showing 0 Coins",
   party_banner_of(table_at({ entry = 0 })).desc,
   "NORMAL   -   2/4 seated   -   Free table")
eq("a host the server did not name is still somebody",
   party_banner_of(table_at({ hostName = "" })).title, "PARTY  -  A PLAYER")
eq("an avatar the server did not send is still drawable",
   party_banner_of({ partyId = "p1", hostName = "Mubarak", entry = 200,
                     mode = "NORMAL", seated = 2, closesAt = (NOW * 1000) + 14000 }).avatar, 1)

-- KEYED ON THE TABLE, NOT ON A REQUEST ID IT DOES NOT HAVE. Every party strip
-- would otherwise share the empty string with every other, and pressing JOIN on
-- one would answer whichever the loop found first.
eq("the strip is keyed on its table", b.key, "party:p1")
eq("...and carries no request id, because there is no request", b.request_id, "")

-- ── THE PANEL IS GONE, NOT HIDDEN ───────────────────────────────────────────
check("no party panel is drawn any more", not RIGHT_C:find("draw_party_tables", 1, true))
check("...and the lobby has no state for one", not ONLINE_C:find("party_open", 1, true))
check("...nor the buttons that were on it",
  not ONLINE_C:find("party_close", 1, true) and not ONLINE_C:find("party_leave", 1, true))

-- ── AND NEITHER DIALOG SURVIVES IN THE INVITE FLOW ──────────────────────────
check("the lobby has no request dialog left at all",
  not ONLINE_C:find("self%.dialog"),
  "a modal in the invite flow is the thing this replaced")
check("...so nothing requires the outgoing one", not ONLINE_C:find("dialog_outgoing", 1, true))
check("a challenge the player SENDS opens a strip",
  ONLINE_C:find("open_outgoing_banner(self, u, sd)", 1, true) ~= nil)

-- ONE BUTTON ON AN OUTGOING STRIP. The answer belongs to the opponent; there is
-- nothing here to accept.
check("the outgoing strip draws no ACCEPT",
  ONLINE_C:find("if not b%.outgoing then") ~= nil)
check("...and its one button is CANCEL",
  ONLINE_C:find('decline_label = "CANCEL"', 1, true) ~= nil)
check("...sitting where the primary button always sits",
  ONLINE_C:find("local dec_x = b%.outgoing and 90 or 225") ~= nil)

-- ── EXPIRY: A STRIP ANSWERS ONLY WHERE THERE IS SOMETHING TO ANSWER ─────────
check("a lapsed table is never declined, and neither is a challenge we sent",
  ONLINE_C:find("if not b%.party_id and not b%.outgoing") ~= nil,
  "GAME_REQUEST_DECLINED for a party id is a message about a request that never existed")
check("an unanswered CHALLENGE still is, so nobody watches a spinner",
  ONLINE_C:find("ws%.decline_game_request%(b%.request_id%)") ~= nil)

-- The one that cannot be got from a fixed window: the deadline is re-read every
-- frame, so the bar tracks the table rather than drifting off it.
check("a party strip counts down to the server's deadline every frame",
  ONLINE_C:find("b%.time_left = %(b%.party_id and ms_left%(b%.closes_at%)%)") ~= nil)

-- ── THE LISTING IS THE WHOLE TRUTH, EVERY TIME ──────────────────────────────
check("a strip whose table left the listing is dropped",
  ONLINE_C:find("sync_party_banners") ~= nil)
check("...and so are all of them once we are seated at one",
  ONLINE_C:find("local seated = type%(ws%.current_party%) == \"table\"") ~= nil)
check("a table is only ever offered once, so LATER means later",
  ONLINE_C:find("self%._party_offered%[pid%] = true") ~= nil)
check("...and at most two are on screen at a time",
  ONLINE_C:find("PARTY_BANNERS_MAX") ~= nil)

-- ── JOINING: THE TABLE DRAWS ITSELF, ON EVERY SCREEN ───────────────────────
--
-- A table used to feed dialog_search — the ring, the reel and the shortlist
-- rail a tournament search uses — because from the player's side the two look
-- alike: you opened something and you are watching people arrive.
--
-- They are not alike, and the rail is where it shows. A search rail holds
-- CANDIDATES, out of whom the server picks one, which is why the reel goes on
-- hunting beside them. A party's seats are neither: four chairs, known from
-- the moment the table opens, everybody on them already in. What a player
-- actually wants to know is how many chairs are LEFT — the one thing a rail
-- that only draws arrivals cannot show.
--
-- And it was drawn by the ONLINE SCREEN, so it only existed there: a player
-- who joined from the lobby or mid-game got a line of text and found out how
-- it went when a board appeared.
--
-- Both are the same fix. The table is now the incoming overlay's, which is
-- global and already carries every other invite.
check("JOIN takes a seat and opens no dialog of its own",
  RIGHT_C:find("function M%.join_party_search") ~= nil
    and RIGHT_C:match("function M%.join_party_search.-ws%.party_join%(pid%)") ~= nil)
-- Read the two PARTY branches themselves rather than the whole file: the
-- NORMAL branch a few lines below each of them still opens a search dialog,
-- and it should — a battle really does shortlist candidates.
local function party_branch(from)
  local at = RIGHT_C:find(from, 1, false)
  if not at then return "" end
  local rest = RIGHT_C:sub(at)
  return rest:sub(1, (rest:find("return true", 1, true) or #rest) + 10)
end
check("...and the search dialog is not what a table opens any more",
  party_branch("ws%.party_create"):find("invite_search", 1, true) == nil
    and party_branch("function M%.join_party_search"):find("invite_search", 1, true) == nil,
  "a table on the search dialog counts candidates, and a table has none")
check("...on the host's side either",
  RIGHT_C:match("ws%.party_create.-rebuild_cb%(%)") ~= nil)
check("...so the online screen no longer re-aims a ring at a table's deadline",
  ONLINE_C:find("search_clock%.adopt%(sr, roster%.remaining_ms, 0, nil%)") == nil)

-- THE TABLE ITSELF, on the overlay: a roster puts it up, and only the server
-- takes it down.
check("a roster raises the table wherever the player is standing",
  OVERLAY_C:find('hash%("party_roster"%)') ~= nil
    and OVERLAY_C:find("open_party_table%(self, ws%.current_party%)") ~= nil)
check("...as a full dialog, never the one-line strip",
  OVERLAY_C:match("party_table = true.-banner = false") ~= nil)
check("...and the input budget may not demote it to one",
  OVERLAY_C:find("if self%.dialog and self%.dialog%.party_table then showing = nil end") ~= nil,
  "a strip cannot show four chairs filling")
check("...counting down to the TABLE's deadline, not a fresh window",
  OVERLAY_C:match("open_party_table.-view%.closes_at %- now_ms") ~= nil,
  "a guest arriving partway through must not be promised time the table has not got")
check("...and the clock is not restarted by a seat filling",
  OVERLAY_C:match("local same = prev and prev%.party_table and prev%.party_id == view%.party_id") ~= nil,
  "a countdown reset by each arrival is a table that never closes")
check("zero on the clock waits for the server rather than declaring failure",
  OVERLAY_C:match("if self%.dialog%.party_table then%s*\n%s*if self%.dialog%.time_left < 0 then") ~= nil)
check("...but not forever, so a dropped socket is never a dead app",
  OVERLAY_C:find("PARTY_STALL_GRACE_SECONDS") ~= nil,
  "a table has no Cancel: the entry is committed on the seat")
check("...and that backstop is written down once, not on both surfaces",
  RIGHT_C:find("function M%.arm_party_failsafe") == nil)
check("a clear meant for a request never takes the table down",
  OVERLAY_C:match('hash%("incoming_clear"%).-if self%.dialog and self%.dialog%.party_table then return end') ~= nil)
check("the table is ended by the server saying so, and nothing else",
  OVERLAY_C:find('hash%("party_over"%)') ~= nil
    and OVERLAY_C:find('ws%.on%("party_cancelled"') ~= nil
    and OVERLAY_C:find('ws%.on%("party_starting"') ~= nil)
check("LEAVE sends the leave and waits to be told, rather than closing itself",
  OVERLAY_C:match('id == "party_leave".-ws%.party_leave%(self%.dialog%.party_id%)') ~= nil,
  "the host leaving takes the whole table, and a leave that raced the deal is too late")

-- THE SEAT FLAG IS NOT THE OFFER FLAG. `dialog.party` means a strip offering a
-- table you are NOT at, and the offer handler closes any dialog carrying it as
-- soon as that table leaves the listing — which is the instant it fills. A
-- seated table wearing the same flag would close itself at exactly the moment
-- it succeeded.
check("the seated table does not wear the offer strip's flag",
  OVERLAY_C:match("party_table = true,%s*\n[^}]-party = true") == nil)

-- ── THE SAME OFFER, EVERYWHERE ELSE ─────────────────────────────────────────
check("the overlay is told about tables too", CTRL:find('"#incoming", "party_offer"', 1, true) ~= nil)
check("...but stands down while the lobby is showing its own strip",
  OVERLAY_C:find('if app_state%.current_screen == "online" then return end') ~= nil)
check("...runs on the table's clock rather than the ten-second one",
  OVERLAY_C:find("elseif d%.party_seconds then window = math%.max%(1, d%.party_seconds%)") ~= nil)
check("...never auto-declines one",
  OVERLAY_C:find("if not self%.dialog%.cup_invite and not self%.dialog%.party") ~= nil)
check("...sends nothing at all when it is put away",
  OVERLAY_C:find("if not cup and not party") ~= nil)
check("...joins by table id when it is taken",
  OVERLAY_C:find("ws%.party_join%(party%)") ~= nil)
check("...and closes the strip when the table leaves the listing",
  OVERLAY_C:match("if seated or not still_open then close_dialog%(self%) end") ~= nil)
-- A table with three seconds left cannot be read, decided on and joined. Not
-- worth interrupting anybody for.
check("...and does not interrupt anybody for a table that is about to deal",
  OVERLAY_C:find("if left < 3 then return end") ~= nil)

-- ── A SEAT OUTRANKS A CHALLENGE ─────────────────────────────────────────────
-- The server refuses to route a request to or from a seated player and retires
-- the ones already in flight; these are the client's half, which is what stops
-- a tap that can only ever be refused.
check("the lobby will not challenge anybody while we are at a table",
  ONLINE_C:match('elseif id == "challenge".-if type%(ws%.current_party%) == "table" and ws%.current_party%.partyId then') ~= nil,
  "a refusal that arrives as a round trip reads as a failure")
check("...and drops the strips for requests the server has just retired",
  ONLINE_C:match("if type%(ws%.current_party%) == \"table\" and ws%.current_party%.partyId and self%.banners then") ~= nil)
check("the global overlay will not raise one over a table either",
  OVERLAY_C:match('hash%("incoming_request"%).-if type%(ws%.current_party%) == "table" and ws%.current_party%.partyId then return end') ~= nil)

-- ── AND NOBODY AT A TABLE IS BEING ASSESSED ─────────────────────────────────
-- A search picks its opponent on tier fit at the end of the window. A table
-- picks nobody: first come, first served, in arrival order. The two share this
-- dialog, so the words and the badges have to say which one you are in.
check("a party roster is not badged by skill",
  SEARCH_C:find("if not sr%.party then tbg, ttx = tier_colors%(r%) end") ~= nil,
  "a tier pill on a seat says a table sorts its players")
check("...and the rail says what it is rather than what it is held for",
  SEARCH_C:find('sr%.party and "AT THE TABLE" or "HELD FOR YOU"') ~= nil)

print(("party invite strip: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
