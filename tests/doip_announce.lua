-- doip_announce.lua — the half of discovery a real vehicle performs.
--
-- ISO 13400: an entity broadcasts a vehicle announcement when it comes up, so a tester finds
-- ECUs nobody told it about by LISTENING rather than asking. The simulator only ever ANSWERED
-- a Vehicle Identification Request, so such a tester saw nothing at all from it.
--   scripts/runtests.sh --project projects/doip-announce-demo.blobnet tests/doip_announce.lua
--
-- The startup burst is FINITE (3 x 500ms), so a suite starting after it can miss the whole
-- sequence however the runner is ordered. These tests do not race it: doip.announce() fires the
-- sequence in the background and returns at once, so the script listens across it. That is also
-- how you would drive a tester under test.

test("a listening tester hears the entity announce itself", function()
  doip.announce("Talker")             -- returns immediately; sequence runs in the background
  local seen = doip.listen(1500)      -- 3 x 500ms, so this window covers the sequence
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
  log("heard", #seen, "announcement(s) from the triggered sequence")
end)

-- announce_count 0 is a legitimate ECU to simulate, and the fault worth injecting at a tester
-- that relies on discovery: it must stay findable by ASKING while never announcing.
test("a silent ECU never announces but still answers a direct query", function()
  doip.announce("Silent")
  local seen = doip.listen(800)
  for _, a in ipairs(seen) do
    check.truthy(a.vin ~= "SILENTECUVIN00001", "the silent ECU announced itself")
  end
  check.equal(doip.discover("Silent").vin, "SILENTECUVIN00001")
  check.equal(uds.open("Silent"):read_did(0xF190), "SILENTECUVIN00001")
end)
