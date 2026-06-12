----------------------------------------------------------------------
-- defold_sim.lua
-- Headless simulation of the Defold runtime pieces this project touches:
-- message routing (msg.post with proper script-instance context semantics),
-- timers, go/factory/sprite stubs, and the websocket extension. Faithful on
-- the ONE semantic that matters for event flow: a Lua callback (timer,
-- websocket) executes in the context of the script instance that CREATED it,
-- so relative urls like "#" resolve against that instance — not against the
-- module that defined the closure.
--
-- Used by tools/test_tournament_flow.lua to replay the online tournament
-- sequence against the real controller.script / game.script / modules.
----------------------------------------------------------------------

local SIM = {
  clock      = 0.0,
  queue      = {},   -- pending msg.post deliveries
  timers     = {},   -- {at, cb, ctx, repeating, interval, dead}
  components = {},   -- id -> {script=true/recorder=true, self, init, on_message, update, received}
  current_ctx = "boot",
  outbound   = {},   -- websocket.send captures (decoded)
  trace      = {},
  go_db      = {},
  spawn_n    = 0,
}
_G.SIM = SIM

local function trace(kind, text)
  SIM.trace[#SIM.trace + 1] = string.format("[%7.2fs] %-10s %s", SIM.clock, kind, text)
end
SIM.log = trace

----------------------------------------------------------------------
-- hash
----------------------------------------------------------------------
local hash_memo = {}
function _G.hash(s)
  local h = hash_memo[s]
  if not h then h = "h#" .. tostring(s); hash_memo[s] = h end
  return h
end
_G.pprint = function(...) end

----------------------------------------------------------------------
-- vmath
----------------------------------------------------------------------
local v_mt
v_mt = {
  __add = function(a, b) return setmetatable({x=a.x+b.x, y=a.y+b.y, z=(a.z or 0)+(b.z or 0)}, v_mt) end,
  __sub = function(a, b) return setmetatable({x=a.x-b.x, y=a.y-b.y, z=(a.z or 0)-(b.z or 0)}, v_mt) end,
  __mul = function(a, b)
    if type(a) == "number" then return setmetatable({x=a*b.x, y=a*b.y, z=a*(b.z or 0)}, v_mt) end
    return setmetatable({x=a.x*b, y=a.y*b, z=(a.z or 0)*b}, v_mt)
  end,
}
_G.vmath = {
  vector3 = function(x, y, z)
    if type(x) == "table" then return setmetatable({x=x.x, y=x.y, z=x.z}, v_mt) end
    return setmetatable({x=x or 0, y=y or 0, z=z or 0}, v_mt)
  end,
  vector4 = function(x, y, z, w) return setmetatable({x=x or 0, y=y or 0, z=z or 0, w=w or 0}, v_mt) end,
  lerp = function(t, a, b) return a end,
}

----------------------------------------------------------------------
-- context switching
----------------------------------------------------------------------
function SIM.with_ctx(ctx, fn, ...)
  local prev = SIM.current_ctx
  SIM.current_ctx = ctx
  local ok, err = xpcall(fn, debug.traceback, ...)
  SIM.current_ctx = prev
  if not ok then
    trace("ERROR", "in ctx=" .. tostring(ctx) .. ": " .. tostring(err))
    print("!! LUA ERROR (ctx=" .. tostring(ctx) .. "):\n" .. tostring(err))
  end
  return ok
end

----------------------------------------------------------------------
-- msg
----------------------------------------------------------------------
local function resolve_target(target)
  if type(target) == "table" then
    if target.fragment and SIM.components[target.fragment] then return target.fragment end
    if target.fragment == "sprite" then return nil end -- card sprite urls
    return target.fragment
  end
  local s = tostring(target)
  if s:sub(1, 1) == "@" or s == "." then return nil end
  if s == "#" then return SIM.current_ctx end
  local frag = s:match("#(.+)$")
  if frag then return frag end
  return s
end

_G.msg = {
  url = function(a, b, c)
    if a == nil and b == nil and c == nil then
      return { path = "/controller", fragment = SIM.current_ctx }
    end
    if b ~= nil or c ~= nil then
      return { path = b, fragment = c }
    end
    local frag = tostring(a):match("#(.+)$") or tostring(a)
    return { path = "/controller", fragment = frag }
  end,
  post = function(target, message_id, message)
    local comp = resolve_target(target)
    local mid = (type(message_id) == "string") and hash(message_id) or message_id
    if comp == nil then return end
    SIM.queue[#SIM.queue + 1] = {
      target = comp, mid = mid, msg = message or {},
      sender = { path = "/controller", fragment = SIM.current_ctx },
    }
    trace("post", string.format("%s -> %s  %s", SIM.current_ctx, comp, tostring(message_id)))
  end,
}

----------------------------------------------------------------------
-- timer
----------------------------------------------------------------------
local timer_n = 0
_G.timer = {
  delay = function(secs, repeating, cb)
    timer_n = timer_n + 1
    local t = {
      id = timer_n, at = SIM.clock + secs, cb = cb, ctx = SIM.current_ctx,
      repeating = repeating, interval = secs, dead = false,
    }
    SIM.timers[#SIM.timers + 1] = t
    return t.id
  end,
  cancel = function(id)
    for _, t in ipairs(SIM.timers) do
      if t.id == id then t.dead = true end
    end
  end,
}

----------------------------------------------------------------------
-- go / factory / sprite
----------------------------------------------------------------------
_G.go = {
  property = function() end,
  PLAYBACK_ONCE_FORWARD = 1, PLAYBACK_ONCE_PINGPONG = 2, PLAYBACK_LOOP_PINGPONG = 3,
  EASING_LINEAR = 0, EASING_OUTCUBIC = 1, EASING_INOUTSINE = 2, EASING_OUTSINE = 3,
  EASING_INSINE = 4, EASING_INOUTCUBIC = 5, EASING_OUTBACK = 6, EASING_OUTQUAD = 7,
  EASING_INOUTQUAD = 8, EASING_INCUBIC = 9, EASING_OUTELASTIC = 10, EASING_INQUAD = 11,
  get_position = function(id)
    local rec = SIM.go_db[id]
    return rec and vmath.vector3(rec.pos) or vmath.vector3(0, 0, 0)
  end,
  set_position = function(pos, id)
    local rec = SIM.go_db[id]
    if rec then rec.pos = vmath.vector3(pos) end
  end,
  set = function(id, prop, val)
    local rec = SIM.go_db[id]
    if not rec then error("go.set on missing object " .. tostring(id)) end
    if prop == "position.z" then rec.pos.z = val
    elseif prop == "position" then rec.pos = vmath.vector3(val)
    else rec.props[prop] = val end
  end,
  get = function(id, prop)
    local rec = SIM.go_db[id]
    if not rec then error("go.get on missing object " .. tostring(id)) end
    return rec.props[prop]
  end,
  animate = function(id, prop, playback, to, easing, dur, delay, cb)
    delay = delay or 0
    local rec = SIM.go_db[id]
    if rec then
      if prop == "position" then rec.pos = vmath.vector3(to)
      elseif prop == "position.y" then rec.pos.y = to
      elseif prop == "position.z" then rec.pos.z = to
      else rec.props[prop] = to end
    end
    if cb then
      timer_n = timer_n + 1
      SIM.timers[#SIM.timers + 1] = {
        id = timer_n, at = SIM.clock + dur + delay, ctx = SIM.current_ctx, dead = false,
        cb = function() cb(SIM.components[SIM.current_ctx] and SIM.components[SIM.current_ctx].self, nil, id) end,
      }
    end
  end,
  cancel_animations = function() end,
  delete = function(id) SIM.go_db[id] = nil end,
}

_G.factory = {
  create = function(url, pos, rot, props)
    SIM.spawn_n = SIM.spawn_n + 1
    local id = "card_" .. SIM.spawn_n
    SIM.go_db[id] = { pos = vmath.vector3(pos or vmath.vector3(0, 0, 0)), props = {} }
    return id
  end,
}

_G.sprite = { play_flipbook = function() end }
_G.window = { get_size = function() return 2400, 1080 end }
_G.sys = {
  get_save_file = function() return "/tmp/sim_save" end,
  save = function() return false end,
  load = function() return {} end,
}

----------------------------------------------------------------------
-- socket / os time
----------------------------------------------------------------------
local BASE_TIME = 1760000000
_G.socket = { gettime = function() return BASE_TIME + SIM.clock end }
local real_os_time = os.time
os.time = function(t) if t then return real_os_time(t) end return math.floor(BASE_TIME + SIM.clock) end

----------------------------------------------------------------------
-- websocket extension
----------------------------------------------------------------------
local json_util -- set lazily (module dir on package.path by the test)
_G.websocket = {
  EVENT_CONNECTED = "EVENT_CONNECTED", EVENT_DISCONNECTED = "EVENT_DISCONNECTED",
  EVENT_ERROR = "EVENT_ERROR", EVENT_MESSAGE = "EVENT_MESSAGE",
  connect = function(url, params, cb)
    SIM.ws_conn = { cb = cb, ctx = SIM.current_ctx }
    trace("ws", "connect requested from ctx=" .. SIM.current_ctx)
    timer_n = timer_n + 1
    SIM.timers[#SIM.timers + 1] = {
      id = timer_n, at = SIM.clock + 0.05, ctx = SIM.current_ctx, dead = false,
      cb = function() SIM.ws_conn.cb(nil, SIM.ws_conn, { event = websocket.EVENT_CONNECTED }) end,
    }
    return SIM.ws_conn
  end,
  send = function(conn, payload)
    json_util = json_util or require("modules.json_util")
    local decoded = json_util.decode(payload) or {}
    SIM.outbound[#SIM.outbound + 1] = { t = SIM.clock, type = decoded.type, data = decoded.data }
    trace("ws-OUT", tostring(decoded.type))
  end,
  disconnect = function() end,
}

-- The "server" pushing a message down the socket. Runs the extension callback
-- in the ctx that called websocket.connect — exactly like the real engine.
function SIM.server_send(tbl)
  json_util = json_util or require("modules.json_util")
  assert(SIM.ws_conn, "server_send before websocket.connect")
  local payload = json_util.encode(tbl)
  trace("ws-IN", tostring(tbl.type))
  SIM.with_ctx(SIM.ws_conn.ctx, function()
    SIM.ws_conn.cb(nil, SIM.ws_conn, { event = websocket.EVENT_MESSAGE, message = payload })
  end)
end

----------------------------------------------------------------------
-- components
----------------------------------------------------------------------
function SIM.add_recorder(comp_id)
  SIM.components[comp_id] = {
    recorder = true, received = {},
    self = {},
    on_message = function(self, mid, m, sender)
      local rec = SIM.components[comp_id]
      rec.received[#rec.received + 1] = { t = SIM.clock, mid = mid, msg = m }
    end,
  }
end

function SIM.load_script_component(comp_id, path)
  local env = setmetatable({}, { __index = _G, __newindex = function(t, k, v) rawset(t, k, v) end })
  local chunk, err = loadfile(path, "t", env)
  assert(chunk, err)
  SIM.with_ctx(comp_id, chunk)
  SIM.components[comp_id] = {
    script = true, env = env, self = {},
    init = env.init, on_message = env.on_message, update = env.update, final = env.final,
  }
end

function SIM.init_component(comp_id)
  local c = SIM.components[comp_id]
  if c and c.init then SIM.with_ctx(comp_id, c.init, c.self) end
end

----------------------------------------------------------------------
-- scheduler
----------------------------------------------------------------------
local function deliver_pending()
  local guard = 0
  while #SIM.queue > 0 do
    guard = guard + 1
    if guard > 10000 then error("message storm") end
    local item = table.remove(SIM.queue, 1)
    local comp = SIM.components[item.target]
    if not comp then
      trace("DROP", "no component '" .. tostring(item.target) .. "' for " .. tostring(item.mid))
    elseif comp.on_message then
      SIM.with_ctx(item.target, comp.on_message, comp.self, item.mid, item.msg, item.sender)
    end
  end
end

function SIM.pump(duration, step)
  step = step or 0.05
  local target = SIM.clock + duration
  while SIM.clock < target - 1e-9 do
    SIM.clock = math.min(SIM.clock + step, target)
    -- fire due timers (collect first; firing may schedule more)
    local due = {}
    for _, t in ipairs(SIM.timers) do
      if not t.dead and t.at <= SIM.clock then due[#due + 1] = t end
    end
    for _, t in ipairs(due) do
      if t.repeating then t.at = SIM.clock + t.interval else t.dead = true end
      SIM.with_ctx(t.ctx, t.cb)
    end
    local alive = {}
    for _, t in ipairs(SIM.timers) do if not t.dead then alive[#alive + 1] = t end end
    SIM.timers = alive

    deliver_pending()

    for id, c in pairs(SIM.components) do
      if c.script and c.update then SIM.with_ctx(id, c.update, c.self, step) end
    end
    deliver_pending()
  end
end

return SIM
