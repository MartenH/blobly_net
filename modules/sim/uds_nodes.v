// Building per-ECU diagnostic servers from a project. Shared by the GUI and the headless
// runner, because a scripted diagnostic test must reach the same servers the interactive one
// does — the class of divergence that produced three copies of build_node and two database
// merges before it.
module sim

import project
import uds

// UdsNode is one simulated ECU's diagnostic server, with the addresses it answers on.
pub struct UdsNode {
pub:
	name string
	rx   u32 // request id  (tester -> ECU)
	tx   u32 // response id (ECU -> tester)
pub mut:
	server uds.Server
}

// uds_nodes builds a server for every node on the channel that configures one.
//
// Returns EMPTY when no node does, and the caller then runs the single built-in server on the
// channel's default addresses as before. That rule — configure one and you own diagnostics on
// this channel — is what keeps the two from fighting over 0x7E0: a default that kept running
// alongside would answer requests meant for a configured ECU whenever the ids overlapped, and
// which reply the tester saw would depend on scheduling.
pub fn uds_nodes(nodes []project.NodeCfg) []UdsNode {
	mut out := []UdsNode{}
	for n in nodes {
		cfg := n.uds or { continue }
		mut srv := uds.Server{
			session: cfg.session
		}
		for d in cfg.dids {
			srv.dids[d.id] = if d.bytes.len > 0 { d.bytes.clone() } else { d.text.bytes() }
		}
		for t in cfg.dtcs {
			srv.dtcs << uds.Dtc{
				code:   t.code
				status: t.status
			}
		}
		out << UdsNode{
			name:   n.name
			rx:     cfg.rx
			tx:     cfg.tx
			server: srv
		}
	}
	return out
}

// validate_uds reports diagnostic configurations that cannot work as written.
pub fn validate_uds(nodes []project.NodeCfg) []string {
	mut warns := []string{}
	mut by_rx := map[u32]string{}
	for n in nodes {
		cfg := n.uds or { continue }
		if cfg.rx == 0 || cfg.tx == 0 {
			warns << 'uds on "${n.name}": rx and tx must both be set'
			continue
		}
		if cfg.rx == cfg.tx {
			// one ISO-TP channel cannot both listen and answer on a single id: the server
			// would receive its own responses and answer them
			warns << 'uds on "${n.name}": rx and tx are both 0x${cfg.rx:X}'
		}
		if prev := by_rx[cfg.rx] {
			// two servers listening on one id both answer, and the tester sees whichever
			// arrives first — a coin toss, not a configuration
			warns << 'uds on "${n.name}": request id 0x${cfg.rx:X} is already answered by "${prev}"'
		}
		by_rx[cfg.rx] = n.name
	}
	return warns
}
