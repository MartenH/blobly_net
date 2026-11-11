module script

import blobly.isotp

// fake_ecu answers 0x31, 0x2F, 0x23 and 0x3D on `ch` until stopped: routine 0x0203 started with
// its option echoed back as the status, I/O control echoing parameter and state, 4 bytes readable
// at 0x20001000, and any write answered with its echo.
fn fake_ecu(mut ch isotp.Channel, stop chan bool) {
	for {
		select {
			_ := <-stop {
				ch.close()
				return
			}
			else {
			}
		}
		req := ch.recv(50) or { continue }
		ans := match req[0] {
			0x31 {
				if req.len >= 4 && req[2] == 0x02 && req[3] == 0x03 {
					mut a := [u8(0x71), req[1], req[2], req[3]]
					a << req[4..]
					a
				} else {
					[u8(0x7F), 0x31, 0x31]
				}
			}
			0x2F {
				mut a := [u8(0x6F)]
				a << req[1..4]
				a << if req.len > 4 { req[4..5] } else { []u8{} }
				a
			}
			0x23 {
				if req == [u8(0x23), 0x24, 0x20, 0x00, 0x10, 0x00, 0x00, 0x04] {
					[u8(0x63), 0xDE, 0xAD, 0xBE, 0xEF]
				} else {
					[u8(0x7F), 0x23, 0x31]
				}
			}
			0x3D {
				n := 2 + int(req[1] & 0x0F) + int(req[1] >> 4)
				mut a := [u8(0x7D)]
				a << req[1..n]
				a
			}
			else {
				[u8(0x7F), req[0], 0x11]
			}
		}
		ch.send(ans) or {}
	}
}

fn test_a_script_runs_routines_io_control_and_memory_by_address() {
	wire := 'inproc:LUA_UDS_SERVICES'
	mut ecu := isotp.open_software(wire, 0x7E8, 0x7E0, false)!
	stop := chan bool{cap: 1}
	t := spawn fake_ecu(mut ecu, stop)
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: wire
	}])!
	mut lines := []string{}
	env.on_output = fn [mut lines] (s string) {
		lines << s
	}
	env.run_source('
		local d = uds.open("CAN1")
		test("routine", function()
			check.equal(d:routine(0x0203, "\\x01\\x02"), "\\x01\\x02")
			check.equal(d:routine(0x0203, nil, 3), "")
			check.nrc(0x31, function() d:routine(0x0204) end)
			local ok, err = pcall(function() d:routine(0x0203, "", 4) end)
			check.truthy(not ok and string.find(err, "routine control", 1, true), tostring(err))
		end)
		test("io_control", function()
			check.equal(d:io_control(0x0101, 3, "\\x7F", "\\xFF"), "\\x7F")
			local ok, err = pcall(function() d:io_control(0x0101, 4) end)
			check.truthy(not ok and string.find(err, "parameter", 1, true), tostring(err))
		end)
		test("memory", function()
			check.equal(d:read_memory(0x20001000, 4), "\\xDE\\xAD\\xBE\\xEF")
			d:write_memory(0x0010, "\\x55", 2, 1)
			local ok, err = pcall(function() d:read_memory(0x1FFFFFFFF, 4) end)
			check.truthy(not ok and string.find(err, "does not fit", 1, true), tostring(err))
		end)
	') or { panic(err) }
	env.close()
	stop <- true
	t.wait()
	assert env.failed() == 0, lines.str()
	assert env.passed() == 3, lines.str()
}
