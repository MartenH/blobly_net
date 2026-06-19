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
