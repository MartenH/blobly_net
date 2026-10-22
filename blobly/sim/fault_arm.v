// Arming a fault from a script: the one rule for which faults may be stored, asked by Lua's
// sim.fault and by the C ABI's bb_sim_fault alike. A fault that could not take effect is refused
// rather than stored: armed and changing nothing, it is the difference between a test that fails
// and a test that lies.
module sim

import blobly.candb
import blobly.project

// FaultTarget is one channel a fault may be armed on, as the front end that arms it knows it.
pub struct FaultTarget {
pub:
	channel  string // the row's name, for the refusals
	eth_kind string // 'DoIP' or 'SOME/IP' for an Ethernet row, where nothing simulates
	iface    string // the logical interface faults are keyed on (fault_key)
	db       candb.Database
	nodes    []project.NodeCfg // the simulated nodes on it
}

// fault_kind_of is a fault kind as a script spells it; clear, none and '' are no fault.
pub fn fault_kind_of(kind string) !FaultKind {
	return match kind {
		'none', 'clear', '' { FaultKind.none_ }
		'drop' { FaultKind.drop }
		'bad_crc' { FaultKind.bad_crc }
		'freeze_counter' { FaultKind.freeze_ctr }
		'out_of_range' { FaultKind.out_of_range }
		else { error('unknown fault kind "${kind}"') }
	}
}

// arm puts `kind` on `node`'s `msg` on this channel for `ms` milliseconds (0 or less: until
// cleared), forcing `signal` out of range for out_of_range (one chosen when empty, as the
// Simulation panel offers one); a kind of clear lifts it. Refused: an Ethernet row, an unknown
// kind, a node not simulated here, a message `node` does not send, and a kind that would change
// no bit on the wire.
pub fn (t FaultTarget) arm(node string, msg string, kind string, ms int, signal string) ! {
	if t.eth_kind != '' {
		return error('"${t.channel}" is a ${t.eth_kind} channel — nothing simulates on it, so a fault there could never take effect')
	}
	k := fault_kind_of(kind)!
	if k == .none_ {
		inject(t.iface, node, msg, Fault{})
		return
	}
	// the DBC naming `node` a sender is not enough: only a node simulated here transmits
	if !t.nodes.any(it.name == node) {
		return error('"${node}" is not simulated on ${t.channel}')
	}
	m := t.db.messages_from(node).filter(it.name == msg)
	if m.len == 0 {
		return error('"${node}" does not send "${msg}" on ${t.channel}')
	}
	prot := t.protection(node, msg)
	mut sg := signal
	match k {
		.out_of_range {
			if sg == '' {
				for cand in m[0].signals {
					if can_force_out_of_range(m[0], cand.name, prot) {
						sg = cand.name
						break
					}
				}
				if sg == '' {
					return error('no signal on "${msg}" has a value outside its declared range')
				}
			}
			past_payload_refusal(m, sg, 'out_of_range')!
			if !m.any(can_force_out_of_range(it, sg, prot)) {
				return error('"${sg}" on "${msg}" has no value outside its declared range')
			}
		}
		.bad_crc {
			if prot.crc == '' {
				return error('"${msg}" on "${node}" has no configured checksum — bad_crc would change nothing')
			}
			past_payload_refusal(m, prot.crc, 'bad_crc')!
		}
		.freeze_ctr {
			// the E2E counter is what freezes; a `counter` generator is an ordinary signal
			if prot.counter == '' {
				return error('"${msg}" on "${node}" has no E2E counter — freeze_counter would change nothing')
			}
			past_payload_refusal(m, prot.counter, 'freeze_counter')!
		}
		else {}
	}
	inject(t.iface, node, msg, Fault{
		kind:         k
		signal:       sg
		remaining_ms: ms
	})
}

// past_payload_refusal refuses a fault `kind` on a field the payload does not hold.
fn past_payload_refusal(msgs []candb.Message, field string, kind string) ! {
	for m in msgs {
		if why := past_payload(m, field) {
			return error('${why} — ${kind} would change nothing')
		}
	}
}

// protection is what `node` stamps on `msg` here (empty when none): its protect: entry or the
// DBC's declaration, the one answer the simulation stamps by (protection_for).
fn (t FaultTarget) protection(node string, msg string) E2e {
	for n in t.nodes {
		if n.name != node {
			continue
		}
		for m in t.db.messages_from(node) {
			if m.name == msg {
				return protection_for(n, m) or { E2e{} }
			}
		}
	}
	return E2e{}
}
