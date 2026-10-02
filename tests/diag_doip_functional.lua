-- diag_doip_functional.lua — functional UDS over DoIP (ISO 13400), against the simulated entity.
--
-- @project ../projects/doip-demo.blobnet
--
-- A functional request on DoIP is a diagnostic message whose TARGET is the functional logical
-- address (0xE400 unless given): the entity acks it from that address and answers from its own,
-- keeping quiet where ISO 14229-1 has a functionally addressed server keep quiet. One TCP
-- connection reaches one entity, so a DoIP channel takes exactly one connection and one reply.

local diag = uds.open("DoIP1")

test("functional TesterPresent: suppressed is silence, unsuppressed is answered", function()
  local rs = uds.functional("DoIP1", nil, { diag }, "\x3E\x80", 300)
  check.equal(#rs, 1)
  check.equal(rs[1].outcome, "silent")
  rs = uds.functional("DoIP1", 0xE400, { diag }, "\x3E\x00", 300)
  check.equal(rs[1].outcome, "positive")
  check.equal(tohex(rs[1].resp), "7E 00")
end)

test("an unsupported service is silent functionally, refused physically", function()
  local rs = uds.functional("DoIP1", nil, { diag }, "\x31\x01\x02\x03", 300)
  check.equal(rs[1].outcome, "silent")
  check.nrc(0x11, function() diag:raw("\x31\x01\x02\x03") end)
end)

test("a functional read is answered from the entity address", function()
  -- the connection takes only an answer whose source is the entity (ecu_address 0x1000)
  local rs = uds.functional("DoIP1", nil, { diag }, "\x22\xF1\x90")
  check.equal(rs[1].outcome, "positive")
  check.equal(rs[1].resp:sub(4), "BLOBLYNETV0SUT001")
end)

test("a refusal ISO does not suppress is reported", function()
  local rs = uds.functional("DoIP1", nil, { diag }, "\x19\x01", 300) -- 0x13
  check.equal(rs[1].outcome, "negative")
  check.equal(rs[1].nrc, 0x13)
end)

test("an address the entity does not answer functionally is a failure, not silence", function()
  local rs = uds.functional("DoIP1", 0x2222, { diag }, "\x3E\x00", 300)
  check.equal(rs[1].outcome, "failed")
  check.truthy(rs[1].err:find("negative ack") ~= nil, rs[1].err)
  check.equal(diag:read_did(0xF18C), "SN-0001") -- the connection is still good
end)

test("a DoIP channel takes its one connection", function()
  local ok, err = pcall(function() uds.functional("DoIP1", nil, {}, "\x3E\x00") end)
  check.truthy(not ok, "expected a refusal without a connection")
  ok, err = pcall(function() uds.functional("DoIP1", 0x10000, { diag }, "\x3E\x00") end)
  check.truthy(not ok, "expected 0x10000 to be refused as a logical address")
  log("refused with:", tostring(err))
end)
