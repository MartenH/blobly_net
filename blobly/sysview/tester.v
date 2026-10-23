module sysview

import os
import blobly.uds

// tester.v — a script's tester by NODE and by DID NAME: which row of the project reaches a node of
// the system and at which ids, the DIDs a tester lists for it, and a DID's value read and written
// through its description (the codec, didcodec.v, and the write gate's plan, uds.write_plan). The
// Lua uds.node and the C ABI's bb_node_* / bb_did_* (which Python's Project.nodes is over) both
// answer by these; the Diagnostics panel reaches its targets by the same rules (can_server,
// node_for).

// node_named is the index of the node called `name`: refused for a name no node has (naming those
// there are) or two share, and when no system.toml describes the project.
pub fn (sys &System) node_named(name string) !int {
	if sys.path == '' {
		return error("no system.toml describes this project (none beside it, beside one of its databases, or in its folder's parent), so it names no nodes")
	}
	mut found := -1
	for i, n in sys.nodes {
		if n.name != name {
			continue
		}
		if found >= 0 {
			return error('two nodes of ${sys.path} are named "${name}"; nothing here can tell which you mean')
		}
		found = i
	}
	if found < 0 {
		names := sys.nodes.map(it.name)
		there := if names.len > 0 { '; there are: ${names.join(', ')}' } else { '' }
		return error('no node "${name}" in ${sys.path}${there}')
	}
	return found
}

// RowRef is one of a project's rows a node may be reached on: its name, its carrier's kind, and on
// a DoIP row the entity it reaches (its endpoint's host, its ecu_address).
pub struct RowRef {
pub:
	name    string
	doip    bool
	eth     bool // an Ethernet row that carries no diagnostics (SOME/IP)
	host    string
	logical u16
}

// RowTarget is node's diagnostic server on one row: a CAN row's request and response ids (29-bit
// past 0x7FF, the convention can_targets uses), or a DoIP row's own connection, whose entity is
// the node.
pub struct RowTarget {
pub:
	row  int
	doip bool
	req  u32
	rsp  u32
	ext  bool
}

// targets: every row of `rows` that reaches node `n`, in their order — a CAN row named after a bus
// its server is on, at its diagnostic ids (can_server, can_targets' rule), and a DoIP row whose
// entity is the node (node_for by the row's logical address and host, the rule the Diagnostics
// panel describes a DoIP target by) at the node's address where both state one (a loopback row
// excepted: a simulated entity). None for a node whose ecu.toml declares no server, nor on a CAN
// bus where another node answers to its ids.
pub fn (sys &System) targets(n int, rows []RowRef) []RowTarget {
	if n < 0 || n >= sys.nodes.len {
		return []RowTarget{}
	}
	node := sys.nodes[n]
	server := sys.can_server(node)
	// one whose ecu.toml declares no server (the tester's own declaration) is reached nowhere, on
	// either carrier; one whose ecu.toml could not be read keeps what system.toml says
	serves := node.ecu_err != '' || node.desc.server
	mut out := []RowTarget{}
	for i, r in rows {
		if r.doip && serves {
			link := sys.node_for(TargetAddr{
				doip:    true
				logical: r.logical
				host:    r.host
				bus:     r.name
			})
			if link.node == n && (node.address == '' || r.host == '' || loopback(r.host)
				|| same_host(node.address, r.host)) {
				out << RowTarget{
					row:  i
					doip: true
				}
			}
		} else if !r.eth {
			if s := server {
				// and on that bus no other node answers to the same ids (node_for's rule)
				if r.name in s.buses && sys.node_for(TargetAddr{
					req: s.req
					rsp: s.rsp
					bus: r.name
				}).node == n {
					out << RowTarget{
						row: i
						req: s.req
						rsp: s.rsp
						ext: s.req > 0x7FF || s.rsp > 0x7FF
					}
				}
			}
		}
	}
	return out
}

