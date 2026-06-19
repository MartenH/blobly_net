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
	dids     map[u16][]u8 // ReadDataByIdentifier table (0x22/0x2E)
	session  u8 = 1
	sec_seed []u8 // last seed handed out (0x27 request seed)
	unlocked bool // security access granted (0x27 valid key accepted)
}

// server_security_seed is the demo seed the simulated server returns for any
// level; paired with uds.security_key() (XOR 0xFF) as the shared test secret.
const server_security_seed = [u8(0x11), 0x22, 0x33, 0x44]

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
		0x2E { // WriteDataByIdentifier
			if req.len < 3 {
				return neg(sid, 0x13)
			}
			did := (u16(req[1]) << 8) | u16(req[2])
			s.dids[did] = req[3..].clone()
			return [u8(0x6E), req[1], req[2]]
		}
		0x27 { // SecurityAccess — odd sub = request seed, even sub = send key
			sub := if req.len > 1 { req[1] } else { u8(0) }
			if sub == 0 {
				return neg(sid, 0x12) // subFunctionNotSupported
			}
			if sub % 2 == 1 { // requestSeed
				s.sec_seed = server_security_seed.clone()
				mut resp := [u8(0x67), sub]
				resp << s.sec_seed
				return resp
			}
			// sendKey: validate against the demo algorithm
			key := if req.len > 2 { req[2..].clone() } else { []u8{} }
			if s.sec_seed.len > 0 && key == security_key(s.sec_seed) {
				s.unlocked = true
				return [u8(0x67), sub]
			}
			return neg(sid, 0x35) // invalidKey
		}
		0x19 { // ReadDTCInformation (sub 0x02 reportDTCByStatusMask)
			sub := if req.len > 1 { req[1] } else { u8(0) }
			if sub != 0x02 {
				return neg(sid, 0x12) // subFunctionNotSupported
			}
			// [0x59, 0x02, statusAvailabilityMask, {DTC hi/mid/lo, status}...]
			return [u8(0x59), 0x02, 0xFF, 0x12, 0x34, 0x56, 0x09, 0xAB, 0xCD, 0xEF, 0x08]
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
