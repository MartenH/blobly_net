// nodes.v — bb.h's "system model" block: the run's system.toml and its nodes' descriptions
// (headless.Run.sys, what the simulated servers answer by), a node reached by name
// (sysview.System.reach), its DIDs read and written through their layout (sysview's codec and
// write_described) and its routine controls run through theirs (run_described), so a host names a
// node, a DID and a routine and never lays out bytes of its own.
module main

import blobly.headless
import blobly.project
import blobly.sysview
import blobly.uds
import blobly.udsconn

const bb_err_gated = i32(C.BB_ERR_GATED)

__global (
	// the started run's system model and each node's listed DIDs (listed once, at the start), under
	// bb_mu beside bb_dbs; a stop replaces them, never writes into them, so a call holding a copy
	// reads what it took
	bb_sys       sysview.System
	bb_sys_dids  [][]sysview.DidDesc
	bb_sys_parts [][][]sysview.Part // each listed DID's parts
	// each routine control's option parts and answer parts, by node and routine
	bb_sys_rparts [][][][]sysview.Part
)

// sys_publish / sys_retire keep bb_sys the run's; the caller holds bb_mu.
fn sys_publish(r &headless.Run) {
	bb_sys = r.sys
	bb_sys_dids = r.sys.nodes.map(it.desc.listed_dids())
	bb_sys_parts = bb_sys_dids.map(it.map(it.parts()))
	bb_sys_rparts = r.sys.nodes.map(it.desc.routines.map([it.option_parts(), it.answer_parts()]))
}

fn sys_retire() {
	bb_sys = sysview.System{}
	bb_sys_dids = [][]sysview.DidDesc{}
	bb_sys_parts = [][][]sysview.Part{}
	bb_sys_rparts = [][][][]sysview.Part{}
}

// SysView is ONE read of the run's model: every call answers from one, so a stop and a start on
// another thread cannot hand it a node of one run and a DID of the next.
struct SysView {
	sys  sysview.System
	dids  [][]sysview.DidDesc
	parts [][][]sysview.Part
	rparts [][][][]sysview.Part
	rows  []project.Channel // the run's rows, as the run has them
	run  u64               // bb_run_gen
}

