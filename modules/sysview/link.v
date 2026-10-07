module sysview

import os
import candb
import project

// link.v — from a tester's diagnostic target to the blobly_emb node it addresses, and from a
// project to the system.toml that describes its nodes. Both pure rules (the second reads only
// whether a file exists), so the Diagnostics panel and anything after it agree on them.

// TargetAddr is how a tester reaches one diagnostic server.
pub struct TargetAddr {
pub:
	doip    bool
	logical u32 // DoIP: the entity's logical address
	req     u32 // CAN: the request id — what the ECU listens on
	rsp     u32 // CAN: the response id
	bus     string // the channel's name: a project made from a system names its channels by its buses
}

// NodeLink is the answer: the node's index in `System.nodes`, or -1 with the reason.
pub struct NodeLink {
pub:
	node int = -1
	why  string
}

// node_for maps a target to the node it addresses — by diagnostic addressing, the one thing a
// target and a node both state: a DoIP target by its entity's logical address, a CAN target by its
// request AND response ids (system.toml's `diag`, else the node's own `[isotp]`). Two nodes with
// one address are told apart by the bus the target's channel is named after; if that does not
// settle it, no node is chosen — a description of the wrong ECU is worse than none.
pub fn (sys &System) node_for(t TargetAddr) NodeLink {
	hits := sys.addressed(t)
	addr := if t.doip { 'DoIP 0x${t.logical:04X}' } else { '0x${t.req:X}/0x${t.rsp:X}' }
	if hits.len == 0 {
		return NodeLink{
			why: 'no node in ${os.file_name(sys.path)} is addressed ${addr}'
		}
	}
	if hits.len > 1 {
		on_bus := hits.filter(t.bus in sys.nodes[it].buses)
		if on_bus.len == 1 {
			return NodeLink{
				node: on_bus[0]
			}
		}
		names := hits.map(sys.nodes[it].name).join(', ')
		return NodeLink{
			why: '${names} are all addressed ${addr}; none chosen'
		}
	}
	return NodeLink{
		node: hits[0]
	}
}

// can_ids is the node's diagnostic request and response id: system.toml's `diag` when it states
// one — the system allocates the ids, and its pair SUPERSEDES the node's — else the node's own
// `[isotp]`. (0, 0) = none.
pub fn (n &SysNode) can_ids() (u32, u32) {
	if n.diag_req != 0 || n.diag_rsp != 0 {
		return n.diag_req, n.diag_rsp
	}
	return n.desc.isotp_req, n.desc.isotp_rsp
}

// ChanRef is one of a project's CAN channels: its name and its interface.
pub struct ChanRef {
pub:
	name  string
	iface string
}

// NodeTarget is one node's diagnostic server on one CAN channel.
pub struct NodeTarget {
pub:
	node  int
	bus   string
	iface string // the channel's interface
	// another channel bears the same name: the label must say which this is
	shared_name bool
	req         u32
	rsp         u32
	ext         bool // 29-bit ids (above 0x7FF, the convention the id allocation uses)
}

// can_targets: every node's diagnostic server on each channel named after a bus it sits on. A
// node addresses by `can_ids`; one whose ecu.toml declares no server (the tester's own
// declaration) is not a target, while one whose ecu.toml could not be read keeps its system.toml
// ids. Two channels with one name are two targets — they are two wires, and either may be the one
// the ECU is on — each marked `shared_name` so neither is shown as THE bus.
pub fn (sys &System) can_targets(chans []ChanRef) []NodeTarget {
	mut out := []NodeTarget{}
	for i, n in sys.nodes {
		if n.ecu_err == '' && !n.desc.server {
			continue
		}
		req, rsp := n.can_ids()
		if req == 0 && rsp == 0 {
			continue
		}
		for b in n.buses {
			on := chans.filter(it.name == b)
			for c in on {
				out << NodeTarget{
					node:        i
					bus:         b
					iface:       c.iface
					shared_name: on.len > 1
					req:         req
					rsp:         rsp
					ext:         req > 0x7FF || rsp > 0x7FF
				}
			}
		}
	}
	return out
}

// find_system is the system.toml describing a project: in the project's own folder, else in the
// folder of one of its databases (a test project in `test/` names `../edge.dbc`, which sits beside
// the system that generated it), else in the project folder's parent. `db_refs` are the channels'
// database references as the project writes them, resolved by `project.resolve_asset` — the rule
// that loads the databases themselves.
pub fn find_system(proj_path string, db_refs []string) ?string {
	if proj_path == '' {
		return none
	}
	base := os.dir(proj_path)
	mut dirs := [base]
	for r in db_refs {
		file, _ := candb.split_database_ref(project.resolve_asset(base, r))
		if os.exists(file) { // a reference that resolves nowhere says nothing about where to look
			dirs << os.dir(file)
		}
	}
	dirs << os.dir(base)
	mut seen := map[string]bool{}
	for d in dirs {
		cand := os.norm_path(os.join_path(d, 'system.toml'))
		if cand in seen {
			continue
		}
		seen[cand] = true
		if os.is_file(cand) {
			return cand
		}
	}
	return none
}

// addressed is every node `t`'s addressing names, whatever bus it is on.
fn (sys &System) addressed(t TargetAddr) []int {
	mut hits := []int{}
	for i, n in sys.nodes {
		if t.doip {
			if n.doip != 0 && n.doip == t.logical {
				hits << i
			}
			continue
		}
		if t.req == 0 && t.rsp == 0 {
			continue
		}
		req, rsp := n.can_ids()
		if req == t.req && rsp == t.rsp {
			hits << i
		}
	}
	return hits
}

// describes reports whether any node is addressed as `t` — on any bus: a target nothing in the
// system answers to is one a tester should expect silence from.
pub fn (sys &System) describes(t TargetAddr) bool {
	return sys.addressed(t).len > 0
}

// doip_tester_for is the tester address an entity found at `host` with logical address `logical`
// lets activate routing, as the system describes it: the first of its node's `testers`. The
// node is the one whose DoIP address is `logical` — and, where several are, whose endpoint
// address is `host`; none when that does not settle it, or the node lists no testers.
pub fn (sys &System) doip_tester_for(logical u16, host string) ?u16 {
	mut hits := sys.addressed(TargetAddr{
		doip:    true
		logical: logical
	})
	if hits.len > 1 && host != '' {
		hits = hits.filter(sys.nodes[it].address != ''
			&& sys.nodes[it].address.to_lower() == host.to_lower())
	}
	if hits.len != 1 {
		return none
	}
	n := sys.nodes[hits[0]]
	if n.address != '' && host != '' && n.address.to_lower() != host.to_lower() {
		return none // the description's entity is at another address: not this one
	}
	return n.testers[0] or { return none }
}
