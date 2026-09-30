// server.v — a native-V UDS server (responder), the twin of sut/uds_server.py.
// It rides an isotp.Channel (e.g. the software ISO-TP over the in-process bus), so
// a simulated ECU can answer diagnostic requests with no Python and no kernel
// ISO-TP. Mirrors uds_server.py: 0x10 session control, 0x22 RDBI (DID table),
// 0x3E tester present; unknown service/DID → negative response. Also 0x11 (the diagnostic state
// back to power-on), 0x14 (the DTC table) and 0x85 (acknowledged — this server records no faults,
// so there is nothing to suspend), and suppress-positive-response on every sub-function service.
// Not 0x28: nothing here gates the simulated ECU's traffic, and an acknowledgement it does not
// act on would be a lie a test could pass on.
module uds

import isotp

pub struct Server {
pub mut:
	dids     map[u16][]u8 // ReadDataByIdentifier table (0x22/0x2E)
	dtcs     []Dtc        // ReadDTCInformation table (0x19 sub 0x02)
	session  u8 = 1
	sec_seed []u8 // last seed handed out (0x27 request seed)
	unlocked bool // security access granted (0x27 valid key accepted)
}

// Dtc is one stored fault: a 3-byte UDS DTC code and its status byte.
//
// A table rather than a constant because simulated ECUs have to differ — the point of running
// several is that a tester can tell them apart, and two ECUs reporting the same fault set is
// indistinguishable from one.
pub struct Dtc {
pub:
	code   u32 // 24-bit DTC (e.g. 0x123456)
	status u8 = 0x09 // status-of-DTC byte; 0x09 = confirmed + testFailed
}

// default_dtcs is what the built-in server has always reported, kept so an unconfigured
// server behaves exactly as before.
pub const default_dtcs = [
	Dtc{0x123456, 0x09},
	Dtc{0xABCDEF, 0x08},
]

// server_security_seed is the demo seed the simulated server returns for any
// level; paired with uds.security_key() (XOR 0xFF) as the shared test secret.
const server_security_seed = [u8(0x11), 0x22, 0x33, 0x44]

// default_server returns a server populated like sut/uds_server.py (VIN forces a
// multi-frame ISO-TP response).
pub fn default_server() Server {
	return Server{
		dids: {
			u16(0xF190): 'BLOBLYNETV0SUT001'.bytes() // VIN, 17 bytes -> multi-frame
			u16(0xF18C): 'SN-0001'.bytes()           // ECU serial number
			u16(0xF195): [u8(0x01), 0x00]            // software version 1.00
		}
		dtcs: default_dtcs.clone()
	}
}

// handle computes the UDS response for one request PDU (pure; no I/O). A sub-function service
// with suppress-positive-response set (bit 7) is served on its sub-function without the bit, and
// its positive response is withheld; a refusal is still answered (ISO 14229-1).
pub fn (mut s Server) handle(req []u8) []u8 {
	if req.len == 0 {
		return []
	}
	_, subfn := echo_of(req) // the client's list: one answer to which services carry a sub-function
	if subfn && req.len > 1 && req[1] & 0x80 != 0 {
		mut plain := req.clone()
		plain[1] &= 0x7F
		resp := s.answer(plain)
		return if resp.len > 0 && resp[0] == 0x7F { resp } else { []u8{} }
	}
	return s.answer(req)
}

fn (mut s Server) answer(req []u8) []u8 {
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
		0x19 { // ReadDTCInformation: 0x01 count, 0x02 by status mask, 0x0A supported
			sub := if req.len > 1 { req[1] } else { u8(0) }
			if sub != 0x01 && sub != 0x02 && sub != 0x0A {
				return neg(sid, 0x12) // subFunctionNotSupported
			}
			if sub == 0x0A { // reportSupportedDTC: every DTC, whole status
				mut all := [u8(0x59), 0x0A, 0xFF]
				for d in s.dtcs {
					all << [u8((d.code >> 16) & 0xFF), u8((d.code >> 8) & 0xFF), u8(d.code & 0xFF), d.status]
				}
				return all
			}
			mask := if req.len > 2 { req[2] } else { u8(0xFF) }
			if sub == 0x01 { // reportNumberOfDTCByStatusMask
				n := s.dtcs.filter(it.status & mask != 0).len
				return [u8(0x59), 0x01, 0xFF, 0x01, u8(n >> 8), u8(n)]
			}
			// [0x59, 0x02, statusAvailabilityMask, {DTC hi/mid/lo, status}...]
			mut resp := [u8(0x59), 0x02, 0xFF]
			for d in s.dtcs {
				if d.status & mask == 0 {
					continue // the tester asked for a status this fault does not have
				}
				resp << u8((d.code >> 16) & 0xFF)
				resp << u8((d.code >> 8) & 0xFF)
				resp << u8(d.code & 0xFF)
				resp << d.status
			}
			return resp
		}
		0x3E { // TesterPresent
			return [u8(0x7E), 0x00]
		}
		0x11 { // ECUReset: the diagnostic state back to power-on (a simulated ECU has no core to restart)
			if req.len < 2 {
				return neg(sid, 0x13)
			}
			if req[1] < 1 || req[1] > 3 {
				return neg(sid, 0x12)
			}
			if req.len != 2 {
				return neg(sid, 0x13)
			}
			s.session = 1
			s.unlocked = false
			s.sec_seed = []u8{}
			return [u8(0x51), req[1]]
		}
		0x85 { // ControlDTCSetting: 0x01 on, 0x02 off
			if req.len < 2 {
				return neg(sid, 0x13)
			}
			if req[1] != 0x01 && req[1] != 0x02 {
				return neg(sid, 0x12)
			}
			return [u8(0xC5), req[1]]
		}
		0x14 { // ClearDiagnosticInformation: a group (0xFFFFFF = all) or one DTC
			if req.len != 4 {
				return neg(sid, 0x13)
			}
			group := u32(req[1]) << 16 | u32(req[2]) << 8 | u32(req[3])
			if group == 0xFFFFFF {
				s.dtcs.clear()
			} else if s.dtcs.any(it.code == group) {
				s.dtcs = s.dtcs.filter(it.code != group)
			} else {
				return neg(sid, 0x31)
			}
			return [u8(0x54)]
		}
		else {
			return neg(sid, 0x11) // serviceNotSupported
		}
	}
}

// serve answers requests on a channel until `stop` is signalled. No duration: a server that
// lived for a fixed number of milliseconds was a test synchronised by the clock -- on a machine
// busy enough, the client's exchanges outlasted it and its last replies came from nobody
// (#191). And no exit on a receive error: a timeout is a poll, and a malformed or stale frame
// is the tester's problem, not a reason for the ECU to leave -- which is also what the two
// production loops that do this job do (cmd/script/run.v, cmd/blobly_net/workers.v), and what
// keeps this free of any one channel's spelling of "timeout". The GUI drives its own loop on
// its own thread; this one is for a spawned server whose owner says when it is done.
// `stop` is checked between requests, so the server leaves within one receive poll; give each
// server its own, cap 1, and signalling it never blocks.
pub fn (mut s Server) serve(mut ch isotp.Channel, stop chan bool) {
	for {
		select {
			_ := <-stop {
				return
			}
			else {}
		}
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
