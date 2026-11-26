module transport

import sync

// canlink.v — what a SocketCAN interface's CONTROLLER is set to, READ and never changed (#454).
//
// Listen-only has two halves (listen.v): this process refusing to transmit, and the controller
// refusing to ACKNOWLEDGE. The four vendor backends set the second half themselves. A SocketCAN
// interface's mode belongs to whoever brought the link up (`ip link set can0 type can listen-only
// on`), and changing it means taking the link down, which needs root and drops every socket on
// it — so this app does not change it. It READS it instead, over rtnetlink (the kind, and the
// ctrlmode a CAN controller carries), and says when it disagrees with the row: a DECLARED fault in
// silence.v, as a CANsub's refusal to reconfigure a live channel is, which the Buses row shows and
// the Log narrates, naming the host command that sets it.
//
// A vcan or vxcan has no controller and so no ACK to suppress: the software refusal is the whole of
// listen-only there, and nothing is said. A CAN interface behind a CAN bridge is read the same way
// by the bridge, on its host, and its reading travels in the bridge's status record.
//
// The rule is pure and lives here, on every OS; the read is `can_link_of` (canlink_linux.c.v).

// ControllerMode is what a link's controller was found in.
pub enum ControllerMode as u8 {
	unknown       = 0 // not read, or the reading said nothing about it
	no_controller = 1 // the link is not a CAN controller (vcan, vxcan): there is no ACK to suppress
	normal        = 2 // a controller that transmits and acknowledges
	listen_only   = 3 // a controller that neither transmits nor acknowledges
}

// CanLink is one reading of an interface: its link kind and what that says of its controller.
pub struct CanLink {
pub:
	kind string
	mode ControllerMode
}

// CAN_CTRLMODE_LISTENONLY, linux/can/netlink.h
const can_ctrlmode_listen_only = u32(0x02)

// link_controller reads one RTM_GETLINK answer: a link of kind `can` is a controller, whose
// ctrlmode says whether it listens only; any other kind (or none) has no controller.
pub fn link_controller(kind string, has_ctrlmode bool, flags u32) ControllerMode {
	if kind != 'can' {
		return .no_controller
	}
	if !has_ctrlmode {
		return .unknown
	}
	return if flags & can_ctrlmode_listen_only != 0 { .listen_only } else { .normal }
}

// ModeVerdict is a controller's mode held against the row's listen-only mark.
pub enum ModeVerdict {
	agrees      // the controller is where the row wants it, or there is no controller
	unread      // the mode is not known: nothing is said
	still_acks  // the row is listen-only and the controller is not: it acknowledges every frame
	cannot_send // the row may transmit and the controller is listen-only: nothing goes out
}

// controller_verdict is the one rule: what a controller in `mode` means for a row whose mark is
// `want` (true = listen-only).
pub fn controller_verdict(mode ControllerMode, want bool) ModeVerdict {
	return match mode {
		.unknown {
			.unread
		}
		.no_controller {
			.agrees
		}
		.normal {
			if want { .still_acks } else { .agrees }
		}
		.listen_only {
			if want { .agrees } else { .cannot_send }
		}
	}
}

// The statuses apply_silence carries for a verdict that disagrees; 0 is agreement.
const mode_status_still_acks = 1
const mode_status_cannot_send = 2

fn verdict_status(v ModeVerdict) int {
	return match v {
		.agrees { 0 }
		.unread { silence_not_attempted }
		.still_acks { mode_status_still_acks }
		.cannot_send { mode_status_cannot_send }
	}
}

// controller_refusal is the operator's sentence for a verdict that disagrees, naming the interface
// on its host and the commands that set it there; none where there is nothing to say. `bridge` is
// the bridge the interface is behind, '' for one on this host. DECLARED: the controller is doing
// what its host set, not failing.
pub fn controller_refusal(host_if string, bridge string, v ModeVerdict) ?SilenceReason {
	at := if bridge == '' { '' } else { ' on the host of bridge "${bridge}"' }
	host := if bridge == '' { 'this host' } else { 'the host of bridge "${bridge}"' }
	return match v {
		.agrees, .unread {
			none
		}
		.still_acks {
			SilenceReason{
				why:      'the controller of ${host_if}${at} is not listen-only, so it still acknowledges every frame — this app reads the mode of a SocketCAN interface and does not change it; set it on ${host} as root: ip link set ${host_if} down; ip link set ${host_if} type can listen-only on; ip link set ${host_if} up'
				declared: true
			}
		}
		.cannot_send {
			SilenceReason{
				why:      'the controller of ${host_if}${at} is listen-only, so this row can neither transmit nor acknowledge — tick the row listen-only, or set the controller back on ${host} as root: ip link set ${host_if} down; ip link set ${host_if} type can listen-only off; ip link set ${host_if} up'
				declared: true
			}
		}
	}
}

