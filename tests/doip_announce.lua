-- doip_announce.lua — the half of discovery a real vehicle performs.
--
-- ISO 13400: an entity broadcasts a vehicle announcement when it comes up, so a tester finds
-- ECUs nobody told it about by LISTENING rather than asking. The simulator only ever ANSWERED
-- a Vehicle Identification Request, so such a tester saw nothing at all from it.
--   scripts/runtests.sh --project projects/doip-announce-demo.blobnet tests/doip_announce.lua
--
-- Talker announces for ~4s so a suite starting after Start still hears it in progress. The
-- shipped 3 x 500ms default is covered by tests/doip_network.lua against doip-network-demo.

test("a listening tester hears an entity announce itself", function()
  local seen = doip.listen(1200)
  check.truthy(#seen > 0, "a listening tester heard nothing at all")
  local found = false
  for _, a in ipairs(seen) do
    if a.vin == "ANNOUNCERVIN00001" then
      found = true
      check.equal(a.logical_address, 0x1000)
      -- the sender endpoint travels with it: vin+address are not routable, and a tester that
      -- discovers an ECU passively still has to dial it
      check.truthy(a.from and a.from:match("127%.0%.0%.1"), "lost the sender: " .. tostring(a.from))
    end
  end
  check.truthy(found, "heard announcements, but none from Talker")
  log("heard", #seen, "announcement(s)")
end)

-- An entity announces where it is BOUND, so a listener on another port hears nothing.
test("announcements arrive on the entity's own port", function()
  local seen = doip.listen(1200, { port = 13555 })   -- AltPort lives there
  local found = false
  for _, a in ipairs(seen) do
    if a.vin == "ALTPORTVIN0000001" then found = true; check.equal(a.logical_address, 0x4000) end
  end
  check.truthy(found, "heard nothing on 13555 — announcements went to the wrong port")
end)

-- announce_count 0 is a legitimate ECU to simulate, and the fault worth injecting at a tester
-- that relies on discovery: it must stay findable by ASKING while never announcing.
test("a silent ECU never announces but still answers a direct query", function()
  local seen = doip.listen(800)
  for _, a in ipairs(seen) do
    check.truthy(a.vin ~= "SILENTECUVIN00001", "the silent ECU announced itself")
  end
  check.equal(doip.discover("Silent").vin, "SILENTECUVIN00001")
  check.equal(uds.open("Silent"):read_did(0xF190), "SILENTECUVIN00001")
end)
