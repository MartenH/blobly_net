-- @project ../projects/sim-demo.blobnet
-- e2e.p01_crc / e2e.p01_protect: AUTOSAR E2E Profile 1 for frames a script builds itself,
-- computed by the simulation's own P01 (sim.p01_crc_bytes). Checked against vectors from an
-- independent implementation (autosar-e2e, sut/e2e_oracle.py): blobly_emb overspeed's
-- BrakeStatus layout, payload E8 03 5A 00, CRC byte 4, counter byte 5, Data ID 0x1244.

local BOTH = { 0xE8, 0xF5, 0xD2, 0xCF, 0x9C, 0x81, 0xA6, 0xBB, 0x00, 0x1D, 0x3A, 0x27, 0x74, 0x69, 0x4E }
local ALT = { 0x92, 0x42, 0xA8, 0x78, 0xE6, 0x36, 0xDC, 0x0C, 0x7A, 0xAA, 0x40, 0x90, 0x0E, 0xDE, 0x34 }

test("e2e.p01_protect stamps the counter and the reference CRC", function()
  local base = fromhex("E8 03 5A 00 00 00")
  for n = 0, 14 do
    local f = e2e.p01_protect(base, 0x1244, 4, 5, n)
    check.equal(string.byte(f, 6) & 0x0F, n)
    check.equal(string.byte(f, 5), BOTH[n + 1])
    check.equal(string.byte(e2e.p01_protect(base, 0x1244, 4, 5, n, "alt"), 5), ALT[n + 1])
    check.equal(e2e.p01_crc(f, 0x1244, 4, 5), BOTH[n + 1])
  end
end)

test("e2e helpers refuse what Profile 1 cannot be", function()
  local base = fromhex("E8 03 5A 00 00 00")
  check.truthy(not pcall(e2e.p01_protect, base, 0x1244, 4, 5, 15), "a counter of 15 was stamped")
  check.truthy(not pcall(e2e.p01_crc, base, 0x10000, 4, 5), "a 17-bit Data ID was accepted")
  check.truthy(not pcall(e2e.p01_crc, base, 0x44, 4, 4), "crc and counter in one byte were accepted")
  check.truthy(not pcall(e2e.p01_crc, base, 0x44, 9, 5), "a crc_pos outside the frame was accepted")
  local ok, err = pcall(e2e.p01_protect, base, 0x44, 1, 7, 3)
  check.truthy(not ok and tostring(err):find("e2e.p01_protect: crc_pos 1 / counter_pos 7", 1, true), tostring(err))
  ok, err = pcall(e2e.p01_protect, base, 0x10000, 4, 5, 3)
  check.truthy(not ok and tostring(err):find("e2e.p01_protect:", 1, true), tostring(err))
end)
