-- @project ../projects/sim-demo.blobnet
-- bus.load / bus.diagnostics: the metrics of the script's own handle on a channel. CAN2 is an
-- in-process bus at sim-demo's default 500 kbit/s; a standard 8-byte frame is 135 bit-times
-- (worst-case stuffing, transport.frame_bits).

test("bus.load counts the frames the handle sends", function()
  local before = bus.load("CAN2")
  check.equal(before.nominal, 500000)
  for i = 1, 100 do bus.send("CAN2", 0x555, "\0\0\0\0\0\0\0\0") end
  local l = bus.load("CAN2")
  check.equal(l.frames - before.frames, 100)
  check.equal(l.bits - before.bits, 100 * 135)
end)

test("bus.load reads the wire's traffic as the handle receives it", function()
  local t0 = __now_ms()
  local got = 0
  while __now_ms() - t0 < 1300 do
    if bus.recv("CAN2", 50) then got = got + 1 end
  end
  local l = bus.load("CAN2")
  check.truthy(got > 0, "the simulated ECUs sent nothing on CAN2")
  check.truthy(l.percent ~= nil, "no whole second after 1.3 s")
  check.between(l.percent, 0.001, 100)
  check.between(l.average, 0.001, 100)
end)

test("bus.diagnostics counts since open", function()
  local d = bus.diagnostics("CAN2")
  check.equal(d.dropped, 0)
  check.equal(d.bus_errors, 0)
  check.equal(d.decode_errors, 0)
end)

test("bus metrics refuse what is not a CAN bus", function()
  check.truthy(not pcall(bus.load, "DoIP1"), "a DoIP row had a load")
  check.truthy(not pcall(bus.diagnostics, "NoSuch"), "an unknown channel had diagnostics")
end)
