-- @project ../projects/described/described.blobnet
-- diag_described.lua — a simulated ECU that answers as blobly_emb DESCRIBES it: zone_a of
-- system_full, whose project block gives only its addresses. Its DIDs, their gates, the services,
-- 0x27 and the parameter come from projects/described/nodes/zone_a/ecu.toml, so every answer
-- below is the one the real zone_a gives (the cross-check in docs/simulation.md).
--   scripts/runtests.sh tests/diag_described.lua

local function diag() return uds.open("edge", { tx = 0x7C0, rx = 0x7C8 }) end
local function u16(v) return frombytes({ (v >> 8) & 0xFF, v & 0xFF }) end

test("the description's values, at their real sizes", function()
  local d = diag()
  d:session(0x01)
  check.equal(d:read_did(0xF190), "BLOBLY-ZONE_A-H723") -- 18 bytes: multi-frame
  check.equal(tohex(d:read_did(0x0110)), "01 68")       -- SteerLimit's default, 360
  check.equal(tohex(d:read_did(0x0111)), "00")          -- uncoded
  check.equal(tohex(d:read_did(0x0102)), "00")
end)

test("a live DID reads the simulated signal", function()
  local d = diag()
  sleep_ms(120) -- a SteeringFrame or two out
  check.equal(tohex(d:read_did(0xF1A0)), "00 00 00 B4") -- the generator's 180, u32 big-endian
end)

test("a gated write needs the extended session and level 1", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x31, function() d:write_did(0x0102, fromhex("05")) end) -- not writable in default
  check.nrc(0x7F, function() d:security_access(1) end)             -- 0x27 only outside default
  d:session(0x03)
  check.nrc(0x33, function() d:write_did(0x0102, fromhex("05")) end) -- locked
  d:security_access(1) -- the description names the reference key
  d:write_did(0x0102, fromhex("05"))
  check.equal(tohex(d:read_did(0x0102)), "05")
  d:write_did(0x0102, fromhex("00"))
  d:session(0x01) -- relocks
  check.nrc(0x31, function() d:write_did(0x0102, fromhex("05")) end)
end)

test("a parameter is written within its range", function()
  local d = diag()
  d:session(0x03)
  d:security_access(1)
  check.nrc(0x31, function() d:write_did(0x0110, u16(400)) end)      -- over the range's 360
  check.nrc(0x13, function() d:write_did(0x0110, fromhex("01")) end) -- a u16 is two bytes
  d:write_did(0x0110, u16(100))
  check.equal(tohex(d:read_did(0x0110)), "00 64")
  check.equal(tohex(d:read_did(0x0111)), "01") -- coded
  d:session(0x01)
end)

test("a service the node does not serve is refused", function()
  local d = diag()
  check.nrc(0x11, function() d:raw(fromhex("31 01 FF 00")) end) -- RoutineControl
  check.nrc(0x12, function() d:raw(fromhex("11 02")) end)       -- key-off-on: only 01 and 03
  check.equal(d:dtc_count(0xFF), 4) -- every declared fault, at its power-on status
end)