// same_host: two spellings of one endpoint address — numeric addresses by their bytes (`2001:db8::1`
// is `[2001:0db8:0:0:0:0:0:1]`, `::ffff:192.0.2.1` is `::ffff:c000:201`) and an IPv6 zone as written,
// a host name without case.
pub fn same_host(a string, b string) bool {
	return canonical_host(a) == canonical_host(b)
}

fn canonical_host(h string) string {
	s := h.trim('[]')
	addr, zone := if i := s.index('%') { s[..i], s[i..] } else { s, '' }
	if b := ip_bytes(addr) {
		return b.hex() + zone
	}
	return s.to_lower()
}

// ip_bytes is a numeric IPv4 or IPv6 address's bytes (4 or 16), none for anything else.
fn ip_bytes(s string) ?[]u8 {
	if !s.contains(':') {
		parts := s.split('.')
		if parts.len != 4 {
			return none
		}
		mut out := []u8{}
		for p in parts {
			if p.len < 1 || p.len > 3 || !p.bytes().all(it.is_digit()) || p.int() > 255 {
				return none
			}
			out << u8(p.int())
		}
		return out
	}
	halves := s.split('::')
	if halves.len > 2 {
		return none
	}
	head := groups_of(halves[0])?
	tail := if halves.len == 2 { groups_of(halves[1])? } else { []u8{} }
	if (halves.len == 1 && head.len != 16) || head.len + tail.len > 16
		|| (halves.len == 2 && head.len + tail.len == 16) {
		return none
	}
	mut out := head.clone()
	out << []u8{len: 16 - head.len - tail.len}
	out << tail
	return out
}

// groups_of is a run of IPv6 groups' bytes, the last of them a dotted IPv4 address if it is one.
fn groups_of(s string) ?[]u8 {
	if s == '' {
		return []u8{}
	}
	parts := s.split(':')
	mut out := []u8{}
	for i, g in parts {
		if i == parts.len - 1 && g.contains('.') {
			out << ip_bytes(g)?
			continue
		}
		if g.len < 1 || g.len > 4 || !g.bytes().all(it.is_hex_digit()) {
			return none
		}
		v := u16(g.parse_uint(16, 16) or { return none })
		out << u8(v >> 8)
		out << u8(v)
	}
	return out
}

// loopback: `host` is this machine — an entity a project hosts for a node in simulation, whose
// system.toml address is the real ECU's.
fn loopback(host string) bool {
	s := host.trim('[]').all_before('%')
	if s.to_lower() == 'localhost' {
		return true
	}
	b := ip_bytes(s) or { return false }
	return (b.len == 4 && b[0] == 127) || (b.len == 16 && b[..15].all(it == 0) && b[15] == 1)
}

// reach is the one target a tester opens on for node `n`: the one on row `row` when it names one
// (-1 = wherever the node is reached). Refused when the node is reached on no row — saying how it is
// reached, so the project can be given that row — on another row than the one named, or on several
// with none named.
pub fn (sys &System) reach(n int, rows []RowRef, row int) !RowTarget {
	if n < 0 || n >= sys.nodes.len {
		return error('no node ${n}')
	}
	ts := sys.targets(n, rows)
	name := sys.nodes[n].name
	if row >= 0 {
		for t in ts {
			if t.row == row {
				return t
			}
		}
		on := if row < rows.len { rows[row].name } else { 'row ${row}' }
		if ts.len == 0 {
			return error('${name} is not reached on ${on}: ${sys.reached_by(n)}')
		}
		return error('${name} is not reached on ${on}; it is on: ${ts.map(rows[it.row].name).join(', ')}')
	}
	if ts.len == 1 {
		return ts[0]
	}
	if ts.len == 0 {
		return error('${name} is reached on no enabled row of the project: ${sys.reached_by(n)}')
	}
	return error('${name} is reached on ${ts.len} rows (${ts.map(rows[it.row].name).join(', ')}); name the channel to use')
}

