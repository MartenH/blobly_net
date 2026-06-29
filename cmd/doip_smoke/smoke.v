// doip_smoke — drive UDS over DoIP end-to-end, V tester ↔ V entity over real
// localhost TCP/UDP (no CAN, no vcan, no drivers). Proves the carrier swap: the
// existing uds.Client rides a doip.DoipClient (which implements isotp.Channel)
// unchanged. Also exercises UDP vehicle discovery.
//
//   v -path "@vlib|@vmodules|modules" run cmd/doip_smoke/smoke.v [port]
module main

import doip
import uds
import net
import os
import time

const default_port = 13400

fn main() {
	// `serve [port]` runs the DoIP entity forever (for the scapy oracle to drive);
	// otherwise run the full V-tester ↔ V-entity self-test and exit.
	serve_only := os.args.len > 1 && os.args[1] == 'serve'
	port := if serve_only {
		if os.args.len > 2 { os.args[2].int() } else { default_port }
	} else {
		if os.args.len > 1 { os.args[1].int() } else { default_port }
	}

	// --- DoIP entity (simulated ECU) wrapping the native UDS server ---------
	mut us := uds.default_server()
	handler := fn [mut us] (req []u8) []u8 {
		return us.handle(req)
	}
	mut srv := doip.new_server(doip.ServerCfg{}, handler)
	srv.listen('127.0.0.1', port) or {
		eprintln('listen failed: ${err}')
		exit(1)
	}
	spawn tcp_loop(mut srv)
	spawn udp_loop(mut srv)
	if serve_only {
		println('DoIP entity serving on 127.0.0.1:${port} (logical address 0x1000); Ctrl-C to stop')
		for {
			time.sleep(1 * time.second)
		}
		return
	}
	time.sleep(150 * time.millisecond) // let the sockets bind

	mut fails := 0

	// --- UDS over DoIP ------------------------------------------------------
	mut ch := doip.open_doip('127.0.0.1', port, 0x0E80, 0x1000) or {
		eprintln('open_doip failed: ${err}')
		exit(1)
	}
	println('connected + routing-activated to DoIP entity @127.0.0.1:${port} (tester 0x0E80 → ECU 0x1000)')
	mut client := uds.new_client(ch)

	// 1) DiagnosticSessionControl (extended)
	sess := client.diagnostic_session(0x03) or {
		eprintln('  session FAIL: ${err}')
		fails++
		[]u8{}
	}
	if sess.len > 0 {
		println('  session 0x03 OK (P2 timings ${hex(sess)})')
	}

	// 2) ReadDataByIdentifier VIN (0xF190)
	vin := client.read_data_by_identifier(0xF190) or {
		eprintln('  read VIN FAIL: ${err}')
		fails++
		[]u8{}
	}
	if vin.len > 0 {
		got := vin.bytestr()
		ok := got == 'BLOBLYNETV0SUT001'
		println('  read VIN 0xF190 = "${got}" ${tick(ok)}')
		if !ok {
			fails++
		}
	}

	// 3) ReadDataByIdentifier software version (0xF195)
	sw := client.read_data_by_identifier(0xF195) or {
		eprintln('  read SW ver FAIL: ${err}')
		fails++
		[]u8{}
	}
	if sw.len > 0 {
		ok := sw == [u8(0x01), 0x00]
		println('  read SW ver 0xF195 = ${hex(sw)} ${tick(ok)}')
		if !ok {
			fails++
		}
	}

	// 4) Negative response: unknown DID → NRC 0x31 requestOutOfRange
	if _ := client.read_data_by_identifier(0x9999) {
		eprintln('  expected NRC for unknown DID, got a positive response')
		fails++
	} else {
		if err is uds.NegativeResponse {
			ok := err.nrc == 0x31
			println('  read 0x9999 → NRC 0x${err.nrc:02X} (${uds.nrc_name(err.nrc)}) ${tick(ok)}')
			if !ok {
				fails++
			}
		} else {
			eprintln('  unexpected error for unknown DID: ${err}')
			fails++
		}
	}

	ch.close()

	// --- UDP vehicle discovery (0x0001 → 0x0004 announcement) ---------------
	disc_vin := discover(port) or {
		eprintln('  discovery FAIL: ${err}')
		fails++
		''
	}
	if disc_vin.len > 0 {
		ok := disc_vin == 'BLOBLYNETV0SUT001'
		println('  UDP discovery → announcement VIN "${disc_vin}" ${tick(ok)}')
		if !ok {
			fails++
		}
	}

	srv.close()
	if fails == 0 {
		println('DoIP smoke: ALL CHECKS PASSED')
		exit(0)
	}
	eprintln('DoIP smoke: ${fails} check(s) FAILED')
	exit(1)
}

// discover sends a UDP vehicle identification request and reads the announcement.
fn discover(port int) !string {
	mut u := net.dial_udp('127.0.0.1:${port}')!
	defer { u.close() or {} }
	u.write(doip.vehicle_id_request())!
	u.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 128}
	n, _ := u.read(mut buf)!
	msg := doip.parse(buf[..n])!
	if msg.payload_type != doip.pt_vehicle_announcement {
		return error('expected announcement, got 0x${msg.payload_type:04X}')
	}
	if msg.payload.len < 17 {
		return error('announcement payload too short for a VIN: ${msg.payload.len} bytes')
	}
	return msg.payload[..17].bytestr()
}

fn tcp_loop(mut srv doip.DoipServer) {
	for {
		srv.accept_and_serve(500) or {
			if srv.is_stopping() {
				break
			}
			continue
		}
	}
}

fn udp_loop(mut srv doip.DoipServer) {
	for {
		srv.serve_udp_once(500) or {
			if srv.is_stopping() {
				break
			}
			continue
		}
	}
}

fn hex(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}

fn tick(ok bool) string {
	return if ok { '✓' } else { '✗' }
}
