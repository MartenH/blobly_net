module script

import isotp
import uds

// The 0x19 03 / 04 / 06 helpers end to end: diag:snapshot_ids / snapshot / extended and
// check.snapshot / check.extended against the native simulated server (uds.default_server, the
// one cmd/script hosts on 0x7E0 / 0x7E8), on an in-process bus — a snapshot DID's size is learned
// by reading it (0x22).
fn serve_default(iface string, stop &bool) {
	mut ch := isotp.open_software(iface, 0x7E8, 0x7E0, false) or { return }
	mut srv := uds.default_server()
	for !*stop {
		req := ch.recv(20) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

fn test_snapshot_and_extended_data_helpers() {
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: 'inproc:RECS'
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	defer { env.close() }
	mut stop := false
	t := spawn serve_default('inproc:RECS', &stop)
	env.run_source('
		local diag = uds.open("CAN1")
				test("snapshots and extended data (0x19 03 / 04 / 06)", function()
		  local ids = diag:snapshot_ids()
		  check.equal(#ids, 1)
		  check.equal(ids[1].name, "P1234-56")
		  check.equal(ids[1].record, 0x01)
		  -- the DID sizes are learned by reading the DIDs (0x22): no description file
		  local s = diag:snapshot("P1234-56")
		  check.truthy(s.confirmedDTC and s.testFailed, "the status bits ride along")
		  check.equal(#s.records, 1)
		  check.equal(s.records[1].number, 0x01)
		  check.equal(s.records[1].dids[1].id, 0xF195)
		  check.equal(tohex(s.records[1].dids[1].data), "01 00")
		  check.equal(s.records[1].dids[2].data, "SN-0001")
		  check.snapshot(diag, "P1234-56", { [0xF195] = fromhex("01 00"), [0xF18C] = true })
		  local ok, err = pcall(function() check.snapshot(diag, "P1234-56", { [0xF195] = fromhex("02 00") }) end)
		  check.truthy(not ok and tostring(err):find("expected 02 00"), tostring(err))
		  -- several records: one holding the wanted value is enough, whichever it is
		  local two = { snapshot = function() return { name = "X", status = 0x2F, records = {
		    { dids = { { id = 0x0101, data = "\x01" } } }, { dids = { { id = 0x0101, data = "\x02" } } } } } end }
		  check.snapshot(two, "X", { [0x0101] = "\x01" })
		  check.snapshot(two, "X", { [0x0101] = "\x02" })
		  ok, err = pcall(function() check.snapshot(two, "X", { [0x0101] = "\x03" }) end)
		  check.truthy(not ok and tostring(err):find("in every record"), tostring(err))
		  ok, err = pcall(function() check.snapshot(diag, "B2BCD-EF") end)
		  check.truthy(not ok and tostring(err):find("no snapshot stored"), tostring(err))
		  check.equal(#diag:snapshot(0xABCDEF).records, 0) -- by code; nothing stored
		  local e = check.extended(diag, "P1234-56", { occurrence = 3, aging = 0, failed_cycles = 1 })
		  check.equal(tohex(e.records[1]), "00 03")
		  check.extended(diag, "B2BCD-EF", { aging = 2, [2] = fromhex("02") })
		  check.equal(diag:extended("P1234-56", 0x01).aging, nil) -- only the record asked for
		  check.nrc(0x31, function() diag:extended("P1234-56", 0x04) end)
		  check.nrc(0x31, function() diag:snapshot("U0001-00") end)
		  ok, err = pcall(function() check.extended(diag, "P1234-56", { occurrence = 4 }) end)
		  check.truthy(not ok and tostring(err):find("occurrence is 3, expected 4"), tostring(err))
		end)
	')!
	stop = true
	t.wait()
	assert env.total() == 1
	assert env.passed() == 1, env.results.filter(!it.ok).map(it.msg).str()
}