// reached_by says how node `n`'s diagnostic server is reached, for a refusal that found no row.
fn (sys &System) reached_by(n int) string {
	node := sys.nodes[n]
	if node.ecu_err == '' && !node.desc.server {
		return 'its ecu.toml (${node.ecu}) declares no diagnostic server ([uds], [isotp] or [doip])'
	}
	mut ways := []string{}
	if s := sys.can_server(node) {
		on := if s.buses.len > 0 {
			'on a CAN row named ${s.buses.join(' or ')}'
		} else {
			'on the CAN bus its [isotp] bus names, which system.toml does not declare'
		}
		ways << 'at 0x${s.req:X}/0x${s.rsp:X} ${on}'
	}
	if node.doip != 0 {
		ways << 'over DoIP on a row whose ecu_address is its logical address 0x${node.doip:04X}'
	}
	if ways.len == 0 {
		return 'neither ${os.file_name(sys.path)} (diag = { req, rsp }) nor its ecu.toml ([isotp] rx_id / tx_id) gives it CAN ids, and it has no DoIP entity (doip = { logical })'
	}
	return 'it is reached ${ways.join(', or ')}'
}

// listed_dids: the DIDs a tester lists for a node — its description's own, then the ISO
// identification DIDs it does not declare (iso_dids).
pub fn (d &EcuDesc) listed_dids() []DidDesc {
	mut out := d.dids.clone()
	out << d.iso_dids()
	return out
}

// listed_did is the listed DID called `name` (a signal's or parameter's name, or ISO's for a
// standard identifier; an identifier is listed_id's): refused for a name no listed DID has (naming
// those there are) or two share.
pub fn (d &EcuDesc) listed_did(name string) !DidDesc {
	listed := d.listed_dids()
	hits := listed.filter(it.name == name)
	if hits.len == 1 {
		return hits[0]
	}
	if hits.len > 1 {
		return error('${hits.len} DIDs are called "${name}" (${hits.map('0x${it.id:04X}').join(', ')}); name it by its identifier')
	}
	names := listed.filter(it.name != '').map('"${it.name}"')
	return error('no DID "${name}" in the description; there are: ${names.join(', ')}')
}

// listed_id is DID `id` as the description lists it, or one of no layout when it does not.
pub fn (d &EcuDesc) listed_id(id u16) DidDesc {
	for x in d.listed_dids() {
		if x.id == id {
			return x
		}
	}
	return DidDesc{
		id:   id
		kind: .unknown
		name: uds.standard_did_name(id)
	}
}

// by_label: a value of this DID is read part by part, each under its label — it has several parts,
// or is a parameter status, whose parts are its parameters; else it is read as its one part's value.
pub fn (x DidDesc) by_label() bool {
	return x.kind == .param_status || x.parts().len > 1
}

// label is how a refusal names the DID: its identifier and its name.
pub fn (x DidDesc) label() string {
	return if x.name == '' { '0x${x.id:04X}' } else { '0x${x.id:04X} ${x.name}' }
}

// write_sessions is the write gate's sessions as 0x10 sub-functions (session_id); refused for one
// no tester here knows.
pub fn (x DidDesc) write_sessions() ![]u8 {
	mut out := []u8{}
	for s in x.write_gate.sessions {
		out << session_id(s) or { return error('written in the "${s}" session, which no tester here knows') }
	}
	return out
}

// plan_write is what a 0x2E of this DID needs first on a connection in state `st` (uds.write_plan
// over the CURRENT description's write gate): `can_unlock` whether the tester can compute the
// node's key.
pub fn (x DidDesc) plan_write(st uds.ConnState, can_unlock bool) uds.WritePlan {
	if !x.write_gate.declared {
		return uds.write_plan(false, 0, [], 0, 0, false)
	}
	sessions := x.write_sessions() or {
		return uds.WritePlan{
			refusal: 'not writable: ${err.msg()}'
		}
	}
	return uds.write_plan(true, st.session, sessions, u8(x.write_gate.level), st.security.unlocked(),
		can_unlock)
}

// write_refusal is why the DID cannot be written whatever a connection establishes (no write
// gate, one that contradicts itself, a session no tester here knows), or none.
pub fn (x DidDesc) write_refusal() ?string {
	plan := x.plan_write(uds.ConnState{}, true)
	if plan.refusal == '' {
		return none
	}
	return plan.refusal
}

