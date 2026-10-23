-- isotp_timing.lua — raw ISO-TP, a UDS connection's timing and the DoIP retarget, against the
-- simulated ECUs of sim-demo.
--
-- @project ../projects/sim-demo.blobnet
--
-- Raw ISO-TP carries whole messages on an id pair with no UDS on top, so a request the UDS helpers
-- would never build goes out as written and its answer comes back as bytes. The timing is the
-- waits a request is bounded by; the retarget moves a DoIP connection to a node behind its gateway.
-- sim-demo has no gateway: the entity refuses a target it does not serve, and is reached again
-- once the connection is moved back.
--   scripts/runtests.sh tests/isotp_timing.lua

test("a raw ISO-TP request and its multi-frame answer", function()
  local tp = isotp.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
  tp:send("\x22\xF1\x90")
  check.equal(tp:recv(1000), "\x62\xF1\x90BLOBLYNETV0SUT001")
  tp:close()
end)

test("a malformed UDS request comes back as the bytes the ECU sent", function()
  local tp = isotp.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
  tp:send("\x22\xF1")                  -- a DID cut short: incorrect message length
  check.equal(tohex(tp:recv(1000)), "7F 22 13")
  tp:close()
end)

test("a long message goes out segmented and is answered", function()
  local tp = isotp.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
  tp:send("\x2E\xF1\xAA" .. string.rep("\x55", 20))   -- a First Frame, then Consecutive Frames
  local answer = tp:recv(1000)
  check.truthy(answer ~= nil, "the segmented request was not answered")
  check.truthy(answer:byte(1) == 0x6E or answer:byte(1) == 0x7F, "not an answer to 0x2E: " .. tohex(answer))
  tp:close()
end)

test("nothing in time is nil, and a wait is bounded", function()
  local tp = isotp.open("CAN1", { tx = 0x6F0, rx = 0x6F8 })   -- nothing answers there
  local t0 = now_ms()
  check.equal(tp:recv(100), nil)
  check.between(now_ms() - t0, 90, 600, "the wait")
  check.equal(tp:recv(0), nil)
  tp:close()
end)

test("raw ISO-TP refuses what it cannot carry", function()
  local ok, err = pcall(isotp.open, "CAN1", { tx = 0x7E0 })
  check.truthy(not ok and tostring(err):find("give both tx and rx", 1, true), tostring(err))
  ok, err = pcall(isotp.open, "DoIP1", { tx = 0x7E0, rx = 0x7E8 })
  check.truthy(not ok and tostring(err):find("carries no ISO-TP", 1, true), tostring(err))
  local tp = isotp.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
  ok, err = pcall(function() tp:send("") end)
  check.truthy(not ok and tostring(err):find("empty", 1, true), tostring(err))
  ok, err = pcall(function() tp:recv(-1) end)
  check.truthy(not ok, "a negative wait was taken")
  tp:close()
  ok = pcall(function() tp:send("\x3E\x00") end)
  check.truthy(not ok, "a closed channel sent")
end)

test("a UDS connection reads and states its timing", function()
  local diag = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8, timeout_ms = 300, pending_budget_ms = 9000 })
  local t = diag:timing()
  check.equal(t.timeout_ms, 300)
  check.equal(t.p2_star_ms, 5000)
  check.equal(t.margin_ms, 1000)
  check.equal(t.pending_budget_ms, 9000)
  diag:session(0x01)                   -- P2 50 ms, P2* 5000 ms
  check.equal(diag:timing().timeout_ms, 1050, "a P2 that needs more lengthens the first wait")
  diag:set_timing({ margin_ms = 200 })
  check.equal(diag:timing().margin_ms, 200)
  check.equal(diag:timing().timeout_ms, 1050, "a field not named was kept")
  local ok, err = pcall(function() diag:set_timing({ timeout_ms = 0 }) end)
  check.truthy(not ok and tostring(err):find("timeout_ms 0", 1, true), tostring(err))
  check.equal(diag:timing().margin_ms, 200, "a refused timing changed something")
  diag:close()
end)

test("a short first wait ends a request nothing answers sooner", function()
  local nobody = uds.open("CAN1", { tx = 0x6F0, rx = 0x6F8, timeout_ms = 100 })
  local t0 = now_ms()
  local ok, err = pcall(function() nobody:tester_present() end)
  check.truthy(not ok and tostring(err):find("timeout", 1, true), tostring(err))
  check.between(now_ms() - t0, 90, 600, "the request")
  nobody:close()
end)

test("a DoIP connection moves to another target and back", function()
  local diag = uds.open("DoIP1")
  check.equal(diag:read_did(0xF190), "BLOBLYNETV0SUT001")
  diag:retarget(0x2000)                -- no node behind this entity: it refuses the target
  local ok, err = pcall(function() diag:read_did(0xF190) end)
  check.truthy(not ok and tostring(err):find("negative ack", 1, true), tostring(err))
  diag:retarget()                      -- back to the channel ecu_address
  check.equal(diag:read_did(0xF190), "BLOBLYNETV0SUT001")
  ok, err = pcall(function() diag:retarget(0x10000) end)
  check.truthy(not ok and tostring(err):find("not a logical address", 1, true), tostring(err))
  diag:close()
  local can = uds.open("CAN1")
  ok, err = pcall(function() can:retarget(0x2000) end)
  check.truthy(not ok and tostring(err):find("DoIP connection", 1, true), tostring(err))
  can:close()
end)
