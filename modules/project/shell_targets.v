// project/shell_targets — derive the Shell panel's selectable command targets.
//
// A mixed project (a someip eth board + a CAN channel whose manifest declares
// the shell frames) has TWO reachable shells; dispatch-by-"eth exists" made the
// CAN one unreachable. This derives the explicit list the panel selects from —
// pure routing/display data, each entry carrying the snapshot its worker needs.
module project

import telem

// ShellTarget is one destination the Shell can send a command line to: a someip
// channel's eth RPC endpoint, the standalone manifest-on-CAN eth shell, or the
// CAN shell of a manifest-carrying channel. Derived (never persisted) —
// rebuilt wherever an input changes (App.rebuild_shell_targets).
pub struct ShellTarget {
pub:
	eth    bool              // eth RPC target; false = CAN shell
	ci     int               // channel index; -1 = standalone eth (no someip channel)
	label  string            // display: '<chan> · eth <ip>' / '<chan> · CAN 0x<cmd>'
	iface  string            // CAN: the channel iface the worker transmits on
	board  string            // eth: the board ip ('' = standalone — typed in the panel)
	sip    telem.SomeipIdent // eth: identity snapshot for the RPC worker
	method u16               // eth: the shell method id
}

// shell_targets derives the target list from the project's channels. `enabled`
// is the RUNTIME per-channel flag (the Buses panel toggles it without a project
// rebuild; falls back to the configured flag when the caller has no runtime
// view). `sip`/`method` are the eth identity — the FIRST someip channel's
// manifest, or the manifest-on-CAN scan when no someip channel exists (then the
// standalone-socket shell is the target, ci -1, board ip typed in the panel).
// `sh` may be undeclared: the ids default like the worker's (or_defaults), so
// an old manifest keeps its CAN shell. A someip channel lists even when
// stopped/disabled (selecting it must hit the worker's "(someip channel
// stopped — Start it)" refusal, not silently reroute).
pub fn shell_targets(chans []Channel, enabled []bool, sip telem.SomeipIdent, method u16, sh telem.ShellFrames) []ShellTarget {
	mut out := []ShellTarget{}
	ids := sh.or_defaults()
	mut someip_seen := false
	for i, ch in chans {
		if ch.is_someip() {
			// only the FIRST someip channel carries the identity (one per
			// project; later ones are forced disabled by the rebuild)
			if !someip_seen && sip.service != 0 && method != 0 {
				out << ShellTarget{
					eth:    true
					ci:     i
					label:  '${ch.name} · eth ${ch.address}'
					board:  ch.address
					sip:    sip
					method: method
				}
			}
			someip_seen = true
			continue
		}
		// the CAN shell rides a monitorable channel carrying the manifest
		// (shell_worker's trace_iface() preference, made explicit per entry)
		en := if i < enabled.len { enabled[i] } else { ch.enabled }
		if en && ch.mode == .monitor && !ch.is_doip() && ch.manifest != '' {
			out << ShellTarget{
				ci:    i
				label: '${ch.name} · CAN 0x${ids.input.hex()}'
				iface: ch.iface
			}
		}
	}
	if !someip_seen && sip.service != 0 && method != 0 {
		out << ShellTarget{
			eth:    true
			ci:     -1
			label:  'manifest · eth (standalone)'
			sip:    sip
			method: method
		}
	}
	return out
}
