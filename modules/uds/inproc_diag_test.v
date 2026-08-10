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

// Two simulated ECUs on one bus, each with its own addresses and content. This is the whole
// point of per-ECU servers: a single channel-wide server means every target answers with the
// same data, so a tester cannot tell one ECU from another.
fn test_two_ecus_answer_as_separate_targets() {
	iface := 'inproc:udsmulti'
	bcm := Server{
		dids: {
			u16(0xF190): 'BCM-0001'.bytes()
		}
		dtcs: [Dtc{0x900101, 0x09}]
	}
	ecm := Server{
		dids: {
			u16(0xF190): 'ECM-0002'.bytes()
		}
		dtcs: [Dtc{0x700205, 0x08}]
	}
	// each on its own request/response pair
	mut bch := isotp.open_software(iface, 0x7E9, 0x7E1, false) or { panic(err) }
	mut ech := isotp.open_software(iface, 0x7EA, 0x7E2, false) or { panic(err) }
	spawn serve_one(mut bch, bcm)
	spawn serve_one(mut ech, ecm)
	time.sleep(50 * time.millisecond)

	// the tester addresses each ECU in turn
	mut t_bcm := isotp.open_software(iface, 0x7E1, 0x7E9, false) or { panic(err) }
	mut t_ecm := isotp.open_software(iface, 0x7E2, 0x7EA, false) or { panic(err) }
	t_bcm.send([u8(0x22), 0xF1, 0x90]) or { panic(err) }
	rb := t_bcm.recv(1000) or { panic('BCM did not answer: ${err}') }
	t_ecm.send([u8(0x22), 0xF1, 0x90]) or { panic(err) }
	re := t_ecm.recv(1000) or { panic('ECM did not answer: ${err}') }
	t_bcm.close()
	t_ecm.close()

	assert rb[3..] == 'BCM-0001'.bytes(), 'BCM answered ${rb[3..].bytestr()}'
	assert re[3..] == 'ECM-0002'.bytes(), 'ECM answered ${re[3..].bytestr()}'
	assert rb != re, 'the two ECUs must be distinguishable'
}

// serve_one answers a few requests on one channel, then closes. A named function because V
// will not spawn a closure taking mutable non-reference arguments.
fn serve_one(mut ch isotp.SoftChannel, srv Server) {
	mut s := srv // V will not spawn with a mutable non-reference argument
	for _ in 0 .. 4 {
		req := ch.recv(500) or { continue }
		ch.send(s.handle(req)) or {}
	}
	ch.close()
}
