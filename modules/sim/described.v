// described.v — a simulated ECU's diagnostic server taken from blobly_emb's description of that
// node (its ecu.toml, read by sysview), so it answers as that ECU does: its DIDs at their real
// sizes and values, their read and write gates, its `[uds] services` table, 0x27 at its levels
// with its key, its parameters within their ranges, its declared DTCs. Shared by the GUI and the
// headless runner, like the rest of this module's server building.
//
// THE LINK is the one the Diagnostics panel already uses to show a description for a target
// (sysview.System.node_for): the node addressed as the simulated server is — a CAN server's
// request and response ids (the bus its channel is named after settling a tie), a DoIP entity's
// logical address. Failing that, the one node bearing the simulated node's name. Without a link
// a server keeps what the project gives it, today's content.
module sim

import math
import os
import project
import sync
import sysview
import transport
import uds

// Described is a simulated server built from a description, or why there is none.
pub struct Described {
pub:
	ok     bool
	node   string // the described node's name
	notes  []string
	server uds.Server
}

// describe builds the server for a simulated node reached as `t`, named `name` (the project's
// node name, '' for a channel's built-in server), whose project `uds:` block is `cfg` (none for
// the built-in server). `remote` = served over DoIP. A described node's DIDs and DTCs come from
// the description; the block's own `dids:` replace a value (or add an open, read-only DID) and
// its `dtcs:` set a status, so a project can still seed a fault.
pub fn describe(sys &sysview.System, t sysview.TargetAddr, name string, cfg ?project.UdsCfg, remote bool) Described {
	idx := link_node(sys, t, name) or {
		if sys.describes(t) {
			// several nodes are addressed so and the bus does not settle it: none is chosen, and
			// no name may choose one either — a description of the wrong ECU is worse than none
			return Described{
				notes: ['${if name != '' { name } else { 'the built-in server' }}: ${sys.node_for(t).why}; served from the project']
			}
		}
		return Described{}
	}
	n := sys.nodes[idx]
	if n.ecu_err != '' {
		return Described{
			node:  n.name
			notes: ['${n.name}: its ecu.toml could not be read (${n.ecu_err}); served from the project']
		}
	}
	if !n.desc.server {
		return Described{
			node:  n.name
			notes: ['${n.name} declares no diagnostic server; served from the project']
		}
	}
	mut spec, base_notes := n.desc.server_spec(remote)
	// what one answer may carry: one ISO-TP transfer, or a DoIP diagnostic message
	max_did := if remote { max_did_bytes_doip } else { max_did_bytes }
	spec.max_response = max_did + 3
	mut notes := n.desc.errs.map('${it} (in its ecu.toml)')
	notes << base_notes
	mut srv := uds.server_from(spec)
	if c := cfg {
		for d in c.dids {
			if d.id <= 0xFFFF && d.value_len() <= max_did { // past that, validate_uds said so
				value := if d.bytes.len > 0 { d.bytes.clone() } else { d.text.bytes() }
				declared := spec.dids.filter(it.id == u16(d.id))
				if declared.len > 0 && declared[0].writable && declared[0].data.len != value.len {
					notes << 'DID 0x${d.id:04X}: the project gives it ${value.len} bytes where the description declares ${declared[0].data.len}; it reads the project\'s value and 0x2E takes ${declared[0].data.len}'
				}
				srv.put_did(u16(d.id), value)
			}
		}
		if c.dtcs.len > 0 && spec.faults.len == 0 {
			notes << 'it has no fault memory (no [[fault]]), so 0x19 is not served and the `dtcs:` of the project are not'
		} else {
			max_dtc := if remote { max_dtcs_doip } else { max_dtcs }
			for x in c.dtcs {
				if x.code <= 0xFFFFFF && x.status <= 0xFF && srv.dtcs.len < max_dtc {
					srv.set_dtc_status(x.code, u8(x.status))
				}
			}
		}
	}
	return Described{
		ok:     true
		node:   n.name
		notes:  notes.map('${n.name}: ${it}')
		server: srv
	}
}

// describe_uds_nodes gives every server a description covers its described content, the live
// DIDs reading the simulation of the node on `iface`. `chans` is each peer's channel name (the
// bus a tie between two nodes of one address is settled by), by the peer's index as UdsNode.src.
// Returns what to tell the operator: which node each server answers as, and every note.
pub fn describe_uds_nodes(sys &sysview.System, mut nodes []UdsNode, peers []project.NodeCfg, chans []string, iface string) []string {
	mut out := []string{}
	for mut u in nodes {
		cfg := if u.src >= 0 && u.src < peers.len { peers[u.src].uds } else { none }
		d := describe(sys, sysview.TargetAddr{
			req: u.rx
			rsp: u.tx
			bus: chans[u.src] or { '' }
		}, u.name, cfg, false)
		if d.ok {
			u.server = d.server
			u.described = d.node
			wire_live(mut u.server, iface, chans[u.src] or { '' }, u.name)
			out << '${u.name}: diagnostics as described for ${d.node} (${os.file_name(sys.path)})'
			if u.src >= 0 && u.src < peers.len {
				out << live_gaps(u.server, u.name, [peers[u.src]]).map('${u.name}: ${it}')
			}
		}
		out << d.notes
	}
	return out
}

// describe_default is a channel's built-in server (on `rx`/`tx`): the node a description
// addresses so, or uds.default_server().
// Its live DIDs read the simulation of the node of the described node's name on the channel.
pub fn describe_default(sys &sysview.System, chan_name string, iface string, rx u32, tx u32) Described {
	mut d := describe(sys, sysview.TargetAddr{ req: rx, rsp: tx, bus: chan_name }, '', none,
		false)
	if d.ok {
		mut srv := d.server
		wire_live(mut srv, iface, chan_name, d.node)
		mut notes := ['${chan_name}: the built-in server answers as described for ${d.node} (${os.file_name(sys.path)})']
		notes << d.notes
		return Described{
			...d
			notes:  notes
			server: srv
		}
	}
	return Described{
		notes:  d.notes
		server: uds.default_server()
	}
}

