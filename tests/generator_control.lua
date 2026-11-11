-- @project ../projects/sim-demo.blobnet
-- A script controls the run of the generators of the project (gen.*): sim-demo writes four on
-- CAN1 (docs/simulation.md); Heartbeat pulse is a manual one, Cyclic wake (0x123) a cyclic one.

local function drain(ch) while bus.recv(ch, 0) do end end

-- the frames of id seen within ms
local function frames_of(ch, id, ms)
  local out, t0 = {}, __now_ms()
  while __now_ms() - t0 < ms do
    local f = bus.recv(ch, 20)
    if f and f.id == id and not f.ext then out[#out + 1] = f end
  end
  return out
end

local function find(name)
  for _, g in ipairs(gen.list()) do if g.name == name then return g end end
end

test("every loop of the run that opens a bus is up", function()
  sim.wait_ready(5000)
end)

test("gen.list names the generators of the run, as the project writes them", function()
  check.equal(#gen.list(), 4)
  local hb, wake = find("Heartbeat pulse"), find("Cyclic wake (0x123)")
  check.equal(hb.channel, "CAN1")
  check.equal(hb.message, "Heartbeat")
  check.equal(hb.id, 0x700)
  check.equal(hb.trigger, "manual")
  check.truthy(not hb.running)
  check.truthy(wake.running)
  check.equal(wake.cycle_ms, 500)
  check.equal(gen.list()[3].name, "Heartbeat pulse") -- the position gen.fire(3) takes
end)

test("gen.fire sends a manual generator once, with the value gen.set gave it", function()
  gen.set(3, "Counter", 42)
  drain("CAN1")
  gen.fire("CAN1/Heartbeat pulse")
  local f = frames_of("CAN1", 0x700, 300)
  -- the simulated SUT sends Heartbeat too: ours is the one at 42
  local ours = 0
  for _, x in ipairs(f) do if x.data:byte(1) == 42 then ours = ours + 1 end end
  check.equal(ours, 1)
  check.truthy(find("Heartbeat pulse").sent >= 1)
end)

test("gen.source puts a value source on a signal", function()
  gen.source("Ping ECU (Request)", "ReqCode", { type = "counter", start = 100, modulo = 256 })
  drain("CAN1")
  gen.fire("Ping ECU (Request)")
  gen.fire("Ping ECU (Request)")
  local f = frames_of("CAN1", 0x101, 300)
  check.equal(#f, 2)
  check.equal(f[2].data:byte(1), f[1].data:byte(1) + 1)
end)

test("gen.stop, gen.start and gen.cycle drive a cyclic generator", function()
  gen.stop("Cyclic wake (0x123)")
  sleep_ms(50)
  drain("CAN1")
  check.equal(#frames_of("CAN1", 0x123, 600), 0)
  gen.start("Cyclic wake (0x123)", 50)
  local n = #frames_of("CAN1", 0x123, 500)
  check.truthy(n >= 4 and n <= 12, "0x123 sent " .. n .. " times in 500 ms at 50 ms")
  gen.cycle("Cyclic wake (0x123)", 500)
  check.equal(find("Cyclic wake (0x123)").cycle_ms, 500)
end)

test("gen.signals reads the values back, gen.unset takes one off, a restore puts them back", function()
  local g = "Rev to 6000 rpm"
  local before = gen.signals(g)
  check.equal(before.EngineSpeed, 6000)
  check.equal(before.Gear, 4)
  gen.set(g, "Gear", 2)
  gen.source(g, "EngineSpeed", { type = "counter", start = 10, step = 5, modulo = 100 })
  check.truthy(not gen.info(g).applied, "an edit not yet sent reads as applied")
  local now = gen.signals(g)
  check.equal(now.Gear, 2)
  check.equal(now.EngineSpeed.type, "counter")
  check.equal(now.EngineSpeed.step, 5)
  check.equal(now.EngineSpeed.amplitude, nil) -- only what a counter reads
  gen.fire(g)
  gen.wait_applied(g, 500)
  gen.unset(g, "Gear")
  check.equal(gen.signals(g).Gear, nil)
  -- the restore: every signal back as it was
  for name, v in pairs(before) do
    if type(v) == "table" then gen.source(g, name, v) else gen.set(g, name, v) end
  end
  local after = gen.signals(g)
  check.equal(after.EngineSpeed, 6000)
  check.equal(after.Gear, 4)
end)

test("gen.set_data changes a raw generator payload, on the wire once gen.wait_applied returns", function()
  local g = "Cyclic wake (0x123)"
  check.equal(gen.data(g), fromhex("DE AD BE EF"))
  gen.set_data(g, fromhex("02 00"))
  check.equal(gen.data(g), fromhex("02 00"))
  gen.wait_applied(g, 2000)
  local f = frames_of("CAN1", 0x123, 700)
  check.truthy(#f >= 1)
  check.equal(f[#f].data, fromhex("02 00"))
  gen.set_data(g, fromhex("DE AD BE EF"))
end)

test("a generator call that cannot take effect is refused", function()
  local refusals = {
    { function() gen.fire("No such generator") end, "no generator" },
    { function() gen.fire(9) end, "no generator at position 9" },
    { function() gen.fire(1.5) end, "its position in gen.list()" },
    { function() gen.fire(0) end, "its position in gen.list()" },
    { function() gen.fire(nil) end, "its position in gen.list()" },
    { function() gen.cycle("Cyclic wake (0x123)", 0) end, "a cycle is 1" },
    { function() gen.set("Heartbeat pulse", "NoSignal", 1) end, "has no signal" },
    { function() gen.set("Cyclic wake (0x123)", "Counter", 1) end, "raw frame" },
    { function() gen.start("Heartbeat pulse") end, "no cycle" },
    { function() gen.unset("Heartbeat pulse", "NoSuchSignal") end, "lists no signal" },
    { function() gen.unset("Cyclic wake (0x123)", "Counter") end, "raw frame" },
    { function() gen.set_data("Heartbeat pulse", "x") end, "set its signals" },
    { function() gen.set_data("Cyclic wake (0x123)", string.rep("x", 9)) end, "at most 8" },
    { function() gen.set_data("Cyclic wake (0x123)", 5) end, "data is bytes" },
    { function() gen.source("Heartbeat pulse", "Counter", { type = "sine", amp = 1 }) end, "no parameter amp" },
    { function() gen.source("Heartbeat pulse", "Counter", { type = "stepmod", period = 1 }) end, "non-zero count" },
  }
  for _, r in ipairs(refusals) do
    local ok, why = pcall(r[1])
    check.truthy(not ok and string.find(tostring(why), r[2], 1, true), r[2] .. ": " .. tostring(why))
  end
end)
