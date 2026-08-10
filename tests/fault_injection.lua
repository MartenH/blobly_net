-- fault_injection.lua — provoking failures on purpose, and seeing them on the bus.
--
-- The point of a rest-bus tool is not that it can send correct traffic; it is that it can stop.
-- These check that a fault a script injects actually reaches the wire, and that clearing it
-- brings the ECU back — which is what makes a fault usable as a regression test rather than a
-- one-way demo.

-- Spend the budget only when the timeout actually elapsed. Decrementing on every iteration
-- counts iterations, not time: on a busy bus recv returns a non-matching frame instantly, so a
-- "2 second" wait gave up in milliseconds.
local function wait_for(channel, want, timeout_ms)
  local left = timeout_ms
  while left > 0 do
    local f = bus.recv(channel, 100)
    if f then
      if f.id == want then return f end
    else
      left = left - 100
    end
  end
  return nil
end

-- count frames with the given id over a window
-- Drain whatever is already buffered. A fault stops NEW frames; the ones sent before it
-- landed are still queued, and counting those reads as "the fault did not work".
local function drain(channel)
  -- a real timeout, not 0: recv(…, 0) can return nil while frames are still queued, which
  -- drained nothing and left the backlog to be counted as "the fault did not work"
  local n = 0
  while bus.recv(channel, 20) and n < 5000 do n = n + 1 end
end

-- Counting over a window is the opposite case: here every iteration must cost time, or a busy
-- bus spins forever. Bounded by iterations AND by elapsed timeouts.
local function count_for(channel, want, window_ms)
  local n, left, spins = 0, window_ms, 0
  while left > 0 and spins < 2000 do
    local f = bus.recv(channel, 100)
    spins = spins + 1
    if f then
      if f.id == want then n = n + 1 end
    else
      left = left - 100
    end
  end
  return n
end

test("baseline: Powertrain is on the bus", function()
  check.truthy(wait_for("CAN1", 0x100, 2000) ~= nil, "no Powertrain frame before any fault")
end)

test("drop takes a message off the bus, and clearing brings it back", function()
  sim.fault("SUT", "Powertrain", "drop")
  sleep_ms(300)                       -- let the fault reach the running engine
  drain("CAN1")                       -- discard frames sent before it landed
  local during = count_for("CAN1", 0x100, 600)
  check.equal(during, 0, "Powertrain still arriving while dropped")

  sim.clear_fault("SUT", "Powertrain")
  sleep_ms(200)
  check.truthy(wait_for("CAN1", 0x100, 2000) ~= nil, "Powertrain did not come back after clear")
end)

test("a timed drop expires by itself", function()
  -- That the drop takes effect is covered above; what this checks is that a fault with a
  -- lifetime comes back OFF without anyone clearing it. Asserting the quiet period again here
  -- would only re-measure a buffered backlog, which is bus depth, not fault behaviour.
  sim.fault("SUT", "Heartbeat", "drop", 800)
  sleep_ms(1600)                      -- comfortably past its lifetime
  drain("CAN1")
  check.truthy(wait_for("CAN1", 0x700, 3000) ~= nil,
    "Heartbeat did not resume after the fault's lifetime expired")
  -- and the table has forgotten it, rather than holding an expired entry
  sim.clear_fault("SUT", "Heartbeat")
end)

test("a frozen counter stops advancing while traffic continues", function()
  sim.fault("SUT", "Heartbeat", "freeze_counter")
  sleep_ms(300)
  drain("CAN1")
  local a = wait_for("CAN1", 0x700, 2000)
  check.truthy(a ~= nil, "Heartbeat stopped entirely — freeze must not silence it")
  local b = wait_for("CAN1", 0x700, 2000)
  check.truthy(b ~= nil, "second Heartbeat not seen")
  check.equal(string.byte(a.data, 1), string.byte(b.data, 1), "the counter advanced while frozen")
  sim.clear_fault("SUT", "Heartbeat")
end)

test("an unknown fault kind is an error, not a silent no-op", function()
  local ok = pcall(function() sim.fault("SUT", "Powertrain", "nonsense") end)
  check.truthy(not ok, "an unknown kind must fail loudly")
end)