// controller_reason is controller_refusal for the status apply_silence hands its `explain`.
fn controller_reason(host_if string, bridge string, st int) SilenceReason {
	v := match st {
		mode_status_still_acks { ModeVerdict.still_acks }
		mode_status_cannot_send { ModeVerdict.cannot_send }
		else { ModeVerdict.unread }
	}
	return controller_refusal(host_if, bridge, v) or { generic_silence_reason(false, st) }
}

// apply_controller_mode holds a controller this app does not configure, read in `mode`, against
// wire `iface`'s mark `want`, through the one seam (silence.v): a declared fault where they
// disagree, the wire's record and any fault brought to agreement where they agree, and nothing at
// all where the mode is not known or there is no controller. Never changes the controller.
//
// It ERRS only for a transmitting row on a listen-only controller (`cannot_send`), as a NotWritten:
// a send there is refused before the driver, so nothing went out, and the kernel would otherwise
// drop the frame while the write reported success. A listen-only row on a controller that
// acknowledges (`still_acks`) is recorded and answered ok: the open of a listen-only wire is
// refused when its reconcile errs (shared.v), which would leave the row with no reader after the
// first open, and SilentBus refuses every send on a listen-only wire anyway.
fn apply_controller_mode(iface string, host_if string, bridge string, mode ControllerMode, want bool) ! {
	v := controller_verdict(mode, want)
	if v == .unread || mode == .no_controller {
		return
	}
	st := verdict_status(v)
	apply_silence_probe(iface, want, fn [st] (_ bool) int {
		return st
	}, fn [host_if, bridge] (_ bool, s int) SilenceReason {
		return controller_reason(host_if, bridge, s)
	}) or {
		if v == .cannot_send {
			return not_written(err.msg())
		}
	}
}

// controller_reread_ns is how often a handle reads its controller again while the reading still
// disagrees with the mark, or said nothing: the mode is set on the host with the link down, which a
// socket bound to it outlives, so a transmit-only handle would otherwise refuse after the controller
// was corrected (SocketCAN, canlink_linux.c.v).
pub const controller_reread_ns = i64(1_000_000_000)

// controller_reread_due is when a handle holding `held` against a controller last read in `mode`
// at `read_ns` reads it again for mark `want`: whenever the mark moved, and once a second while the
// pair disagrees or the mode is not known. An agreeing pair is never read again.
pub fn controller_reread_due(mode ControllerMode, held ?bool, want bool, read_ns i64, now_ns i64) bool {
	h := held or { return true }
	if h != want {
		return true
	}
	if controller_verdict(mode, want) == .agrees {
		return false
	}
	return now_ns - read_ns >= controller_reread_ns
}

// controller_send_refusal is the refusal a send on a wire whose held (mode, mark) still disagrees
// owes without asking anything again: only `cannot_send` refuses (apply_controller_mode).
fn controller_send_refusal(host_if string, bridge string, mode ControllerMode, want bool) ! {
	v := controller_verdict(mode, want)
	if v == .cannot_send {
		r := controller_refusal(host_if, bridge, v) or { return }
		return not_written(r.why)
	}
}

// ControllerHolders counts the open handles per wire of a backend whose controller this app reads
// and does not configure (SocketCAN), so the wire's silence record and declared fault are forgotten
// when its last handle closes: a fault must not outlive the wire it describes (silence.v).
struct ControllerHolders {
mut:
	mu   sync.Mutex
	refs map[string]int
}

__global controller_holders = &ControllerHolders{}

// controller_wire_opened counts a handle on `iface`; called before the open reads the controller,
// so a close racing it cannot forget what that read records.
fn controller_wire_opened(iface string) {
	k := wire_key(iface)
	controller_holders.mu.lock()
	controller_holders.refs[k] = controller_holders.refs[k] + 1
	controller_holders.mu.unlock()
}

// controller_wire_closed uncounts a handle on `iface`, forgetting the wire's silence record and
// fault when it was the last. The forget is done under the count's lock, so an open counted after
// it reads afresh and is not erased.
fn controller_wire_closed(iface string) {
	k := wire_key(iface)
	controller_holders.mu.lock()
	defer {
		controller_holders.mu.unlock()
	}
	n := controller_holders.refs[k] - 1
	if n > 0 {
		controller_holders.refs[k] = n
		return
	}
	controller_holders.refs.delete(k)
	forget_wire_silence(iface)
}

// mode_holds_against reports whether a controller in `mode` is one apply_controller_mode would hold
// a mark against: a CAN controller whose mode was read.
fn mode_holds_against(mode ControllerMode) bool {
	return mode == .normal || mode == .listen_only
}