// link_node is the described node a simulated server is: by addressing, else — when no node is
// addressed so at all — by name.
fn link_node(sys &sysview.System, t sysview.TargetAddr, name string) ?int {
	l := sys.node_for(t)
	if l.node >= 0 {
		return l.node
	}
	if name == '' || sys.describes(t) {
		return none
	}
	named := []int{len: sys.nodes.len, init: index}.filter(sys.nodes[it].name == name)
	return if named.len == 1 { named[0] } else { none }
}

// live is the simulated signal values a described server's live DIDs read: the generators'
// current values, published by the simulation loop of the wire (publish_live) for the signals
// some described server asked for (want_live). Process-wide like the fault table, and for the
// same reason: the simulation and the diagnostic server run on different threads, reached
// through different call chains.
__global live = &LiveTable{}

pub struct LiveTable {
mut:
	mu   sync.RwMutex
	want map[string]bool
	vals map[string]i64
}

// keyed by wire, channel and node: node names are not unique across the channels of one wire
fn live_key(iface string, chan_name string, node string, signal string) string {
	return '${transport.destination_key(iface)}|${chan_name}|${node}|${signal}'
}

// any_key is what a server wants when it does not know the wire: a DoIP entity's node, whose
// frames a CAN channel of the project simulates.
fn any_key(node string, signal string) string {
	return '*|${node}|${signal}'
}

// want_live registers what a described server reads, so the simulation publishes it.
pub fn want_live(iface string, chan_name string, node string, signal string) {
	live.mu.lock()
	live.want[live_key(iface, chan_name, node, signal)] = true
	live.mu.unlock()
}

// live_value_of_node is node `node`'s published value of `signal` on whichever wire simulates it;
// none when no wire does, or when two do (which of them the ECU is cannot be said).
pub fn live_value_of_node(node string, signal string) ?i64 {
	suffix := '|${node}|${signal}'
	live.mu.rlock()
	defer {
		live.mu.runlock()
	}
	mut found := []i64{}
	for k, v in live.vals {
		if k.ends_with(suffix) {
			found << v
		}
	}
	return if found.len == 1 { found[0] } else { none }
}

// clear_live forgets every want and value: a new run registers its own.
pub fn clear_live() {
	live.mu.lock()
	live.want.clear()
	live.vals.clear()
	live.mu.unlock()
}

// live_value is a published signal's value, none before its node has sent it.
pub fn live_value(iface string, chan_name string, node string, signal string) ?i64 {
	live.mu.rlock()
	defer {
		live.mu.runlock()
	}
	return live.vals[live_key(iface, chan_name, node, signal)] or { return none }
}

// publish_live records, for the signals a described server wants, the value each generator gave
// the last frame due_frames sent of its message.
pub fn publish_live(iface string, chan_name string, e &Engine) {
	live.mu.rlock()
	empty := live.want.len == 0
	live.mu.runlock()
	if empty {
		return
	}
	for ecu in e.ecus {
		for m in ecu.messages {
			if m.period_ms <= 0 || m.last_n < 0 {
				continue // a response, or none handed out yet: no frame carries a generator's value
			}
			for s in m.signals {
				k := live_key(iface, chan_name, ecu.name, s.name)
				live.mu.rlock()
				wanted := k in live.want || any_key(ecu.name, s.name) in live.want
				live.mu.runlock()
				if !wanted {
					continue
				}
				mut phys := s.gen.value(m.last_t, m.last_n)
				for sig in m.msg.signals {
					if sig.name == s.name {
						phys = sig.phys_from_raw(sig.raw_from_phys(phys)) // as encoded: clamped
						break
					}
				}
				v := i64(math.round(phys))
				live.mu.lock()
				live.vals[k] = v
				live.mu.unlock()
			}
		}
	}
}

// wire_live_node points a described server's live DIDs at node `node` on whichever wire the
// project simulates it — a DoIP entity, whose node sends its frames on a CAN channel.
pub fn wire_live_node(mut srv uds.Server, node string) {
	mut any := false
	for d in srv.spec.dids {
		if d.source == .live {
			live.mu.lock()
			live.want[any_key(node, d.signal)] = true
			live.mu.unlock()
			any = true
		}
	}
	if any {
		srv.signal_value = fn [node] (signal string) ?i64 {
			return live_value_of_node(node, signal)
		}
	}
}

// live_gaps: a note for each live DID of `srv` whose signal no simulated node `node` generates
// (`sims`: the nodes the project simulates on CAN) — it reads zeros.
pub fn live_gaps(srv uds.Server, node string, sims []project.NodeCfg) []string {
	mut out := []string{}
	for d in srv.spec.dids {
		if d.source != .live {
			continue
		}
		if !sims.any(it.name == node && it.signals.any(it.signal == d.signal)) {
			out << 'DID 0x${d.id:04X} reads ${d.signal}, which no simulated ${node} generates; it reads zeros'
		}
	}
	return out
}

// wire_live points a described server's live DIDs at the simulation of node `node` of channel
// `chan_name` on `iface`.
pub fn wire_live(mut srv uds.Server, iface string, chan_name string, node string) {
	mut any := false
	for d in srv.spec.dids {
		if d.source == .live {
			want_live(iface, chan_name, node, d.signal)
			any = true
		}
	}
	if any {
		srv.signal_value = fn [iface, chan_name, node] (signal string) ?i64 {
			return live_value(iface, chan_name, node, signal)
		}
	}
}
