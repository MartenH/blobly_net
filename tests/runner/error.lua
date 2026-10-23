-- A script that raises outside any test(), for scripts/runner_report_test.sh.
test("passes", function()
  check.equal(1, 1)
end)
error("not inside a test")
