-- @project ../projects/described-ecu-demo/described-ecu-demo.blobnet
-- diag_nodes.lua — a node of the system model by its name, its DIDs by name through its ecu.toml
-- layout: uds.node, uds.nodes, d:read / d:write, and DTCs named by their [[fault]]. zone_a of
-- system_full, which the native simulation answers as projects/described-ecu-demo/nodes/zone_a/
-- ecu.toml describes it (tests/diag_described.lua reads the same DIDs by number).
--   scripts/runtests.sh tests/diag_nodes.lua

test("the system model names its nodes", function()
  local names = uds.nodes()
  check.equal(#names, 1)
  check.equal(names[1], "zone_a")
  local ok, err = pcall(uds.node, "zone_b")
  check.truthy(not ok and string.find(tostring(err), "there are: zone_a", 1, true), tostring(err))
end)

test("a node is reached on the channel and ids its system.toml gives it", function()
  local d = uds.node("zone_a")
  check.equal(d.node, "zone_a")
  check.equal(d.channel, "edge")
  check.equal(d:read_did(0xF190), "BLOBLY-ZONE_A-H723") -- the same connection as uds.open
  d:close()
  local e = uds.node("zone_a", { channel = "edge" })
  check.equal(e:read("VIN"), "BLOBLY-ZONE_A-H723")
end)

test("its DIDs are listed with their layout and gates", function()
  local d = uds.node("zone_a")
  local steer = d:did("SteerLimit")
  check.equal(steer.id, 0x0110)
  check.equal(steer.kind, "param")
  check.equal(steer.size, 2)
  check.equal(#steer.parts, 1)
  check.equal(steer.parts[1].label, "deg")
  check.equal(steer.parts[1].kind, "int")
  check.equal(steer.parts[1].hint, "u16 0..360")
  check.equal(steer.read, nil)
  check.equal(steer.write.sessions[1], "extended")
  check.equal(steer.write.level, 1)
  check.equal(d:did(0xF190).write, nil) -- not writable
  local all = d:dids()
  check.equal(all[1].id, 0xF190)
  check.truthy(#all > 20, "the ISO identification DIDs follow its own")
end)

test("a DID is read by name, decoded by its layout", function()
  local d = uds.node("zone_a")
  d:session(0x01)
  check.equal(d:read("SteerLimit"), 360)
  check.equal(d:read(0x0110), 360)
  local ok, err = pcall(d.read, d, "0x0110") -- a string is a name, whatever it spells
  check.truthy(not ok and string.find(tostring(err), "no DID \"0x0110\"", 1, true), tostring(err))
  check.equal(d:read("parameter status").SteerLimit, 0) -- by parameter: uncoded
  check.equal(tohex(d:read(0x0102)), "00")                 -- fixed bytes
  sleep_ms(120)
  check.equal(d:read("SteeringAngle"), 180)                -- the live signal
end)

test("a gated write says what it needs, then writes once it has it", function()
  local d = uds.node("zone_a")
  d:session(0x01)
  local ok, err = pcall(d.write, d, "SteerLimit", 300)
  check.truthy(not ok and string.find(tostring(err), "switch to the extended session (0x10 03), then unlock level 1", 1, true), tostring(err))
  d:session(0x03)
  ok, err = pcall(d.write, d, "SteerLimit", 300)
  check.truthy(not ok and string.find(tostring(err), "needs it to unlock level 1", 1, true), tostring(err))
  d:security_access(1)
  ok, err = pcall(d.write, d, "SteerLimit", 400)
  check.truthy(not ok and string.find(tostring(err), "400 is outside 0..360", 1, true), tostring(err))
  ok, err = pcall(d.write, d, "SteerLimit", "300")
  check.truthy(not ok and string.find(tostring(err), "an integer", 1, true), tostring(err))
  d:write("SteerLimit", 300)
  check.equal(d:read("SteerLimit"), 300)
  check.equal(d:read("parameter status").SteerLimit, 1) -- coded
  d:write("SteerLimit", { deg = 360 })
  check.equal(d:read("SteerLimit"), 360)
  ok, err = pcall(d.write, d, "VIN", "X")
  check.truthy(not ok and string.find(tostring(err), "not writable", 1, true), tostring(err))
  d:session(0x01)
end)

test("DTCs are named by the faults of the description", function()
  local d = uds.node("zone_a")
  local recs = d:dtcs(0xFF)
  check.equal(#recs, 4)
  check.equal(recs[1].name, "U0401-00")
  check.equal(recs[1].fault, "SpeedImplausible")
  check.equal(d:supported_dtcs()[2].fault, "SafetyCmdTimeout")
end)
