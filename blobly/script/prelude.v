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

-- the line of the running script a failure was raised at: the innermost frame in that file, else
-- the innermost in any file, else 0
local getinfo = debug.getinfo
local test_xpcall = xpcall -- the one protected call a deadline does not see through (set_deadline)
local function failure_line()
  local chunk = __script_chunk()
  local first = 0
  local level = 3
  while true do
    local info = getinfo(level, "Sl")
    if not info then break end
    if info.currentline > 0 and string.sub(info.source, 1, 1) == "@" then
      if info.source == chunk then return info.currentline end
      if first == 0 then first = info.currentline end
    end
    level = level + 1
  end
  return first
end

function test(name, fn)
  if __expired() then error("run timeout", 0) end
  __tests_total = __tests_total + 1
  __test_begin(name)
  local line = 0
  local ok, err = test_xpcall(fn, function(e) line = failure_line() return e end)
  if not ok then __tests_failed = __tests_failed + 1 end
  __report(name, ok, ok and "" or tostring(err), line)
  -- past the run deadline the script ends here rather than starting its next test
  if __expired() then error(ok and "run timeout" or err, 0) end
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
-- check.e2e(frame [, msg]): the received frame passed its E2E check (frame.e2e == "ok"); an error
-- naming the verdict otherwise, and one saying so for a frame whose message has no E2E. Returns
-- the frame, so check.e2e(expect(channel, id)) reads as one step.
function check.e2e(f, msg)
  local what = msg or "check.e2e"
  if type(f) ~= "table" then error(what .. ": no frame", 2) end
  if f.e2e == nil then
    error(string.format("%s: frame 0x%X has no E2E to check (no verify: entry or DBC declaration describes its message)", what, f.id), 2)
  end
  if f.e2e ~= "ok" then
    error(string.format("%s: frame 0x%X failed its E2E check: %s", what, f.id, f.e2e), 2)
  end
  return f
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

-- __dtc_arg: a DTC given by name ("U0401-00") or by its 24-bit code, as the code
function __dtc_arg(dtc, level)
  if type(dtc) == "number" then return dtc end
  local code = __uds_dtc_code(tostring(dtc))
  if code == nil then error("not a DTC name: " .. tostring(dtc), level + 1) end
  return code
end

-- check.snapshot(diag, name [, want]): the server holds a snapshot of DTC `name` (0x19 04), and
-- each DID `want` names was captured with the value it gives (bytes), e.g. { [0xF1A0] = fromhex("00 00 00 2A") };
-- a DID given as true only has to be there. Returns the snapshot.
function check.snapshot(diag, name, want)
  local s = diag:snapshot(name)
  if #s.records == 0 then error(string.format("%s: no snapshot stored (status 0x%02X)", s.name, s.status), 2) end
  for id, v in pairs(want or {}) do
    -- every record holding the DID is looked at: one with the wanted value is enough
    local seen, hit = nil, false
    for _, r in ipairs(s.records) do
      for _, d in ipairs(r.dids) do
        if d.id == id then
          seen = d.data
          if v == true or d.data == v then hit = true end
        end
      end
    end
    if seen == nil then error(string.format("%s: the snapshot holds no DID 0x%04X", s.name, id), 2) end
    if not hit then
      error(string.format("%s: snapshot DID 0x%04X is %s in every record, expected %s", s.name, id, tohex(seen), tohex(v)), 2)
    end
  end
  return s
end

-- check.extended(diag, name, want): DTC `name`s extended data (0x19 06) has the counters `want`
-- gives — occurrence, aging, failed_cycles — or, by record number, the bytes. Returns the answer.
local ext_names = { occurrence = true, aging = true, failed_cycles = true }
function check.extended(diag, name, want)
  local e = diag:extended(name)
  for k, v in pairs(want or {}) do
    local got
    if type(k) == "number" then
      got = e.records[k]
    elseif ext_names[k] then
      got = e[k]
    else
      error("check.extended: no extended data named " .. tostring(k), 2)
    end
    if got == nil then error(string.format("%s: the answer has no %s", e.name, tostring(k)), 2) end
    if got ~= v then
      error(string.format("%s: %s is %s, expected %s", e.name, tostring(k), tostring(got), tostring(v)), 2)
    end
  end
  return e
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
-- errors name the function the script called, at the line that called it (not a tail call, so
-- level 3 is that line)
local function e2e_call(fname, prim, frame, ...)
  -- a number would be read as its decimal text
  if type(frame) ~= "string" then error(fname .. ": a frame is a string of bytes, not a " .. type(frame), 3) end
  local ok, v = pcall(prim, frame, ...)
  if not ok then error(fname .. ": " .. tostring(v), 3) end
  return v
end
function e2e.p01_crc(frame, data_id, crc_pos, counter_pos, mode)
  local crc = e2e_call("e2e.p01_crc", __e2e_p01_crc, frame, data_id, crc_pos, counter_pos, mode or "")
  return crc
end
function e2e.p01_protect(frame, data_id, crc_pos, counter_pos, counter, mode)
  local f = e2e_call("e2e.p01_protect", __e2e_p01_protect, frame, data_id, crc_pos, counter_pos, counter, mode or "")
  return f
end

sim = {}
function sim.fault(channel, node, message, kind, ms, signal)
  __sim_fault(channel, node, message, kind, ms or 0, signal or "")
end
function sim.clear_fault(channel, node, message)
  __sim_fault(channel, node, message, "clear", 0, "")
end

