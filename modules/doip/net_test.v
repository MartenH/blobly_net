module doip

import net
import time

// A uds-free networking test: a DoIP server with a trivial echo+1 handler, driven
// by DoipClient over real localhost TCP, plus UDP discovery. Keeps `v test
// modules/doip/` free of the uds→isotp→transport globals dependency.

const test_port = 13456

fn echo_handler(req []u8) []u8 {
	return req.map(it + 1) // distinct from the request so we know it round-tripped
}

fn test_client_server_roundtrip() {
	mut srv := new_server(ServerCfg{ logical_address: 0x1000, vin: 'TESTVIN0000000001' },
		echo_handler)
	srv.listen('127.0.0.1', test_port) or {
		assert false, 'listen failed: ${err}'
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.accept_and_serve(300) or { continue }
		}
	}(mut srv)
	spawn fn (mut s DoipServer) {
		for {
			s.serve_udp_once(300) or { continue }
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)

	// TCP: routing activation (in open_doip) + a diagnostic message round-trip.
	mut ch := open_doip('127.0.0.1', test_port, 0x0E80, 0x1000) or {
		assert false, 'open_doip failed: ${err}'
		return
	}
	assert ch.tx_id == 0x0E80
	assert ch.rx_id == 0x1000
	ch.send([u8(0x10), 0x20, 0x30]) or { assert false, 'send: ${err}' }
	resp := ch.recv(2000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert resp == [u8(0x11), 0x21, 0x31] // echo_handler added 1 to each byte
	ch.close()

	// UDP: vehicle identification request → announcement with our VIN.
	mut u := net.dial_udp('127.0.0.1:${test_port}') or {
		assert false, 'dial_udp: ${err}'
		return
	}
	u.write(vehicle_id_request()) or { assert false, 'udp write: ${err}' }
	u.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 128}
	n, _ := u.read(mut buf) or {
		assert false, 'udp read: ${err}'
		return
	}
	ann := parse(buf[..n]) or {
		assert false, 'parse announcement: ${err}'
		return
	}
	assert ann.payload_type == pt_vehicle_announcement
	assert ann.payload[..17].bytestr() == 'TESTVIN0000000001'

	// Regression: a hostile UDP datagram advertising a 0xFFFFFFFF payload length
	// must NOT crash the discovery thread (parse() rejects it before slicing).
	hostile := [protocol_version, u8(~protocol_version), u8(0x00), 0x01, 0xFF, 0xFF, 0xFF,
		0xFF]
	u.write(hostile) or { assert false, 'udp write hostile: ${err}' }
	time.sleep(100 * time.millisecond)
	// The thread should still answer a subsequent valid request.
	u.write(vehicle_id_request()) or { assert false, 'udp write 2: ${err}' }
	u.set_read_timeout(2 * time.second)
	mut buf2 := []u8{len: 128}
	n2, _ := u.read(mut buf2) or {
		assert false, 'discovery thread died after hostile datagram: ${err}'
		return
	}
	ann2 := parse(buf2[..n2]) or {
		assert false, 'parse after hostile: ${err}'
		return
	}
	assert ann2.payload_type == pt_vehicle_announcement
	u.close() or {}

	// Regression: a diagnostic message before routing activation must NOT be
	// dispatched (the server drops it; the peer gets no response).
	mut raw := net.dial_tcp('127.0.0.1:${test_port}') or {
		assert false, 'dial: ${err}'
		return
	}
	raw.write(diagnostic_message(0x0E80, 0x1000, [u8(0x10), 0x20, 0x30])) or {
		assert false, 'write: ${err}'
	}
	raw.set_read_timeout(500 * time.millisecond)
	mut rbuf := []u8{len: 32}
	got := raw.read(mut rbuf) or { -1 } // timeout → error → -1
	assert got <= 0, 'server replied to diagnostics without routing activation'
	raw.close() or {}

	// Regression: an oversized advertised payload length must be rejected before
	// allocating a buffer (the server returns an error → closes the connection,
	// rather than allocating gigabytes or hanging on a body that never arrives).
	mut big := net.dial_tcp('127.0.0.1:${test_port}') or {
		assert false, 'dial: ${err}'
		return
	}
	// generic header only: payload_type 0x8001, payload_length 0x7FFFFFFF, no body.
	header := [protocol_version, u8(~protocol_version), u8(0x80), 0x01, 0x7F, 0xFF, 0xFF,
		0xFF]
	big.write(header) or { assert false, 'write: ${err}' }
	big.set_read_timeout(1 * time.second)
	mut bbuf := []u8{len: 16}
	bgot := big.read(mut bbuf) or { -1 } // connection closed (EOF) or timeout
	assert bgot <= 0, 'server did not reject oversized payload length'
	big.close() or {}

	srv.close()
}
