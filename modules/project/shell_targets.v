// project/shell_targets — derive the Shell panel's selectable command targets.
//
// A mixed project (a someip eth board + a CAN channel whose manifest declares
// the shell frames) has TWO reachable shells; dispatch-by-"eth exists" made the
// CAN one unreachable. This derives the explicit list the panel selects from —
// pure routing/display data, each entry carrying the snapshot its worker needs.
module project

import telem

// ShellTarget is one destination the Shell can send a command line to: a someip
// channel's eth RPC endpoint, or the CAN shell of a manifest-carrying channel.
// Derived (never persisted) — rebuilt wherever the eth identity is derived.
pub struct ShellTarget {
pub:
	eth    bool              // eth RPC target (someip channel); false = CAN shell
	ci     int               // index of the channel in the project's channel list
	label  string            // display: '<chan> · eth <ip>' / '<chan> · CAN 0x<cmd>'
	board  string            // eth: the board ip (the channel's address)
	sip    telem.SomeipIdent // eth: identity snapshot for the RPC worker
	method u16               // eth: the shell method id
}

// shell_targets derives the target list from the project's channels. `sip`/
// `method` are the FIRST someip channel's manifest identity (the one eth
// identity a project has — later someip channels are forced disabled); `sh` is
// the global manifest's shell section, UNfilled: a CAN entry requires declared
// cmd/rsp ids — the or_defaults fallback stays a zero-target legacy affair.
// A someip channel lists even when stopped/disabled (selecting it must hit the
// worker's "(someip channel stopped — Start it)" refusal, not silently reroute).
pub fn shell_targets(chans []Channel, sip telem.SomeipIdent, method u16, sh telem.ShellFrames) []ShellTarget {
	mut out := []ShellTarget{}
	can_shell := sh.input != 0 && sh.out != 0
	mut someip_seen := false
	for i, ch in chans {
		if ch.is_someip() {
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
		// the CAN shell rides the channel shell_worker's trace_iface() picks:
		// a monitorable channel carrying the manifest
		if can_shell && ch.enabled && ch.mode == .monitor && !ch.is_doip() && ch.manifest != '' {
			out << ShellTarget{
				ci:    i
				label: '${ch.name} · CAN 0x${sh.input.hex()}'
			}
		}
	}
	return out
}
