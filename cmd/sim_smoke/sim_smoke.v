// sim_smoke — runs the native simulated SUT ECU on the driver-free in-process
// bus and verifies it end-to-end: a monitor client receives the cyclic frames
// (decoded via the DBC) and a Request(0x101) gets the Response(0x102, byte0+1).
// This is the native replacement for `python3 sut/can_sut.py` + a tester, all in
// one process with zero drivers.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/sim_smoke/sim_smoke.v
module main

import os
import time
import transport
import candb
import sim

// EcuRunner owns an engine + its bus so it can be driven from a spawned thread
// via a pointer receiver (spawn forbids `mut` non-reference args).
struct EcuRunner {
mut:
	engine sim.Engine
	bus    transport.Bus
}

fn (mut r EcuRunner) run(duration_ms int) {
	r.engine.run_for(mut r.bus, duration_ms)
}

fn main() {
	dbc := os.getenv_opt('BLOBLY_DBC') or { 'dbc/blobly_net.dbc' }
	db := candb.load_dbc_file(dbc) or {
		eprintln('load dbc: ${err}')
		exit(1)
	}

	ecu_bus := transport.open('inproc:CAN1') or { panic(err) }
	mut mon := transport.open('inproc:CAN1') or { panic(err) }

	mut runner := &EcuRunner{
		engine: sim.Engine{
			ecus: [sim.sut_ecu(db)]
		}
		bus:    ecu_bus
	}
	spawn runner.run(1000)

	mut counts := map[u32]int{}
	mut got_response := false
	mut sent_request := false
	start := time.ticks()
	deadline := start + 1100
	for time.ticks() < deadline {
		// Fire one Request partway through to exercise the response rule.
		if !sent_request && time.ticks() - start > 300 {
			mon.send(transport.CanFrame{ id: 0x101, data: [u8(0x10), 0x20, 0x30] }) or {}
			sent_request = true
		}
		frame := mon.recv(50) or { continue }
		counts[frame.id]++
		if frame.id == 0x102 {
			got_response = true
			println('  response 0x102 [${hexstr(frame.data)}] (expect 11 20 30)')
		}
		if frame.id == 0x100 && counts[0x100] <= 2 {
			if m := db.lookup(0x100) {
				mut parts := []string{}
				for s in m.signals {
					parts << '${s.name}=${s.physical(frame.data):.1f}${s.unit}'
				}
				println('  0x100 ${m.name}: ${parts.join(', ')}')
			}
		}
	}

	println('--- summary ---')
	for id, n in counts {
		nm := if m := db.lookup(id) { m.name } else { '?' }
		println('  0x${id:X} ${nm}: ${n}')
	}
	pt := counts[0x100]
	ok := pt >= 8 && pt <= 12 && counts[0x700] >= 8 && got_response
	println(if ok {
		'PASS: ~10Hz Powertrain+Heartbeat received & decoded, response correct'
	} else {
		'FAIL: pt=${pt} hb=${counts[0x700]} response=${got_response}'
	})
	mon.close()
	if !ok {
		exit(1)
	}
}

fn hexstr(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X} '
	}
	return s.trim_space()
}
