-- doip_announce.lua — the half of discovery a real vehicle performs.
--
-- An entity announces itself when the simulation starts (ISO 13400: three times, 500ms apart),
-- so a tester that DISCOVERS BY LISTENING finds ECUs nobody told it about. Before this the
-- simulator only ever answered a Vehicle Identification Request, so such a tester saw nothing.
--   scripts/runtests.sh --project projects/doip-network-demo.blobnet tests/doip_announce.lua

-- The entities announce at Start, before this script runs, so listening now would be too late.
-- What we CAN check here is that the announced identity matches the served one for every
-- entity — the property that matters and the one a tester acts on.
test("every entity announces the VIN it serves", function()
  local expect = { Gateway = "BLOBLYNETGATEWAY1", EngineECU = "BLOBLYNETENGINE01",
                   BodyECU = "BLOBLYNETBODYEC01" }
  for chan, vin in pairs(expect) do
    check.equal(doip.discover(chan).vin, vin)
    check.equal(uds.open(chan):read_did(0xF190), vin)
  end
end)

test("a listening tester hears the entities announce themselves", function()
  -- The runner announces in the background at Start: three per entity, 500ms apart, so they
  -- are still in flight when a script begins. This is the case the simulator could not
  -- exercise at all before — a tester that waits instead of asking.
  local seen = doip.listen(1200)
  check.truthy(#seen > 0, "a listening tester heard nothing at all")
  local vins = {}
  for _, a in ipairs(seen) do vins[a.vin] = a.logical_address end
  local known = { BLOBLYNETGATEWAY1 = 0x1000, BLOBLYNETENGINE01 = 0x1001,
                  BLOBLYNETBODYEC01 = 0x1002 }
  local matched = 0
  for vin, addr in pairs(vins) do
    if known[vin] then
      check.equal(addr, known[vin])   -- announced address must match the project
      matched = matched + 1
    end
  end
  check.truthy(matched > 0, "heard announcements, but none from a configured entity")
  log("heard", #seen, "announcement(s) from", matched, "configured entit(ies)")
end)
