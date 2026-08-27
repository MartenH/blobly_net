// inproc — a driver-free in-process virtual CAN bus.
//
// The default medium for simulation: simulated ECUs and the tester attach to a
// named in-memory bus and exchange frames with NO kernel device, NO sockets, NO
// drivers — so it runs identically on Linux/Windows/macOS and inside one process.
// It implements the same `Bus` interface as SocketCAN/udpbus, so it's a drop-in:
// `transport.open('inproc:CAN1')` joins the named bus.
//
// Semantics mirror a real bus: every participant on a name sees every other
// participant's frames (broadcast), but NOT its own (no self-loopback). A
// process-global registry (one shared struct) maps bus names to hubs so that
// independent open_inproc() calls anywhere in the process find the same medium.
// Requires `-enable-globals` (V's idiom for process-global state).
module transport

import time

const inproc_queue_cap = 8192 // per-subscriber buffered frames before overflow drops

// InprocHub is one named medium: the set of buses currently attached to it.
struct InprocHub {
mut:
	subs []&InprocBus
}

// InprocRegistry is the single process-global: name -> hub, plus a monotonic id
// source so each bus can filter its own echoes without rand collisions.
struct InprocRegistry {
mut:
	hubs    map[string]&InprocHub
	next_id u32
}

__global (
	inproc_reg shared InprocRegistry
)

pub struct InprocBus {
mut:
	name  string
	id    u32
	queue chan CanFrame
}

// parse_inproc_iface recognises `inproc` or `inproc:NAME` (default name 'CAN').
// Returns none for anything else, so open() can dispatch.
fn parse_inproc_iface(iface string) ?string {
	if iface == 'inproc' {
		return 'CAN'
	}
	if iface.starts_with('inproc:') {
		name := iface[7..]
		return if name.len > 0 { name } else { 'CAN' }
	}
	return none
}

// open_inproc attaches to the named in-process bus, creating it on first use.
pub fn open_inproc(name string) !&InprocBus {
	mut bus := &InprocBus{
		name:  name
		queue: chan CanFrame{cap: inproc_queue_cap}
	}
	lock inproc_reg {
		inproc_reg.next_id++
		bus.id = inproc_reg.next_id
		if mut hub := inproc_reg.hubs[name] {
			hub.subs << bus
		} else {
			inproc_reg.hubs[name] = &InprocHub{
				subs: [bus]
			}
		}
	}
	return bus
}

// send broadcasts the frame to every other bus on the same name. A full
// subscriber queue drops the frame (bus overload) rather than blocking the sender.
pub fn (mut b InprocBus) send(frame CanFrame) ! {
	// A FRAME NO CONTROLLER COULD SEND is refused here too, not only on hardware. This bus is what
	// every headless test and the whole simulation run on, so carrying an `rtr` FD frame, a classic
	// frame with `brs`, or an id too wide for the width it declares makes the simulation a model of
	// something that cannot happen — and a test that passes here and fails on a bench (codex round
	// 2 on #204). LENGTHS are deliberately not refused: padding an FD payload to a length a DLC can
	// express is what a controller genuinely does, and this bus is in the tier that pads. See
	// frame_rules.v and clamps_to_classic.
	if why := frame_send_refusal(frame) {
		return error('inproc: ${why}')
	}
	// Padded like every other backend: an in-process bus that carried a 9-byte FD payload
	// verbatim would make a headless test pass where hardware pads to 12, which is the one
	// thing the default transport must never do.
	f := if frame.fd {
		CanFrame{
			...frame
			data: fd_pad(frame.data)
		}
	} else {
		frame
	}
	mut targets := []&InprocBus{}
	rlock inproc_reg {
		if hub := inproc_reg.hubs[b.name] {
			for s in hub.subs {
				if s.id != b.id {
					targets << s
				}
			}
		}
	}
	for t in targets {
		select {
			t.queue <- f {}
			else {} // queue full → drop (overflow), like a real bus under overload
		}
	}
}

// recv returns the next frame from another participant within timeout_ms
// (timeout_ms < 0 blocks indefinitely), or error('timeout').
pub fn (mut b InprocBus) recv(timeout_ms int) !CanFrame {
	if timeout_ms < 0 {
		frame := <-b.queue
		return frame
	}
	select {
		frame := <-b.queue {
			return frame
		}
		(i64(timeout_ms) * time.millisecond) {
			return error('timeout')
		}
	}
	return error('timeout')
}

// health: an in-process broadcast has no error counters — nothing to report, honestly.
pub fn (mut b InprocBus) health() BusHealth {
	return .unknown
}

// reconcile_silence — nothing to reconcile: this bus has no controller, so it generates no
// acknowledgement and `SilentBus` refusing its sends is the whole of listen-only here.
pub fn (mut b InprocBus) reconcile_silence(want bool) ! {
	{}
}

pub fn (mut b InprocBus) close() {
	lock inproc_reg {
		if mut hub := inproc_reg.hubs[b.name] {
			hub.subs = hub.subs.filter(it.id != b.id)
		}
	}
	b.queue.close()
}
