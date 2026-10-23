module script

import blobly.candb
import blobly.project

// BrakeCommand declares Profile 1 (CRC byte 2, counter in byte 3, Data ID 0x2201); Plain declares
// nothing
const e2e_dbc = 'BU_: Tester Chassis
BO_ 770 BrakeCommand: 4 Tester
 SG_ Demand : 0|16@1+ (1,0) [0|65535] "" Chassis
 SG_ CommandCrc : 16|8@1+ (1,0) [0|255] "" Chassis
 SG_ CommandCounter : 24|4@1+ (1,0) [0|15] "" Chassis
BO_ 771 Plain: 2 Tester
 SG_ Value : 0|16@1+ (1,0) [0|65535] "" Chassis
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_ "E2ECounterSignal" BO_ 770 "CommandCounter";
BA_ "E2ECrcSignal" BO_ 770 "CommandCrc";
BA_ "E2EProfile" BO_ 770 "P01";
BA_ "E2EDataId" BO_ 770 8705;
'

// two channels on one in-process wire: what the script sends on A is heard on B
fn e2e_env(wire string, b_verify []project.ProtectCfg) &Env {
	db := candb.parse_dbc(e2e_dbc) or { panic(err) }
	mut env := new_env([
		ChanInfo{
			name:  'A'
			iface: wire
			db:    db
		},
		ChanInfo{
			name:   'B'
			iface:  wire
			db:     db
			verify: b_verify
		},
	]) or { panic(err) }
	env.on_output = fn (s string) {}
	return env
}

fn test_a_send_by_name_is_stamped_and_judged_where_it_is_heard() {
	mut env := e2e_env('inproc:UTE2E', [])
	defer { env.close() }
	env.run_source('
		test("stamped by the declaration, judged ok", function()
			bus.recv("B", 0)
			for i = 0, 3 do
				local sent = bus.send_message("A", "BrakeCommand", { Demand = i })
				check.equal(string.byte(sent.data, 4) & 0x0F, i)
				check.equal(string.byte(sent.data, 3), e2e.p01_crc(sent.data, 0x2201, 2, 3))
				local f = bus.recv("B", 500)
				check.equal(f.data, sent.data)
				check.equal(f.e2e, "ok")
			end
		end)
		test("opts.e2e = false sends it as encoded", function()
			local sent = bus.send_message("A", "BrakeCommand", { Demand = 9 }, { e2e = false })
			check.equal(string.byte(sent.data, 3), 0)
			check.equal(bus.recv("B", 500).e2e, "bad_crc")
			check.equal(pcall(bus.send_message, "A", "BrakeCommand", {}, 5), false)
		end)
		test("a message with no E2E is sent as encoded and carries no verdict", function()
			local sent = bus.send_message("A", "Plain", { Value = 7 })
			local f = bus.recv("B", 500)
			check.equal(f.data, sent.data)
			check.equal(f.e2e, nil)
		end)
	')!
	assert env.total() == 3
	assert env.passed() == 3, '${env.results}'
}

// the channel verify: entry is what its frames are judged by first: here a checksum the sender
// does not stamp, so the declared stamp reads as a bad one
fn test_the_channels_verify_entry_wins_over_the_declaration() {
	mut env := e2e_env('inproc:UTE2EV', [
		project.ProtectCfg{
			message: 'BrakeCommand'
			counter: 'CommandCounter'
			crc:     'CommandCrc'
			profile: 'xor8'
		},
	])
	defer { env.close() }
	env.run_source('
		test("judged by the verify: entry", function()
			bus.recv("B", 0)
			bus.send_message("A", "BrakeCommand", { Demand = 300 })
			check.equal(bus.recv("B", 500).e2e, "bad_crc")
		end)
	')!
	assert env.passed() == 1, '${env.results}'
}
