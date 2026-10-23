-- A suite that removes the runner's deadline hook and spins, for scripts/runner_report_test.sh:
-- only the watchdog ends it.
test("unhooked", function()
  debug.sethook()
  while true do end
end)
