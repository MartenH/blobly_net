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
//   seed of that level outstanding (0x24), the lockout delay (0x37, the seed spent), the key (0x35,
//   0x36 on the last allowed attempt);
//   0x29, on a node whose description says `access = "authentication"` (0x27 is then not served):
//   blobly_emb comm/uds auth.v's order — length (0x13), sub-function 00/05/06 (0x12), its exact
//   length and fixed length fields (0x13); 05: algorithm or level (0x31), the delay (0x37); 06: a
//   challenge outstanding (0x24), the algorithm (0x31), the delay (0x37, the challenge void), the
//   proof (0x58, 0x36 on the last allowed).
//
// The description is not read here: uds is below sysview (which imports uds for the standard DID
// names), so sysview fills a ServerSpec and this builds from it. What a simulated ECU cannot do it
// refuses rather than acknowledges: 0x28 is serviceNotSupported (nothing here gates the simulated
// traffic), and the programming handoff (0x10 02) is conditionsNotCorrect once its gates pass —
// there is no bootloader to hand the ECU to. 0x2F and 0x23/0x3D are served for the IO DIDs and
// memory ranges a project declares (io_memory.v), behind their table rows like any service.
module uds

import time
import blobly.isotp
import crypto.ed25519 as ed

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
	width   int
	signed  bool
	boolean bool // a bool: any nonzero value is 1
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
	// `[uds] access = "authentication"`: the levels are unlocked with 0x29 ACR against auth_keys
	// (index level - 1, each a 32-byte Ed25519 public key; empty = no key for that level), and 0x27
	// is not served
	authenticates bool
	auth_keys     [][]u8
	// levels (bit L-1) whose key the node would refuse here — the dev tester key over DoIP without
	// allow_bench_key (sysview server_spec): a challenge is served, as the node serves one, and NO
	// proof verifies, the key being absent rather than some other key's
	auth_refused u8
}

// auth_key: the public key level L's proofs verify against; none when the description gives none,
// or the level's key is refused here (auth_refused)
pub fn (spec ServerSpec) auth_key(level u8) ?[]u8 {
	if level < 1 || int(level) > spec.auth_keys.len || spec.auth_keys[level - 1].len != 32
		|| spec.auth_refused & (u8(1) << (level - 1)) != 0 {
		return none
	}
	return spec.auth_keys[level - 1]
}

// auth_keyed: level L has a key, whether or not it is refused here — what a 05 asks
pub fn (spec ServerSpec) auth_keyed(level u8) bool {
	if level < 1 || level > 8 {
		return false
	}
	return spec.auth_refused & (u8(1) << (level - 1)) != 0 || (spec.auth_key(level) or { []u8{} }).len == 32
}