-- Generators: the run of the project (its `senders:`), each named by its name or "channel/name",
-- or by its position in gen.list() (a number).
--   gen.list()                   -> { { name, channel, message, id, ext, trigger, cycle_ms,
--                                       running, sent, target, note }, ... }
--   gen.fire(g)                  sends its frame once, returning once the bus took it
--   gen.start(g [, cycle_ms])    sends it on its cycle (its own when omitted)
--   gen.stop(g)                  ends the cycle; gen.fire still sends it
--   gen.cycle(g, cycle_ms)       a new cycle, from its next frame
--   gen.set(g, signal, value)    the signal at a static value, from the next frame
--   gen.source(g, signal, { type = "sine", offset = 50, amplitude = 10, freq = 1 })
--                                the signal from a value source (const, sine, sawtooth, counter,
--                                stepmod; the parameters a project writes), from the next frame
gen = {}
local gen_params = { "value", "offset", "amplitude", "freq", "phase", "min", "max", "period",
  "start", "step", "modulo", "count", "base" }
-- a generator as the primitives take it: a name and a position (0: none)
local function gsel(g)
  if type(g) == "string" then return g, 0 end
  if math.type(g) ~= "integer" or g < 1 then
    error("gen: a generator is its name or its position in gen.list() (1, 2, ...), not " .. tostring(g), 3)
  end
  return "", g
end
function gen.list() return __gen_list() end
function gen.fire(g) local n, p = gsel(g); __gen_fire(n, p) end
function gen.start(g, cycle_ms) local n, p = gsel(g); __gen_start(n, p, cycle_ms or 0) end
function gen.stop(g) local n, p = gsel(g); __gen_stop(n, p) end
function gen.cycle(g, cycle_ms) local n, p = gsel(g); __gen_cycle(n, p, cycle_ms) end
function gen.set(g, signal, value) local n, p = gsel(g); __gen_set(n, p, signal, value) end
function gen.source(g, signal, src)
  if type(src) ~= "table" or type(src.type) ~= "string" then
    error("gen.source: a source is a table naming its type, { type = \"sine\", ... }", 2)
  end
  local known = { type = true }
  for _, k in ipairs(gen_params) do known[k] = true end
  for k, v in pairs(src) do
    if not known[k] then error("gen.source: no parameter " .. tostring(k), 2) end
    if k ~= "type" and type(v) ~= "number" then error("gen.source: " .. k .. " is a number", 2) end
  end
  local args = {}
  for i, k in ipairs(gen_params) do args[i] = src[k] or (k == "step" and 1 or 0) end
  local n, p = gsel(g)
  __gen_source(n, p, signal, src.type, table.unpack(args))
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

-- someip_hex is a header field as the binding reads it: hex, or empty for one left to its default.
local function someip_hex(v)
  if v == nil then return "" end
  return string.format("%x", v)
end

-- someip.send(to, msgs [, opts]) -> messages, malformed
--
-- Send SOME/IP messages to `to` ("host:port", IPv4) FROM a local port, then hear that port for a
-- window -- one socket both ways, because a node with a static peer endpoint (a blobly_emb SOME/IP
-- node) accepts datagrams only from its configured peer and answers that same endpoint.
-- msgs: one message table or a list of them, each { service=, method=, payload=<bytes>,
-- type="notification"|"request" (default: notification for an event id, request otherwise),
-- iface=1, client=, session= }. A request goes out with a live Request ID by default (client
-- 0x1234 -- a blobly_emb node refuses client 0 -- and the run`s next session); a notification
-- with client and session 0. A request`s session, given or not, is reserved for the run like a
-- someip.call one. opts = { port = 30491, window_ms = 1000 }.
-- Returns what someip.listen returns for the window that follows the send.
function someip.send(to, msgs, opts)
  opts = opts or {}
  if type(msgs) ~= "table" then error("someip.send: msgs must be a message or a list of them", 2) end
  if msgs[1] == nil then msgs = { msgs } end
  local lines = {}
  for i, m in ipairs(msgs) do
    if math.type(m.service) ~= "integer" or math.type(m.method) ~= "integer" then
      error("someip.send: message " .. i .. " needs an integer service and method", 2)
    end
    local code = nil
    if m.type ~= nil then
      code = someip_types[m.type]
      if code == nil then error("someip.send: type must be notification or request, got " .. tostring(m.type), 2) end
    end
    local payload = tohex(m.payload or ""):gsub(" ", "")
    lines[#lines+1] = table.concat({ someip_hex(m.service), someip_hex(m.method), someip_hex(m.iface),
      someip_hex(code), someip_hex(m.client), someip_hex(m.session), payload }, "|")
  end
  local raw, malformed = __someip_send(opts.port or 30491, tostring(to), table.concat(lines, "\n"),
                                       opts.window_ms or 1000)
  return shape_someip(raw), malformed
end

-- someip.call(to, req [, opts]) -> response | nil, why
--
-- One request/response exchange (blobly/someip call: RpcClient correlation): sends `req`
-- ({service=, method=, payload=, iface=1, client=0x1234, session=next}) from the local port and
-- returns as soon as the RESPONSE or ERROR mirroring its Request ID arrives from `to` -- an ERROR
-- is an answer, with its return code in `rc`. Events, other senders and stale replies to an
-- earlier session are ignored; sessions are never reused within a run. opts = { port = 30491,
-- timeout_ms = 1000 }. nil, "no answer" when the deadline passes.
function someip.call(to, req, opts)
  opts = opts or {}
  if type(req) ~= "table" or type(req.service) ~= "number" or type(req.method) ~= "number" then
    error("someip.call: req needs an integer service and method", 2)
  end
  local outcome, rc, payload, session, client = __someip_call(opts.port or 30491, tostring(to),
    req.service, req.method, req.iface, req.client, req.session,
    (tohex(req.payload or ""):gsub(" ", "")), opts.timeout_ms or 1000)
  if outcome == "timeout" then return nil, "no answer" end
  return { type = outcome, rc = rc, payload = payload, service = req.service,
           method = req.method, client = client, session = session }
end

