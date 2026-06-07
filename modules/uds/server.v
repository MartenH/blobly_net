// server.v — a native-V UDS server (responder), the twin of sut/uds_server.py.
// It rides an isotp.Channel (e.g. the software ISO-TP over the in-process bus), so
// a simulated ECU can answer diagnostic requests with no Python and no kernel
// ISO-TP. Mirrors uds_server.py: 0x10 session control, 0x22 RDBI (DID table),
// 0x3E tester present; unknown service/DID → negative response.
module uds

import time
import isotp

pub struct Server {
pub mut:
	dids    map[u16][]u8 // ReadDataByIdentifier table
	session u8 = 1
}

// default_server returns a server populated like sut/uds_server.py (VIN forces a
// multi-frame ISO-TP response).
pub fn default_server() Server {
	return Server{
		dids: {
			u16(0xF190): 'CANTESTERV0SUT001'.bytes() // VIN, 17 bytes -> multi-frame
			u16(0xF18C): 'SN-0001'.bytes()           // ECU serial number
			u16(0xF195): [u8(0x01), 0x00]            // software version 1.00
		}
	}
}

// handle computes the UDS response for one request PDU (pure; no I/O).
pub fn (mut s Server) handle(req []u8) []u8 {
	if req.len == 0 {
		return []
	}
	sid := req[0]
	match sid {
		0x10 { // DiagnosticSessionControl
			session := if req.len > 1 { req[1] } else { u8(1) }
			s.session = session
			return [u8(0x50), session, 0x00, 0x32, 0x01, 0xF4] // + default P2 timings
		}
		0x22 { // ReadDataByIdentifier
			if req.len < 3 {
				return neg(sid, 0x13) // incorrectMessageLengthOrInvalidFormat
			}
			did := (u16(req[1]) << 8) | u16(req[2])
			if data := s.dids[did] {
				mut resp := [u8(0x62), req[1], req[2]]
				resp << data
				return resp
			}
			return neg(sid, 0x31) // requestOutOfRange
		}
		0x3E { // TesterPresent
			return [u8(0x7E), 0x00]
		}
		else {
			return neg(sid, 0x11) // serviceNotSupported
		}
	}
}

// serve_for answers requests on a channel until duration_ms elapses (used by the
// in-process diagnostics test; the GUI will drive the loop via its own thread).
pub fn (mut s Server) serve_for(mut ch isotp.Channel, duration_ms int) {
	deadline := time.ticks() + i64(duration_ms)
	for time.ticks() < deadline {
		req := ch.recv(50) or { continue }
		resp := s.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
}

fn neg(sid u8, nrc u8) []u8 {
	return [u8(negative_response_sid), sid, nrc]
}
