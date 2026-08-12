-- doip_announce.lua — the half of discovery a real vehicle performs.
--
-- ISO 13400: an entity broadcasts a vehicle announcement when it comes up, so a tester finds
-- ECUs nobody told it about by LISTENING rather than asking. The simulator only ever ANSWERED
-- a Vehicle Identification Request, so such a tester saw nothing at all from it.
--   scripts/runtests.sh --project projects/doip-announce-demo.blobnet tests/doip_announce.lua
--
-- Talker uses the ISO defaults (3 x 500ms). The runner fires announcements once the script
-- environment exists, so those defaults are observable — the earlier version of this test
-- needed a 4-second sequence to pass, which hid that a normal project could not be tested.

test("a listening tester hears an entity announce itself", function()
  local seen = doip.listen(1500)
  check.truthy(#seen > 0, "a listening tester heard nothing at all")
  local by_vin = {}
  for _, a in ipairs(seen) do by_vin[a.vin] = a.logical_address end
  check.equal(by_vin["ANNOUNCERVIN00001"], 0x1000)
  -- the sender endpoint travels with it: vin+address are not routable, and a tester that
  -- discovers an ECU passively still has to dial it
  for _, a in ipairs(seen) do
    if a.vin == "ANNOUNCERVIN00001" then
      check.truthy(a.from and a.from:match("127%.0%.0%.1"), "lost the sender: " .. tostring(a.from))
    end
  end
  log("heard", #seen, "with ISO defaults; Talker at 0x1000")
end)

-- announce_count 0 is a legitimate ECU to simulate, and the fault worth injecting at a tester
-- that relies on discovery: it must stay findable by ASKING while never announcing.
test("a silent ECU never announces but still answers a direct query", function()
  local seen = doip.listen(1200)
  for _, a in ipairs(seen) do
    check.truthy(a.vin ~= "SILENTECUVIN00001", "the silent ECU announced itself")
  end
  check.equal(doip.discover("Silent").vin, "SILENTECUVIN00001")
  check.equal(uds.open("Silent"):read_did(0xF190), "SILENTECUVIN00001")
end)
