-- doip_network.lua — a small network of DoIP entities (projects/doip-network-demo.blobnet).
--
-- Three entities on 127.0.0.1/.2/.3, each announcing its own VIN. The point of this suite is
-- that an entity's ANNOUNCED identity (what discovery returns) and its SERVED identity (DID
-- 0xF190) are the same ECU: a tester that finds "BLOBLYNETGATEWAY1" on the network and then
-- reads a different VIN out of it has no way to tell which one is the lie.
--   scripts/runtests.sh --project projects/doip-network-demo.blobnet tests/doip_network.lua

test("each entity serves the VIN it announces", function()
  local expect = {
    Gateway   = "BLOBLYNETGATEWAY1",
    EngineECU = "BLOBLYNETENGINE01",
    BodyECU   = "BLOBLYNETBODYEC01",
  }
  for chan, vin in pairs(expect) do
    local d = uds.open(chan)
    check.equal(d:read_did(0xF190), vin)
    log(chan, "->", vin)
  end
end)

test("the entities are independent -- each answers for itself", function()
  local a = uds.open("Gateway"):read_did(0xF190)
  local b = uds.open("EngineECU"):read_did(0xF190)
  check.truthy(a ~= b, "two entities must not report the same VIN")
end)