// WriteGated is a write not sent because the connection has not established what the DID's write
// gate needs: `session` the session to switch to (0 = the one it is in will do), `level` the
// security level to unlock (0 = none), `state` what the connection has.
pub struct WriteGated {
	Error
pub:
	did     u16
	name    string
	session u8
	level   u8
	state   uds.ConnState
}

pub fn (e WriteGated) msg() string {
	steps := uds.WritePlan{
		session: e.session
		unlock:  e.level
	}.steps()
	what := if e.name == '' { '0x${e.did:04X}' } else { '0x${e.did:04X} ${e.name}' }
	return '0x2E ${what}: not written — this connection has ${e.state.words()}, and its write gate needs it to ${steps.join(', then ')} first'
}

// write_described writes `texts` (one per part, DidDesc.parts) to DID `x` as its description lays
// out and gates it: refused before anything is sent when the description gives the DID no write
// gate (or one that cannot be met), the codec refuses a part, or the connection has not established
// the session and level the gate needs (WriteGated — this connection's own exchanges are what say
// so, Client.state). A script may unlock with a key of its own, so the level is always the
// script's to unlock: nothing is switched or unlocked here.
pub fn write_described(mut cli uds.Client, x DidDesc, texts []string) ! {
	if why := x.write_refusal() {
		return error('0x2E ${x.label()}: ${why}')
	}
	data := x.encode(texts) or { return error('0x2E ${x.label()}: not written — ${err.msg()}') }
	plan := x.plan_write(cli.state, true)
	if plan.session != 0 || plan.unlock != 0 {
		return WriteGated{
			did:     x.id
			name:    x.name
			session: plan.session
			level:   plan.unlock
			state:   cli.state
		}
	}
	cli.write_data_by_identifier(x.id, data)!
}

// read_texts decodes a value read from the DID into one text per part: an answer the description
// cannot lay out (not its declared size) is uds.UndecodableAnswer — the ECU answered, and its answer
// is not what its description says.
pub fn (x DidDesc) read_texts(data []u8) ![]string {
	x.readable(data)!
	return x.texts(data) or {
		return uds.UndecodableAnswer{
			why:  'DID ${x.label()}: ${err.msg()}'
			resp: data.clone()
		}
	}
}

// read_part is part `p` of read_texts(data), decoding that part alone.
pub fn (x DidDesc) read_part(data []u8, p int) !string {
	x.readable(data)!
	if !x.laid_out() {
		if p != 0 {
			return error('DID ${x.label()} has no part ${p} (it has 1)')
		}
		return x.read_texts(data)![0]
	}
	if p < 0 || p >= x.fields.len {
		return error('DID ${x.label()} has no part ${p} (it has ${x.fields.len})')
	}
	mut at := 0
	for f in x.fields[..p] {
		at += f.width()
	}
	w := x.fields[p].width()
	if at + w > data.len {
		return uds.UndecodableAnswer{
			why:  'DID ${x.label()}: ${data.len} byte(s), too few for its fields'
			resp: data.clone()
		}
	}
	return field_value(x.fields[p], data[at..at + w])
}

// readable refuses a value that is not what the description says: not its declared size, or a text
// DID that is not printable ASCII (as encode writes it; its NUL padding apart).
fn (x DidDesc) readable(data []u8) ! {
	if x.size >= 0 && data.len != x.size {
		return uds.UndecodableAnswer{
			why:  'DID ${x.label()}: ${data.len} byte(s), the description says ${x.size}'
			resp: data.clone()
		}
	}
	if x.kind == .ascii {
		mut n := data.len
		for n > 0 && data[n - 1] == 0 {
			n--
		}
		for i, b in data[..n] {
			if b < 0x20 || b > 0x7E {
				return uds.UndecodableAnswer{
					why:  'DID ${x.label()}: byte ${i + 1} (0x${b:02X}) is not printable ASCII'
					resp: data.clone()
				}
			}
		}
	}
}