-- ============================ diagnostics (UDS) ============================
uds = {}
-- uds.functional(channel, id, diags, req [, window_ms]): send req ONCE on the functional id and
-- collect each connection in diags answer on its own response id, in the order of diags: a table
-- per connection, outcome "positive", "negative", "silent" (nothing, which is normal for a
-- functional request and what a suppressed positive response looks like), "pending" (0x78 and
-- then nothing) or "failed"; resp (the answer bytes), nrc, pended (0x78 on the way), err.
-- window_ms bounds the first answers (default 1000). A functional request is one Single Frame.
-- On a DoIP channel id is the functional logical address (nil = 0xE400) and diags is the one
-- connection of the channel: one TCP connection reaches one entity, so one reply; the connection
-- lost under it raises, as a CAN listener failing does.
function uds.functional(channel, id, diags, req, window_ms)
  local hs = {}
  for i = 1, #diags do
    local d = diags[i]
    if type(d) ~= "table" or type(d.handle) ~= "number" then
      error("uds.functional: diags[" .. i .. "] is not a uds.open connection", 2)
    end
    if d.__node ~= nil then __node_on(d.handle, d.__node) end -- a node connection addresses its node
    hs[i] = d.handle
  end
  return __uds_functional(channel, id, req, window_ms or 0, table.unpack(hs))
end
-- connection(h, channel): the object uds.open and uds.node answer, over the uds handle h
local function connection(h, channel)
  local self = { handle = h, channel = channel }
  function self:session(sub) return __uds_session(self.handle, sub or 0x01) end
  -- let the connection go: the next uds.open on the channel opens a new one
  function self:close() __uds_close(self.handle) end
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
  -- 0x19 03: every DTC holding a snapshot, as {code, name, record}
  function self:snapshot_ids() return __uds_snapshot_ids(self.handle) end
  -- 0x19 04: the DTC (a name like "U0401-00", or its code) with its status bits, and records =
  -- array of {number, dids = array of {id, data}}; record defaults to 0xFF (all). A snapshot DID
  -- whose size the tester does not know yet is read once (0x22) to learn it.
  function self:snapshot(dtc, record) if record == nil then record = 0xFF end return __uds_snapshot(self.handle, __dtc_arg(dtc, 2), record) end
  -- 0x19 06: the DTC with its status bits, records[number] = bytes, and blobly_emb counters by
  -- name: occurrence (0x01), aging (0x02), failed_cycles (0x03); record defaults to 0xFF (all)
  function self:extended(dtc, record) if record == nil then record = 0xFF end return __uds_extended(self.handle, __dtc_arg(dtc, 2), record) end
  -- the sizes a 0x19 04 / 06 answer does not carry: a snapshot DID the tester cannot read (or whose
  -- size varies), an extended data record other than blobly_emb ones
  function self:did_size(did, n) __uds_did_size(self.handle, did, n) end
  function self:ext_record_size(record, n) __uds_ext_size(self.handle, record, n) end
  -- security access: request the seed for `level` (odd), compute the key with
  -- `keyfn` (default = the simulated servers algorithm, XOR 0xFF), send it at
  -- level+1. Returns the seed. An all-zero seed is ISO 14229-1 "already unlocked":
  -- no key is sent. Raises on an invalid key (NRC 0x35).
  function self:security_access(level, keyfn)
    local seed, unlocked = __uds_sec_seed(self.handle, level)
    if unlocked then return seed end
    keyfn = keyfn or function(s)
      return (s:gsub(".", function(c) return string.char(string.byte(c) ~ 0xFF) end))
    end
    local target = __uds_target(self.handle)
    local key = keyfn(seed)
    -- a retarget inside keyfn would send this seed key to another ECU
    if __uds_target(self.handle) ~= target then
      error("security_access: the connection was retargeted inside keyfn; no key sent", 2)
    end
    __uds_sec_key(self.handle, level + 1, key)
    return seed
  end
  -- the waits, in ms: timeout_ms (the first answer), p2_star_ms (after each 0x78, plus margin_ms)
  -- and pending_budget_ms (one request from its send). timing() reads them as they stand;
  -- set_timing(t) states the ones t names, from the next request on
  function self:timing()
    local t, p, m, b = __uds_timing(self.handle)
    return { timeout_ms = t, p2_star_ms = p, margin_ms = m, pending_budget_ms = b }
  end
  function self:set_timing(t)
    if type(t) ~= "table" then error("set_timing(t): t is a table of waits in ms", 2) end
    __uds_set_timing(self.handle, t.timeout_ms, t.p2_star_ms, t.margin_ms, t.pending_budget_ms)
  end
  -- DoIP: requests go to logical address `address` (nil: the channel ecu_address), a node behind
  -- the gateway the entity is, on the same connection
  function self:retarget(address) __uds_retarget(self.handle, address) end
  -- keep a non-default session alive: 3E 80 every period_ms (250 .. 60000; nil or 0 stops it),
  -- from a thread of its own and never inside a request, while a session a 0x10 answer
  -- established on this connection is not the default one and nothing else went for that long.
  -- A refusal stops it until a session is answered again; a failure is logged at the next call.
  function self:keep_alive(period_ms) __uds_keep_alive(self.handle, period_ms or 0) end
  -- { period_ms, sent, failures, running, failure } -- failure the last one, "" when none
  function self:keep_alive_status()
    local period, sent, failures, running, failure = __uds_keep_alive_status(self.handle)
    return { period_ms = period, sent = sent, failures = failures, running = running, failure = failure }
  end
  return self
