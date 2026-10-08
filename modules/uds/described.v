// described.v — a Server built from a node's DESCRIPTION (`server_from`), answering as
// blobly_emb's comm/uds server answers for that node: the DID table with its sizes, values and
// read/write gates, the `[uds] services` table, 0x27 at the levels the gates name, parameters
// written through 0x2E within their range, and the fault memory's DTCs. The negative responses
// follow comm/uds's evaluation order, which is ISO 14229-1's:
//
//   every service: supported (0x11) → in the table (0x11) → in the active session (0x7F) → the
//   row's security level (0x33) → then the service's own flow;
//   0x22: length (0x13) → each DID's support and read session (0x31 when none answers) → its
//   security (0x33);
//   0x2E: length (0x13) → the DID's support, writability and write session (0x31) → security
//   (0x33) → the record length, which must be the DID's size (0x13) → a parameter's range (0x31);
//   0x27: sub-function (0x12) → requestSeed: the lockout delay (0x37); sendKey: length (0x13), a
//   seed of that level outstanding (0x24), the key (0x35, 0x36 on the last allowed attempt).
//
// The description is not read here: uds is below sysview (which imports uds for the standard DID
// names), so sysview fills a ServerSpec and this builds from it. What a simulated ECU cannot do it
// refuses rather than acknowledges: 0x28 is serviceNotSupported (nothing here gates the simulated
// traffic), and the programming handoff (0x10 02) is conditionsNotCorrect once its gates pass —
// there is no bootloader to hand the ECU to.
module uds

import time

// Session masks, one bit per 0x10 session value (bit n-1 for session n); 0 = every session.
pub const in_default = u8(0x01)
pub const in_programming = u8(0x02)
pub const in_extended = u8(0x04)
pub const in_safety = u8(0x08)

// GateSpec is where an access is allowed: the sessions (an in_* mask, 0 = every session) and the
// 0x27 level it needs (0 = none).
pub struct GateSpec {
pub:
	sessions u8
	level    u8
}

// FieldSpec is one big-endian field of a laid-out DID value: its width, signedness and, for a
// parameter, the range a written value must lie in.
pub struct FieldSpec {
pub:
	width  int
	signed bool
	ranged bool
	min    i64
	max    i64
}

// DidKind says where a described DID's value comes from.
pub enum DidSource {
	constant     // fixed bytes (text, bytes, a status nobody changes)
	live         // a signal's value (Server.signal_value), zeros of its width without one
	param        // a parameter: written through 0x2E within its fields' ranges
	param_status // one status byte per parameter: 0 default, 1 coded
}

// DidSpec is one described DID.
pub struct DidSpec {
pub:
	id       u16
	source   DidSource
	data     []u8 // its initial value, at its real size
	read     GateSpec
	writable bool
	write    GateSpec
	signal   string      // live: the signal it reads
	fields   []FieldSpec // live / param: its layout
	// param: its byte in the parameter status DID, -1 = none
	status_index int = -1
}

// ServiceSpec is one `[uds] services` row. sessions 0 = the service's default sessions.
pub struct ServiceSpec {
pub:
	sid      u8
	sessions u8
	level    u8
}

// FaultSpec is one declared fault: its DTC and the DIDs its snapshot freezes.
pub struct FaultSpec {
pub:
	code   u32
	freeze []u16
}

// ServerSpec is a node's diagnostic server as its description states it.
pub struct ServerSpec {
pub mut:
	dids []DidSpec
	// `[uds] services` given: exactly `services` are served; false = the default table
	table    bool
	services []ServiceSpec
	// `[boot]`: 0x10 02 is the programming handoff, gated by the handoff row when there is one
	handoff          bool
	handoff_row      bool
	handoff_sessions u8
	handoff_level    u8
	faults           []FaultSpec
	// 0x27 accepts blobly_net's reference key (security_key) — else a key it does not match, as
	// an OEM node's
	// 0x11 is served: an owner performs the reset (comm/uds serves_reset) — on CAN; a DoIP
	// connection's server does not
	serves_reset      bool
	reference_key     bool
	security_attempts int // 0 = 3
	// the longest answer the carrier takes (0x22 answers 0x14 past it); 0 = one ISO-TP transfer
	max_response int
	security_delay_ms int // 0 = 10 s
	s3_ms             int // 0 = 5 s
}

// default_sessions is where a service runs unless its row says otherwise (comm/uds
// default_sessions): 0x27, 0x28 and 0x85 only outside the default session.
pub fn default_sessions(sid u8) u8 {
	return match sid {
		0x27, 0x28, 0x85 { in_extended | in_programming }
		else { u8(0) }
	}
}

