-- @project ../projects/sim-demo.blobnet
-- Background senders (bus.send_cyclic, bus.send_message_cyclic): a frame on a period from a thread
-- of its own while the script waits for something else. sim-demo answers a Request (0x101) on
-- CAN1 with a Response (0x102) whose first byte is ReqCode + 1.

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

test("a raw sender is heard at its period and takes an update", function()
  drain("CAN1")
  local s = bus.send_cyclic("CAN1", 0x321, fromhex("01 02"), 20)
  local f = frames_of("CAN1", 0x321, 300)
  check.between(#f, 5, 17) -- the first at once, then one per 20 ms, never a burst
  check.equal(tohex(f[1].data), "01 02")
  s:update(fromhex("09"))
  sleep_ms(60)
  drain("CAN1") -- what went out before the update
  local later = frames_of("CAN1", 0x321, 100)
  check.truthy(#later > 0)
  for _, x in ipairs(later) do check.equal(tohex(x.data), "09") end
  s:period(100)
  check.equal(s:status().period_ms, 100)
  check.truthy(s:stop())
  local st = s:status()
  check.truthy(not st.running)
  check.truthy(st.sent >= 8)
  check.equal(st.failed, 0)
  drain("CAN1")
  check.equal(#frames_of("CAN1", 0x321, 100), 0)
end)

test("a message sender keeps the simulated ECU answering while the script waits", function()
  drain("CAN1")
  local s = bus.send_message_cyclic("CAN1", "Request", { ReqCode = 5 }, 50)
  -- the script blocks in a wait of its own; the requests go on underneath it
  local r = frames_of("CAN1", 0x102, 400)
  check.truthy(#r >= 5)
  check.equal(r[#r].data:byte(1), 6)
  s:update({ ReqCode = 9 })
  sleep_ms(120)
  drain("CAN1")
  local r2 = frames_of("CAN1", 0x102, 200)
  check.truthy(#r2 > 0)
  check.equal(r2[#r2].data:byte(1), 10)
  s:stop()
end)

test("what a sender cannot send is refused when it is started", function()
  local ok, e = pcall(bus.send_cyclic, "CAN1", 0x10, "", 0)
  check.truthy(not ok and tostring(e):find("a period of 0 ms", 1, true), tostring(e))
  ok, e = pcall(bus.send_message_cyclic, "CAN1", "Request", { Nope = 1 }, 10)
  check.truthy(not ok and tostring(e):find('unknown signal "Nope"', 1, true), tostring(e))
  ok, e = pcall(bus.send_cyclic, "CAN1", "oops", "", 10)
  check.truthy(not ok and tostring(e):find("an id is an integer", 1, true), tostring(e))
  ok, e = pcall(bus.send_cyclic, "CAN1", 0x800, "", 10)
  check.truthy(not ok and tostring(e):find("0x800", 1, true), tostring(e))
  ok, e = pcall(bus.send_cyclic, "CAN1", 0x10, { 1, 2 }, 10)
  check.truthy(not ok and tostring(e):find("data is bytes", 1, true), tostring(e))
  local s = bus.send_cyclic("CAN1", 0x10, "", 50)
  ok, e = pcall(s.update, s, true)
  check.truthy(not ok and tostring(e):find("bytes (a string)", 1, true), tostring(e))
  s:stop()
  ok, e = pcall(s.period, s, 777)
  check.truthy(not ok and tostring(e):find("stopped", 1, true), tostring(e))
  check.equal(s:status().period_ms, 50)
  ok, e = pcall(bus.send_cyclic, "DoIP1", 0x10, "", 10)
  check.truthy(not ok and tostring(e):find("not a CAN bus", 1, true), tostring(e))
end)

test("a sender left running is stopped when the script ends", function()
  -- not stopped here: the close of the script stops it (and the run stop would)
  bus.send_cyclic("CAN1", 0x322, "", 10)
  check.truthy(#frames_of("CAN1", 0x322, 60) > 0)
end)
