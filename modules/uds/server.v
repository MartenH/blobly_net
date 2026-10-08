// server.v — a native-V UDS server (responder), the twin of sut/uds_server.py.
// It rides an isotp.Channel (e.g. the software ISO-TP over the in-process bus), so
// a simulated ECU can answer diagnostic requests with no Python and no kernel
// ISO-TP. Mirrors uds_server.py: 0x10 session control, 0x22 RDBI (DID table),
// 0x3E tester present; unknown service/DID → negative response. Also 0x11 (the diagnostic state
// back to power-on), 0x19 01/02/0A (the DTC table: count, by status mask, all) and 03/04/06 (its
// snapshots and extended data, shaped as blobly_emb's fault memory answers them), 0x14 (clears it)
// and 0x85 (acknowledged — this server records no faults, so there is nothing to suspend), and
// suppress-positive-response on every sub-function service but 0x19, whose answer is its report.
// Not 0x28: nothing here gates the simulated ECU's traffic, and an acknowledgement it does not
// act on would be a lie a test could pass on.
module uds

import isotp

pub struct Server {
pub mut:
	dids     map[u16][]u8 // ReadDataByIdentifier table (0x22/0x2E)
	dtcs     []Dtc        // ReadDTCInformation table (0x19 01/02/0A), cleared by 0x14
	// each DTC's snapshot DID values, captured when the server serves its first request: a freeze
	// frame is history, so a later 0x2E to one of its DIDs must not rewrite it
	snap_vals  map[u32]map[u16][]u8
	snap_taken bool
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
	// its snapshot (0x19 03/04): the DIDs of record 0x01, their values captured from the server's
	// own table when it serves its first request (Server.take_snapshots); none = no snapshot stored
	snapshot []u16
	// its extended data (0x19 06), blobly_emb's records: 0x01 occurrences, 0x02 aging,
	// 0x03 failed cycles
	occurrence    u16
	aging         u8
	failed_cycles u8
}

// default_dtcs is what the built-in server has always reported, kept so an unconfigured
// server behaves exactly as before.
pub const default_dtcs = [
	Dtc{
		code:          0x123456
		status:        0x09
		snapshot:      [u16(0xF195), 0xF18C]
		occurrence:    3
		failed_cycles: 1
	},
	Dtc{
		code:   0xABCDEF
		status: 0x08
		aging:  2
	},
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
	if !s.snap_taken {
		s.take_snapshots()
	}
	_, subfn := echo_of(req) // the client's list: one answer to which services carry a sub-function
	if subfn && req[0] != sid_read_dtc_information && req.len > 1 && req[1] & 0x80 != 0 {
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
			// ISO 14229-1: every session transition locks the server again
			s.unlocked = false
			s.sec_seed = []u8{}
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
				mut resp := [u8(0x67), sub]
				if s.unlocked {
					// ISO 14229-1: an unlocked server answers an all-zero seed, and expects no key
					resp << []u8{len: server_security_seed.len}
					return resp
				}
				s.sec_seed = server_security_seed.clone()
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
			if sub == 0x03 || sub == 0x04 || sub == 0x06 {
				return s.dtc_records(req)
			}
			if sub != 0x01 && sub != 0x02 && sub != 0x0A {
				return neg(sid, 0x12) // subFunctionNotSupported (bit 7 too: 0x19 has no suppress)
			}
			if req.len != if sub == 0x0A { 2 } else { 3 } {
				return neg(sid, 0x13) // incorrectMessageLengthOrInvalidFormat
			}
			if sub == 0x0A { // reportSupportedDTC: every DTC, whole status
				mut all := [u8(0x59), 0x0A, 0xFF]
				for d in s.dtcs {
					all << [u8((d.code >> 16) & 0xFF), u8((d.code >> 8) & 0xFF), u8(d.code & 0xFF), d.status]
				}
				return all
			}
			mask := req[2]
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
// server its own, cap 1, and signalling it never blocks (closing it works too). It is read
// without being taken, so a software channel's segmented answer can ask it as well and abandon
// the transfer rather than finish it (#347).
pub fn (mut s Server) serve(mut ch isotp.Channel, stop chan bool) {
	stopped := fn [stop] () bool {
		return stop.len > 0 || stop.closed
	}
	// installed for this serve only: the caller's own hook is put back on the way out
	mut prev := stopped
	if mut ch is isotp.SoftChannel {
		prev = ch.stop_requested
		ch.stop_requested = stopped
	}
	for {
		if stopped() {
			if mut ch is isotp.SoftChannel {
				ch.stop_requested = prev
			}
			// taken, as the select this replaced took it, so `stop` can serve again
			select {
				_ := <-stop {}
				else {}
			}
			return
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

// take_snapshots captures every DTC's snapshot DIDs from the table as it stands; a DID the
// table does not hold has nothing to capture and is left out.
fn (mut s Server) take_snapshots() {
	for d in s.dtcs {
		mut vals := map[u16][]u8{}
		for id in d.snapshot {
			if v := s.dids[id] {
				vals[id] = v.clone()
			}
		}
		s.snap_vals[d.code] = vals.clone()
	}
	s.snap_taken = true
}

// dtc_records answers 0x19 03 / 04 / 06 the way blobly_emb's fault memory does: one snapshot
// record (0x01) per DTC that has one, extended data records 0x01 .. 0x03, 0xFF for all, an unknown
// DTC or record number out of range.
fn (mut s Server) dtc_records(req []u8) []u8 {
	sub := req[1]
	if sub == 0x03 {
		if req.len != 2 {
			return neg(0x19, 0x13)
		}
		mut out := [u8(0x59), 0x03]
		for d in s.dtcs {
			if (s.snap_vals[d.code] or { map[u16][]u8{} }).len > 0 {
				out << [u8(d.code >> 16), u8(d.code >> 8), u8(d.code), 0x01]
			}
		}
		return out
	}
	if req.len != 6 {
		return neg(0x19, 0x13)
	}
	code := u32(req[2]) << 16 | u32(req[3]) << 8 | u32(req[4])
	rec := req[5]
	mut found := -1
	for i, d in s.dtcs {
		if d.code == code {
			found = i
		}
	}
	if found < 0 {
		return neg(0x19, 0x31)
	}
	d := s.dtcs[found]
	mut out := [u8(0x59), sub, req[2], req[3], req[4], d.status]
	if sub == 0x04 {
		if rec != 0x01 && rec != 0xFF {
			return neg(0x19, 0x31)
		}
		// the values captured, in the order the DTC lists its DIDs
		vals := (s.snap_vals[d.code] or { map[u16][]u8{} }).clone()
		snap := d.snapshot.filter(it in vals)
		if snap.len > 0 {
			// a count that does not fit one byte is sent as 0, "not stated": the DIDs run to the end
			out << [u8(0x01), if snap.len > 255 { u8(0) } else { u8(snap.len) }]
			for id in snap {
				out << [u8(id >> 8), u8(id)]
				out << vals[id]
			}
		}
		return out
	}
	if rec != 0xFF && (rec < 1 || rec > 3) {
		return neg(0x19, 0x31)
	}
	if rec == 0xFF || rec == 1 {
		out << [u8(0x01), u8(d.occurrence >> 8), u8(d.occurrence)]
	}
	if rec == 0xFF || rec == 2 {
		out << [u8(0x02), d.aging]
	}
	if rec == 0xFF || rec == 3 {
		out << [u8(0x03), d.failed_cycles]
	}
	return out
}
