-- @project ../projects/e2e-demo.blobnet
-- e2e_verify.lua — E2E on what a script reads and sends, by the E2E Profile 1 dbc/e2e_demo.dbc
-- declares: every frame read carries its verdict (frame.e2e), and bus.send_message stamps the
-- declared counter and CRC. E2E and E2E_TAP are one in-process wire, so what the script sends on
-- E2E is heard, and judged, on E2E_TAP.

local BRAKE_STATUS, BRAKE_COMMAND, WHEEL_SPEED = 0x301, 0x302, 0x303

-- the next frame of `id` on `channel` whose verdict is `want`, within timeout_ms; nil otherwise
local function verdict(channel, id, want, timeout_ms)
  local deadline = __now_ms() + timeout_ms
  repeat
    local f = bus.recv(channel, 50)
    if f and f.id == id and f.e2e == want then return f end
  until __now_ms() >= deadline
  return nil
end

-- the next n frames of `id` on `channel`, within timeout_ms
local function frames(channel, id, n, timeout_ms)
  local out, deadline = {}, __now_ms() + timeout_ms
  while #out < n and __now_ms() < deadline do
    local f = bus.recv(channel, 50)
    if f and f.id == id then out[#out + 1] = f end
  end
  return out
end

test("the simulated sender stamps the declared E2E, and every frame passes", function()
  local got = frames("E2E", BRAKE_STATUS, 10, 2000)
  check.equal(#got, 10, "BrakeStatus frames within 2 s")
  for i, f in ipairs(got) do check.equal(f.e2e, "ok", "frame " .. i) end
  check.e2e(expect("E2E", BRAKE_STATUS, 500))
end)

test("a message with no E2E carries no verdict, and check.e2e says so", function()
  local f = expect("E2E", WHEEL_SPEED, 500)
  check.equal(f.e2e, nil)
  local ok, err = pcall(check.e2e, f)
  check.truthy(not ok and tostring(err):find("has no E2E to check", 1, true), tostring(err))
end)

test("a bad CRC is bad_crc, and the stream passes again once it is cleared", function()
  sim.fault("E2E", "Chassis", "BrakeStatus", "bad_crc")
  local bad = verdict("E2E", BRAKE_STATUS, "bad_crc", 1000)
  sim.clear_fault("E2E", "Chassis", "BrakeStatus")
  check.truthy(bad ~= nil, "no bad_crc frame while the fault was armed")
  local ok, err = pcall(check.e2e, bad)
  check.truthy(not ok and tostring(err):find("failed its E2E check: bad_crc", 1, true), tostring(err))
  check.truthy(verdict("E2E", BRAKE_STATUS, "ok", 1000) ~= nil, "no ok frame after the clear")
end)

test("a frozen counter is repeated", function()
  sim.fault("E2E", "Chassis", "BrakeStatus", "freeze_counter")
  local stuck = verdict("E2E", BRAKE_STATUS, "repeated", 1000)
  sim.clear_fault("E2E", "Chassis", "BrakeStatus")
  check.truthy(stuck ~= nil, "no repeated frame while the counter was frozen")
  check.truthy(verdict("E2E", BRAKE_STATUS, "ok", 1000) ~= nil, "no ok frame after the clear")
end)

test("bus.send_message stamps the declared counter and CRC", function()
  bus.recv("E2E_TAP", 0) -- opens the tap, which hears what is sent from here on
  local sent = {}
  for i = 1, 4 do
    sent[i] = bus.send_message("E2E", "BrakeCommand", { Demand = 100 * i })
  end
  local heard = frames("E2E_TAP", BRAKE_COMMAND, 4, 1000)
  check.equal(#heard, 4, "BrakeCommand frames heard on E2E_TAP")
  for i, f in ipairs(heard) do
    check.equal(f.data, sent[i].data, "frame " .. i .. " as sent")
    check.equal(string.byte(f.data, 4) & 0x0F, i - 1, "frame " .. i .. " counter")
    check.equal(string.byte(f.data, 3), e2e.p01_crc(f.data, 0x2201, 2, 3), "frame " .. i .. " CRC")
    check.e2e(f, "frame " .. i)
  end
end)

test("opts.e2e = false sends the message as encoded", function()
  local m = bus.send_message("E2E", "BrakeCommand", { Demand = 700 }, { e2e = false })
  check.equal(string.byte(m.data, 3), 0, "the CRC field was stamped")
  check.truthy(e2e.p01_crc(m.data, 0x2201, 2, 3) ~= 0, "0 happens to be the right CRC")
  local f = expect("E2E_TAP", BRAKE_COMMAND, 500)
  check.equal(f.e2e, "bad_crc")
end)

test("run() hands a handler each frame with its verdict", function()
  local seen = {}
  on_message("E2E", BRAKE_STATUS, function(f) seen[#seen + 1] = f.e2e end)
  run(150)
  check.truthy(#seen >= 5, "BrakeStatus frames in 150 ms: " .. #seen)
  for i, v in ipairs(seen) do check.equal(v, "ok", "frame " .. i) end
end)
