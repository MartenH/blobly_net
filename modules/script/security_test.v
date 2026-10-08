module script

import isotp
import uds

fn serve_sim(mut s uds.Server, mut ch isotp.Channel, stop chan bool) {
	s.serve(mut ch, stop)
}

// diag:security_access against the simulated server: an all-zero seed (the level is already
// unlocked) returns at once, without computing or sending a key.
fn test_an_all_zero_seed_sends_no_key() {
	wire := 'inproc:LSEC1'
	mut srv := &uds.Server{}
	// the server: answers on 0x7E8, hears 0x7E0
	mut ch := isotp.open_software(wire, 0x7E8, 0x7E0, false) or { panic(err) }
	stop := chan bool{cap: 1}
	t := spawn serve_sim(mut srv, mut ch, stop)
	mut env := new_env([ChanInfo{
		name:  'SEC'
		iface: wire
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	env.run_source('
		local diag = uds.open("SEC")
		test("unlock, then unlock again", function()
			local seed = diag:security_access(0x01)
			check.equal(tohex(seed), "11 22 33 44")
			local again = diag:security_access(0x01, function(s) error("a key was computed") end)
			check.equal(tohex(again), "00 00 00 00")
		end)
		test("a session change locks it again", function()
			diag:session(0x03)
			check.equal(tohex(diag:security_access(0x01)), "11 22 33 44")
		end)
	') or { panic(err) }
	passed, failed := env.passed(), env.failed()
	env.close()
	stop <- true
	t.wait()
	assert failed == 0
	assert passed == 2
}
