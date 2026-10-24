-- sequences.lua — wait/expect sequences + reactive callbacks against the sim.
-- Shows the conventional "wait for an event with a timeout" and on_message/on_timer
-- event loop, all over the in-process simulation.

test("expect a cyclic frame within a timeout", function()
  local f = expect("CAN1", 0x100, 2000)         -- Powertrain
  check.truthy(f, "no Powertrain frame in 2s")
end)

test("a received frame says its format and when it was received", function()
  local a = expect("CAN1", 0x100, 2000)
  local b = expect("CAN1", 0x100, 2000)
  check.equal(a.fd, false)
  check.equal(a.brs, false)
  check.truthy(a.t_ms < b.t_ms and b.t_ms <= now_ms(), "t_ms out of order")
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

-- an id is matched with its kind: a number alone is either kind, { ext = true } or false only
-- that one. The simulation sends Powertrain as an 11-bit 0x100 and no 29-bit 0x100.
test("an id matches the kind ext names", function()
  local either, wide, narrow = 0, 0, 0
  on_message("CAN1", 0x100, function(_) either = either + 1 end)
  on_message("CAN1", 0x100, function(_) wide = wide + 1 end, { ext = true })
  on_message("CAN1", 0x100, function(_) narrow = narrow + 1 end, { ext = false })
  run(500)
  check.truthy(either >= 2, "too few Powertrain frames: " .. either)
  check.equal(narrow, either, "the 11-bit handler")
  check.equal(wide, 0, "the 29-bit handler")
  check.equal(expect("CAN1", 0x100, 2000, { ext = false }).ext, false)
  local ok, err = pcall(expect, "CAN1", 0x100, 300, { ext = true })
  check.truthy(not ok and string.find(err, "(29-bit)", 1, true), "expect of a 29-bit 0x100: " .. tostring(err))
  local v = expect_signal("CAN1", 0x100, "EngineSpeed", function(x) return x >= 0 end, 2000, { ext = false })
  check.between(v, 0, 8000)
end)

-- what a test registers ends with it; what the script registers outside any test stays
heard_in_test, heard_outside = 0, 0
test("a handler registered in a test", function()
  on_message("CAN1", 0x700, function(_) heard_in_test = heard_in_test + 1 end)
  on_timer(50, function() heard_in_test = heard_in_test + 1 end)
  run(300)
  check.truthy(heard_in_test >= 2, "the test`s own handlers fire during its run()")
end)

on_message("CAN1", 0x700, function(_) heard_outside = heard_outside + 1 end)

test("is gone after it, and one registered outside any test is not", function()
  local before = heard_in_test
  run(500)
  check.equal(heard_in_test, before, "a handler of an earlier test fired")
  check.truthy(heard_outside >= 2, "the handler registered outside any test: " .. heard_outside)
end)
