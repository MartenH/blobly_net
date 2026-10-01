module script

// prelude is Lua source loaded into every interpreter before the user script.
// It builds the ergonomic, professional scripting API (test framework, assertions,
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
-- check.dtc(diag, name [, want]): the server holds DTC `name` ("U0121-00", or "U0121" for failure
-- type 00), and each status bit `want` names has the value it gives, e.g.
-- { confirmedDTC = true, testFailed = false }. Read with 0x19 0A, so every status bit is as the
-- server keeps it; a server without 0x0A (NRC 0x12) is read with 0x19 02 FF instead, which lists
-- only DTCs with a status bit set. A bit outside the availability mask of the server is an error, not
-- a pass. Returns the record.
local dtc_bit_names = { testFailed = true, testFailedThisOperationCycle = true, pendingDTC = true,
  confirmedDTC = true, testNotCompletedSinceLastClear = true, testFailedSinceLastClear = true,
  testNotCompletedThisOperationCycle = true, warningIndicatorRequested = true }
function check.dtc(diag, name, want)
  local code = __uds_dtc_code(tostring(name))
  if code == nil then error("check.dtc: not a DTC name: " .. tostring(name), 2) end
  local ok, recs = pcall(function() return diag:supported_dtcs() end)
  if not ok then
    if not string.find(tostring(recs), "NRC 0x12", 1, true) then error(recs, 2) end
    recs = diag:dtcs(0xFF)
  end
  for _, r in ipairs(recs) do
    if r.code == code then
      for bit, v in pairs(want or {}) do
        if not dtc_bit_names[bit] then error("check.dtc: no status bit named " .. tostring(bit), 2) end
        if r[bit] == nil then
          error(string.format("%s: the server does not report %s (availability 0x%02X)", r.name, bit,
            r.availability), 2)
        end
        if r[bit] ~= v then
          error(string.format("%s: %s is %s, expected %s (status 0x%02X)", r.name, bit, tostring(r[bit]),
            tostring(v), r.status), 2)
        end
      end
      return r
    end
  end
  error("check.dtc: the server has no DTC " .. tostring(name), 2)
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

-- Fault injection on a simulated ECU. `kind` is one of
--   "drop" | "bad_crc" | "freeze_counter" | "out_of_range" | "clear"
-- `ms` (optional) makes it expire by itself; omit for "until cleared".
--   sim.fault("BCM", "Powertrain", "drop", 3000)
--   sim.fault("BCM", "Powertrain", "clear")
-- `channel` first, because a project may run the same node and message names on two buses and
-- dropping a frame on the wrong one invalidates observations nobody was testing.
--   sim.fault("CAN1", "SUT", "Powertrain", "drop", 3000)
-- e2e: AUTOSAR E2E Profile 1 for frames a script builds itself (the simulation stamps its own).
--   e2e.p01_crc(frame, data_id, crc_pos, counter_pos [, mode])  -> the CRC byte for the frame as it
--     stands (the CRC byte itself is not covered; mode "both" (default), "low" or "alt")
--   e2e.p01_protect(frame, data_id, crc_pos, counter_pos, counter [, mode]) -> the frame with the
--     counter (0..14) in the low nibble of counter_pos and the CRC stamped
-- Positions are 0-based byte offsets, as the [[frame]].e2e of blobly_emb writes them.
e2e = {}
-- errors name the function the script called, at the line that called it
local function p01_crc(fname, frame, data_id, crc_pos, counter_pos, mode)
  local ok, v = pcall(__e2e_p01_crc, frame, data_id, crc_pos, counter_pos, mode or "")
  if not ok then error(fname .. ": " .. tostring(v), 3) end
  return v
end
function e2e.p01_crc(frame, data_id, crc_pos, counter_pos, mode)
  return p01_crc("e2e.p01_crc", frame, data_id, crc_pos, counter_pos, mode)
