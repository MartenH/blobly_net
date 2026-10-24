module script

import strconv
import blobly.lua
import blobly.sysview
import blobly.udsconn

// nodes.v — uds.nodes and uds.node: a connection by the node's name in the system model
// (Env.sys, sysview.System.reach), its DIDs listed, read and written by name through the node's
// layout (sysview's codec and write_described), its DTCs named by its faults — the rules the C
// ABI's bb_node_* answer by. A DID argument is its identifier when a number
// (sysview.EcuDesc.listed_id), else its name (listed_did).

fn (mut env Env) register_nodes() {
	env.st.register('__uds_nodes', l_uds_nodes)
	env.st.register('__uds_node', l_uds_node)
	env.st.register('__node_dids', l_node_dids)
	env.st.register('__node_did', l_node_did)
	env.st.register('__node_faults', l_node_faults)
	env.st.register('__node_read', l_node_read)
	env.st.register('__node_write', l_node_write)
	env.st.register('__node_on', l_node_on)
}

fn l_uds_nodes(l lua.State) i32 {
	env := env_of(l)
	l.new_table()
	for i, n in env.sys.nodes {
		l.push_str(n.name)
		l.set_index(i + 1)
	}
	return 1
}

// l_uds_node opens a connection on node argument 1 — on channel argument 2 when it is not nil — and
// answers its handle, the node's index and the channel's name.
fn l_uds_node(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	n := env.sys.node_named(name) or { return l.fail('uds.node: ${err.msg()}') }
	mut row := -1
	if !l.arg_is_nil(2) {
		row = env.find_chan(l.arg_str(2)) or { return l.fail('uds.node("${name}"): ${err.msg()}') }
	}
	rows := env.chans.map(udsconn.row_ref(it.name, it.iface, it.carrier, it.hosts))
	t := env.sys.reach(n, rows, row) or { return l.fail('uds.node: ${err.msg()}') }
	ask := if t.doip {
		udsconn.Ask{
			what: 'uds.node'
		}
	} else {
		udsconn.Ask{
			what:   'uds.node'
			has_tx: true
			tx:     t.req
			has_rx: true
			rx:     t.rsp
		}
	}
	channel := env.chans[t.row].name
	h := env.open_uds(channel, ask, false) or {
		if err is Expired {
			return timeout_at(l)
		}
		return l.fail(err.msg())
	}
	// a reused DoIP connection retargeted elsewhere addresses another ECU, not this node
	env.on_node(&env.conns[h], env.sys.nodes[n].name) or { return l.fail(err.msg()) }
	env.seed_sizes(h, n)
	l.push_int(h)
	l.push_int(n)
	l.push_str(channel)
	return 3
}

// node_arg is the node argument `i` names (an index uds.node answered).
fn node_arg(l lua.State, i int) !sysview.SysNode {
	env := env_of(l)
	n := l.arg_int_exact(i) or { -1 }
	if n < 0 || n >= env.sys.nodes.len {
		return error('bad node ${n}')
	}
	return env.sys.nodes[int(n)]
}

// did_arg is the DID argument `i` names among node's: an identifier when argument i + 1 says the
// prelude was given a number (a numeric string is a name all the same), else a name.
fn did_arg(l lua.State, node sysview.SysNode, i int) !sysview.DidDesc {
	if l.arg_bool(i + 1) {
		id := l.arg_int_exact(i) or { return error('DID ${l.arg_num(i)} is not an identifier') }
		if id < 0 || id > 0xFFFF {
			return error('DID ${id} is not a 16-bit identifier')
		}
		return node.desc.listed_id(u16(id))
	}
	return node.desc.listed_did(l.arg_str(i))
}

// push_did pushes one DID as a table: id, name, kind, size (nil when not known), parts (each with
// label, kind — "int", "bool", "text", "bytes" — and hint), and read / write, each its gate's
// {sessions, level} or nil where none is declared (write: not writable).
fn push_did(l lua.State, x sysview.DidDesc) {
	l.new_table()
	l.set_int('id', i64(x.id))
	l.set_str('name', x.name)
	l.set_str('kind', x.kind.str())
	l.set_bool('by_label', x.by_label())
	if x.size >= 0 {
		l.set_int('size', x.size)
	}
	l.new_table()
	for i, p in x.parts() {
		l.new_table()
		l.set_str('label', p.label)
		l.set_str('kind', part_kind(p.kind))
		l.set_str('hint', p.hint)
		l.set_index(i + 1)
	}
	l.set_field('parts')
	for key, g in {
		'read':  x.read_gate
		'write': x.write_gate
	} {
		if g.declared {
			l.new_table()
			l.new_table()
			for i, s in g.sessions {
				l.push_str(s)
				l.set_index(i + 1)
			}
			l.set_field('sessions')
			l.set_int('level', g.level)
			l.set_field(key)
		}
	}
}

fn part_kind(k sysview.PartKind) string {
	return match k {
		.integer { 'int' }
		.boolean { 'bool' }
		.text { 'text' }
		.bytes { 'bytes' }
	}
}

