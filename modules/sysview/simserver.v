module sysview

import uds

// simserver.v — a node's description as the diagnostic server a simulation serves for it
// (uds.server_from). Here and not in uds because uds sits below sysview (this module imports it
// for the standard DID names): sysview fills uds's ServerSpec, uds builds and runs the server.

// session_mask is a gate's sessions as a uds in_* mask; 0 = every session (none listed). A name
// that is no session allows nothing: a gate naming only such names is closed (a mask of a session
// no 0x10 enters), never opened to every session.
fn session_mask(names []string) u8 {
	mut m := u8(0)
	for n in names {
		if id := session_id(n) {
			m |= u8(1) << (id - 1)
		}
	}
	return if m == 0 && names.len > 0 { closed_mask } else { m }
}

// closed_mask is session 8's bit, which no request enters here (0x10 serves 01 to 04).
const closed_mask = u8(0x80)

// unknown_sessions: the names in a gate that are no session.
fn unknown_sessions(names []string) []string {
	return names.filter((session_id(it) or { u8(0) }) == 0)
}

fn gate_spec(g Gate) uds.GateSpec {
	return uds.GateSpec{
		sessions: session_mask(g.sessions)
		level:    u8(g.level)
	}
}

fn field_spec(f Field, r ?Range) uds.FieldSpec {
	rg := r or {
		if f.typ == 'bool' {
			// a bool holds 0 or 1 whatever the range says nothing about
			return uds.FieldSpec{
				width:  1
				ranged: true
				min:    0
				max:    1
			}
		}
		return uds.FieldSpec{
			width:  f.width()
			signed: f.typ.starts_with('i')
		}
	}
	return uds.FieldSpec{
		width:  f.width()
		signed: f.typ.starts_with('i')
		ranged: true
		min:    rg.min
		max:    rg.max
	}
}

// be_bytes is `v` big-endian in `w` bytes (two's complement for a negative).
fn be_bytes(v i64, w int) []u8 {
	mut out := []u8{len: w}
	for i in 0 .. w {
		out[w - 1 - i] = u8(u64(v) >> (8 * i))
	}
	return out
}

// performed_sids are the services a described server performs (uds supported(), less those a
// description may leave out): a table row for any other is refused, and said.
const performed_sids = [u8(0x10), 0x11, 0x14, 0x19, 0x22, 0x27, 0x2E, 0x3E, 0x85]

// boot_sw_version_did is the DID a [boot] node answers with its running image's sw_version
// (blobly_emb loom2v handoff_did): a u32, which the simulation has no image to take it from.
const boot_sw_version_did = u16(0xF195)

// server_spec is the server the description states. `remote` = served over DoIP, where the
// reference key is accepted only with `allow_bench_key` (blobly_emb REQ-NET-012). The notes say
// what the simulation serves differently from the node, one line each.
pub fn (d &EcuDesc) server_spec(remote bool) (uds.ServerSpec, []string) {
	mut notes := []string{}
	mut dids := []uds.DidSpec{}
	mut status_of := map[string]int{}
	for i, p in d.params {
		status_of[p.name] = i
	}
	mut seen := map[u16]bool{}
	for x in d.dids {
		if x.id in seen {
			notes << 'DID 0x${x.id:04X} is declared twice; the first is served'
			continue
		}
		seen[x.id] = true
		for key, g in {
			'read':  x.read_gate
			'write': x.write_gate
		} {
			bad := unknown_sessions(g.sessions)
			if bad.len > 0 {
				notes << 'DID 0x${x.id:04X}: ${key} session ${bad.join(', ')} is no session; not allowed there'
			}
		}
		if x.size < 0 {
			notes << 'DID 0x${x.id:04X}: its size is not known here; not served'
			continue
		}
		mut src := uds.DidSource.constant
		mut data := []u8{len: x.size}
		mut fields := []uds.FieldSpec{}
		mut signal := ''
		mut status_index := -1
		match x.kind {
			.ascii {
				data = x.text.bytes()
			}
			.bytes {
				if x.data.len == x.size {
					data = x.data.clone()
				}
			}
			.signal {
				src = .live
				signal = x.name
				fields = x.fields.map(field_spec(it, none))
			}
			.param {
				src = .param
				fields = x.fields.map(field_spec(it, x.ranges[it.name] or { none }))
				data = []u8{}
				for f in x.fields {
					pd := d.params.filter(it.name == x.name)
					v := if pd.len > 0 { pd[0].defaults[f.name] or { 0 } } else { 0 }
					data << be_bytes(v, f.width())
				}
				status_index = status_of[x.name] or { -1 }
			}
			.param_status {
				src = .param_status
			}
			.tx_saturations {
				notes << 'DID 0x${x.id:04X} (sent values saturated) reads 0: the simulation does not count them'
			}
			.unknown {}
		}
		dids << uds.DidSpec{
			id:           x.id
			source:       src
			data:         data
			read:         gate_spec(x.read_gate)
			writable:     x.write_gate.declared
			write:        gate_spec(x.write_gate)
			signal:       signal
			fields:       fields
			status_index: status_index
		}
	}
	if d.boot && !dids.any(it.id == boot_sw_version_did) {
		dids << uds.DidSpec{
			id:   boot_sw_version_did
			data: []u8{len: 4}
		}
		notes << 'DID 0x${boot_sw_version_did:04X} (the image sw_version) reads 0: the simulation runs no image'
	}
	mut services := []uds.ServiceSpec{}
	mut handoff_row := false
	mut handoff_sessions := u8(0)
	mut handoff_level := u8(0)
	for r in d.services {
		bad := unknown_sessions(r.gate.sessions)
		if bad.len > 0 {
			notes << '[uds] services 0x${r.sid:02X}: session ${bad.join(', ')} is no session; not allowed there'
		}
		if r.sid !in performed_sids {
			notes << '[uds] services 0x${r.sid:02X} is not simulated; it is refused (serviceNotSupported)'
		}
		if r.sub >= 0 && !(r.sid == 0x10 && r.sub == 2) {
			notes << '[uds] services "0x${r.sid:02X} ${r.sub:02X}": the one sub-function row is the programming handoff "0x10 02"; ignored'
		}
		if r.sub >= 0 {
			if r.sid == 0x10 && r.sub == 2 {
				handoff_row = true
				handoff_sessions = session_mask(r.gate.sessions)
				handoff_level = u8(r.gate.level)
			}
			continue
		}
		services << uds.ServiceSpec{
			sid:      r.sid
			sessions: session_mask(r.gate.sessions)
			level:    u8(r.gate.level)
		}
	}
	if d.boot {
		notes << '0x10 02 (the programming handoff) is refused with conditionsNotCorrect: no bootloader is simulated'
	}
	reference := d.security_key == 'reference' && (!remote || d.allow_bench_key)
	spec := uds.ServerSpec{
		dids:              dids
		table:             d.services_table
		services:          services
		handoff:           d.boot
		handoff_row:       handoff_row
		handoff_sessions:  handoff_sessions
		handoff_level:     handoff_level
		faults:            d.faults.map(uds.FaultSpec{
			code:   it.dtc
			freeze: it.freeze.clone()
		})
		serves_reset:      !remote
		reference_key:     reference
		security_attempts: d.security_attempts
		security_delay_ms: d.security_delay_ms
		s3_ms:             d.s3_ms
	}
	if spec.security_mask() != 0 && !reference {
		notes << '0x27 refuses the reference key, as the node does (no `security_key = "reference"`' +
			if remote && d.security_key == 'reference' { ' with `allow_bench_key` over DoIP)' } else { ')' }
	}
	return spec, notes
}
