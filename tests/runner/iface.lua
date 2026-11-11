-- A suite for scripts/runner_report_test.sh, run with --interface CAN1=inproc:RUNNER_CAN1: the
-- simulated ECUs of the row moved by the override are heard on the interface it names.
test("hears the moved row", function()
  local moved = bus.open_iface("inproc:RUNNER_CAN1")
  check.truthy(bus.recv(moved, 1000), "nothing on inproc:RUNNER_CAN1")
  check.truthy(bus.recv("CAN1", 1000), "nothing on CAN1")
end)
