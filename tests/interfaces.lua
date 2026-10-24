-- @project ../projects/sim-demo.blobnet
-- bus.open_iface / bus.interfaces / bus.discover_cansub / vector.*: a bus by its address with no
-- project row, the interfaces present, and Vector assignment (Windows-only, so refused by name on
-- a machine without the XL driver).

test("an address opens once and sends", function()
  local a = bus.open_iface("inproc:LUA_IFACE_A")
  check.equal(a, "inproc:LUA_IFACE_A")
  check.equal(bus.open_iface("inproc:LUA_IFACE_A"), a, "opened once")
  bus.send(a, 0x123, "\1\2")
  check.equal(bus.recv(a, 50), nil, "a script handle heard its own send")
  check.equal(bus.load(a).frames, 1)
  check.equal(bus.load(a).nominal, 500000)
end)

test("an address of a project wire hears its traffic", function()
  local name = bus.open_iface("inproc:CAN1")
  local f = bus.recv(name, 2000)
  check.truthy(f ~= nil, "nothing on inproc:CAN1 from the simulated ECUs")
  check.truthy(f.t_ms ~= nil, "a received frame has its time")
end)

test("what is not a CAN bus, or names a project channel, is refused", function()
  check.truthy(not pcall(bus.open_iface, "doip:127.0.0.1:13400"), "a DoIP endpoint opened")
  check.truthy(not pcall(bus.open_iface, "CAN1"), "a project channel name was taken for an address")
  check.truthy(not pcall(bus.open_iface, 5), "a number opened")
end)

test("the interfaces present are well-formed rows", function()
  local rows = bus.interfaces()
  check.truthy(#rows >= 2, "the software buses are always there")
  local kinds = { socketcan = true, vcan = true, pcan = true, kvaser = true, vector = true,
    cansub = true, bridge = true, udp = true, inproc = true }
  local sim = nil
  for _, r in ipairs(rows) do
    check.truthy(r.address ~= "" and kinds[r.kind] and r.description ~= "", "a malformed row")
    check.truthy(r.fd == nil or type(r.fd) == "boolean", "fd is a boolean or nil")
    if r.kind == "inproc" then sim = r end
  end
  check.truthy(sim ~= nil and sim.virtual and sim.fd == true, "no in-process bus listed")
end)

test("a CANsub browse is bounded", function()
  check.truthy(not pcall(bus.discover_cansub, 0), "a 0 ms window browsed")
  check.truthy(not pcall(bus.discover_cansub, 10001), "a window past 10 s browsed")
end)

test("Vector assignment says why it cannot be used", function()
  local why = vector.driver()
  if why == nil then return end -- a Windows bench with the XL driver: nothing to refuse here
  check.equal(#vector.assignments(), 0)
  check.truthy(not pcall(vector.slot, 1), "a slot was read without a driver")
  local ok, err = pcall(vector.assign, 1, { hw_type = 57, hw_index = 0, hw_channel = 0 }, { create = true })
  check.truthy(not ok and tostring(err):find(why, 1, true), "the refusal names the cause: " .. tostring(err))
end)
