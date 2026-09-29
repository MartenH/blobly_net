-- diag_advanced.lua — the newer UDS services against the simulated SUT:
-- WriteDataByIdentifier (0x2E), SecurityAccess (0x27), ReadDTCInformation (0x19).

local diag = uds.open("CAN1")

test("write then read back a DID (0x2E / 0x22)", function()
  diag:write_did(0xF1AA, fromhex("CA FE"))
  check.equal(tohex(diag:read_did(0xF1AA)), "CA FE")
end)

test("security access unlocks with the seed/key exchange (0x27)", function()
  local seed = diag:security_access(0x01)   -- default key algorithm (XOR 0xFF)
  check.truthy(#seed > 0, "no seed returned")
  log("seed =", tohex(seed))
end)

test("a wrong key is rejected (NRC 0x35 invalidKey)", function()
  -- identity keyfn returns the seed unchanged -> wrong key
  check.nrc(0x35, function() diag:security_access(0x01, function(s) return s end) end)
end)

test("read DTCs returns records (0x19 sub 0x02)", function()
  local dtcs = diag:read_dtcs(0xFF)
  check.truthy(#dtcs > 0, "no DTC data")
  log("DTC record bytes:", tohex(dtcs))
end)

test("ECUReset is answered with its kind (0x11)", function()
  check.equal(tohex(diag:reset(0x01)), "01")
  check.nrc(0x12, function() diag:reset(0x09) end)
end)

test("communication control and DTC setting are acknowledged (0x28 / 0x85)", function()
  diag:comm_control(0x03)     -- disable rx and tx of the normal messages
  diag:comm_control(0x00)     -- and enable them again
  diag:dtc_setting(false)
  diag:dtc_setting(true)
end)

test("a suppressed positive response is silence, a refusal is still said", function()
  check.equal(diag:raw_suppressed("\x3E\x00"), false)  -- tester present, no answer
  check.equal(diag:raw_suppressed("\x10\x01"), false)
  check.nrc(0x12, function() diag:raw_suppressed("\x11\x05") end)
end)

-- last: it empties the simulated fault memory the tests above read
test("ClearDiagnosticInformation clears one DTC, then all (0x14)", function()
  diag:clear_dtcs(0x123456)
  check.nrc(0x31, function() diag:clear_dtcs(0x123456) end) -- gone
  diag:clear_dtcs()
  check.equal(tohex(diag:read_dtcs(0xFF)), "FF")          -- the availability mask, no DTCs
end)
