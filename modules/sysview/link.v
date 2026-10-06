module sysview

import os

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
		if (n.diag_req == t.req && n.diag_rsp == t.rsp)
			|| (n.desc.isotp_req == t.req && n.desc.isotp_rsp == t.rsp) {
			hits << i
		}
	}
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

// NodeTarget is one node's diagnostic server on one CAN bus.
pub struct NodeTarget {
pub:
	node int
	bus  string
	req  u32
	rsp  u32
	ext  bool // 29-bit ids (above 0x7FF, the convention the id allocation uses)
}

// can_targets: every node's diagnostic server on each of `buses` it sits on — the channels a
// project names after its system's buses. A node addresses by system.toml's `diag`, else its own
// `[isotp]`; one whose ecu.toml declares no server (the tester's own declaration) is not a
// target, while one whose ecu.toml could not be read keeps its system.toml ids.
pub fn (sys &System) can_targets(buses []string) []NodeTarget {
	mut out := []NodeTarget{}
	for i, n in sys.nodes {
		if n.ecu_err == '' && !n.desc.server {
			continue
		}
		mut req, mut rsp := n.diag_req, n.diag_rsp
		if req == 0 && rsp == 0 {
			req, rsp = n.desc.isotp_req, n.desc.isotp_rsp
		}
		if req == 0 && rsp == 0 {
			continue
		}
		for b in n.buses {
			if b in buses {
				out << NodeTarget{
					node: i
					bus:  b
					req:  req
					rsp:  rsp
					ext:  req > 0x7FF || rsp > 0x7FF
				}
			}
		}
	}
	return out
}

// find_system is the system.toml describing a project: in the project's own folder, else in the
// folder of one of its databases (a test project in `test/` names `../edge.dbc`, which sits beside
// the system that generated it), else in the project folder's parent. `db_refs` are the channels'
// database references as the project writes them, relative to the project's folder.
pub fn find_system(proj_path string, db_refs []string) ?string {
	if proj_path == '' {
		return none
	}
	base := os.dir(proj_path)
	mut dirs := [base]
	for r in db_refs {
		p := if os.is_abs_path(r) { r } else { os.join_path(base, r) }
		dirs << os.dir(p)
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
