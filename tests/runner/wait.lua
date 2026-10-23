-- A suite whose test waits far past any --timeout, for scripts/runner_report_test.sh.
test("waits", function()
  sleep_ms(600000)
end)
