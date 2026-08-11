-- mixed_carriers.lua — one ECU, two carriers, one script.
--
-- sim-demo defines SUT twice: on CAN1 it answers over ISO-TP at 0x7E0/0x7E8, and on DoIP1 it
-- answers over TCP at logical address 0x1000. Same identity, different transport. The script
-- body is identical either way — which is the whole claim, and worth a test rather than a
-- paragraph. Run headless:
--   scripts/runtests.sh tests/mixed_carriers.lua

local can  = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
local eth  = uds.open("DoIP1")   -- named `eth`, not `doip`: `doip` is the discovery module

test("the same VIN reads back over both carriers", function()
  local a = can:read_did(0xF190)
  local b = eth:read_did(0xF190)
  check.equal(a, "BLOBLYNETV0SUT001")
  check.equal(b, a)
  log("VIN over CAN =", a, "| over DoIP =", b)
end)

test("serial and software version agree across carriers", function()
  check.equal(eth:read_did(0xF18C), can:read_did(0xF18C))
  check.equal(tohex(eth:read_did(0xF195)), tohex(can:read_did(0xF195)))
end)

test("the same DTCs are reported on both", function()
  check.equal(tohex(eth:read_dtcs()), tohex(can:read_dtcs()))
end)

test("a session opens on each independently", function()
  check.truthy(can:session(0x01) ~= nil, "CAN session")
  check.truthy(eth:session(0x01) ~= nil, "DoIP session")
end)

-- ChassisECU lives only on CAN1. Reaching it over DoIP is not a matter of a different
-- address: the entity serves ONE logical address, and a diagnostic message aimed elsewhere is
-- NACKed rather than routed. Pinned so the limit is visible in a test and not just in prose.
test("the DoIP entity serves one logical address, not the whole bus", function()
  local chassis = uds.open("CAN1", { tx = 0x7E1, rx = 0x7E9 })
  check.equal(chassis:read_did(0xF190), "BLOBLY-CHASSIS-01")
  check.truthy(eth:read_did(0xF190) ~= "BLOBLY-CHASSIS-01",
    "the DoIP entity must not answer for another ECU")
end)

-- sim-demo's VIN happens to equal the module default, so this cannot tell a correct
-- announcement from a fallback — it pins the invariant only. tests/doip_network.lua carries
-- the version that can actually fail.
test("the DoIP entity announces what it serves", function()
  check.equal(doip.discover("DoIP1").vin, eth:read_did(0xF190))
end)
