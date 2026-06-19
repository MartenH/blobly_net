module script

// prelude is Lua source loaded into every interpreter before the user script.
// It builds the ergonomic, CANoe-like scripting API (test framework, assertions,
// uds:/bus./decode, byte helpers) on top of the small set of host primitives
// registered from V (the `__*` functions). Keeping the ergonomics in Lua keeps
// the V<->C surface tiny and scalar-only.
//
// NOTE: written with DOUBLE-quoted Lua strings only, so it can live in a V raw
// string (r'...') with no escaping or accidental $-interpolation.
const prelude = r'
-- ============================ test framework ============================
__tests_total = 0
__tests_failed = 0

function test(name, fn)
  __tests_total = __tests_total + 1
  local ok, err = pcall(fn)
  if not ok then __tests_failed = __tests_failed + 1 end
  __report(name, ok, ok and "" or tostring(err))
end

-- assertions live under `check` so they do not shadow Lua`s built-in assert
check = {}
function check.equal(got, want, msg)
  if got ~= want then
    error((msg or "values differ") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
  end
end
function check.truthy(v, msg)
  if not v then error(msg or "expected a truthy value", 2) end
end
function check.between(v, lo, hi, msg)
  if type(v) ~= "number" or v < lo or v > hi then
    error((msg or "out of range") .. ": " .. tostring(v) .. " not in [" .. tostring(lo) .. ".." .. tostring(hi) .. "]", 2)
  end
end
-- expect a UDS negative response with NRC `code` while running fn
function check.nrc(code, fn)
  local ok, err = pcall(fn)
  if ok then
    error(string.format("expected NRC 0x%02X but the call succeeded", code), 2)
  end
  local want = string.format("NRC 0x%02X", code)
  if not string.find(tostring(err), want, 1, true) then
    error("expected " .. want .. " but got: " .. tostring(err), 2)
  end
end

-- ============================ byte helpers ============================
-- CAN/UDS payloads are plain Lua (byte-clean) strings.
function tohex(s)
  return (s:gsub(".", function(c) return string.format("%02X ", string.byte(c)) end)):gsub(" $", "")
end
function fromhex(h)
  h = h:gsub("%s", "")
  return (h:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end
function frombytes(t)
  local out = {}
  for i = 1, #t do out[i] = string.char(t[i]) end
  return table.concat(out)
end
function u16be(s, i) i = i or 1; return string.byte(s, i) * 256 + string.byte(s, i + 1) end
function ascii(s) return s end

-- ============================ logging ============================
function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  __log(table.concat(parts, "\t"))
end
print = function(...) log(...) end   -- route print() through the host sink too
function sleep_ms(ms) __sleep(ms) end

-- ============================ diagnostics (UDS) ============================
uds = {}
function uds.open(channel, opts)
  opts = opts or {}
  local h = __uds_open(channel, opts.tx or 0x7E0, opts.rx or 0x7E8)
  local self = { handle = h, channel = channel }
  function self:session(sub) return __uds_session(self.handle, sub or 0x01) end
  function self:read_did(did) return __uds_read_did(self.handle, did) end
  function self:write_did(did, data) return __uds_write_did(self.handle, did, data) end
  function self:tester_present() return __uds_tester_present(self.handle) end
  function self:raw(req) return __uds_raw(self.handle, req) end
  function self:read_dtcs(mask) return __uds_read_dtc(self.handle, mask or 0xFF) end
  -- security access: request the seed for `level` (odd), compute the key with
  -- `keyfn` (default = the simulated servers algorithm, XOR 0xFF), send it at
  -- level+1. Returns the seed. Raises on an invalid key (NRC 0x35).
  function self:security_access(level, keyfn)
    local seed = __uds_sec_seed(self.handle, level)
    keyfn = keyfn or function(s)
      return (s:gsub(".", function(c) return string.char(string.byte(c) ~ 0xFF) end))
    end
    __uds_sec_key(self.handle, level + 1, keyfn(seed))
    return seed
  end
  return self
end

-- ============================ raw bus + signals ============================
bus = {}
function bus.send(channel, id, data, opts)
  opts = opts or {}
  __bus_send(channel, id, opts.ext or false, data or "")
end
function bus.recv(channel, timeout_ms)
  local id, ext, data = __bus_recv(channel, timeout_ms or 1000)
  if id == nil then return nil end
  return { id = id, ext = ext, data = data }
end
-- encode a DBC message by name from a {Signal = value} table and send it
function bus.send_message(channel, name, sigs)
  local id, ext, data = __msg_template(channel, name)
  for k, v in pairs(sigs or {}) do
    data = __encode_signal(channel, name, k, v, data)
  end
  __bus_send(channel, id, ext, data)
  return { id = id, ext = ext, data = data }
end
-- decode raw bytes against the channel`s DBC -> { SignalName = physical_value }
function decode(channel, id, data, ext)
  return __decode(channel, id, ext or false, data)
end

-- ============================ sequences (wait / expect) ============================
-- Block up to timeout_ms for a frame with CAN id `id` on `channel`; return it or error.
function expect(channel, id, timeout_ms)
  timeout_ms = timeout_ms or 1000
  local deadline = __now_ms() + timeout_ms
  repeat
    local left = deadline - __now_ms()
    local f = bus.recv(channel, left > 0 and left or 0)
    if f and f.id == id then return f end
  until __now_ms() >= deadline
  error(string.format("expect: no frame id=0x%X on %s within %dms", id, channel, timeout_ms), 2)
end

-- Block until a decoded signal of message `id` matches `want` (a value, or a
-- predicate function), or timeout. Returns the matching value.
function expect_signal(channel, id, signal, want, timeout_ms)
  timeout_ms = timeout_ms or 1000
  local deadline = __now_ms() + timeout_ms
  repeat
    local left = deadline - __now_ms()
    local f = bus.recv(channel, left > 0 and left or 0)
    if f and f.id == id then
      local s = decode(channel, f.id, f.data)
      local v = s and s[signal]
      if v ~= nil then
        if type(want) == "function" then
          if want(v) then return v end
        elseif v == want then
          return v
        end
      end
    end
  until __now_ms() >= deadline
  error("expect_signal: " .. signal .. " did not match within " .. timeout_ms .. "ms", 2)
end

-- ============================ reactive callbacks ============================
-- on_message(channel, id, fn): fn(frame) fires for each matching frame during run().
-- id may be nil to match every frame on the channel.
-- on_timer(period_ms, fn): fn() fires every period_ms during run().
-- run(duration_ms): cooperative event loop — pump the listened channels + timers.
__on_msg = {}
__timers = {}
function on_message(channel, id, fn) __on_msg[#__on_msg + 1] = { channel = channel, id = id, fn = fn } end
function on_timer(period_ms, fn) __timers[#__timers + 1] = { due = __now_ms() + period_ms, period = period_ms, fn = fn } end

function run(duration_ms)
  local deadline = __now_ms() + (duration_ms or 1000)
  local chans = {}
  for _, h in ipairs(__on_msg) do chans[h.channel] = true end
  repeat
    local now = __now_ms()
    for _, t in ipairs(__timers) do
      if now >= t.due then t.fn(); t.due = now + t.period end
    end
    local any = false
    for ch, _ in pairs(chans) do
      local f = bus.recv(ch, 5)
      if f then
        any = true
        for _, h in ipairs(__on_msg) do
          if h.channel == ch and (h.id == nil or h.id == f.id) then h.fn(f) end
        end
      end
    end
    if not any then sleep_ms(2) end
  until __now_ms() >= deadline
end
'
