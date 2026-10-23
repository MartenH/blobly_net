-- A suite whose second test never ends, for scripts/runner_report_test.sh and --timeout.
test("before", function()
  check.equal(1, 1)
end)
test("spins", function()
  while true do end
end)
test("after", function()
  check.equal(1, 1)
end)
