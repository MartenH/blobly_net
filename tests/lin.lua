-- @project ../projects/lin-demo.blobnet
-- LIN from a script: the project's BODY bus (master, simulating CEM, LSM and RSM on NormalTable),
-- its frames decoded through dbc/lin_demo.ldf, a signal changed, the schedule switched, a wait
-- that names what came instead, and go-to-sleep and wakeup.

local body = lin.open("BODY")

test("frames arrive with their template values", function()
  local f = lin.expect(body, "CEM_Frm2", 500)
  check.equal(f.id, 0x02)
  check.equal(f.origin, "TX-S")
  check.equal(#f.data, 3)
  check.equal(f.signals.CabinTemp, 20)        -- init 120, 0.5 degC per bit from -40
  check.equal(f.signals.VehicleSpeed, 15.625) -- init 0x0FA, 0.0625 km/h per bit
  local l = lin.expect(body, "LSM_Frm2", 500)
  check.equal(l.signals.LSMerror, "OK")
  check.equal(l.raw.IntTest, 0)
end)

test("lin.set changes what LSM sends", function()
  lin.set(body, "IntTest", "passed")
  local f
  for _ = 1, 10 do
    f = lin.expect(body, "LSM_Frm2", 500)
    if f.raw.IntTest == 2 then break end
  end
  check.equal(f.signals.IntTest, "passed")
  lin.set(body, "IntTest", 0, { raw = true })
end)

test("a schedule switch to FastTable", function()
  lin.schedule(body, "FastTable")
  local f = lin.expect(body, "RSM_Frm3", 500)
  check.equal(#f.data, 8)
  check.equal(f.signals.RSM_Serial[1], 0x10)
  check.equal(lin.status(body).schedule, "FastTable")
  lin.schedule(body, "NormalTable")
end)

test("lin.expect names what came instead", function()
  local ok, e = pcall(lin.expect, body, 0x30, 100)
  check.truthy(not ok)
  check.truthy(e:find("no 0x30 within 100 ms; came instead: ", 1, true) ~= nil, e)
  check.truthy(e:find("CEM_Frm1 x", 1, true) ~= nil, e)
end)

test("sleep and wakeup", function()
  check.truthy(lin.stop_schedule(body))
  lin.sleep(body)
  local f = lin.expect(body, 0x3C, 500)
  check.equal(f.event, "sleep")
  check.equal(lin.status(body).state, "sleep")
  lin.wakeup(body)
  local w
  repeat w = lin.recv(body, 500) until w == nil or w.event == "wakeup"
  check.equal(w.event, "wakeup")
  check.equal(lin.status(body).state, "active")
  lin.schedule(body, "NormalTable")
  lin.expect(body, "CEM_Frm1", 500)
end)

test("status counts per id", function()
  local st = lin.status(body)
  check.equal(st.name, "BODY")
  check.equal(st.role, "master")
  check.truthy(st.frames[0x01].count > 0)
  check.equal(st.frames[0x01].name, "CEM_Frm1")
  check.equal(st.frames[0x12].errors, 0)
  check.equal(type(st.load), "number")
  check.equal(lin.diagnostics(body).dropped, 0)
end)
