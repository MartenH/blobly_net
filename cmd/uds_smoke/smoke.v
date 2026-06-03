// uds_smoke — drive the UDS client against a UDS server (sut/uds_server.py).
// Opens an ISO-TP channel to the ECU (tester tx 0x7E0, rx 0x7E8), then runs a
// small diagnostic session: start session, read a few DIDs, tester-present, and
// a deliberately-unknown DID to show negative-response handling.
//
//   v -path "@vlib|@vmodules|modules" run cmd/uds_smoke/smoke.v [iface]
module main

import isotp
import uds
import os

fn main() {
	iface := if os.args.len > 1 { os.args[1] } else { 'vcan0' }

	mut ch := isotp.open(iface, 0x7E0, 0x7E8, false) or {
		eprintln('isotp open failed: ${err}')
		exit(1)
	}
	defer { ch.close() }
	mut c := uds.new_client(ch)

	// 0x10: switch to the default diagnostic session.
	params := c.diagnostic_session(0x01) or {
		eprintln('session control failed: ${err}')
		exit(1)
	}
	println('session 0x01 OK, params: ${hex(params)}')

	// 0x22: read a few data identifiers.
	read_did(mut c, 0xF190, 'VIN (ASCII)', true)
	read_did(mut c, 0xF18C, 'ECU serial (ASCII)', true)
	read_did(mut c, 0x0100, 'EngineSpeed raw', false)

	// EngineSpeed: decode the 2-byte big-endian raw at 0.25 rpm/bit.
	if raw := c.read_data_by_identifier(0x0100) {
		if raw.len >= 2 {
			val := ((u32(raw[0]) << 8) | u32(raw[1]))
			println('  -> EngineSpeed = ${f64(val) * 0.25:.1f} rpm')
		}
	}

	// 0x3E: tester present.
	c.tester_present() or {
		eprintln('tester present failed: ${err}')
		exit(1)
	}
	println('tester present OK')

	// Unknown DID -> expect a negative response (requestOutOfRange).
	if _ := c.read_data_by_identifier(0xABCD) {
		println('unexpected: 0xABCD returned data')
	} else {
		println('0xABCD -> negative response as expected: ${err}')
	}
}

fn read_did(mut c uds.Client, did u16, label string, ascii bool) {
	data := c.read_data_by_identifier(did) or {
		println('DID 0x${did:04X} (${label}): ERROR ${err}')
		return
	}
	if ascii {
		println('DID 0x${did:04X} (${label}): "${data.bytestr()}"')
	} else {
		println('DID 0x${did:04X} (${label}): ${hex(data)}')
	}
}

fn hex(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}
