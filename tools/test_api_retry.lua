-- A REQUEST THAT NEVER LANDED IS RETRIED. A REQUEST THAT MOVED MONEY IS NOT.
--
--   Run: lua tools/test_api_retry.lua
--
-- Reported while testing through an ngrok tunnel: link-phone fails and the
-- backend never sees it. The log says why, and says it in under two seconds:
--
--   20:31:37.162  [API] POST .../auth/link-phone
--   20:31:38.840  SSLSocket mbedtls_ssl_handshake: -29312
--   20:31:38.841  HTTP request to '.../auth/link-phone' failed
--                   (http result: -1  socket result: -1000)
--
-- -29312 is MBEDTLS_ERR_SSL_CONN_EOF — the peer closed the connection during
-- the TLS handshake. At 1.7s this is nowhere near the client's own 20s budget,
-- so nothing timed out: the request failed below HTTP and the server was never
-- reached. Every websocket handshake in the same window failed identically,
-- which is a tunnel shedding connections rather than anything about this route.
--
-- parse_response already models that as status_code 0, distinct from any real
-- server answer. One retry turns most of them into a success.
--
-- THE PART THAT NEEDS GUARDING is the other side of it: status_code 0 means "no
-- answer came back", NOT "the server did not act". A response lost on the way
-- home is indistinguishable from a request that never arrived, so a blanket
-- retry would risk charging a player twice for one withdrawal.

package.path = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../?.lua;" .. package.path

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %s %s (got %s, want %s)",
        ok and "PASS" or "FAIL", label, tostring(got), tostring(want)))
end

local base = debug.getinfo(1, "S").source:match("@(.*/)") or "./"
local f = assert(io.open(base .. "../modules/api_service.lua"))
local raw = f:read("a"); f:close()
-- The comments name the endpoints being asserted absent, so absence checks run
-- against code with the prose stripped out.
local code = (raw:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))

print("A TRANSPORT FAILURE IS RETRIED")
check("retries are threaded through request()",
    code:find("local retries_left = opts.retries or 0", 1, true) ~= nil, true)
check("triggered by the no-answer case only",
    code:find("res.status_code == 0 and retries_left > 0", 1, true) ~= nil, true)
check("with a delay rather than immediately",
    code:find("timer.delay(RETRY_BACKOFF", 1, true) ~= nil, true)
check("and the budget is spent down, so it terminates",
    code:find("retries_left = retries_left - 1", 1, true) ~= nil, true)
-- Headers are rebuilt per attempt so a token that arrived in between is used.
check("headers are rebuilt each attempt",
    code:find("local headers = build_headers()", 1, true)
        > code:find("fire = function()", 1, true), true)

print("")
print("BUT ONLY WHERE REPEATING IS SAFE")
-- The default is what makes this safe by construction: an endpoint has to ask.
check("the default is no retries", code:find("opts.retries or 0", 1, true) ~= nil, true)

local function opts_for(endpoint)
    -- `(` opens a capture group in a Lua pattern, so it has to be escaped —
    -- unescaped it matched nothing and every endpoint read as MISSING.
    local at = code:find('request%("%u+", "' .. endpoint:gsub("%-", "%%-"))
    if not at then return "MISSING" end
    -- The call's own text — bounded by the START OF THE NEXT request() call,
    -- not a flat character count. Some of these calls are one line
    -- (create_tournament); others wrap a callback across several (device/
    -- phone login, whose retries option sits on the LAST line, past any
    -- fixed line or character cutoff short enough to also exclude a
    -- neighbouring function). Stopping at the next call's own opening is
    -- exact either way.
    local next_call = code:find('request%(', at + 10)
    local chunk = code:sub(at, next_call and (next_call - 1) or (at + 1000))
    return chunk:find("retries", 1, true) ~= nil and "retries" or "none"
end

print("  the way in, where a lost request means the app cannot start:")
check("    /auth/device retries", opts_for("/auth/device"), "retries")
check("    /auth/phone retries", opts_for("/auth/phone"), "retries")
check("    /auth/link-phone retries", opts_for("/auth/link-phone"), "retries")

print("  and the ones where a repeat could cost a player twice:")
check("    /payments does NOT", opts_for("/payments"), "none")
check("    /themes/purchase does NOT", opts_for("/themes/purchase"), "none")
check("    /tournaments (create) does NOT", opts_for("/tournaments"), "none")

-- The championship JOIN is a different animal from creating a tournament —
-- ensureJoined is idempotent server-side (a repeat reports charged: 0
-- rather than charging again), so it belongs with the find-or-create group
-- above, not this one. Checked separately: opts_for's prefix match on
-- "/tournaments" only ever finds the FIRST such call (create_tournament),
-- so it can't see this one at all.
do
    local at = code:find('request%("POST", "/tournaments/" %.%. tournament_id %.%. "/join"')
    local next_call = at and code:find('request%(', at + 10)
    local chunk = at and code:sub(at, next_call and (next_call - 1) or (at + 200))
    check("    /tournaments/:id/join DOES retry — it's idempotent, not a create",
        chunk ~= nil and chunk:find("retries", 1, true) ~= nil, true)
end

print("")
print("THE TUNNEL'S OTHER FAILURE MODE IS CLOSED OFF TOO")
-- ngrok's free tier serves an HTML interstitial to anything it takes for a
-- browser. That comes back 200 with markup where the JSON should be, which
-- decodes to nothing and reads to every caller as an empty answer rather than
-- a wrong one — a much harder thing to recognise than a failure.
check("the skip header is sent",
    code:find("ngrok%-skip%-browser%-warning") ~= nil, true)
check("on every request, not per call site",
    code:find("ngrok%-skip%-browser%-warning") < code:find("fire = function()", 1, true), true)

print("")
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
