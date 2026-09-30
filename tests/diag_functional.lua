-- @project ../projects/sim-demo.blobnet
-- Functional addressing against the simulated ECUs: SUT (0x7E0/0x7E8) and ChassisECU
-- (0x7E1/0x7E9) both answer the functional id 0x7DF (sim-demo.blobnet, `functional:`), each on
-- its own response id. One Single Frame out, every answer back — multi-frame ones included,
-- whose Flow Control the tester sends to each ECU's physical request id.

local function ecus()
  return { uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 }), uds.open("CAN1", { tx = 0x7E1, rx = 0x7E9 }) }
end

test("functional: both ECUs answer one request, each multi-frame, on its own id", function()
  local rs = uds.functional("CAN1", 0x7DF, ecus(), "\x22\xF1\x90")
  check.equal(rs[1].outcome, "positive")
  check.equal(rs[1].resp:sub(4), "BLOBLYNETV0SUT001")
  check.equal(rs[2].outcome, "positive")
  check.equal(rs[2].resp:sub(4), "BLOBLY-CHASSIS-01")
end)

test("functional: a refusal ISO suppresses is silence; one it does not is reported", function()
  local ds = ecus()
  local rs = uds.functional("CAN1", 0x7DF, ds, "\x22\xAB\xCD", 300) -- 0x31, suppressed
  check.equal(rs[1].outcome, "silent")
  check.equal(rs[2].outcome, "silent")
  rs = uds.functional("CAN1", 0x7DF, ds, "\x19\x01", 300) -- 0x13, answered
  check.equal(rs[1].outcome, "negative")
  check.equal(rs[1].nrc, 0x13)
  check.equal(rs[2].nrc, 0x13)
end)

test("functional: a suppressed positive response is silence all round; physical still works", function()
  local ds = ecus()
  local rs = uds.functional("CAN1", 0x7DF, ds, "\x3E\x80", 300)
  check.equal(rs[1].outcome, "silent")
  check.equal(rs[2].outcome, "silent")
  check.equal(ds[1]:read_did(0xF190), "BLOBLYNETV0SUT001") -- the physical path is untouched
end)
