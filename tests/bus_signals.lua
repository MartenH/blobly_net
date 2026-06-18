-- bus_signals.lua — raw CAN + DBC signal tests on CAN1, against the simulated
-- SUT / Chassis ECUs of the sim-demo project. Shows recv + decode, encode + send,
-- and a request/response round-trip — all driver-free over the in-process bus.

-- wait up to timeout_ms for a frame with the given CAN id
local function wait_for(channel, want, timeout_ms)
  local left = timeout_ms
  while left > 0 do
    local f = bus.recv(channel, 200)
    if f and f.id == want then return f end
    left = left - 200
  end
  return nil
end

test("SUT transmits Powertrain (0x100) cyclically", function()
  local f = wait_for("CAN1", 0x100, 2000)
  check.truthy(f ~= nil, "no Powertrain frame seen within 2s")
end)

test("decoded EngineSpeed is within the simulated range", function()
  local f = wait_for("CAN1", 0x100, 2000)
  check.truthy(f ~= nil, "no Powertrain frame")
  local sig = decode("CAN1", f.id, f.data)
  log("EngineSpeed =", sig.EngineSpeed, "rpm  Gear =", sig.Gear)
  check.between(sig.EngineSpeed, 0, 8000, "EngineSpeed out of range")
end)

test("encode -> send -> decode round-trips through the DBC", function()
  local m = bus.send_message("CAN1", "Powertrain", { EngineSpeed = 1600, Gear = 4 })
  local sig = decode("CAN1", m.id, m.data)
  check.between(sig.EngineSpeed, 1599, 1601, "EngineSpeed mis-encoded")
  check.equal(sig.Gear, 4)
end)

test("Request 0x101 -> SUT answers Response 0x102", function()
  bus.send_message("CAN1", "Request", { ReqCode = 1 })
  local f = wait_for("CAN1", 0x102, 2000)
  check.truthy(f ~= nil, "no Response (0x102) from the SUT")
  local sig = decode("CAN1", f.id, f.data)
  check.equal(sig.RespCode, 2)   -- SUT response rule: byte0 + 1
end)