// in_mask: `session` is allowed by `mask` (0 = every session).
fn in_mask(mask u8, session u8) bool {
	if mask == 0 {
		return true
	}
	if session == 0 || session > 8 {
		return false
	}
	return mask & (u8(1) << (session - 1)) != 0
}

// status_cleared is a DTC's status after a clear and at power-on (comm/fault): nothing completed.
pub const status_cleared = u8(0x50)

// availability_mask is the status bits blobly_emb's fault memory maintains (no warning lamp).
pub const fault_availability = u8(0x7F)

// max_described_did is the most a written DID record may hold (comm/uds max_did_data).
pub const max_described_did = 32

// sa_seed_len is a seed's length (comm/uds seed_len), which a key must match.
const sa_seed_len = 4

// oem_key stands in for an OEM's key algorithm on a node whose description names no
// `security_key`: a key blobly_net's reference algorithm (security_key, XOR 0xFF) never matches,
// so a tester using it is refused as it would be by the real node.
pub fn oem_key(seed []u8) []u8 {
	return seed.map(it ^ u8(0x5A))
}

// server_from builds a server from a description.
pub fn server_from(spec ServerSpec) Server {
	mut s := Server{
		described: true
		spec:      spec
		avail:     fault_availability
	}
	for d in spec.dids {
		if d.id !in s.dids {
			s.dids[d.id] = d.data.clone() // the first declaration, whose gates did_spec finds
		}
	}
	for f in spec.faults {
		s.dtcs << Dtc{
			code:   f.code
			status: status_cleared
		}
	}
	// a fault memory snapshots only a DTC that failed; none has yet
	s.snap_taken = true
	return s
}

// put_did sets a DID's value, keeping its gates; a DID the description does not declare is added
// readable everywhere and not writable (a project's `dids:` on a described node). A 0x2E still
// takes a record of the DESCRIBED size, whatever length the value put here has.
pub fn (mut s Server) put_did(id u16, data []u8) {
	if !s.spec.dids.any(it.id == id) {
		s.spec.dids << DidSpec{
			id:   id
			data: data.clone()
		}
	}
	s.dids[id] = data.clone()
}

// set_dtc_status gives a described DTC a status (a project's `dtcs:` seeding a fault), adding a
// DTC the description does not declare. A failed one gets its snapshot of the DIDs as they stand.
pub fn (mut s Server) set_dtc_status(code u32, status u8) {
	st := status & s.avail
	mut found := false
	for i, d in s.dtcs {
		if d.code == code {
			s.dtcs[i] = Dtc{
				...d
				status: st
			}
			found = true
		}
	}
	if !found {
		s.dtcs << Dtc{
			code:   code
			status: st
		}
	}
	if st & 0x2F == 0 {
		return // never failed: no snapshot
	}
	for f in s.spec.faults {
		if f.code == code && f.freeze.len > 0 {
			mut vals := map[u16][]u8{}
			for id in f.freeze {
				if v := s.dids[id] {
					vals[id] = v.clone()
				}
			}
			s.snap_vals[code] = vals.clone()
			for i, d in s.dtcs {
				if d.code == code {
					s.dtcs[i] = Dtc{
						...d
						snapshot: f.freeze.clone()
					}
				}
			}
		}
	}
}

fn (spec ServerSpec) resp_cap() int {
	return if spec.max_response > 0 { spec.max_response } else { 4095 }
}

// security_mask is the 0x27 levels the server serves (bit L-1 for level L): every level a DID
// gate, a service row or the handoff row names — a level nothing is gated on unlocks nothing.
pub fn (spec ServerSpec) security_mask() u8 {
	mut m := u8(0)
	mut levels := []u8{}
	for d in spec.dids {
		levels << d.read.level
		levels << d.write.level
	}
	for r in spec.services {
		levels << r.level
	}
	levels << spec.handoff_level
	for l in levels {
		if l > 0 && l <= 8 {
			m |= u8(1) << (l - 1)
		}
	}
	return m
}

fn (s &Server) now_ms() i64 {
	if s.clock != unsafe { nil } {
		return s.clock()
	}
	return i64(time.sys_mono_now() / 1_000_000) // monotonic: a wall-clock step moves no deadline
}

// physical_only: a request a server ignores when it arrives functionally — SecurityAccess, whose
// seed and key are one tester's exchange (comm/uds handle_functional).
pub fn physical_only(req []u8) bool {
	return req.len > 0 && req[0] == 0x27
}