end
function uds.open(channel, opts)
  opts = opts or {}
  -- Passed through AS GIVEN, nil included. The CAN default (0x7E0/0x7E8) is applied on the V
  -- side, once the carrier of the channel is known: defaulting here would hand every DoIP open
  -- a pair of CAN ids that DoIP has no use for. No sentinel value is used, because every
  -- sentinel is also a number a script might mean -- 0 is a valid arbitration id, and a
  -- negative one is a mistake that must be reported rather than read as "omitted".
  local timed = opts.timeout_ms ~= nil or opts.p2_star_ms ~= nil or opts.margin_ms ~= nil or opts.pending_budget_ms ~= nil
  if timed then __uds_timing_check(opts.timeout_ms, opts.p2_star_ms, opts.margin_ms, opts.pending_budget_ms) end
  local ka = opts.keep_alive_ms
  if ka ~= nil and ka ~= 0 and (math.type(ka) ~= "integer" or ka < 250 or ka > 60000) then
    error("uds.open: keep_alive_ms " .. tostring(ka) .. ": give 250 .. 60000", 2)
  end
  local h = __uds_open(channel, opts.tx, opts.rx)
  local self = connection(h, channel)
  if timed then self:set_timing(opts) end
  if opts.keep_alive_ms ~= nil then self:keep_alive(opts.keep_alive_ms) end
  return self
end

-- uds.nodes(): the names of the nodes of the system model (the system.toml beside the project, or
-- beside one of its databases, or in the parent of its folder), in its order; empty without one.
function uds.nodes() return __uds_nodes() end

-- a part of a DID value as the text the codec of the description reads (sysview.DidDesc.encode)
local function part_text(did, part, v)
  local where = (did.name ~= "" and did.name or string.format("0x%04X", did.id)) .. "." .. part.label
  if part.kind == "int" or part.kind == "bool" then
    if type(v) == "boolean" then return v and "true" or "false" end
    if math.type(v) == "integer" then return string.format("%d", v) end
    error(where .. " is " .. (part.kind == "int" and "an integer" or "true or false") .. ", not " .. tostring(v), 3)
  end
  if type(v) ~= "string" then
    error(where .. " is a " .. (part.kind == "text" and "string" or "byte string") .. ", not " .. tostring(v), 3)
  end
  if part.kind == "text" then return v end
  return tohex(v)
end

