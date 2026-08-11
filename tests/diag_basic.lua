-- diag_basic.lua — UDS diagnostic tests against the simulated SUT ECU.
-- Tester sends on 0x7E0, the ECU answers on 0x7E8 (standard physical pair).
-- Run headless:
--   scripts/runtests.sh tests/diag_basic.lua
-- (brings up the sim-demo project's SUT + native UDS server, no GUI/Python).

local diag = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })

test("default diagnostic session starts", function()
  local params = diag:session(0x01)        -- 0x10 DiagnosticSessionControl
  check.truthy(params ~= nil, "expected a session-parameter response")
end)

test("VIN reads back over multi-frame ISO-TP", function()
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

test("tester present keeps the session alive", function()
  diag:tester_present()                      -- 0x3E
  sleep_ms(20)
  diag:tester_present()
end)

test("unknown DID -> negative response (NRC 0x31 requestOutOfRange)", function()
  check.nrc(0x31, function() diag:read_did(0xABCD) end)
end)

-- Arbitration id 0 is valid. It must reach id 0 — where nothing answers — rather than
-- being read as "unset" and quietly redirected to the 0x7E0 server, which would make this
-- read succeed against an ECU the script never asked for.
test("explicit CAN id 0 is not silently replaced by the default", function()
  local zero = uds.open("CAN1", { tx = 0, rx = 0 })
  local ok, got = pcall(function() return zero:read_did(0xF190) end)
  check.truthy(not ok, "expected no responder at id 0, got: " .. tostring(got))
end)