// handle_functional answers a request that arrived on the functional address: a described server
// ignores one that is physical only, which still keeps its session alive.
pub fn (mut s Server) handle_functional(req []u8) []u8 {
	if s.described && physical_only(req) {
		s.received(s.now_ms()) // ignored, but it is a request: S3 first, then the stamp
		return []u8{}
	}
	return s.handle(req)
}

// received is the ONE place a request reaches a described server, answered or ignored: S3 ends a
// session no request has kept alive, then this request is stamped.
fn (mut s Server) received(now i64) {
	s3 := i64(if s.spec.s3_ms > 0 { s.spec.s3_ms } else { 5000 })
	if s.session != 1 && s.rx_seen && now - s.last_rx_ms > s3 {
		s.enter_session(1) // S3: no request for that long ends the session
	}
	s.last_rx_ms = now
	s.rx_seen = true
}

fn (s &Server) did_spec(id u16) ?DidSpec {
	for d in s.spec.dids {
		if d.id == id {
			return d
		}
	}
	return none
}

// unreadable_at_start: why a fresh tester — default session, nothing unlocked — cannot read DID
// `id` with 0x22 from this described server; none when it can (or the server is not described).
pub fn (s &Server) unreadable_at_start(id u16) ?string {
	if !s.described {
		return none
	}
	if !s.supported(0x22) {
		return '0x22 is not served'
	}
	row, listed := s.row(0x22)
	if !listed {
		return '[uds] services leaves out 0x22'
	}
	if !in_mask(row.sessions, 1) || row.level != 0 {
		return '0x22 is not served in the default session without unlocking'
	}
	d := s.did_spec(id) or { return 'it is not declared' }
	if !in_mask(d.read.sessions, 1) || d.read.level != 0 {
		return 'its read gate excludes the default session or needs a level'
	}
	return none
}

// supported: the services a described server performs at all.
fn (s &Server) supported(sid u8) bool {
	return match sid {
		0x10, 0x22, 0x2E, 0x3E { true }
		0x11 { s.spec.serves_reset }
		0x14, 0x19, 0x85 { s.spec.faults.len > 0 }
		0x27 { s.spec.security_mask() != 0 }
		else { false }
	}
}

// row is the table's row for `sid`, its sessions resolved to the service's default; false when a
// stated table leaves it out.
fn (s &Server) row(sid u8) (ServiceSpec, bool) {
	if !s.spec.table {
		return ServiceSpec{
			sid:      sid
			sessions: default_sessions(sid)
		}, true
	}
	for r in s.spec.services {
		if r.sid == sid {
			return ServiceSpec{
				sid:      sid
				sessions: if r.sessions != 0 { r.sessions } else { default_sessions(sid) }
				level:    r.level
			}, true
		}
	}
	return ServiceSpec{}, false
}

// enter_session relocks and voids an outstanding seed, every entry included the one already
// active.
fn (mut s Server) enter_session(session u8) {
	s.unlocked = 0
	s.seed_lvl = 0
	s.sec_seed = []u8{}
	s.session = session
}

fn (mut s Server) answer_described(req []u8) []u8 {
	now := s.now_ms()
	s.received(now)
	sid := req[0]
	if !s.supported(sid) {
		return neg(sid, 0x11)
	}
	row, listed := s.row(sid)
	if !listed {
		return neg(sid, 0x11)
	}
	if !in_mask(row.sessions, s.session) {
		return neg(sid, 0x7F)
	}
	if row.level != 0 && s.unlocked != row.level {
		return neg(sid, 0x33)
	}
	return match sid {
		0x10 { s.d_session(req) }
		0x11 { s.d_reset(req) }
		0x22 { s.d_read(req) }
		0x2E { s.d_write(req) }
		0x27 { s.d_security(req, now) }
		0x3E { s.d_tester_present(req) }
		0x14, 0x19, 0x85 { s.answer_dtc(req) }
		else { neg(sid, 0x11) }
	}
}

fn (mut s Server) d_session(req []u8) []u8 {
	if req.len < 2 {
		return neg(0x10, 0x13)
	}
	sub := req[1]
	if sub < 1 || sub > 4 {
		return neg(0x10, 0x12)
	}
	handoff := sub == 2
	if handoff && !s.spec.handoff {
		return neg(0x10, 0x12) // an application server never enters programming itself
	}
	if handoff {
		mask := if s.spec.handoff_row && s.spec.handoff_sessions != 0 {
			s.spec.handoff_sessions
		} else {
			in_extended
		}
		if !in_mask(mask, s.session) {
			return neg(0x10, 0x7E)
		}
		if s.spec.handoff_level != 0 && s.unlocked != s.spec.handoff_level {
			return neg(0x10, 0x33)
		}
	}
	if req.len != 2 {
		return neg(0x10, 0x13)
	}
	if handoff {
		return neg(0x10, 0x22) // no bootloader to hand the simulated ECU to
	}
	s.enter_session(sub)
	return [u8(0x50), sub, 0x00, 0x32, 0x01, 0xF4]
}