end
function e2e.p01_protect(frame, data_id, crc_pos, counter_pos, counter, mode)
  if counter < 0 or counter > 14 then error("e2e.p01_protect: a Profile 1 counter is 0..14, not " .. counter, 2) end
  if counter_pos < 0 or counter_pos >= #frame or crc_pos < 0 or crc_pos >= #frame then
    error("e2e.p01_protect: crc_pos " .. crc_pos .. " / counter_pos " .. counter_pos .. " must be bytes of the " .. #frame .. "-byte frame", 2)
  end
  local b = { string.byte(frame, 1, #frame) }
  b[counter_pos + 1] = (b[counter_pos + 1] & 0xF0) | counter
  local f = string.char(table.unpack(b))
  b[crc_pos + 1] = p01_crc("e2e.p01_protect", f, data_id, crc_pos, counter_pos, mode)
  return string.char(table.unpack(b))
end

sim = {}
function sim.fault(channel, node, message, kind, ms, signal)
  __sim_fault(channel, node, message, kind, ms or 0, signal or "")
end
function sim.clear_fault(channel, node, message)
  __sim_fault(channel, node, message, "clear", 0, "")
end

-- ============================ discovery (DoIP) =============================
doip = {}

-- doip.discover(channel) -> { vin = "...", logical_address = 0x1000 }
-- The identity the entity ANNOUNCES, which is not automatically the one it serves at
-- DID 0xF190: a tester that finds one ECU on the network and reads another out of it has
-- no way to tell which is the lie, so both are observable from a script.
function doip.discover(channel)
  local vin, addr = __doip_discover(channel)
  return { vin = vin, logical_address = addr }
end

-- doip.listen(window_ms [, opts]) -> { {vin=..., logical_address=..., from="host:port"}, ... }
--
-- Unsolicited announcements, the way a real tester discovers ECUs it was never told about.
--
-- opts = { port = 13400, ip6 = false, from = "DoIP1" }. `from` names a channel and listens on
-- the port that channel is on (a `port` that contradicts it is an error, not overruled). Nothing is
-- queued for a listener that is not there, so start listening before the entity announces — or
-- give it a long enough sequence to still be in progress. IPv4 is the verified path; see
-- docs/doip.md for the IPv6 caveat.
function doip.listen(window_ms, opts)
  opts = opts or {}
  if type(opts) == "number" then opts = { port = opts } end   -- back-compat: listen(ms, port)
  -- A `from` that is not a name (a uds handle, `true`) would reach the host as "" and read as
  -- ABSENT — the quiet default this option exists to remove. Refused here, by type; and an
  -- EMPTY name too (an unset variable), which is the same "" by another route.
  if opts.from ~= nil and (type(opts.from) ~= "string" or opts.from == "") then
    error("doip.listen: from must be a channel name (a non-empty string), got " ..
          (type(opts.from) == "string" and "an empty string" or type(opts.from)), 2)
  end
  -- port 0 = "derive": with `from`, the port that channel is on; otherwise 13400.
  local raw = __doip_listen(opts.port or 0, window_ms or 1000,
                            opts.ip6 and true or false, opts.from or "")
  local out = {}
  for line in tostring(raw):gmatch("[^\n]+") do
    local vin, addr, from = line:match("^(.-)|0x(%x+)|(.+)$")
    if vin then
      out[#out+1] = { vin = vin, logical_address = tonumber(addr, 16), from = from }
    end
  end
  return out
end

-- ============================ observation (SOME/IP) ============================
someip = {}

-- shape_someip turns the binding lines into message tables (the shape someip.listen returns).
local function shape_someip(raw)
  local out = {}
  for line in tostring(raw):gmatch("[^\n]+") do
    local at, from, svc, mth, iface, mtype, client, session, rc, hex =
      line:match("^(%d+)|([^|]+)|(%x+)|(%x+)|(%x+)|([%w ]+)|(%x+)|(%x+)|(%x+)|(%x*)$")
    if at then
      local method = tonumber(mth, 16)
      out[#out+1] = {
        at_ms = tonumber(at), from = from,
        service = tonumber(svc, 16), method = method, event = method >= 0x8000,
        type = mtype:lower(), iface = tonumber(iface, 16),
        client = tonumber(client, 16), session = tonumber(session, 16), rc = tonumber(rc, 16),
        payload = fromhex(hex),
      }
    end
  end
  return out
end

-- someip.listen(window_ms [, opts]) -> messages, malformed
--
-- Sit on a port for a window and report every SOME/IP message that arrived, decoded to its
-- header; the payload is raw bytes (the layout belongs to the deployment, not to the tester).
-- Nothing is sent and nothing is subscribed to: what you hear is what the network already
-- carries -- events a blobly_emb node sends its peer (bind the peer port), events a service
-- publishes to a multicast group, SD offers (join the SD group with `group`; multicast is not
-- heard by a plain bind). An event a service sends only to subscribers is not among them; see
-- docs/scripting.md and docs/ethernet_architecture.md.
--
-- opts = { port = 30490, group = "239.x.x.x", from = "ETH1" }. `group` joins that multicast group
-- on the port, and is refused on a unicast bind host (the kernel would drop the group traffic).
-- `from` names a someip channel of the project and takes its bind host, port and group (a port,
-- or a group differing from the channel own, is an error, not overruled). An endpoint another
-- listener in this process holds is refused and names it, however this call spelled the endpoint:
-- two sockets on one UDP port SPLIT the stream rather than share it.
-- Each message: { at_ms=, from="host:port", service=, method=, event=bool, type="notification"|
-- "request"|"response"|"error"|"type nn", iface=, client=, session=, rc=, payload=<bytes> }.
-- `malformed` counts datagrams that could not be read to the end -- reported, never hidden.
function someip.listen(window_ms, opts)
  opts = opts or {}
  if opts.group ~= nil and (type(opts.group) ~= "string" or opts.group == "") then
    error("someip.listen: group must be a multicast address (a non-empty string), got " ..
          (type(opts.group) == "string" and "an empty string" or type(opts.group)), 2)
  end
  if opts.from ~= nil and (type(opts.from) ~= "string" or opts.from == "") then
    error("someip.listen: from must be a channel name (a non-empty string), got " ..
          (type(opts.from) == "string" and "an empty string" or type(opts.from)), 2)
  end
  local raw, malformed = __someip_listen(opts.port or 0, window_ms or 1000, opts.group or "",
                                         opts.from or "")
  return shape_someip(raw), malformed
end

local someip_types = { request = 0x00, notification = 0x02 }

-- someip_to checks a destination is "host:port", IPv4: the local port is bound on the IPv4
-- wildcard, which is the claim every other listener here makes.
local function someip_to(fname, to)
  if type(to) ~= "string" or not to:match("^[^:%[%]]+:%d+$") then
    error(fname .. ": to must be an IPv4 \"host:port\", got " .. tostring(to), 3)
  end
end

-- someip.send(to, msgs [, opts]) -> messages, malformed
--
-- Send SOME/IP messages to `to` ("host:port") FROM a local port, then hear that port for a
-- window -- one socket both ways, because a node with a static peer endpoint (a blobly_emb SOME/IP
-- node) accepts datagrams only from its configured peer and answers that same endpoint.
-- msgs: one message table or a list of them, each { service=, method=, payload=<bytes>,
-- type="notification"|"request" (default: notification for an event id, request otherwise),
-- iface=1, client=0, session=0 }. opts = { port = 30491, window_ms = 1000 }.
-- Returns what someip.listen returns for the window that follows the send.
function someip.send(to, msgs, opts)
  opts = opts or {}
  someip_to("someip.send", to)
  if type(msgs) ~= "table" then error("someip.send: msgs must be a message or a list of them", 2) end
  if msgs[1] == nil then msgs = { msgs } end
  local lines = {}
  for i, m in ipairs(msgs) do
    if math.type(m.service) ~= "integer" or math.type(m.method) ~= "integer" then
      error("someip.send: message " .. i .. " needs an integer service and method", 2)
    end
    local mt = m.type or (m.method >= 0x8000 and "notification" or "request")
    local code = someip_types[mt]
    if code == nil then error("someip.send: type must be notification or request, got " .. tostring(mt), 2) end
    -- a request goes out with a live Request ID by default: a blobly_emb node refuses client 0
    -- and treats session 0 as dead
    local req = code == 0
    lines[#lines+1] = string.format("%x|%x|%x|%x|%x|%x|%s", m.service, m.method, m.iface or 1,
      code, m.client or (req and 0x1234 or 0), m.session or (req and 1 or 0),
      tohex(m.payload or ""):gsub(" ", ""))
  end
  local raw, malformed = __someip_send(opts.port or 30491, to, table.concat(lines, "\n"),
                                       opts.window_ms or 1000)
  return shape_someip(raw), malformed
end

-- someip.call(to, req [, opts]) -> response | nil, why
--
-- One request/response exchange (modules/someip call: RpcClient correlation): sends `req`
-- ({service=, method=, payload=, iface=1, client=0x1234, session=next}) from the local port and
-- returns as soon as the RESPONSE or ERROR mirroring its Request ID arrives from `to` -- an ERROR
-- is an answer, with its return code in `rc`. Events, other senders and stale replies to an
-- earlier session are ignored; sessions are never reused within a run. opts = { port = 30491,
-- timeout_ms = 1000 }. nil, "no answer" when the deadline passes.
function someip.call(to, req, opts)
  opts = opts or {}
  someip_to("someip.call", to)
  if type(req) ~= "table" or type(req.service) ~= "number" or type(req.method) ~= "number" then
    error("someip.call: req needs an integer service and method", 2)
  end
  local outcome, rc, payload, session = __someip_call(opts.port or 30491, to, req.service,
    req.method, req.iface or 1, req.client or 0x1234, req.session or 0,
    tohex(req.payload or ""):gsub(" ", ""), opts.timeout_ms or 1000)
  if outcome == "timeout" then return nil, "no answer" end
  return { type = outcome, rc = rc, payload = payload, service = req.service,
           method = req.method, client = req.client or 0x1234, session = session }
end

-- ============================ diagnostics (UDS) ============================
uds = {}
-- uds.functional(channel, id, diags, req [, window_ms]): send req ONCE on the functional id and
-- collect each connection in diags answer on its own response id, in the order of diags: a table
-- per connection, outcome "positive", "negative", "silent" (nothing, which is normal for a
-- functional request and what a suppressed positive response looks like), "pending" (0x78 and
-- then nothing) or "failed"; resp (the answer bytes), nrc, pended (0x78 on the way), err.
-- window_ms bounds the first answers (default 1000). A functional request is one Single Frame.
function uds.functional(channel, id, diags, req, window_ms)
  local hs = {}
  for i = 1, #diags do
    local d = diags[i]
    if type(d) ~= "table" or type(d.handle) ~= "number" then
      error("uds.functional: diags[" .. i .. "] is not a uds.open connection", 2)
    end
    hs[i] = d.handle
  end
  return __uds_functional(channel, id, req, window_ms or 0, table.unpack(hs))
end
function uds.open(channel, opts)
  opts = opts or {}
  -- Passed through AS GIVEN, nil included. The CAN default (0x7E0/0x7E8) is applied on the V
  -- side, once the carrier of the channel is known: defaulting here would hand every DoIP open
  -- a pair of CAN ids that DoIP has no use for. No sentinel value is used, because every
  -- sentinel is also a number a script might mean -- 0 is a valid arbitration id, and a
  -- negative one is a mistake that must be reported rather than read as "omitted".
  local h = __uds_open(channel, opts.tx, opts.rx)
  local self = { handle = h, channel = channel }
  function self:session(sub) return __uds_session(self.handle, sub or 0x01) end
  function self:read_did(did) return __uds_read_did(self.handle, did) end
  function self:write_did(did, data) return __uds_write_did(self.handle, did, data) end
  function self:tester_present() return __uds_tester_present(self.handle) end
  function self:raw(req) return __uds_raw(self.handle, req) end
  function self:read_dtcs(mask) return __uds_read_dtc(self.handle, mask or 0xFF) end
  -- 0x11 ECUReset: kind 1 hard, 2 key-off-on, 3 soft; returns the answer after its SID
  -- (a default stands only for an OMITTED argument: `x or default` would turn false into it too)
  function self:reset(kind) if kind == nil then kind = 0x01 end return __uds_reset(self.handle, kind) end
  -- 0x28 CommunicationControl: control 0..3 for messages of type (1 = the normal ones)
  function self:comm_control(control, ctype) if ctype == nil then ctype = 0x01 end __uds_comm_control(self.handle, control, ctype) end
  -- 0x85 ControlDTCSetting: true = on, false = off
  function self:dtc_setting(on)
    if type(on) ~= "boolean" then error("dtc_setting(on): on must be true or false", 2) end
    __uds_dtc_setting(self.handle, on and 1 or 0)
  end
  -- 0x14 ClearDiagnosticInformation: one DTC or a group (default 0xFFFFFF, all)
  function self:clear_dtcs(group) if group == nil then group = 0xFFFFFF end __uds_clear_dtc(self.handle, group) end
  -- a request with suppress-positive-response set: a refusal raises; returns whether a positive
  -- answer came anyway
  function self:raw_suppressed(req) return __uds_raw_suppressed(self.handle, req) end
  -- 0x19 as records: {code, name = "U0121-00", status, and a boolean per ISO status bit —
  -- testFailed, testFailedThisOperationCycle, pendingDTC, confirmedDTC,
  -- testNotCompletedSinceLastClear, testFailedSinceLastClear, testNotCompletedThisOperationCycle,
  -- warningIndicatorRequested}
  function self:dtcs(mask) if mask == nil then mask = 0xFF end return __uds_dtcs(self.handle, mask) end   -- 0x19 02
  function self:supported_dtcs() return __uds_supported_dtcs(self.handle) end                              -- 0x19 0A
  function self:dtc_count(mask) if mask == nil then mask = 0xFF end return __uds_dtc_count(self.handle, mask) end -- 0x19 01
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
