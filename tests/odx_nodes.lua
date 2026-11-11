-- @project ../projects/odx-demo.blobnet
-- odx_nodes.lua — a node a project row names by its ODX description (diagnostics: on CAN1): its
-- DIDs listed and read and written by name through the layout the ODX gives them, and its DTCs
-- named by the variant's DTC list. The simulated BodyECU answers at the node's ids.
--   scripts/runtests.sh tests/odx_nodes.lua

test("the row's ODX names the node", function()
  local names = uds.nodes()
  check.equal(#names, 1)
  check.equal(names[1], "BodyController")
  local d = uds.node("BodyController")
  check.equal(d.channel, "CAN1")
end)

test("its DIDs carry the layout the ODX gives them", function()
  local d = uds.node("BodyController")
  local vin = d:did("VIN")
  check.equal(vin.id, 0xF190)
  check.equal(vin.kind, "text")
  check.equal(vin.size, 17)
  local lamp = d:did("LampConfig")
  check.equal(lamp.kind, "fields")
  check.equal(lamp.parts[1].label, "Brightness")
  check.equal(lamp.parts[2].hint, "u16 0..65535")
  check.equal(d:did("Temperature").kind, "data") -- a LINEAR value: its bytes, not a number
end)

test("a DID is read and written by name", function()
  local d = uds.node("BodyController")
  check.equal(d:read("VIN"), "WVWZZZ1JZXW000001")
  check.equal(d:read("LampConfig").DelayMs, 1500)
  check.equal(d:read("TrimOffset"), -100)
  check.equal(tohex(d:read("Temperature")), "0B B8")
  d:write("TrimOffset", 25)
  check.equal(d:read("TrimOffset"), 25)
  d:write("LampConfig", { Brightness = 10, DelayMs = 250 })
  check.equal(d:read("LampConfig").Brightness, 10)
  local ok, err = pcall(d.write, d, "EcuSerial", "00 00 00 01")
  check.truthy(not ok and string.find(tostring(err), "not writable", 1, true), tostring(err))
end)

test("DTCs are named by the variant's DTC list", function()
  local d = uds.node("BodyController")
  local recs = d:dtcs(0xFF)
  check.equal(#recs, 2)
  check.equal(recs[1].fault, "LampOpenCircuit")
  check.equal(recs[2].fault, "SupplyLow")
end)