fn (mut s Server) d_reset(req []u8) []u8 {
	if req.len < 2 {
		return neg(0x11, 0x13)
	}
	if req[1] != 0x01 && req[1] != 0x03 {
		return neg(0x11, 0x12)
	}
	if req.len != 2 {
		return neg(0x11, 0x13)
	}
	s.enter_session(1)
	if s.sa_failed.any(it > 0) {
		// a reset between wrong keys costs the delay (comm/uds reset_state), or resets would be
		// the way around the attempt limit
		s.sa_delay_until = s.now_ms() + i64(s.sa_delay())
	}
	return [u8(0x51), req[1]]
}

fn (mut s Server) d_tester_present(req []u8) []u8 {
	if req.len < 2 {
		return neg(0x3E, 0x13)
	}
	if req[1] != 0 {
		return neg(0x3E, 0x12)
	}
	if req.len != 2 {
		return neg(0x3E, 0x13)
	}
	return [u8(0x7E), 0x00]
}

// readable: the DID exists and may be read in the active session.
fn (s &Server) readable(id u16) ?DidSpec {
	d := s.did_spec(id)?
	if !in_mask(d.read.sessions, s.session) {
		return none
	}
	return d
}

fn (mut s Server) d_read(req []u8) []u8 {
	if req.len < 3 || (req.len - 1) % 2 != 0 {
		return neg(0x22, 0x13)
	}
	mut ids := []u16{}
	for k := 1; k + 1 < req.len; k += 2 {
		id := u16(req[k]) << 8 | u16(req[k + 1])
		d := s.readable(id) or { continue }
		if d.read.level != 0 && s.unlocked != d.read.level {
			return neg(0x22, 0x33)
		}
		ids << id
	}
	if ids.len == 0 {
		return neg(0x22, 0x31)
	}
	mut total := 1
	for id in ids {
		total += 2 + (s.dids[id] or { []u8{} }).len
	}
	if total > s.spec.resp_cap() {
		return neg(0x22, 0x14) // responseTooLong: more than the carrier takes in one answer
	}
	mut resp := [u8(0x62)]
	for id in ids {
		d := s.did_spec(id) or { continue }
		if d.source == .live {
			s.refresh_live(d)
		}
		resp << [u8(id >> 8), u8(id)]
		resp << s.dids[id] or { []u8{} }
	}
	return resp
}

// refresh_live puts a live DID's signal value into the table, big-endian at its width; a server
// with no signal source, or a signal it does not have, keeps what is there (zeros at first).
fn (mut s Server) refresh_live(d DidSpec) {
	if s.signal_value == unsafe { nil } || d.fields.len != 1 {
		return
	}
	v := s.signal_value(d.signal) or { return }
	w := d.fields[0].width
	mut out := []u8{len: w}
	for i in 0 .. w {
		out[w - 1 - i] = u8(u64(v) >> (8 * i))
	}
	s.dids[d.id] = out
}

fn (mut s Server) d_write(req []u8) []u8 {
	if req.len < 4 {
		return neg(0x2E, 0x13)
	}
	id := u16(req[1]) << 8 | u16(req[2])
	rec := req[3..].clone()
	d := s.did_spec(id) or { return neg(0x2E, 0x31) }
	if !d.writable || !in_mask(d.write.sessions, s.session) {
		return neg(0x2E, 0x31)
	}
	if d.write.level != 0 && s.unlocked != d.write.level {
		return neg(0x2E, 0x33)
	}
	// the declared size is the only record a DID takes (comm/uds, emb#403): a write never
	// resizes a DID; past comm/uds's cell no record is taken at all
	if rec.len != d.data.len || rec.len > max_described_did {
		return neg(0x2E, 0x13)
	}
	if d.source == .param {
		if nrc := param_refusal(d.fields, rec) {
			return neg(0x2E, nrc)
		}
		if d.status_index >= 0 {
			for st in s.spec.dids {
				if st.source == .param_status {
					mut b := (s.dids[st.id] or { []u8{} }).clone()
					if d.status_index < b.len {
						b[d.status_index] = 1 // coded
						s.dids[st.id] = b
					}
				}
			}
		}
	}
	s.dids[id] = rec
	return [u8(0x6E), req[1], req[2]]
}

