-- diag_doip.lua — UDS over DoIP (ISO 13400), against the simulated DoIP entity.
--
-- The same uds.Server the CAN suites talk to, reached over real localhost TCP
-- instead of ISO-TP: no CAN ids, addressing is the logical pair configured on the
-- channel (tester_address / ecu_address). Run headless:
--   scripts/runtests.sh --project projects/doip-demo.blobnet tests/diag_doip.lua

local diag = uds.open("DoIP1", {})   -- addressing comes from the channel

test("routing activation + default session", function()
  local params = diag:session(0x01)        -- 0x10 DiagnosticSessionControl
  check.truthy(params ~= nil, "expected a session-parameter response")
end)

test("VIN reads back over DoIP", function()
  local vin = diag:read_did(0xF190)         -- 0x22 ReadDataByIdentifier
  check.equal(vin, "BLOBLYNETV0SUT001")
  check.equal(#vin, 17)
  log("VIN =", vin)
end)

test("ECU serial number", function()
  check.equal(diag:read_did(0xF18C), "SN-0001")
end)

test("software version is 1.00", function()
  check.equal(tohex(diag:read_did(0xF195)), "01 00")
end)

test("tester present keeps the connection alive", function()
  diag:tester_present()                      -- 0x3E
  sleep_ms(20)
  diag:tester_present()
end)

test("unknown DID -> negative response (NRC 0x31 requestOutOfRange)", function()
  check.nrc(0x31, function() diag:read_did(0xABCD) end)
end)

-- The carrier is chosen by channel type, not by the caller. Passing CAN ids to a
-- DoIP channel is a mistake worth reporting: they cannot be honoured, and silently
-- ignoring them would let a test think it had addressed something it had not.
test("CAN ids are refused on a DoIP channel", function()
  local ok, err = pcall(function() uds.open("DoIP1", { tx = 0x7E0, rx = 0x7E8 }) end)
  check.truthy(not ok, "expected uds.open to reject tx/rx on a DoIP channel")
  log("refused with:", tostring(err))
end)

-- The entity has TWO identity surfaces: what discovery announces and what DID 0xF190 serves.
-- A write to that DID changes one of them, so the other has to move with it — otherwise the
-- entity spends the rest of the run advertising a VIN it no longer reports.
test("writing the VIN moves the announcement with it", function()
  local d = uds.open("DoIP1")
  check.equal(doip.discover("DoIP1").vin, d:read_did(0xF190))
  d:write_did(0xF190, "REWRITTENVIN00001")
  check.equal(d:read_did(0xF190), "REWRITTENVIN00001")
  check.equal(doip.discover("DoIP1").vin, "REWRITTENVIN00001")
end)

test("a VIN the announcement could not carry is refused", function()
  local d = uds.open("DoIP1")
  local before = d:read_did(0xF190)
  check.nrc(0x31, function() d:write_did(0xF190, "TOOSHORT") end)
  check.equal(d:read_did(0xF190), before)   -- and nothing changed
end)

-- `2E F1 90` with no payload is a well-formed request that clears the record. Checking the
-- data length before the identifier missed it entirely: the server cleared the VIN, answered
-- positively, and discovery kept advertising the old one.
test("a zero-length VIN write is refused, not silently applied", function()
  local d = uds.open("DoIP1")
  local before = d:read_did(0xF190)
  check.nrc(0x31, function() d:raw(string.char(0x2E, 0xF1, 0x90)) end)
  check.equal(d:read_did(0xF190), before)
  check.equal(doip.discover("DoIP1").vin, before)
end)