// default_sessions is where a service runs unless its row says otherwise (comm/uds
// default_sessions): 0x27, 0x28, 0x29, 0x2F and 0x85 only outside the default session.
pub fn default_sessions(sid u8) u8 {
	return match sid {
		0x27, 0x28, 0x29, 0x2F, 0x85 { in_extended | in_programming }
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
	return if spec.max_response > 0 { spec.max_response } else { isotp.max_pdu }
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

// physical_only: a request a server ignores when it arrives functionally — SecurityAccess and
// Authentication, whose seed and key (or challenge and proof) are one tester's exchange (comm/uds
// handle_functional).
pub fn physical_only(req []u8) bool {
	return req.len > 0 && (req[0] == 0x27 || req[0] == 0x29)
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

// written_size: the size a 0x2E to DID `id` must carry on this described server; none when the
// DID is not writable, 0x2E is not served or its table leaves it out (or the server is not
// described).
pub fn (s &Server) written_size(id u16) ?int {
	if !s.described || !s.supported(0x2E) {
		return none
	}
	_, listed := s.row(0x2E)
	if !listed {
		return none
	}
	d := s.did_spec(id) or { return none }
	if !d.writable {
		return none
	}
	return d.data.len
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
		0x27 { s.spec.security_mask() != 0 && !s.spec.authenticates }
		0x29 { s.spec.security_mask() != 0 && s.spec.authenticates }
		0x2F { s.io_start.len > 0 }
		0x23, 0x3D { s.memory.len > 0 }
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
// active; it returns the IO controls the entry ends (io_ends: every one on entering the default
// session — a reset and S3 included —, on another entry those the relock or the new session ends).
fn (mut s Server) enter_session(session u8) {
	s.unlocked = 0
	s.seed_lvl = 0
	s.sec_seed = []u8{}
	s.auth_challenge = []u8{}
	s.session = session
	if s.io_ends(0, false, session) {
		s.return_io_control()
	}
}

// io_ends: whether the 0x2F controls go back to the ECU — every one is gated by the "0x2F" row (its
// level and sessions), and the rule is blobly_emb comm/uds io_ends: on a session entry (`session`
// != 0) a return to default ends them, and any other entry relocks, so a control that needs a
// level ends, as does one whose sessions leave out the new one; else (`session` 0) when the relock
// of `level` ends its level — or, `others`, the relock of every level but `level` (a grant)
fn (s &Server) io_ends(level u8, others bool, session u8) bool {
	row, listed := s.row(0x2F)
	sec := if listed { row.level } else { u8(0) }
	if session != 0 {
		return session == 1 || sec != 0 || (listed && !in_mask(row.sessions, session))
	}
	return if others { sec != 0 && sec != level } else { level != 0 && sec == level }
}

// relock: level `level` relocked without a session entry (0x29 00 deAuthenticate, the end of the
// connection that earned it) — blobly_emb comm/uds relock: the unlock where it is that level, and
// the 0x2F controls gated on it returned (the routines it gates are blobly_emb's; this server
// performs none)
fn (mut s Server) relock(level u8) {
	if level != 0 && s.unlocked == level {
		s.unlocked = 0
	}
	if s.io_ends(level, false, 0) {
		s.return_io_control()
	}
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
		0x11 { s.d_reset(req, now) }
		0x22 { s.d_read(req) }
		0x2E { s.d_write(req) }
		0x27 { s.d_security(req, now) }
		0x29 { s.d_auth(req, now) }
		0x3E { s.d_tester_present(req) }
		0x14, 0x19, 0x85 { s.answer_dtc(req) }
		0x2F { s.io_control(req) }
		0x23 { s.read_memory(req) }
		0x3D { s.write_memory(req) }
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

fn (mut s Server) d_reset(req []u8, now i64) []u8 {
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
	// a reset with a wrong key counted since a served level's last correct key costs that level's
	// full delay — after a lockout that has ended too, and one during a lockout restarts it — as
	// comm/uds reset_state does, or resets would be the way around the attempt limit
	s.sa_restart(now)
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
		if _ := s.session_did(id) {
			ids << id
			continue
		}
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
		total += 2 + (s.dids[id] or { s.session_did(id) or { []u8{} } }).len
	}
	if total > s.spec.resp_cap() {
		return neg(0x22, 0x14) // responseTooLong: more than the carrier takes in one answer
	}
	mut resp := [u8(0x62)]
	for id in ids {
		if v := s.session_did(id) {
			resp << [u8(id >> 8), u8(id)]
			resp << v
			continue
		}
		d := s.did_spec(id) or { continue }
		if d.source == .live && id !in s.io_held {
			s.refresh_live(d)
		}
		resp << [u8(id >> 8), u8(id)]
		resp << s.dids[id] or { []u8{} }
	}
	return resp
}

// refresh_live puts a live DID's signal value into the table (live_field_bytes); a server with no
// signal source, or a signal it does not have, keeps what is there (zeros at first).
fn (mut s Server) refresh_live(d DidSpec) {
	if s.signal_value == unsafe { nil } || d.fields.len != 1 {
		return
	}
	v := s.signal_value(d.signal) or { return }
	s.dids[d.id] = live_field_bytes(v, d.fields[0])
}

// LiveValue is a live signal's value as an exact integer: `bits` read as an i64 (two's
// complement) when `negative`, as a u64 otherwise, so both 64-bit ranges are carried whole.
pub struct LiveValue {
pub:
	bits     u64
	negative bool
}

// live_int is `v` as a LiveValue.
pub fn live_int(v i64) LiveValue {
	return LiveValue{
		bits:     u64(v)
		negative: v < 0
	}
}

// live_field_bytes is a live value in its DID field, big-endian at the field's width: held to
// what the width holds, a bool 1 for any nonzero value (blobly_emb's did_signal_encode).
pub fn live_field_bytes(v LiveValue, f FieldSpec) []u8 {
	w := f.width // 1, 2, 4 or 8 (sysview.Field.width)
	umax := if w >= 8 { max_u64 } else { (u64(1) << (8 * w)) - 1 }
	smax := umax >> 1
	mut raw := u64(0)
	if f.boolean {
		raw = if v.bits != 0 { u64(1) } else { u64(0) }
	} else if f.signed && v.negative {
		raw = u64(if i64(v.bits) < -i64(smax) - 1 { -i64(smax) - 1 } else { i64(v.bits) })
	} else if f.signed {
		raw = if v.bits > smax { smax } else { v.bits }
	} else if !v.negative {
		raw = if v.bits > umax { umax } else { v.bits }
	}
	mut out := []u8{len: w}
	for i in 0 .. w {
		out[w - 1 - i] = u8(raw >> (8 * i))
	}
	return out
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
	if rec.len != d.data.len || rec.len > max_described_did || !s.io_sized(id, rec.len) {
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
		if now < s.sa_delay_until[level - 1] {
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
	if now < s.sa_delay_until[level - 1] {
		return neg(0x27, 0x37) // a seed drawn before the lockout buys no key during it
	}
	want := if s.spec.reference_key { security_key(seed) } else { oem_key(seed) }
	if req[2..] != want {
		return neg(0x27, s.d_wrong(level, now, 0x35))
	}
	s.d_granted(level)
	return [u8(0x67), sub]
}

// d_wrong: a wrong 0x27 key or a failed 0x29 proof of `level`, counted — one count per level for
// both, as comm/uds sa_wrong: `wrong` to answer, or 0x36 when this one reached the limit and
// started the lockout
fn (mut s Server) d_wrong(level u8, now i64, wrong u8) u8 {
	limit := s.sa_limit()
	if s.sa_since[level - 1] < limit {
		s.sa_since[level - 1]++
	}
	s.sa_failed[level - 1]++
	if s.sa_failed[level - 1] >= limit {
		s.sa_failed[level - 1] = 0
		s.sa_delay_until[level - 1] = now + i64(s.sa_delay())
		return 0x36
	}
	return wrong
}

// d_granted: a correct key or proof of `level` — unlocked, its count cleared, and the controls of
// another level it relocks returned (blobly_emb comm/uds sa_granted's end_levels)
fn (mut s Server) d_granted(level u8) {
	s.sa_failed[level - 1] = 0
	s.sa_since[level - 1] = 0
	if s.io_ends(level, true, 0) {
		s.return_io_control()
	}
	s.unlocked = level
}

// d_auth is 0x29 on a described server that authenticates — blobly_emb comm/uds auth.v's layouts
// and order, through this module's offsets (auth.v): 00 relocks (relock: its controls returned), 05 binds a fresh 32-byte challenge
// to the level its communicationConfiguration names, 06 verifies the Ed25519 signature over the
// application message for that level and challenge (auth_message) against the level's public key.
// A failed proof counts as a wrong key (d_wrong).
fn (mut s Server) d_auth(req []u8, now i64) []u8 {
	if req.len < 2 {
		return neg(0x29, 0x13)
	}
	sub := req[1] & 0x7F
	suppress := req[1] & 0x80 != 0
	want := match sub {
		auth_deauthenticate { 2 }
		auth_request_challenge { auth_challenge_req_len }
		auth_verify_proof { auth_proof_req_len }
		else { 0 }
	}
	if want == 0 {
		return neg(0x29, 0x12)
	}
	if req.len != want {
		return neg(0x29, 0x13)
	}
	if sub == auth_verify_proof && (be16_at(req, auth_proof_len_at) != auth_proof_len
		|| be16_at(req, auth_cc_len_at) != 0 || be16_at(req, auth_ap_len_at) != 0) {
		return neg(0x29, 0x13)
	}
	if sub == auth_deauthenticate {
		s.relock(s.unlocked) // the unlock, and the controls it gated
		s.seed_lvl = 0
		s.auth_challenge = []u8{}
		return if suppress { []u8{} } else { [u8(0x69), 0x00, auth_deauthenticated] }
	}
	if sub == auth_request_challenge {
		level := req[auth_level_at]
		if req[auth_alg05_at..auth_alg05_at + 16] != ed25519_algorithm || level == 0 || level > 8
			|| s.spec.security_mask() & (u8(1) << (level - 1)) == 0 || !s.spec.auth_keyed(level) {
			return neg(0x29, 0x31)
		}
		if now < s.sa_delay_until[level - 1] {
			return neg(0x29, 0x37)
		}
		if s.spec.resp_cap() < auth_challenge_answer_len {
			return neg(0x29, 0x14)
		}
		s.seed_lvl = 0
		s.auth_challenge = s.next_bytes(auth_challenge_len) // never all zero: no 0x59 here
		s.seed_lvl = level
		mut resp := [u8(0x69), auth_request_challenge, auth_request_accepted]
		resp << ed25519_algorithm
		resp << [u8(0x00), u8(auth_challenge_len)]
		resp << s.auth_challenge
		resp << [u8(0), 0]
		return resp
	}
	if s.seed_lvl == 0 || s.auth_challenge.len != auth_challenge_len {
		return neg(0x29, 0x24)
	}
	if req[auth_alg_at..auth_alg_at + 16] != ed25519_algorithm {
		return neg(0x29, 0x31) // the challenge stays
	}
	if now < s.sa_delay_until[s.seed_lvl - 1] {
		s.seed_lvl = 0
		s.auth_challenge = []u8{}
		return neg(0x29, 0x37) // a challenge drawn before the lockout buys no proof during it
	}
	if s.spec.resp_cap() < auth_proof_answer_len {
		return neg(0x29, 0x14) // the challenge stays
	}
	level := s.seed_lvl
	challenge := s.auth_challenge.clone()
	s.seed_lvl = 0
	s.auth_challenge = []u8{}
	key := s.spec.auth_key(level) or { []u8{} }
	ok := key.len == 32 && (ed.verify(key, auth_message(level, challenge), req[auth_proof_at..auth_proof_at +
		auth_proof_len]) or { false })
	if !ok {
		return neg(0x29, s.d_wrong(level, now, nrc_ownership_failed))
	}
	s.d_granted(level)
	// answered whatever the suppress bit, as the board does: its 06 answers responsePending first,
	// which lifts the suppression (ISO 14229-1); the simulation verifies at once and sends no 0x78
	return auth_proof_answer()
}

fn be16_at(b []u8, at int) int {
	return int(b[at]) << 8 | int(b[at + 1])
}

// connection_dropped: the tester's connection is gone (a hosted DoIP entity's tester disconnected)
// — as blobly_emb comm/diag remote_dropped: its seed or challenge is void, its unlock ends and the
// session it opened returns to default. The next connection authenticates for itself.
pub fn (mut s Server) connection_dropped() {
	s.relock(s.unlocked) // the unlock it earned, and the controls it gated
	if s.session != 1 {
		s.enter_session(1)
	}
	s.unlocked = 0
	s.seed_lvl = 0
	s.sec_seed = []u8{}
	s.auth_challenge = []u8{}
}

// sa_restart: what a reset makes of the 0x27 counts, comm/uds sa_restart's rule (a target's
// start-up restoring its journal follows it too): per served level with a wrong key counted since
// its last correct key, the lockout count is that count below the attempt limit, or 0 at or above
// it — after the delay of a saturated count the level has its attempts again, as after any lockout
// — and that level's delay runs from `now`; another level's seed is not delayed. Only a served
// level ever counts (another's seed is refused 0x12 first), and this server keeps no journal.
fn (mut s Server) sa_restart(now i64) {
	limit := s.sa_limit()
	for i in 0 .. 8 {
		if s.sa_since[i] > 0 {
			s.sa_failed[i] = if s.sa_since[i] < limit { s.sa_since[i] } else { 0 }
			s.sa_delay_until[i] = now + i64(s.sa_delay())
		}
	}
}

// sa_limit: the wrong keys a level takes before its lockout (comm/uds attempts_of: 0 = the default 3)
fn (s &Server) sa_limit() int {
	return if s.spec.security_attempts > 0 { s.spec.security_attempts } else { 3 }
}

fn (s &Server) sa_delay() int {
	return if s.spec.security_delay_ms > 0 { s.spec.security_delay_ms } else { 10000 }
}

// next_seed is a fresh, never all-zero seed (all zeros means "already unlocked" on the wire).
fn (mut s Server) next_seed() []u8 {
	return s.next_bytes(sa_seed_len)
}

// next_bytes is `n` fresh bytes from the seed generator, never all zero — a 0x27 seed or a 0x29
// challenge.
fn (mut s Server) next_bytes(n int) []u8 {
	if s.sa_state == 0 {
		s.sa_state = u32(time.sys_mono_now()) | 1
	}
	mut out := []u8{len: n}
	for {
		for i in 0 .. n {
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
