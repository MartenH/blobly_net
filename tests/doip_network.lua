-- doip_network.lua — a small network of DoIP entities.
--
-- @project ../projects/doip-network-demo.blobnet
--
-- Gateway, EngineECU and BodyECU exist in that project alone; against any other this test
-- reports failures rather than the configuration mistake it actually is (#115).
--
-- Three entities on 127.0.0.1/.2/.3, each announcing its own VIN. The point of this suite is
-- that an entity's ANNOUNCED identity (what discovery returns) and its SERVED identity (DID
-- 0xF190) are the same ECU: a tester that finds "BLOBLYNETGATEWAY1" on the network and then
-- reads a different VIN out of it has no way to tell which one is the lie.
--   scripts/runtests.sh --project projects/doip-network-demo.blobnet tests/doip_network.lua

test("each entity serves the VIN it announces", function()
  local expect = {
    Gateway   = { vin = "BLOBLYNETGATEWAY1", addr = 0x1000 },
    EngineECU = { vin = "BLOBLYNETENGINE01", addr = 0x1001 },
    BodyECU   = { vin = "BLOBLYNETBODYEC01", addr = 0x1002 },
  }
  for chan, want in pairs(expect) do
    -- BOTH surfaces. Reading only the DID left every entity free to advertise the default,
    -- or another entity's VIN and logical address, with this suite still green — the test
    -- named the property it was not checking.
    local served = uds.open(chan):read_did(0xF190)
    local ann = doip.discover(chan)
    check.equal(served, want.vin)
    check.equal(ann.vin, want.vin)
    check.equal(ann.logical_address, want.addr)
    log(chan, "announced", ann.vin, string.format("0x%X", ann.logical_address))
  end
end)

test("the entities are independent -- each answers for itself", function()
  local a = uds.open("Gateway"):read_did(0xF190)
  local b = uds.open("EngineECU"):read_did(0xF190)
  check.truthy(a ~= b, "two entities must not report the same VIN")
end)

-- The announcement is a SEPARATE value from DID 0xF190 — server_cfg carries one, the UDS
-- handler the other — so "they agree" has to be observed, not assumed. These VINs differ from
-- the module default, which is what makes the check able to fail.
test("discovery announces the same VIN the entity serves", function()
  for _, chan in ipairs({"Gateway", "EngineECU", "BodyECU"}) do
    local ann = doip.discover(chan)
    local served = uds.open(chan):read_did(0xF190)
    check.equal(ann.vin, served)
    log(chan, "announced", ann.vin, "at", string.format("0x%X", ann.logical_address))
  end
end)
