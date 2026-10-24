-- @project ../projects/described-ecu-demo/described-ecu-demo.blobnet
-- A UDS session kept alive between the requests of a script (diag:keep_alive): zone_a ends a
-- non-default session after S3 (its ecu.toml, 5000 ms) without a request, and a keep-alive is
-- that request, sent from a thread of its own while the script waits.

local function diag() return uds.open("edge", { tx = 0x7C0, rx = 0x7C8 }) end

test("a keep-alive holds the extended session through a pause past S3", function()
  local d = diag()
  d:session(0x03)
  d:keep_alive(1000)
  sleep_ms(5600)
  local st = d:keep_alive_status()
  check.truthy(st.running)
  check.truthy(st.sent >= 4, "sent " .. st.sent)
  check.equal(st.failures, 0)
  -- still extended: 0x27 is served only outside the default session
  d:security_access(1)
  d:keep_alive(0)
  check.truthy(not d:keep_alive_status().running)
  d:session(0x01)
end)

test("nothing is kept in the default session", function()
  local d = uds.open("edge", { tx = 0x7C0, rx = 0x7C8, keep_alive_ms = 250 })
  d:session(0x01)
  sleep_ms(600)
  check.equal(d:keep_alive_status().sent, 0)
  d:keep_alive(0)
end)
