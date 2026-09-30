-- @project ../projects/sim-demo.blobnet
-- A project's cyclic generators run headless as they do in the GUI: sim-demo's "Cyclic wake
-- (0x123)" sends DE AD BE EF every 500 ms on CAN1 for as long as the run lasts.

test("a cyclic generator is sent at its cadence", function()
  while bus.recv("CAN1", 0) do end
  local seen, t0, first, last = 0, __now_ms(), nil, nil
  while __now_ms() - t0 < 1600 do
    local f = bus.recv("CAN1", 50)
    if f and f.id == 0x123 and not f.ext then
      check.equal(tohex(f.data), "DE AD BE EF")
      seen = seen + 1
      first = first or __now_ms()
      last = __now_ms()
    end
  end
  check.truthy(seen >= 3 and seen <= 4, "0x123 sent " .. seen .. " times in 1.6 s at 500 ms")
  local gap = (last - first) / (seen - 1)
  check.truthy(gap > 400 and gap < 600, "0x123 every " .. gap .. " ms, configured 500")
end)
