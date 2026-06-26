module uds

import isotp
import time

// End-to-end native diagnostics with NO Python and NO kernel ISO-TP: a uds.Server
// and a uds.Client talk over the software ISO-TP state machine on the driver-free
// in-process bus. Exercises single-frame and multi-frame (the 17-byte VIN) paths,
// proving the whole stack (software ISO-TP + UDS server) against the already-
// Python-validated uds.Client.

// ServerRunner wraps the server + its channel so it can run in a spawned thread
// via a pointer receiver (spawn forbids `mut` non-reference args).
struct ServerRunner {
mut:
	server Server
	ch     &isotp.SoftChannel
}

fn (mut r ServerRunner) run(duration_ms int) {
	r.server.serve_for(mut r.ch, duration_ms)
}

fn test_inproc_uds_roundtrip() {
	// Server: rx on 0x7E0 (requests), tx on 0x7E8 (responses). Client mirrored.
	srv_ch := isotp.open_software('inproc:DIAG', 0x7E8, 0x7E0, false) or { panic(err) }
	cli_ch := isotp.open_software('inproc:DIAG', 0x7E0, 0x7E8, false) or { panic(err) }

	mut runner := &ServerRunner{
		server: default_server()
		ch:     srv_ch
	}
	spawn runner.run(3000)
	time.sleep(50 * time.millisecond) // let the server reach its recv loop

	mut client := new_client(cli_ch)

	// 0x10 DiagnosticSessionControl (single frame both ways)
	sess := client.raw([u8(0x10), 0x03]) or {
		assert false, 'session: ${err}'
		return
	}
	assert sess[0] == 0x50 // positive response
	assert sess[1] == 0x03 // echoed session

	// 0x22 RDBI 0xF190 — VIN is 17 bytes → multi-frame ISO-TP (FF/CF/FC)
	vin := client.read_data_by_identifier(0xF190) or {
		assert false, 'VIN: ${err}'
		return
	}
	assert vin.bytestr() == 'BLOBLYNETV0SUT001', 'VIN was ${vin.bytestr()}'

	// 0x22 RDBI 0xF195 — single-frame, 2 data bytes
	sw := client.read_data_by_identifier(0xF195) or {
		assert false, 'sw: ${err}'
		return
	}
	assert sw == [u8(0x01), 0x00]

	// 0x3E TesterPresent
	tp := client.raw([u8(0x3E), 0x00]) or {
		assert false, 'tester present: ${err}'
		return
	}
	assert tp[0] == 0x7E

	// unknown DID → negative response 0x31 (requestOutOfRange)
	if _ := client.read_data_by_identifier(0xDEAD) {
		assert false, 'expected a negative response for unknown DID'
	} else {
		assert err is NegativeResponse
		nr := err as NegativeResponse
		assert nr.code() == 0x31
	}
}
