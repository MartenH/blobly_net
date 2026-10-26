module script

import blobly.candb
import blobly.transport

const framing_dbc = 'BU_: Tester Chassis
BO_ 771 Plain: 2 Tester
 SG_ Value : 0|16@1+ (1,0) [0|65535] "" Chassis
'

// A canfd row and a can row on one wire, which declares nothing: what the script sends on each
// row goes out in that row's format, and opts.format states one (#384).
fn test_each_row_handle_on_a_disputed_wire_sends_its_own_format() {
	transport.replace_wire_policy_rows([], map[string]transport.Framing{}, {
		'inproc:UTFRAMING': {
			'FD': transport.Framing{
				fd:  true
				brs: true
			}
		}
	})
	db := candb.parse_dbc(framing_dbc) or { panic(err) }
	mut env := new_env([
		ChanInfo{
			name:  'FD'
			iface: 'inproc:UTFRAMING'
			db:    db
		},
		ChanInfo{
			name:  'CL'
			iface: 'inproc:UTFRAMING'
			db:    db
		},
	]) or { panic(err) }
	env.on_output = fn (s string) {}
	defer {
		env.close()
		transport.clear_wire_framing()
	}
	env.run_source('
		test("each row in its own format", function()
			bus.recv("CL", 0)
			bus.send_message("FD", "Plain", { Value = 1 })
			local f = bus.recv("CL", 500)
			check.equal(f.fd, true)
			check.equal(f.brs, true)
			bus.send("FD", 0x123, "\\x01")
			check.equal(bus.recv("CL", 500).fd, true)
			bus.send_message("CL", "Plain", { Value = 2 })
			check.equal(bus.recv("FD", 500).fd, false)
		end)
		test("opts.format states one", function()
			bus.send_message("FD", "Plain", { Value = 3 }, { format = "classic" })
			check.equal(bus.recv("CL", 500).fd, false)
			bus.send_message("CL", "Plain", { Value = 4 }, { format = "fd" })
			local f = bus.recv("FD", 500)
			check.equal(f.fd, true)
			check.equal(f.brs, false)
			check.equal(pcall(bus.send_message, "CL", "Plain", {}, { format = 5 }), false)
		end)
	') or { panic(err) }
	assert env.passed() == 2, '${env.results}'
}