// run_sys is the run's model now, or BB_ERR_STATE's refusal.
fn run_sys() !SysView {
	bb_mu.lock()
	live := bb_dbs_live
	v := SysView{
		sys:  bb_sys
		dids:  bb_sys_dids
		parts: bb_sys_parts
		rparts: bb_sys_rparts
		rows: bb_run_rows
		run:  bb_run_gen
	}
	bb_mu.unlock()
	if !live {
		return error_with_code("not started: the system model is the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	return v
}

// refs are the run's rows as the system model reaches a node on them.
fn (v SysView) refs() []sysview.RowRef {
	return v.rows.map(udsconn.row_ref(it.name, it.iface_with_bitrate(), udsconn.carrier_of(it),
		it.hosts_doip_entity()))
}

fn (v SysView) node(n i32) !sysview.SysNode {
	if n < 0 || int(n) >= v.sys.nodes.len {
		return error('no node ${n} (the system has ${v.sys.nodes.len})')
	}
	return v.sys.nodes[int(n)]
}

// did is DID d of the DIDs node n lists (sysview.EcuDesc.listed_dids).
fn (v SysView) did(n i32, d i32) !sysview.DidDesc {
	node := v.node(n)!
	dids := v.dids[int(n)]
	if d < 0 || int(d) >= dids.len {
		return error('${node.name} has no DID ${d} (it lists ${dids.len})')
	}
	return dids[int(d)]
}

fn node_did(n i32, d i32) !sysview.DidDesc {
	v := run_sys()!
	return v.did(n, d)
}

fn did_part(n i32, d i32, p i32) !sysview.Part {
	v := run_sys()!
	x := v.did(n, d)!
	ps := v.parts[int(n)][int(d)]
	if p < 0 || int(p) >= ps.len {
		return error('DID ${x.label()} has no part ${p} (it has ${ps.len})')
	}
	return ps[int(p)]
}

fn put_target(t sysview.RowTarget, out &C.bb_reach) {
	unsafe {
		out.row = i32(t.row)
		out.doip = u8(t.doip)
		out.ext = u8(t.ext)
		out.tx = t.req
		out.rx = t.rsp
	}
}

@[export: 'bb_system_path']
pub fn bb_system_path(buf &char, cap i32) i32 {
	v := run_sys() or { return refused(err) }
	return put(v.sys.path, buf, cap)
}

@[export: 'bb_node_count']
pub fn bb_node_count() i32 {
	v := run_sys() or { return refused(err) }
	ok()
	return i32(v.sys.nodes.len)
}

@[export: 'bb_node_info']
pub fn bb_node_info(n i32, out &C.bb_node) i32 {
	if isnil(out) {
		return fail(bb_err, 'node_info: nowhere to put it')
	}
	v := run_sys() or { return refused(err) }
	node := v.node(n) or { return refused(err) }
	unsafe {
		out.dids = i32(v.dids[int(n)].len)
		out.faults = i32(node.desc.faults.len)
		out.targets = i32(v.sys.targets(int(n), v.refs()).len)
		out.described = u8(node.ecu_err == '')
		out.server = u8(node.ecu_err == '' && node.desc.server)
		out.reference_key = u8(node.desc.security_key == 'reference')
		out.authenticates = u8(node.desc.authenticates())
	}
	return ok()
}

@[export: 'bb_node_name']
pub fn bb_node_name(n i32, buf &char, cap i32) i32 {
	v := run_sys() or { return refused(err) }
	node := v.node(n) or { return refused(err) }
	return put(node.name, buf, cap)
}

@[export: 'bb_node_problem']
pub fn bb_node_problem(n i32, buf &char, cap i32) i32 {
	v := run_sys() or { return refused(err) }
	node := v.node(n) or { return refused(err) }
	return put(node.ecu_err, buf, cap)
}

@[export: 'bb_node_target']
pub fn bb_node_target(n i32, k i32, out &C.bb_reach) i32 {
	if isnil(out) {
		return fail(bb_err, 'node_target: nowhere to put it')
	}
	v := run_sys() or { return refused(err) }
	node := v.node(n) or { return refused(err) }
	ts := v.sys.targets(int(n), v.refs())
	if k < 0 || int(k) >= ts.len {
		return fail(bb_err, '${node.name} has no target ${k} (it is reached on ${ts.len} rows)')
	}
	put_target(ts[int(k)], out)
	return ok()
}

@[export: 'bb_node_reach']
pub fn bb_node_reach(n i32, r i32, out &C.bb_reach) i32 {
	if isnil(out) {
		return fail(bb_err, 'node_reach: nowhere to put it')
	}
	v := run_sys() or { return refused(err) }
	v.node(n) or { return refused(err) }
	if r < -1 || int(r) >= v.rows.len {
		return fail(bb_err, 'no channel ${r}')
	}
	t := v.sys.reach(int(n), v.refs(), int(r)) or { return fail(bb_err, err.msg()) }
	put_target(t, out)
	return ok()
}

@[export: 'bb_node_fault']
pub fn bb_node_fault(n i32, k i32, dtc &u32, buf &char, cap i32) i32 {
	v := run_sys() or { return refused(err) }
	node := v.node(n) or { return refused(err) }
	fs := node.desc.faults
	if k < 0 || int(k) >= fs.len {
		return fail(bb_err, '${node.name} has no fault ${k} (it declares ${fs.len})')
	}
	if !isnil(dtc) {
		unsafe {
			*dtc = fs[int(k)].dtc
		}
	}
	return put(fs[int(k)].name, buf, cap)
}

@[export: 'bb_did_info']
pub fn bb_did_info(n i32, d i32, out &C.bb_did) i32 {
	if isnil(out) {
		return fail(bb_err, 'did_info: nowhere to put it')
	}
	v := run_sys() or { return refused(err) }
	x := v.did(n, d) or { return refused(err) }
	unsafe {
		out.id = x.id
		out.kind = did_kind_code(x.kind)
		out.size = i32(x.size)
		out.parts = i32(v.parts[int(n)][int(d)].len)
		out.by_label = u8(x.by_label())
		out.read_gated = u8(x.read_gate.declared)
		out.read_sessions = i32(x.read_gate.sessions.len)
		out.read_level = i32(x.read_gate.level)
		out.writable = u8(x.write_gate.declared)
		out.write_sessions = i32(x.write_gate.sessions.len)
		out.write_level = i32(x.write_gate.level)
	}
	return ok()
}

// did_kind_code is a DID's kind as bb.h numbers it, mapped by name so a reordered DidKind cannot
// shift what a host reads.
fn did_kind_code(k sysview.DidKind) i32 {
	return match k {
		.ascii { i32(C.BB_DID_ASCII) }
		.bytes { i32(C.BB_DID_BYTES) }
		.signal { i32(C.BB_DID_SIGNAL) }
		.param { i32(C.BB_DID_PARAM) }
		.param_status { i32(C.BB_DID_PARAM_STATUS) }
		.tx_saturations { i32(C.BB_DID_TX_SATURATIONS) }
		.unknown { i32(C.BB_DID_UNKNOWN) }
		.fields { i32(C.BB_DID_FIELDS) }
		.text { i32(C.BB_DID_TEXT) }
		.data { i32(C.BB_DID_DATA) }
	}
}

@[export: 'bb_did_name']
pub fn bb_did_name(n i32, d i32, buf &char, cap i32) i32 {
	x := node_did(n, d) or { return refused(err) }
	return put(x.name, buf, cap)
}

@[export: 'bb_did_session']
pub fn bb_did_session(n i32, d i32, write i32, k i32, buf &char, cap i32) i32 {
	x := node_did(n, d) or { return refused(err) }
	sessions := if write != 0 { x.write_gate.sessions } else { x.read_gate.sessions }
	if k < 0 || int(k) >= sessions.len {
		return fail(bb_err, "DID ${x.label()}'s ${if write != 0 { 'write' } else { 'read' }} gate has no session ${k} (it names ${sessions.len})")
	}
	return put(sessions[int(k)], buf, cap)
}

@[export: 'bb_did_part']
pub fn bb_did_part(n i32, d i32, p i32, kind &i32, buf &char, cap i32) i32 {
	part := did_part(n, d, p) or { return refused(err) }
	if !isnil(kind) {
		unsafe {
			*kind = part_kind_code(part.kind)
		}
	}
	return put(part.label, buf, cap)
}

// part_kind_code is a part's kind as bb.h numbers it, mapped by name.
fn part_kind_code(k sysview.PartKind) i32 {
	return match k {
		.integer { i32(C.BB_PART_INTEGER) }
		.boolean { i32(C.BB_PART_BOOLEAN) }
		.text { i32(C.BB_PART_TEXT) }
		.bytes { i32(C.BB_PART_BYTES) }
		.number { i32(C.BB_PART_NUMBER) }
		.label { i32(C.BB_PART_LABEL) }
	}
}

@[export: 'bb_did_hint']
pub fn bb_did_hint(n i32, d i32, p i32, buf &char, cap i32) i32 {
	part := did_part(n, d, p) or { return refused(err) }
	return put(part.hint, buf, cap)
}

@[export: 'bb_did_text']
pub fn bb_did_text(n i32, d i32, data &u8, len i32, p i32, buf &char, cap i32) i32 {
	x := node_did(n, d) or { return refused(err) }
	value := bytes_in('did_text', data, len) or { return fail(bb_err, err.msg()) }
	if p == -1 {
		// the value checked alone: what a layout of no parts answers
		x.read_texts(value) or { return uds_failed(err) }
		return put('', buf, cap)
	}
	text := x.read_part(value, int(p)) or { return uds_failed(err) }
	return put(text, buf, cap)
}

@[export: 'bb_uds_write_described']
pub fn bb_uds_write_described(u i32, n i32, d i32, texts &&char, k i32, needs &C.bb_write_needs) i32 {
	parts := texts_in('write_described', texts, k) or { return fail(bb_err, err.msg()) }
	v := run_sys() or { return refused(err) }
	x := v.did(n, d) or { return refused(err) }
	if why := x.write_refusal() {
		return fail(bb_err, '0x2E ${x.label()}: ${why}')
	}
	reach := v.reaches(n)
	return exchange(u, fn [x, parts, reach, needs] (mut hd UdsHandle) !i32 {
		reach.check(hd)!
		// a text the layout refuses is refused before a lost connection is opened again
		x.encode(parts) or { return error('0x2E ${x.label()}: not written — ${err.msg()}') }
		mut cl := hd.cli()!
		reach.on_node(hd)!
		sysview.write_described(mut cl, x, parts) or {
			if err is sysview.WriteGated {
				put_needs(err, needs)
				return error_with_code(err.msg(), int(bb_err_gated))
			}
			return err
		}
		return ok()
	})
}

// texts_in is the `k` texts a host passed.
fn texts_in(what string, texts &&char, k i32) ![]string {
	if k < 0 || (k > 0 && isnil(texts)) {
		return error('${what}: ${k} texts, and no array of them')
	}
	mut parts := []string{}
	for i in 0 .. int(k) {
		t := unsafe { texts[i] }
		if isnil(t) {
			return error('${what}: text ${i} is NULL')
		}
		parts << unsafe { cstring_to_vstring(t) }
	}
	return parts
}

fn put_needs(g sysview.WriteGated, needs &C.bb_write_needs) {
	if !isnil(needs) {
		unsafe {
			needs.session = g.session
			needs.level = g.level
		}
	}
}

// Reach is where node `node` is in run `run`: the bytes its description lays out go to it alone.
struct Reach {
	node string
	run  u64
	ts   []sysview.RowTarget
	// the logical address each row's DoIP entity has: a handle retargeted elsewhere reaches another ECU
	ecus []u32
}

fn (v SysView) reaches(n i32) Reach {
	return Reach{
		node: v.sys.nodes[int(n)].name
		run:  v.run
		ts:   v.sys.targets(int(n), v.refs())
		ecus: v.rows.map(u32(udsconn.carrier_of(it).ecu))
	}
}

// check refuses a handle that is not of this run on one of the node's targets.
fn (r Reach) check(hd &UdsHandle) ! {
	if hd.run != r.run || !r.ts.any(it.row == int(hd.row) && it.doip == hd.doip
		&& (it.doip || (it.req == hd.conn.ch.tx_id && it.rsp == hd.rx && it.ext == hd.ext))) {
		return error("UDS handle on ${hd.row_name} does not reach ${r.node} in this run; open it with ${r.node}'s target (bb_node_reach)")
	}
}

// on_node refuses a DoIP handle retargeted away from its row's entity.
fn (r Reach) on_node(hd &UdsHandle) ! {
	if hd.doip && hd.conn.ch.rx_id != r.ecus[int(hd.row)] {
		return error('UDS handle on ${hd.row_name} is retargeted to 0x${hd.conn.ch.rx_id:04X}, not ${r.node}; retarget it back first')
	}
}

// routine is routine control k of node n.
fn (v SysView) routine(n i32, k i32) !sysview.RoutineDesc {
	node := v.node(n)!
	rs := node.desc.routines
	if k < 0 || int(k) >= rs.len {
		return error('${node.name} has no routine ${k} (it describes ${rs.len})')
	}
	return rs[int(k)]
}

fn node_routine(n i32, k i32) !sysview.RoutineDesc {
	v := run_sys()!
	return v.routine(n, k)
}

// routine_parts are routine control k's option parts (answer 0) or answer parts, as published.
fn (v SysView) routine_parts(n i32, k i32, answer i32) ![]sysview.Part {
	v.routine(n, k)!
	return v.rparts[int(n)][int(k)][if answer != 0 { 1 } else { 0 }]
}

// routine_part is part p of routine control k's option record (answer 0) or answer record.
fn routine_part(n i32, k i32, answer i32, p i32) !sysview.Part {
	v := run_sys()!
	r := v.routine(n, k)!
	ps := v.routine_parts(n, k, answer)!
	if p < 0 || int(p) >= ps.len {
		return error('routine ${r.label()}: its ${if answer != 0 { 'answer' } else { 'option' }} has no part ${p} (it has ${ps.len})')
	}
	return ps[int(p)]
}

@[export: 'bb_routine_count']
pub fn bb_routine_count(n i32) i32 {
	v := run_sys() or { return refused(err) }
	node := v.node(n) or { return refused(err) }
	ok()
	return i32(node.desc.routines.len)
}

@[export: 'bb_routine_info']
pub fn bb_routine_info(n i32, k i32, out &C.bb_routine) i32 {
	if isnil(out) {
		return fail(bb_err, 'routine_info: nowhere to put it')
	}
	v := run_sys() or { return refused(err) }
	r := v.routine(n, k) or { return refused(err) }
	unsafe {
		out.id = r.id
		out.control = r.control
		out.gated = u8(r.gate.declared)
		out.sessions = i32(r.gate.sessions.len)
		out.level = i32(r.gate.level)
		out.option_size = i32(r.option.size)
		out.option_parts = i32(v.rparts[int(n)][int(k)][0].len)
		out.answer_size = i32(r.answer.size)
		out.answer_parts = i32(v.rparts[int(n)][int(k)][1].len)
	}
	return ok()
}

@[export: 'bb_routine_name']
pub fn bb_routine_name(n i32, k i32, buf &char, cap i32) i32 {
	r := node_routine(n, k) or { return refused(err) }
	return put(r.name, buf, cap)
}

@[export: 'bb_routine_session']
pub fn bb_routine_session(n i32, k i32, j i32, buf &char, cap i32) i32 {
	r := node_routine(n, k) or { return refused(err) }
	if j < 0 || int(j) >= r.gate.sessions.len {
		return fail(bb_err, "routine ${r.label()}'s gate has no session ${j} (it names ${r.gate.sessions.len})")
	}
	return put(r.gate.sessions[int(j)], buf, cap)
}

@[export: 'bb_routine_part']
pub fn bb_routine_part(n i32, k i32, answer i32, p i32, kind &i32, buf &char, cap i32) i32 {
	part := routine_part(n, k, answer, p) or { return refused(err) }
	if !isnil(kind) {
		unsafe {
			*kind = part_kind_code(part.kind)
		}
	}
	return put(part.label, buf, cap)
}

@[export: 'bb_routine_hint']
pub fn bb_routine_hint(n i32, k i32, answer i32, p i32, buf &char, cap i32) i32 {
	part := routine_part(n, k, answer, p) or { return refused(err) }
	return put(part.hint, buf, cap)
}

@[export: 'bb_routine_text']
pub fn bb_routine_text(n i32, k i32, data &u8, len i32, p i32, buf &char, cap i32) i32 {
	r := node_routine(n, k) or { return refused(err) }
	value := bytes_in('routine_text', data, len) or { return fail(bb_err, err.msg()) }
	if p == -1 {
		// the answer checked whole
		r.answer_texts(value) or { return uds_failed(err) }
		return put('', buf, cap)
	}
	text := r.answer_part(value, int(p)) or { return uds_failed(err) }
	return put(text, buf, cap)
}

@[export: 'bb_uds_routine_described']
pub fn bb_uds_routine_described(u i32, n i32, k i32, texts &&char, cnt i32, needs &C.bb_write_needs, buf &u8, cap i32) i32 {
	parts := texts_in('routine_described', texts, cnt) or { return fail(bb_err, err.msg()) }
	v := run_sys() or { return refused(err) }
	r := v.routine(n, k) or { return refused(err) }
	// a gate no connection can meet is refused before the handle is asked
	refusal := r.plan(uds.ConnState{}, true).refusal
	if refusal != '' {
		return fail(bb_err, '${r.label()}: ${refusal}')
	}
	reach := v.reaches(n)
	return exchange(u, fn [r, parts, reach, needs, buf, cap] (mut hd UdsHandle) !i32 {
		reach.check(hd)!
		// a text the layout refuses is refused before a lost connection is opened again
		r.encode_option(parts) or { return error('${r.label()}: not sent — ${err.msg()}') }
		out_buf(buf, cap)!
		mut cl := hd.cli()!
		reach.on_node(hd)!
		answer := sysview.run_described(mut cl, r, parts) or {
			if err is sysview.WriteGated {
				put_needs(err, needs)
				return error_with_code(err.msg(), int(bb_err_gated))
			}
			return err
		}
		return hd.answer(answer, buf, cap)
	})
}