fn l_node_dids(l lua.State) i32 {
	node := node_arg(l, 1) or { return l.fail(err.msg()) }
	l.new_table()
	for i, x in node.desc.listed_dids() {
		push_did(l, x)
		l.set_index(i + 1)
	}
	return 1
}

fn l_node_did(l lua.State) i32 {
	node := node_arg(l, 1) or { return l.fail(err.msg()) }
	x := did_arg(l, node, 2) or { return l.fail('${node.name}: ${err.msg()}') }
	push_did(l, x)
	return 1
}

// l_node_faults: the node's fault names by DTC code.
fn l_node_faults(l lua.State) i32 {
	node := node_arg(l, 1) or { return l.fail(err.msg()) }
	l.new_table()
	// the first of a DTC declared twice names it, as EcuDesc.fault does: set last
	for f in node.desc.faults.reverse() {
		l.push_str(f.name)
		l.set_numkey(f64(f.dtc))
	}
	return 1
}

// l_node_read (handle, node, did, by_id): 0x22 decoded by the layout — one field's value (an integer, a
// boolean), a text, bytes, or a table by label for several fields and for a parameter status
// (whose fields are its parameters).
fn l_node_read(l lua.State) i32 {
	mut env := env_of(l)
	node := node_arg(l, 2) or { return l.fail(err.msg()) }
	x := did_arg(l, node, 3) or { return l.fail('${node.name}: ${err.msg()}') }
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	env.on_node(c, node.name) or { return l.fail(err.msg()) }
	data := c.cli.read_data_by_identifier(x.id) or { return l.fail(err.msg()) }
	texts := x.read_texts(data) or { return l.fail(err.msg()) }
	parts := x.parts()
	for i, p in parts {
		if p.kind == .integer && lua_int(texts[i]) == none {
			return l.fail('DID ${x.label()}: ${p.label} is ${texts[i]}, past what a Lua integer holds; read_did gives its bytes')
		}
	}
	if !x.by_label() {
		push_part(l, parts[0], texts[0])
		return 1
	}
	l.new_table()
	for i, p in parts {
		push_part(l, p, texts[i])
		l.set_field(p.label)
	}
	return 1
}

// push_part pushes one part's text as the Lua value it is: an integer (lua_int's; the caller
// refuses one past it), a boolean, a string, or bytes.
fn push_part(l lua.State, p sysview.Part, text string) {
	match p.kind {
		.integer {
			l.push_int(lua_int(text) or { 0 })
		}
		.boolean {
			l.push_bool(text == 'true')
		}
		.text {
			l.push_str(text)
		}
		.bytes {
			l.push_bytes(sysview.parse_hex(text) or { []u8{} })
		}
	}
}

// l_node_write (handle, node, did, by_id, text...): 0x2E of the texts of every part (the prelude
// spells a value as them), as sysview.write_described writes it.
fn l_node_write(l lua.State) i32 {
	mut env := env_of(l)
	node := node_arg(l, 2) or { return l.fail(err.msg()) }
	x := did_arg(l, node, 3) or { return l.fail('${node.name}: ${err.msg()}') }
	mut texts := []string{}
	for i in 5 .. l.nargs() + 1 {
		texts << l.arg_str(i)
	}
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	env.on_node(c, node.name) or { return l.fail(err.msg()) }
	sysview.write_described(mut c.cli, x, texts) or { return l.fail(err.msg()) }
	return 0
}

// lua_int is an integer part's text as a Lua integer (64-bit signed), none past it: a u64's upper
// half has no exact Lua value.
fn lua_int(text string) ?i64 {
	v := strconv.parse_int(text, 10, 64) or { return none }
	return if '${v}' == text { v } else { none }
}

// l_node_on (handle, node): raises unless the connection addresses the node (on_node).
fn l_node_on(l lua.State) i32 {
	mut env := env_of(l)
	node := node_arg(l, 2) or { return l.fail(err.msg()) }
	c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	env.on_node(c, node.name) or { return l.fail(err.msg()) }
	env.seed_sizes(int(l.arg_int(1)), int(l.arg_int(2)))
	return 0
}

// seed_sizes puts node n's description sizes on connection h: a snapshot (0x19 04) need not read a
// DID to learn one. Learned, not stated (set_did_size), so a retarget to another ECU forgets them as
// it forgets what was read, and they are put back while the connection addresses the node again; a
// size stated or read on the connection wins.
fn (mut env Env) seed_sizes(h int, n int) {
	for id, size in env.sys.nodes[n].desc.did_sizes() {
		if id !in env.conns[h].cli.did_lens {
			env.conns[h].cli.did_lens[id] = size
		}
	}
}

// on_node refuses a DoIP connection retargeted away from its channel's entity (a uds.open one that
// uds.node took up): bytes laid out by the node's description would go to another ECU.
fn (env &Env) on_node(c &UdsConn, node string) ! {
	ci := env.find_chan(c.chan) or { return }
	car := env.chans[ci].carrier
	if car.doip && c.ch.rx_id != u32(car.ecu) {
		return error('${node}: the connection on ${c.chan} is retargeted to 0x${c.ch.rx_id:04X}; retarget it back first')
	}
}