// param_refusal: the NRC a parameter's record is refused with (comm/param): each field's range
// (0x31); none = accepted. d_write has held the record to the declared size, which is the fields'
// width; a record of another width is still 0x13 rather than read past its end.
fn param_refusal(fields []FieldSpec, rec []u8) ?u8 {
	mut n := 0
	for f in fields {
		n += f.width
	}
	if rec.len != n {
		return u8(0x13)
	}
	mut at := 0
	for f in fields {
		v := field_int(f, rec[at..at + f.width])
		at += f.width
		if f.ranged && (v < f.min || v > f.max) {
			return u8(0x31)
		}
	}
	return none
}

// field_int reads one big-endian field, sign-extending a signed one.
fn field_int(f FieldSpec, b []u8) i64 {
	mut v := u64(0)
	for x in b {
		v = v << 8 | u64(x)
	}
	if f.signed && b.len > 0 && b.len < 8 && v & (u64(1) << (8 * b.len - 1)) != 0 {
		return i64(v) - i64(u64(1) << (8 * b.len))
	}
	return i64(v)
}

fn (mut s Server) d_security(req []u8, now i64) []u8 {
	if req.len < 2 {
		return neg(0x27, 0x13)
	}
	sub := req[1]
	level := u8((int(sub) + 1) / 2)
	mask := s.spec.security_mask()
	if sub == 0 || level > 8 || mask & (u8(1) << (level - 1)) == 0 {
		return neg(0x27, 0x12)
	}
	if sub % 2 == 1 {
		if now < s.sa_delay_until {
			return neg(0x27, 0x37)
		}
		s.seed_lvl = 0
		s.sec_seed = []u8{}
		if s.unlocked == level {
			return [u8(0x67), sub, 0, 0, 0, 0]
		}
		s.sec_seed = s.next_seed()
		s.seed_lvl = level
		mut resp := [u8(0x67), sub]
		resp << s.sec_seed
		return resp
	}
	if req.len != 2 + sa_seed_len {
		return neg(0x27, 0x13)
	}
	if s.seed_lvl != level || s.sec_seed.len == 0 {
		return neg(0x27, 0x24)
	}
	seed := s.sec_seed.clone()
	s.seed_lvl = 0
	s.sec_seed = []u8{}
	want := if s.spec.reference_key { security_key(seed) } else { oem_key(seed) }
	if req[2..] != want {
		s.sa_failed[level - 1]++
		limit := if s.spec.security_attempts > 0 { s.spec.security_attempts } else { 3 }
		if s.sa_failed[level - 1] >= limit {
			s.sa_failed[level - 1] = 0
			s.sa_delay_until = now + i64(s.sa_delay())
			return neg(0x27, 0x36)
		}
		return neg(0x27, 0x35)
	}
	s.sa_failed[level - 1] = 0
	s.unlocked = level
	return [u8(0x67), sub]
}

fn (s &Server) sa_delay() int {
	return if s.spec.security_delay_ms > 0 { s.spec.security_delay_ms } else { 10000 }
}

// next_seed is a fresh, never all-zero seed (all zeros means "already unlocked" on the wire).
fn (mut s Server) next_seed() []u8 {
	if s.sa_state == 0 {
		s.sa_state = u32(time.sys_mono_now()) | 1
	}
	mut out := []u8{len: sa_seed_len}
	for {
		for i in 0 .. sa_seed_len {
			s.sa_state ^= s.sa_state << 13
			s.sa_state ^= s.sa_state >> 17
			s.sa_state ^= s.sa_state << 5
			out[i] = u8(s.sa_state >> 24)
		}
		if out.any(it != 0) {
			return out
		}
	}
	return out
}

// clear_described is 0x14 on a described server: its declared DTCs go back to their power-on
// status with nothing frozen or counted (comm/fault), all of them or the one named; any other
// group is out of range.
fn (mut s Server) clear_described(group u32) []u8 {
	if group != 0xFFFFFF && !s.dtcs.any(it.code == group) {
		return neg(0x14, 0x31)
	}
	for i, d in s.dtcs {
		if group == 0xFFFFFF || d.code == group {
			s.dtcs[i] = Dtc{
				code:   d.code
				status: status_cleared
			}
			s.snap_vals.delete(d.code)
		}
	}
	return [u8(0x54)]
}
