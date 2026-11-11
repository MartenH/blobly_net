// Arming a fault from a script: the one rule for which faults may be stored, asked by Lua's
// sim.fault and by the C ABI's bb_sim_fault alike. A fault that could not take effect is refused
// rather than stored: armed and changing nothing, it is the difference between a test that fails
// and a test that lies.
module sim

import blobly.candb
import blobly.nm
import blobly.project

// FaultTarget is one channel a fault may be armed on, as the front end that arms it knows it.
pub struct FaultTarget {
pub:
	channel  string // the row's name, for the refusals
	not_can string // the kind of a row that is not CAN (DoIP, SOME/IP, LIN), where nothing simulates
	iface    string // the logical interface faults are keyed on (fault_key)
	db       candb.Database
	nodes    []project.NodeCfg // the simulated nodes on it
	nm       ?nm.Config        // its wire's NM cluster, which says who announces (nm_request)
	row      int               // the project row's index, which NM requests are keyed on with iface
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
// Simulation panel offers one); for bad_crc and freeze_counter `signal` names the E2E window it
// acts on (its group, E2e.label; empty for every window). A kind of clear lifts it. Refused: an
// Ethernet row, an unknown kind, a node not simulated here, a message `node` does not send, a
// window it does not stamp, and a kind that would change no bit on the wire.
pub fn (t FaultTarget) arm(node string, msg string, kind string, ms int, signal string) ! {
	if t.not_can != '' {
		return error('"${t.channel}" is a ${t.not_can} channel — nothing simulates on it, so a fault there could never take effect')
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
	t.announced_refusal(node, m[0], k)!
	all := t.protection(node, msg)
	mut prot := all.clone()
	mut group := ''
	if k in [.bad_crc, .freeze_ctr] && signal != '' {
		prot = all.filter(it.label(m[0]) == signal)
		if prot.len == 0 {
			names := all.map(it.label(m[0]))
			return error('"${msg}" on "${node}" has no E2E window "${signal}"${if names.len > 0 {
				' (its windows: ${names.join(', ')})'
			} else {
				''
			}}')
		}
		group = prot[0].group
	}
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
			wide_refusal(m, sg, 'out_of_range')!
			if !m.any(can_force_out_of_range(it, sg, prot)) {
				return error('"${sg}" on "${msg}" has no value outside its declared range')
			}
		}
		.bad_crc {
			crcs := prot.filter(it.crc != '')
			if crcs.len == 0 {
				return error('"${msg}" on "${node}" has no configured checksum — bad_crc would change nothing${t.unapplied(node, m[0])}')
			}
			for e in crcs {
				past_payload_refusal(m, e.crc, 'bad_crc')!
			}
			sg = ''
		}
		.freeze_ctr {
			// the E2E counter is what freezes; a `counter` generator is an ordinary signal
			ctrs := prot.filter(it.counter != '')
			if ctrs.len == 0 {
				return error('"${msg}" on "${node}" has no E2E counter — freeze_counter would change nothing${t.unapplied(node, m[0])}')
			}
			for e in ctrs {
				past_payload_refusal(m, e.counter, 'freeze_counter')!
			}
			sg = ''
		}
		else {}
	}
	inject(t.iface, node, msg, Fault{
		kind:         k
		group:        group
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

// wide_refusal refuses a fault `kind` on a signal past the 64-bit scalar model, which nothing writes.
fn wide_refusal(msgs []candb.Message, field string, kind string) ! {
	for m in msgs {
		for sig in m.signals {
			if sig.name == field && !sig.is_scalar() {
				return error('${sig.scalar_refusal()} — ${kind} would change nothing')
			}
		}
	}
}

// protection is what `node` stamps on `msg` here, per window (empty when none): the protection the
// engine attaches to its messages of that name (protections).
fn (t FaultTarget) protection(node string, msg string) []E2e {
	for n in t.nodes {
		if n.name == node {
			return protections(t.db, n)[msg] or { []E2e{} }
		}
	}
	return []E2e{}
}

// FaultOffer is what can be put on one message of one simulated node: the kinds that take effect
// there, none_ and drop first, and the signal out_of_range forces (empty when it is not offered).
pub struct FaultOffer {
pub:
	kinds      []FaultKind
	oor_signal string
}

// fault_offer is the faults that take effect on `node`'s `msg`, `prot` what it stamps there per
// window (the protection the engine attaches to its messages of that name, protections) and `anns`
// the announcements of its wire: bad_crc where a window stamps a checksum the payload holds,
// freeze_counter where one stamps an E2E counter, out_of_range where a signal has a value outside its range — and on
// a frame it announces NM on, drop alone, since the announcement goes out in its place.
pub fn fault_offer(node project.NodeCfg, msg candb.Message, prot []E2e, anns []nm.Announce) FaultOffer {
	mut kinds := [FaultKind.none_, .drop]
	if announced_frame(anns, node.name, msg) {
		return FaultOffer{
			kinds: kinds
		}
	}
	if prot.any(it.crc != '' && past_payload(msg, it.crc) == none) {
		kinds << .bad_crc
	}
	if prot.any(it.counter != '' && past_payload(msg, it.counter) == none) {
		kinds << .freeze_ctr
	}
	mut oor := ''
	for sg in msg.signals {
		if can_force_out_of_range(msg, sg.name, prot) {
			oor = sg.name
			break
		}
	}
	if oor != '' {
		kinds << .out_of_range
	}
	return FaultOffer{
		kinds:      kinds
		oor_signal: oor
	}
}

// unapplied says why `node` stamps nothing on `m` although a protect: entry or the DBC's
// declaration names protection for it (shape_problem, declared_problem), as a clause a refusal
// ends with; '' when nothing names any. Its protect: entries are asked before the file's
// declarations, since an entry overrides them.
fn (t FaultTarget) unapplied(node string, m candb.Message) string {
	for n in t.nodes {
		if n.name != node {
			continue
		}
		mine := n.protect.filter(it.message == m.name)
		for p in mine {
			if why := shape_problem(m, e2e_of(p)) {
				return ' (its protect: entry is not applied: ${why})'
			}
		}
		if mine.len > 0 {
			return ''
		}
	}
	for d in m.e2e {
		if d.declared() {
			why := declared_problem(m, d)
			if why != '' {
				return ' (its E2E declaration is not applied: ${why})'
			}
		}
	}
	return ''
}
