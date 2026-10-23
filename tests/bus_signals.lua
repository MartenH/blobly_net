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

test("the DBC catalog lists Powertrain and describes its signals", function()
  local names = {}
  for _, m in ipairs(dbc.messages("CAN1")) do names[m.name] = m end
  check.truthy(names.Powertrain ~= nil, "Powertrain not in the catalog")
  check.equal(names.Powertrain.id, 0x100)
  check.equal(names.Powertrain.dlc, 8)
  local rpm = dbc.signal("CAN1", "Powertrain", "EngineSpeed")
  check.equal(rpm.unit, "rpm")
  check.equal(rpm.factor, 0.25)
  check.equal(rpm.maximum, 16383.75)
  local amps = dbc.signal("CAN1", "BatteryStatus", "PackCurrent")
  check.equal(amps.signed, true)
  check.equal(amps.minimum, -3276.8)
  local gear = dbc.signal("CAN1", 0x100, "Gear")
  check.equal(gear.labels[3], "Third")
  check.equal(gear.raw_labels[6], "Sixth")
end)

test("decode reads raw values and value labels of a received frame", function()
  local f = wait_for("CAN1", 0x100, 2000)
  check.truthy(f ~= nil, "no Powertrain frame")
  local phys = decode("CAN1", f.id, f.data, f.ext)
  local raw = decode("CAN1", f.id, f.data, f.ext, "raw")
  local text = decode("CAN1", f.id, f.data, f.ext, "label")
  check.equal(raw.EngineSpeed * 0.25, phys.EngineSpeed)
  local gear = dbc.signal("CAN1", "Powertrain", "Gear")
  check.equal(text.Gear, gear.raw_labels[raw.Gear])
  check.equal(text.CruiseOn, raw.CruiseOn == 1 and "On" or "Off")
  check.equal(text.EngineSpeed, nil)
end)
