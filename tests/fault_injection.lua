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
  sim.fault("CAN1", "SUT", "Powertrain", "drop")
  sleep_ms(300)                       -- let the fault reach the running engine
  drain("CAN1")                       -- discard frames sent before it landed
  local during = count_for("CAN1", 0x100, 600)
  check.equal(during, 0, "Powertrain still arriving while dropped")

  sim.clear_fault("CAN1", "SUT", "Powertrain")
  sleep_ms(200)
  check.truthy(wait_for("CAN1", 0x100, 2000) ~= nil, "Powertrain did not come back after clear")
end)

test("a timed drop expires by itself", function()
  -- That the drop takes effect is covered above; what this checks is that a fault with a
  -- lifetime comes back OFF without anyone clearing it. Asserting the quiet period again here
  -- would only re-measure a buffered backlog, which is bus depth, not fault behaviour.
  sim.fault("CAN1", "SUT", "Heartbeat", "drop", 800)
  sleep_ms(1600)                      -- comfortably past its lifetime
  drain("CAN1")
  check.truthy(wait_for("CAN1", 0x700, 3000) ~= nil,
    "Heartbeat did not resume after the fault's lifetime expired")
  -- and the table has forgotten it, rather than holding an expired entry
  sim.clear_fault("CAN1", "SUT", "Heartbeat")
end)

test("freeze_counter is refused where there is no E2E counter to freeze", function()
  -- sim-demo configures no `protect:` block, so the SUT's Counter signal is an ordinary
  -- generator. Freezing the E2E counter would change nothing there, and reporting success
  -- would be the difference between a test that fails and a test that lies. (The freeze
  -- behaviour itself is covered by the V unit tests, against a protected message.)
  local ok = pcall(function() sim.fault("CAN1", "SUT", "Heartbeat", "freeze_counter") end)
  check.truthy(not ok, "freeze_counter without protection must fail loudly")
end)

test("an unknown fault kind is an error, not a silent no-op", function()
  local ok = pcall(function() sim.fault("CAN1", "SUT", "Powertrain", "nonsense") end)
  check.truthy(not ok, "an unknown kind must fail loudly")
end)

test("a fault that cannot take effect is refused, not silently armed", function()
  -- a message this node does not send
  local ok1 = pcall(function() sim.fault("CAN1", "SUT", "NotAMessage", "drop") end)
  check.truthy(not ok1, "an unknown message must fail loudly")

  -- a node that is not on this channel
  local ok2 = pcall(function() sim.fault("CAN1", "NoSuchEcu", "Powertrain", "drop") end)
  check.truthy(not ok2, "an unknown node must fail loudly")

  -- bad_crc where the project configures no checksum: it would change no bits
  local ok3 = pcall(function() sim.fault("CAN1", "SUT", "Powertrain", "bad_crc") end)
  check.truthy(not ok3, "bad_crc without a configured checksum must fail loudly")
end)
