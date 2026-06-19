-- sequences.lua — wait/expect sequences + reactive callbacks against the sim.
-- Shows the conventional "wait for an event with a timeout" and on_message/on_timer
-- event loop, all over the in-process simulation.

test("expect a cyclic frame within a timeout", function()
  local f = expect("CAN1", 0x100, 2000)         -- Powertrain
  check.truthy(f, "no Powertrain frame in 2s")
end)

test("expect_signal waits for a decoded value to match", function()
  local v = expect_signal("CAN1", 0x100, "EngineSpeed", function(x) return x >= 0 end, 2000)
  check.between(v, 0, 8000)
  log("EngineSpeed settled at", v, "rpm")
end)

test("on_message + on_timer fire during run()", function()
  local hb, ticks = 0, 0
  on_message("CAN1", 0x700, function(_) hb = hb + 1 end)   -- Heartbeat (~10 Hz)
  on_timer(100, function() ticks = ticks + 1 end)
  run(1500)
  log("heartbeats:", hb, " timer ticks:", ticks)
  -- assert both callback kinds fire repeatedly during run(); exact cadence is
  -- scheduling-dependent under a busy bus, so we don't pin a precise rate.
  check.truthy(hb >= 2, "too few heartbeats: " .. hb)
  check.truthy(ticks >= 2, "timer never fired repeatedly: " .. ticks)
end)
