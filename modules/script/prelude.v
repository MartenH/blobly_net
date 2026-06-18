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
  function self:tester_present() return __uds_tester_present(self.handle) end
  function self:raw(req) return __uds_raw(self.handle, req) end
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
'