-- uds.node(name [, opts]): a uds.open connection on the node `name` of the system model, on the
-- channel and at the ids its system.toml (else its ecu.toml) gives it -- opts.channel names the
-- channel when the node is reached on several -- with, beside every uds.open method:
--   d.node                the name of the node
--   d:dids()              its DIDs (those of its description, then the ISO identification DIDs it
--                         does not declare): {id, name, kind, size (nil: not known), by_label,
--                         parts = {{label, kind ("int", "bool", "text", "bytes"), hint}},
--                         read, write = {sessions, level} or nil (write nil: not writable)}
--   d:did(did)            one of them: did is its name, or its identifier
--   d:read(did)           0x22 decoded by its layout: the value of its one part (an integer, a
--                         boolean, a string, bytes), or a table by part label (by_label)
--   d:write(did, value)   0x2E encoded by its layout, value as read answers it; raises, nothing
--                         sent, when the layout refuses it, the DID has no write gate, or this
--                         connection has not established the session and level the gate needs
--                         ("... not written -- ... needs it to switch ..., then unlock ...")
--   d:dtcs() and the other 0x19 calls: each record carries fault, the name of its [[fault]]
function uds.node(name, opts)
  opts = opts or {}
  local h, n, channel = __uds_node(name, opts.channel)
  local self = connection(h, channel)
  self.node = name
  self.__node = n -- what uds.functional and flash.program check a node connection by (__node_on)
  -- its reads and writes are laid out by its node: it does not move to another ECU
  function self:retarget() error("uds.node: a node connection addresses its node; retarget a uds.open connection instead", 2) end
  -- a DID is its identifier when a number (one that is not an integer is refused), else its name
  -- (a numeric string is a name)
  local function by_id(did)
    if type(did) ~= "number" and type(did) ~= "string" then
      error("a DID is its name (a string) or its identifier (a number), not " .. tostring(did), 3)
    end
    return type(did) == "number"
  end
  function self:dids() return __node_dids(n) end
  function self:did(did) return __node_did(n, did, by_id(did)) end
  function self:read(did) return __node_read(self.handle, n, did, by_id(did)) end
  function self:write(did, value)
    local d = __node_did(n, did, by_id(did))
    local texts = {}
    if d.by_label or type(value) == "table" then
      if type(value) ~= "table" then error("write(" .. tostring(did) .. "): its parts go in a table by label", 2) end
      for k in pairs(value) do
        local known = false
        for _, p in ipairs(d.parts) do if p.label == k then known = true end end
        if not known then error("write(" .. tostring(did) .. "): no part " .. tostring(k), 2) end
      end
      for _, p in ipairs(d.parts) do
        if value[p.label] == nil then error("write(" .. tostring(did) .. "): part " .. p.label .. " not given", 2) end
        texts[#texts + 1] = part_text(d, p, value[p.label])
      end
    else
      texts[1] = part_text(d, d.parts[1], value)
    end
    __node_write(self.handle, n, did, by_id(did), table.unpack(texts))
  end
  local faults = __node_faults(n)
  local function named(r) if r ~= nil and r.code ~= nil then r.fault = faults[r.code] end return r end
  local function each(rs) for _, r in ipairs(rs) do named(r) end return rs end
  local dtcs, supported, ids = self.dtcs, self.supported_dtcs, self.snapshot_ids
  local snapshot, extended = self.snapshot, self.extended
  function self:dtcs(mask) return each(dtcs(self, mask)) end
  function self:supported_dtcs() return each(supported(self)) end
  function self:snapshot_ids() return each(ids(self)) end
  function self:snapshot(dtc, record) return named(snapshot(self, dtc, record)) end
  function self:extended(dtc, record) return named(extended(self, dtc, record)) end
  -- every call that asks the ECU, only while the connection addresses this node: a DoIP connection
  -- is shared with uds.open, which may retarget it (__node_on also puts the description back)
  for k, f in pairs(self) do
    if type(f) == "function" and k ~= "close" and k ~= "retarget" and k ~= "dids" and k ~= "did" then
      self[k] = function(s, ...) __node_on(s.handle, n) return f(s, ...) end
    end
  end
  return self
end

-- ============================ raw ISO-TP ============================
-- isotp.open(channel, {tx = ..., rx = ...}): whole messages on a CAN channel, sent on tx and
-- received on rx (both needed), segmented and reassembled by the ISO-TP a uds.open connection
-- rides, with no UDS on top. :send(data) returns once the message is on the wire; :recv(timeout_ms)
-- the next whole message, or nil after timeout_ms (default 1000); :close() lets it go.
isotp = {}
function isotp.open(channel, opts)
  opts = opts or {}
  local h = __isotp_open(channel, opts.tx, opts.rx)
  local self = { handle = h, channel = channel }
  function self:send(data) __isotp_send(self.handle, data) end
  function self:recv(timeout_ms)
    if timeout_ms == nil then timeout_ms = 1000 end
    return __isotp_recv(self.handle, timeout_ms)
  end
  function self:close() __isotp_close(self.handle) end
  return self
end

-- ============================ flashing ============================
-- flash.program(target, opts): the download session against a blobly_emb bootloader (0x10 02,
-- 0x29, erase, 0x34/0x36/0x37, check, 0x11) -- the session cmd/flash runs, from blobly/flash.
-- target is a channel name (opened on opts.tx/opts.rx, default 0x7B0/0x7B8, as cmd/flash) or a
-- uds.open connection (its ids; the connection a handoff to the bootloader was made on).
-- opts: image (path, required; relative to the script), base (default 0x08020000), sw_version
-- (default 1; for a raw image, which gets its header here), seed (64 hex chars) or seed_file
-- (relative to the script) -- default $BLOBLY_FLASH_SEED, else the dev tester seed --, auth = false
-- to skip 0x29, progress = function(done, total) called per whole percent of the blocks (without
-- it a line per tenth is logged; one that raises stops the transfer before the check, so the image
-- is not marked valid), quiet = true for no lines at all.
-- Returns { bytes, blocks, wrapped, auth, reset_acknowledged }; a failed step raises, named.
flash = {}
-- the callback of each flash.program in progress, innermost last: the host calls __flash_progress,
-- which calls the innermost, so a flash started inside a callback does not take the outer one
local flash_progress = {}
function __flash_progress(done, total) flash_progress[#flash_progress](done, total) end
function flash.program(target, opts)
  opts = opts or {}
  if type(opts.image) ~= "string" or opts.image == "" then
    error("flash.program: opts.image must be the path of the image", 2)
  end
  if opts.progress ~= nil and type(opts.progress) ~= "function" then
    error("flash.program: opts.progress must be a function(done, total)", 2)
  end
  local h
  if type(target) == "table" and type(target.handle) == "number" then
    if opts.tx ~= nil or opts.rx ~= nil then
      error("flash.program: a uds.open connection brings its own ids; drop tx/rx", 2)
    end
    if target.__node ~= nil then __node_on(target.handle, target.__node) end -- as uds.functional
    h = target.handle
  elseif type(target) == "string" then
    h = __flash_open(target, opts.tx, opts.rx)
  else
    error("flash.program: target must be a channel name or a uds.open connection", 2)
  end
  flash_progress[#flash_progress + 1] = opts.progress or false
  local ok, r = pcall(__flash_program, h, opts.image, opts.base, opts.sw_version, opts.auth ~= false,
    opts.seed, opts.seed_file, opts.progress ~= nil, opts.quiet == true)
  flash_progress[#flash_progress] = nil
  if not ok then error(r, 2) end
  return r
end

-- ============================ replay and recording ============================
-- replay.start(channels, opts): a recording played onto one channel, or several on one clock (a
-- name or a list of names), by blobly/player -- the rest-bus subtraction and the command protocol
-- the GUI Replay panel uses. What opts leave out the rows replay: blocks say. opts: source (the
-- recording, .log or .mf4, relative to the script), speed (above 0), loop, paused (start paused at
-- the beginning), exclude (a list of nodes subtracted by DBC sender, in place of each row own),
-- bus (the recorded bus, for one channel). Returns a replay: r:pause(), r:resume(), r:seek(s),
-- r:speed(x), r:loop(on) -- each applied before it returns --, r:status(), r:wait_done(ms) (true
-- once a non-looping replay ran out or it was stopped; default 10000), r:stop(), and r.notes, what
-- the plan kept and withheld per channel.
replay = {}
local Replay = {}
Replay.__index = Replay
function Replay:pause() __replay_ctl(self.handle, "pause") end
function Replay:resume() __replay_ctl(self.handle, "resume") end
function Replay:seek(s) __replay_ctl(self.handle, "seek", s) end
function Replay:speed(x) __replay_ctl(self.handle, "speed", x) end
function Replay:loop(on) __replay_ctl(self.handle, "loop", on == true) end
function Replay:status() return __replay_status(self.handle) end
function Replay:wait_done(ms) return __replay_wait(self.handle, ms or 10000) end
function Replay:stop() return __replay_stop(self.handle) end
local function names_of(what, channels)
  if type(channels) == "string" then return { channels } end
  if type(channels) ~= "table" or #channels == 0 then
    error(what .. ": channels must be a channel name or a list of names", 3)
  end
  for _, c in ipairs(channels) do
    if type(c) ~= "string" then error(what .. ": channels must be names", 3) end
  end
  return channels
end
function replay.start(channels, opts)
  opts = opts or {}
  local names = names_of("replay.start", channels)
  local exclude = nil
  if opts.exclude ~= nil then
    if type(opts.exclude) ~= "table" then error("replay.start: exclude must be a list of node names", 2) end
    for _, n in ipairs(opts.exclude) do
      if type(n) ~= "string" or n == "" or n:find("\n", 1, true) then
        error("replay.start: exclude must be node names, each on one line", 2)
      end
    end
    exclude = table.concat(opts.exclude, "\n")
  end
  local h = __replay_start(opts.source, opts.speed, opts.loop, opts.paused == true, exclude, opts.bus,
    table.unpack(names))
  return setmetatable({ handle = h, notes = __replay_notes(h) }, Replay)
end
-- record.start(channels, path): what the channels carry written to a candump .log (relative to the
-- script), a line per frame, ending T for a frame this process sent (tester, simulated ECU or
-- replay alike) and R for the rest. Returns a recording: rec:counts() and rec:stop(), each
-- { frames, ours, theirs, missed, dropped }.
record = {}
local Recording = {}
Recording.__index = Recording
function Recording:counts() return __record_counts(self.handle) end
function Recording:stop() return __record_stop(self.handle) end
function record.start(channels, path)
  if type(path) ~= "string" or path == "" then error("record.start: path must be a file name", 2) end
  return setmetatable({ handle = __record_start(path, table.unpack(names_of("record.start", channels))) },
    Recording)
end

-- ============================ raw bus + signals ============================
bus = {}
function bus.send(channel, id, data, opts)
  opts = opts or {}
  if opts.format ~= nil and type(opts.format) ~= "string" then
    error("bus.send: format must be a string (classic, fd or fd_brs)", 2)
  end
  __bus_send(channel, id, opts.ext or false, data or "", opts.format)
end
-- the controller`s ladder now: "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF", or "" where the
-- backend cannot say (the software buses)
function bus.health(channel) return __bus_health(channel) end
-- bus metrics of this script`s handle on the channel since it opened. load: percent over the last
-- whole second and average since open (both nil before one), frames and bits (nominal bit-times) counted,
-- the nominal rate they are priced at. DECODED frames only, both directions: what the handle
-- receives (counted when read) and what it sends. diagnostics: the backend`s counts since open.
function bus.load(channel)
  local percent, average, frames, bits, nominal = __bus_load(channel)
  return { percent = percent, average = average, frames = frames, bits = bits, nominal = nominal }
end
function bus.diagnostics(channel)
  local dropped, bus_errors, decode_errors = __bus_diagnostics(channel)
  return { dropped = dropped, bus_errors = bus_errors, decode_errors = decode_errors }
end
-- a received frame: fd/brs/esi/rtr as the wire carried it, t_ms when it was received (now_ms clock),
-- e2e its E2E verdict ("ok", "bad_crc", "repeated", "skipped", "truncated", "timeout"), nil where
-- its message has none: the verify: entry of the channel for it, else what its DBC declares
function __frame(id, ext, data, fd, brs, esi, rtr, t_ms, e2e)
  return { id = id, ext = ext, data = data, fd = fd, brs = brs, esi = esi, rtr = rtr, t_ms = t_ms,
    e2e = e2e }
end
function bus.recv(channel, timeout_ms)
  local id, ext, data, fd, brs, esi, rtr, t_ms, e2e = __bus_recv(channel, timeout_ms or 1000)
  if id == nil then return nil end
  return __frame(id, ext, data, fd, brs, esi, rtr, t_ms, e2e)
end
-- encode a DBC message by name from a {Signal = value} table and send it, its declared E2E
-- (counter and CRC) stamped over what sigs gave them; opts.e2e = false sends it as encoded
function bus.send_message(channel, name, sigs, opts)
  if opts ~= nil and type(opts) ~= "table" then error("bus.send_message: opts is a table", 2) end
  local id, ext, data = __msg_template(channel, name)
  for k, v in pairs(sigs or {}) do
    data = __encode_signal(channel, name, k, v, data)
  end
  if not (opts and opts.e2e == false) then data = __e2e_stamp(channel, name, data) end
  __bus_send(channel, id, ext, data)
  return { id = id, ext = ext, data = data }
end
-- ============================ background senders ============================
-- bus.send_cyclic(channel, id, data, period_ms, opts): the frame every period_ms (1 .. 3600000),
-- the first at once, from a thread of its own on a bus of its own (this script`s handle hears it
-- as another node`s frame), until sender:stop(), the script ends or its run stops. opts.ext,
-- opts.format as bus.send. bus.send_message_cyclic(channel, name, sigs, period_ms, opts): a DBC
-- message encoded from sigs, its declared E2E stamped on every frame (its own counter from 0)
-- unless opts.e2e = false. A sender: sender:update(data) or sender:update(sigs) from its next
-- frame, sender:period(ms), sender:status() -> { sent, failed, error, period_ms, running },
-- sender:stop() -> true once its loop is out.
local Sender = {}
Sender.__index = Sender
local function flat(sigs)
  local out = {}
  for k, v in pairs(sigs or {}) do
    if type(k) ~= "string" then error("signal names are strings", 3) end
    out[#out + 1] = k
    out[#out + 1] = v
  end
  return out
end
function Sender:update(x)
  if type(x) == "table" then __cyclic_signals(self.handle, table.unpack(flat(x)))
  elseif type(x) == "string" then __cyclic_data(self.handle, x)
  else error("sender:update: bytes (a string) or a table of signals", 2) end
end
function Sender:period(ms) __cyclic_period(self.handle, ms) end
function Sender:status()
  local sent, failed, err, period, running = __cyclic_status(self.handle)
  return { sent = sent, failed = failed, error = err, period_ms = period, running = running }
end
function Sender:stop() return __cyclic_stop(self.handle) end
function bus.send_cyclic(channel, id, data, period_ms, opts)
  opts = opts or {}
  if opts.format ~= nil and type(opts.format) ~= "string" then
    error("bus.send_cyclic: format must be a string (classic, fd or fd_brs)", 2)
  end
  if math.type(period_ms) ~= "integer" then error("bus.send_cyclic: period_ms is a whole number of ms", 2) end
  if data ~= nil and type(data) ~= "string" then error("bus.send_cyclic: data is bytes (a string)", 2) end
  if math.type(id) ~= "integer" then error("bus.send_cyclic: an id is an integer", 2) end
  return setmetatable({ handle = __cyclic_start(channel, id, opts.ext or false, data or "", opts.format,
    period_ms) }, Sender)
end
function bus.send_message_cyclic(channel, name, sigs, period_ms, opts)
  opts = opts or {}
  if math.type(period_ms) ~= "integer" then
    error("bus.send_message_cyclic: period_ms is a whole number of ms", 2)
  end
  return setmetatable({ handle = __cyclic_start_msg(channel, name, opts.e2e ~= false, period_ms,
    table.unpack(flat(sigs))) }, Sender)
end
-- decode raw bytes against the channel`s DBC -> { SignalName = value } for each signal the frame
-- carries: physical values, or with as = "raw" the field bits, or "label" the value table text
-- (a signal with no text for its value left out)
function decode(channel, id, data, ext, as)
  if as ~= nil and type(as) ~= "string" then error("decode: as is a string (physical, raw or label)", 2) end
  return __decode(channel, id, ext or false, data, as or "physical")
end

-- ============================ the DBC catalog ============================
-- dbc.messages(channel): every message of the channel`s databases, in their order, each
-- { name, id, ext, dlc, j1939, signals = { ... } }; a signal is { name, start_bit, length,
-- byte_order = "little"|"big", signed, factor, offset, minimum, maximum, unit, multiplexor,
-- multiplexed, mux_value (multiplexed only), labels = { [physical] = text },
-- raw_labels = { [raw] = text } }.
-- dbc.message(channel, name_or_id [, ext]): one message, an id of that kind (ext defaults
-- false) exactly as the database defines it; nil for none.
-- dbc.signal(channel, message, name [, ext]): one signal of a message (a name or an id); nil for none.
dbc = {}
function dbc.messages(channel) return __dbc_messages(channel) end
-- the (by_id, key, ext) a message argument is, or an error raised at the caller of the caller
local function __dbc_key(fname, key, ext)
  if type(key) == "number" then
    if math.type(key) ~= "integer" or key < 0 or key > 0x1FFFFFFF then
      error(fname .. ": an id is an integer 0..0x1FFFFFFF, not " .. key, 3)
    end
    return true, key, ext or false
  end
  if type(key) ~= "string" then error(fname .. ": a message is a name or an id", 3) end
  return false, key, false
end
function dbc.message(channel, key, ext)
  local by_id, k, x = __dbc_key("dbc.message", key, ext)
  return __dbc_message(channel, by_id, k, x)
end
function dbc.signal(channel, message, name, ext)
  local by_id, k, x = __dbc_key("dbc.signal", message, ext)
  return __dbc_signal(channel, by_id, k, x, name)
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
  local frames, carried = 0, 0
  repeat
    local left = deadline - __now_ms()
    local f = bus.recv(channel, left > 0 and left or 0)
    if f and f.id == id then
      frames = frames + 1
      local s = decode(channel, f.id, f.data)
      local v = s and s[signal]
      if v ~= nil then
        carried = carried + 1
        if type(want) == "function" then
          if want(v) then return v end
        elseif v == want then
          return v
        end
      end
    end
  until __now_ms() >= deadline
  if frames > 0 and carried == 0 then
    error("expect_signal: " .. frames .. " frame(s) came within " .. timeout_ms .. "ms, none carrying " .. signal, 2)
  end
  error("expect_signal: " .. signal .. " did not match within " .. timeout_ms .. "ms", 2)
end

-- ============================ reactive callbacks ============================
-- on_message(channel, id, fn): fn(frame) fires for each matching frame received during run() —
-- what other nodes sent; the script`s own sends are never heard back. id may be nil to match
-- every frame on the channel.
-- on_health(channel, fn): fn(state) fires during run() when the controller`s ladder has moved —
-- "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF" — sampled every 100 ms, and at its first
-- sample with the state then, however late it was registered. A software bus never fires.
-- on_timer(period_ms, fn): fn() fires every period_ms during run(), on its own grid: a late fire
-- does not move the next one, and periods missed while the script was busy are skipped.
-- run(duration_ms): the event loop. It reads every channel a handler names, and a frame it reads
-- is consumed — a later expect gets the next one — whether or not a handler matched it. No event
-- (a frame, a timer, a health sample) is taken up once the deadline has passed; a frame taken up
-- before it reaches every handler it matches.
__on_msg = {}
__on_health = {}
__timers = {}
__listened = {}
-- a channel is listened from where a handler names it on; a health handler needs it read only
-- where the backend`s ladder advances inside recv (SocketCAN, Vector), not where it is polled
local function listen(channel, for_health)
  local needs_reader = __listen(channel)
  if for_health and not needs_reader then return end
  for _, c in ipairs(__listened) do
    if c == channel then return end
  end
  __listened[#__listened + 1] = channel
end
function on_message(channel, id, fn)
  listen(channel, false)
  __on_msg[#__on_msg + 1] = { channel = channel, id = id, fn = fn }
end
function on_health(channel, fn)
  listen(channel, true)
  __on_health[#__on_health + 1] = { channel = channel, fn = fn, said = nil }
end
function on_timer(period_ms, fn)
  -- the clock counts milliseconds: a shorter period could not move a timer`s grid at all
  if type(period_ms) ~= "number" or period_ms < 1 then
    error("on_timer: the period must be a number of milliseconds, at least 1", 2)
  end
  __timers[#__timers + 1] = { due = __now_ms() + period_ms, period = period_ms, fn = fn, active = false }
end

local health_poll_ms = 100
-- each health handler is sampled for itself, so a nested run() inside an earlier handler cannot
-- leave it an older sample, and is told a known state it has not been told: kept per handler, so
-- one registered late hears the current state; "" (unknown) is never said and resets nothing
local function poll_health(deadline)
  for _, h in ipairs(__on_health) do
    if __now_ms() >= deadline then return end
    local s = __bus_health(h.channel)
    if s ~= "" and s ~= h.said then
      h.said = s
      h.fn(s)
    end
  end
end

-- past_grid moves a timer to the first point on its grid after `at`
local function past_grid(t, at)
  if t.due <= at then
    t.due = t.due + (math.floor((at - t.due) / t.period) + 1) * t.period
    while t.due <= at do t.due = t.due + t.period end -- rounding, at most once
  end
end

-- fire_timer moves a due timer to its next point on its grid BEFORE calling it, and marks it
-- running, so a run() inside its callback neither fires it again nor waits on it; and again when
-- the callback ends, so the points a long callback ran over are skipped, not fired back to back
local function fire_timer(t)
  past_grid(t, __now_ms())
  t.active = true
  -- however the callback ends: a return, an error, or the coroutine it yielded from closed
  local _ <close> = setmetatable({}, { __close = function()
    t.active = false
    past_grid(t, __now_ms())
  end })
  t.fn()
end

-- the frames being given to their handlers, oldest first — ONE queue for the script: any run(),
-- nested or in another coroutine, first finishes them and queues what it takes behind them, so
-- every handler sees a channel`s frames in order, and a coroutine suspended in a handler leaves
-- its frame to whichever run() comes next
local inflight = {}
-- per coroutine, which frame each of its delivery levels is calling a handler for, and one guard
-- every level closes as it ends: a frame whose handler did not return — it raised (even nil), or
-- yielded into a coroutine that was closed — is ended for the handlers that have not had it yet
local calling_of = setmetatable({}, { __mode = "k" })
local function calling_state()
  local co = coroutine.running()
  local s = calling_of[co]
  if not s then
    s = { calling = {} }
    s.guard = setmetatable({}, { __close = function()
      local d = table.remove(s.calling)
      if d then
        for k, e in ipairs(inflight) do
          if e == d then table.remove(inflight, k) break end
        end
      end
    end })
    calling_of[co] = s
  end
  return s
end
local taken = 0 -- frames run() has taken up, numbering them in the queue
-- a frame is ended once any coroutine that was mid-call on it is dead: it raised out of a resume,
-- which closes nothing, so no guard ran for it — however many coroutines are on the frame
local function died_on(d)
  for c, n in pairs(d.callers) do
    if n > 0 and coroutine.status(c) == "dead" then return true end
  end
  return false
end
local function deliver_inflight()
  local s = calling_state()
  local _ <close> = s.guard
  s.calling[#s.calling + 1] = false
  local level = #s.calling
  local q = inflight
  local co = coroutine.running()
  -- the frames queued when this level began, and none after: a frame an inner run() takes is
  -- that run()`s to deliver, or the next one`s — never this level`s, whose run() may be past its
  -- deadline
  local upto = #q > 0 and q[#q].n or 0
  while #q > 0 and q[1].n <= upto do
    local d = q[1]
    -- stops as soon as an inner run() has finished this frame (what it delivered came after), or
    -- a coroutine died on it
    while q[1] == d and d.i <= #__on_msg and not died_on(d) do
      local h = __on_msg[d.i]
      d.i = d.i + 1
      if h.channel == d.ch and (h.id == nil or h.id == d.f.id) then
        s.calling[level] = d
        d.callers[co] = (d.callers[co] or 0) + 1
        h.fn(d.f)
        d.callers[co] = d.callers[co] - 1
        s.calling[level] = false
      end
    end
    if q[1] == d then table.remove(q, 1) end
  end
end

-- run looks __now_ms, __wait_frame and __bus_health up as globals at every call: the model test
-- (events_test.v) replaces them
function run(duration_ms)
  local deadline = __now_ms() + (duration_ms or 1000)
  local next_health = __now_ms()
  repeat
    deliver_inflight() -- the frame an outer run() is delivering reaches its later handlers first
    local now = __now_ms()
    for _, t in ipairs(__timers) do
      if __now_ms() >= deadline then break end
      if not t.active and now >= t.due then fire_timer(t) end
    end
    if #__on_health > 0 and __now_ms() >= next_health and __now_ms() < deadline then
      next_health = __now_ms() + health_poll_ms
      poll_health(deadline)
    end
    now = __now_ms() -- after the callbacks: the time they took is not waited again
    if now >= deadline then break end
    local wake = deadline
    for _, t in ipairs(__timers) do
      if not t.active and t.due < wake then wake = t.due end
    end
    if #__on_health > 0 and next_health < wake then wake = next_health end
    -- whole milliseconds, rounded UP: a fractional wait would reach the binding as 0, a busy poll
    local wait = math.ceil(wake - now)
    if wait < 0 then wait = 0 end
    if wait > 1000 then wait = 1000 end -- the loop goes on; a run(math.huge) is not one wait
    local ch, id, ext, data, fd, brs, esi, rtr, t_ms, e2e = __wait_frame(wait, table.unpack(__listened))
    if ch then
      taken = taken + 1
      inflight[#inflight + 1] = { ch = ch, f = __frame(id, ext, data, fd, brs, esi, rtr, t_ms, e2e), i = 1, n = taken,
        callers = {} }
      deliver_inflight()
    end
  until __now_ms() >= deadline
end
'
