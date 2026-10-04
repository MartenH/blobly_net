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

test("DTCs read as records with named status bits (0x19 01 / 02 / 0A)", function()
  check.equal(diag:dtc_count(), 2)
  local all = diag:supported_dtcs()
  check.equal(#all, 2)
  check.equal(all[1].name, "P1234-56")
  check.truthy(all[1].confirmedDTC and all[1].testFailed, "P1234-56 is confirmed and failing")
  check.equal(#diag:dtcs(0x01), 1) -- only one has testFailed
  check.dtc(diag, "P1234-56", { confirmedDTC = true, testFailed = true })
  check.equal(math.type(all[1].code), "integer")
  check.dtc(diag, "b2bcd-ef", { confirmedDTC = true, testFailed = false }) -- 0xABCDEF, any case
  local ok, err = pcall(function() check.dtc(diag, "B2BCD-EF", { testFailed = true }) end)
  check.truthy(not ok and tostring(err):find("testFailed is false"), tostring(err))
  ok = pcall(function() check.dtc(diag, "U0001-00") end)
  check.truthy(not ok, "a DTC the server does not have passed")
end)

test("snapshots and extended data (0x19 03 / 04 / 06)", function()
  local ids = diag:snapshot_ids()
  check.equal(#ids, 1)
  check.equal(ids[1].name, "P1234-56")
  check.equal(ids[1].record, 0x01)
  -- the DID sizes are learned by reading the DIDs (0x22): no description file
  local s = diag:snapshot("P1234-56")
  check.truthy(s.confirmedDTC and s.testFailed, "the status bits ride along")
  check.equal(#s.records, 1)
  check.equal(s.records[1].number, 0x01)
  check.equal(s.records[1].dids[1].id, 0xF195)
  check.equal(tohex(s.records[1].dids[1].data), "01 00")
  check.equal(s.records[1].dids[2].data, "SN-0001")
  check.snapshot(diag, "P1234-56", { [0xF195] = fromhex("01 00"), [0xF18C] = true })
  local ok, err = pcall(function() check.snapshot(diag, "P1234-56", { [0xF195] = fromhex("02 00") }) end)
  check.truthy(not ok and tostring(err):find("expected 02 00"), tostring(err))
  ok, err = pcall(function() check.snapshot(diag, "B2BCD-EF") end)
  check.truthy(not ok and tostring(err):find("no snapshot stored"), tostring(err))
  check.equal(#diag:snapshot(0xABCDEF).records, 0) -- by code; nothing stored
  local e = check.extended(diag, "P1234-56", { occurrence = 3, aging = 0, failed_cycles = 1 })
  check.equal(tohex(e.records[1]), "00 03")
  check.extended(diag, "B2BCD-EF", { aging = 2, [2] = fromhex("02") })
  check.equal(diag:extended("P1234-56", 0x01).aging, nil) -- only the record asked for
  check.nrc(0x31, function() diag:extended("P1234-56", 0x04) end)
  check.nrc(0x31, function() diag:snapshot("U0001-00") end)
  ok, err = pcall(function() check.extended(diag, "P1234-56", { occurrence = 4 }) end)
  check.truthy(not ok and tostring(err):find("occurrence is 3, expected 4"), tostring(err))
end)

test("ECUReset is answered with its kind (0x11)", function()
  check.equal(tohex(diag:reset(0x01)), "01")
  check.nrc(0x12, function() diag:reset(0x09) end)
end)

test("DTC setting is acknowledged, communication control is not faked (0x85 / 0x28)", function()
  diag:dtc_setting(false)
  diag:dtc_setting(true)
  -- the argument is required and boolean: nothing is sent for a missing or other value
  for _, v in ipairs({ "nil", 1, "on" }) do
    local ok = pcall(function() if v == "nil" then diag:dtc_setting() else diag:dtc_setting(v) end end)
    check.truthy(not ok, "dtc_setting(" .. tostring(v) .. ") was sent")
  end
  -- the simulated ECU cannot gate its own traffic, so it refuses rather than acknowledge
  check.nrc(0x11, function() diag:comm_control(0x03) end)
end)

test("a suppressed positive response is silence, a refusal is still said", function()
  check.equal(diag:raw_suppressed("\x3E\x00"), false)  -- tester present, no answer
  check.equal(diag:raw_suppressed("\x10\x01"), false)
  check.nrc(0x12, function() diag:raw_suppressed("\x11\x05") end)
end)

-- the refusals only: a clear would empty the simulated fault memory for every later script in
-- the same invocation (mixed_carriers compares it across carriers); clearing is unit-tested
test("ClearDiagnosticInformation refuses what it cannot clear (0x14)", function()
  check.nrc(0x31, function() diag:clear_dtcs(0x000001) end) -- no such DTC
  check.nrc(0x13, function() diag:raw("\x14\xFF\xFF") end) -- a group is three bytes
  -- and a group that does not fit is refused before anything is sent, never truncated to "all"
  for _, g in ipairs({ -1, 0x1FFFFFF }) do
    local ok, err = pcall(function() diag:clear_dtcs(g) end)
    check.truthy(not ok and tostring(err):find("24%-bit"), "clear_dtcs(" .. g .. "): " .. tostring(err))
  end
  -- and one Lua cannot convert exactly is refused too, not read as group 0
  for _, g in ipairs({ 1e30, 1.5 }) do
    local ok, err = pcall(function() diag:clear_dtcs(g) end)
    check.truthy(not ok and tostring(err):find("not an integer"), "clear_dtcs(" .. g .. "): " .. tostring(err))
  end
  local ok = pcall(function() diag:reset(1.5) end)
  check.truthy(not ok, "reset(1.5) was sent")
  -- false is not "omitted": it must not become the clear-all default
  ok = pcall(function() diag:clear_dtcs(false) end)
  check.truthy(not ok, "clear_dtcs(false) was sent")
  check.equal(tohex(diag:read_dtcs(0xFF)), "FF 12 34 56 09 AB CD EF 08") -- nothing was cleared
  check.equal(tohex(diag:read_dtcs(0xFF)), "FF 12 34 56 09 AB CD EF 08") -- nothing was cleared
end)
