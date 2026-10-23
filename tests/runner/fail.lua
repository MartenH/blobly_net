-- A suite with one failing test for scripts/runner_report_test.sh; the failure is on line 7.
test("passes", function()
  check.equal(2, 2)
end)

test("fails", function()
  check.equal(1, 2, "one is two")
end)
