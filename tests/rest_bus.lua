-- @project ../projects/restbus-db.blobnet
-- rest_bus.lua — a rest bus built from the database alone.
--
-- restbus-db simulates BodyECU, ChassisECU and BatteryECU with one line, `simulate:`, and leaves
-- out SUT (the ECU under test) and Tester (the test's own role). These check what that line puts
-- on the wire: each node's cyclic messages at the DBC's cycle, signals at their start values, and,
-- with no ECU attached, nothing of SUT's; then a signal held at a value and let go, and a message
-- dropped and brought back. Ids and cycle times are read from the database, never restated.

-- the rest bus's messages and their simulated senders
local cyclic = {
  { name = "BodyStatus",    node = "BodyECU" },
  { name = "WheelSpeeds",   node = "ChassisECU" },
  { name = "BrakeStatus",   node = "ChassisECU" },
  { name = "BatteryStatus", node = "BatteryECU" },
}
-- the ECU under test's messages, which the rest bus never sends
local sut = { "Powertrain", "Heartbeat", "Response" }

-- a message's id, as the database gives it
local function id_of(name) return dbc.message("CAN1", name).id end

-- every frame read in the next window_ms, as a list of receive times per id
local function listen(channel, window_ms)
  local seen = {}
  local deadline = now_ms() + window_ms
  while now_ms() < deadline do
    local f = bus.recv(channel, 20)
    if f then
      seen[f.id] = seen[f.id] or {}
      table.insert(seen[f.id], f.t_ms)
    end
  end
  return seen
end

-- discard what is already queued, so a count starts from frames sent from now on
local function drain(channel)
  local deadline = now_ms() + 500
  while now_ms() < deadline do
    if not bus.recv(channel, 10) then return end
  end
end

test("the rest bus is up", function()
  sim.wait_ready(5000)
  expect("CAN1", id_of("WheelSpeeds"), 1000)
end)

test("each simulated node sends its messages at the database's cycle", function()
  local seen = listen("CAN1", 1700)
  for _, c in ipairs(cyclic) do
    local m = dbc.message("CAN1", c.name)
    local t = seen[m.id] or {}
    check.truthy(#t >= 3, string.format("%s (0x%X): %d frames in 1.7 s", m.name, m.id, #t))
    local mean = (t[#t] - t[1]) / (#t - 1)
    log(string.format("%-13s 0x%X from %-10s every %6.1f ms (DBC: %d ms)", m.name, m.id, c.node, mean, m.cycle_ms))
    check.between(mean, m.cycle_ms * 0.75, m.cycle_ms * 1.25, m.name .. " cycle")
  end
end)

-- On a bench the real ECU sends these, so this check is the no-ECU (CI) half of the suite.
test("with no ECU attached, nothing of SUT's is on the bus", function()
  local seen = listen("CAN1", 600)
  for _, name in ipairs(sut) do
    local id = id_of(name)
    check.equal(seen[id], nil, string.format("%s (0x%X) is SUT's, and the rest bus sent it", name, id))
  end
end)

test("signals go out at their start value: raw 0 where the DBC states none", function()
  local f = expect("CAN1", id_of("BodyStatus"), 1000)
  local s = decode("CAN1", f.id, f.data)
  check.equal(s.DoorFL, 0)
  check.equal(s.InteriorTemp, -40)   -- raw 0 with offset -40 is -40 degC, not 0
end)

test("sim.set holds one signal at a value, and sim.clear gives it back", function()
  sim.set("CAN1", "ChassisECU", "BrakeStatus", "BrakePedal", 80)
  expect_signal("CAN1", id_of("BrakeStatus"), "BrakePedal", 80, 1000)
  local f = expect("CAN1", id_of("BrakeStatus"), 500)
  check.equal(decode("CAN1", f.id, f.data).BrakePressure, 0, "the other signals keep their source")
  sim.clear("CAN1", "ChassisECU", "BrakeStatus", "BrakePedal")
  expect_signal("CAN1", id_of("BrakeStatus"), "BrakePedal", 0, 1000)
end)

test("a drop fault takes one message off the bus, and clearing brings it back", function()
  sim.fault("CAN1", "ChassisECU", "WheelSpeeds", "drop")
  sleep_ms(100)                      -- the next pass of the simulation picks it up
  drain("CAN1")
  local seen = listen("CAN1", 400)
  check.equal(seen[id_of("WheelSpeeds")], nil, "WheelSpeeds still arriving while dropped")
  check.truthy(seen[id_of("BrakeStatus")] ~= nil, "BrakeStatus, from the same node, stopped too")
  sim.clear_fault("CAN1", "ChassisECU", "WheelSpeeds")
  expect("CAN1", id_of("WheelSpeeds"), 1000)
end)
