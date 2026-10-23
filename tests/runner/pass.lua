-- A passing suite for scripts/runner_report_test.sh.
test("adds", function()
  check.equal(1 + 1, 2)
end)
test("hears the SUT", function()
  check.truthy(bus.recv("CAN1", 1000), "no frame on CAN1")
end)
