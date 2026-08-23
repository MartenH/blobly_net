module transport

// One wire, one handle — for the backends whose driver permits exactly one open per
// destination per process.
//
// PCANBasic is the proven case (issue #147): `CAN_Initialize` on a channel that is already
// initialized returns PCAN_ERROR_INITIALIZE (0x4000000), whose text — "a PCAN Channel has not
// been initialized yet" — reads like the opposite of what happened. The app opens each wire
// several times per Start (a monitor, a named transmit tap, the anonymous tap, more per
// generator target), so on PCAN one caller won a race for the channel and the rest were told
// the adapter was missing. The reader usually lost, leaving a measurement that transmits and
// hears nothing.
//
// This is NOT applied to every backend, and must not be. Opening `inproc:` twice is how the
// hub gives each subscriber its own queue; `udpbus` filters its own echoes per instance; and
// SocketCAN hands every socket its own copy of the traffic (see echoes_own_sends). For those,
// a second open is a second SUBSCRIBER and sharing one would have the openers stealing each
// other's frames. Sharing is a property a backend declares by routing its open through here —
// see open_windows.v. Kvaser (CANlib allows several handles per channel) and Vector are NOT
// routed through it: unverified on hardware is not the same as known-safe.
//
// Per wire there is exactly one reader and N writers — `tx_buses` is send-only — so this is
// refcounting with no RX fan-out. Were a second reader ever to appear on one destination, the
// two would split the frames between them; that is a property of the driver's single receive
// queue, not of this file, and the caller-side rule (one monitor per destination) is what
// keeps it true.

// SharedEntry is the one open bus behind a destination, and the count of handles using it.
struct SharedEntry {
	key  string
	spec string // the interface string that opened it — see the conflict check in shared_open
mut:
	bus  Bus
	refs int
}

struct SharedRegistry {
mut:
	entries map[string]&SharedEntry
}

__global (
	shared_reg shared SharedRegistry
)

// shared_open returns the process-wide bus for `key`, opening it with `make` only if this is
// the first caller. Every caller gets its own handle, so each can close independently; the
// underlying bus closes when the last one does.
//
// `spec` guards against a second caller asking for the SAME wire with DIFFERENT settings —
// two project rows on one adapter at different bitrates, say. It cannot be honoured (the
// channel is already configured), and silently handing back the first one's bitrate is the
// class of promise this repo refuses to make. It is an error instead.
fn shared_open(key string, spec string, make fn (string) !Bus) !Bus {
	mut handle := ?&SharedHandle(none)
	mut conflict := ''
	mut failure := ''
	// `make` runs INSIDE the lock, deliberately. A vendor open takes on the order of a second,
	// so the obvious refinement is to publish a reservation, open outside the lock and fill it
	// in — but then a second opener of the same wire joins an entry that has no bus yet and is
	// handed a handle it can only crash on. That is not hypothetical: the monitor thread and
	// the main thread's transmit taps open the same wire at the same moment, which is the very
	// race that produced #147. Correctness first; the cost is that concurrent opens of PCAN
	// wires serialise (nothing else is routed through here, so no other backend waits). If a
	// bench with many vendor adapters ever makes Start too slow, the fix is a per-entry lock
	// taken before the registry lock is released — not moving `make` out on its own.
	lock shared_reg {
		if mut e := shared_reg.entries[key] {
			if e.spec != spec {
				conflict = e.spec
			} else {
				e.refs++
				handle = &SharedHandle{
					key:   key
					entry: e
				}
			}
		} else if bus := make(spec) {
			e := &SharedEntry{
				key:  key
				spec: spec
				bus:  bus
				refs: 1
			}
			shared_reg.entries[key] = e
			handle = &SharedHandle{
				key:   key
				entry: e
			}
		} else {
			// Nothing was inserted, so a failed open leaves no entry behind: the next attempt
			// re-opens rather than joining a destination with no bus.
			failure = err.msg()
		}
	}
	if conflict != '' {
		return error('${spec}: this wire is already open as `${conflict}` — one destination cannot be opened twice with different settings')
	}
	if failure != '' {
		return error(failure)
	}
	if h := handle {
		return h
	}
	return error('${spec}: shared_open produced no handle')
}

// SharedHandle is one caller's view of a shared bus. It is a Bus, so nothing above transport
// knows the difference between this and a bus of its own.
struct SharedHandle {
	key string
mut:
	entry  &SharedEntry = unsafe { nil }
	closed bool
}

fn (mut h SharedHandle) send(frame CanFrame) ! {
	if h.closed {
		return error('${h.key}: bus is closed')
	}
	mut e := h.entry
	// No lock across the driver call. Sends come from several threads (generators, the Send
	// panel, diagnostics) and the vendor APIs are thread-safe per channel; serialising here
	// would only add a queue in front of one that already exists.
	return e.bus.send(frame)
}

fn (mut h SharedHandle) recv(timeout_ms int) !CanFrame {
	if h.closed {
		return error('${h.key}: bus is closed')
	}
	mut e := h.entry
	// Emphatically no lock: recv blocks for up to timeout_ms, and a lock held across it would
	// stall every sender on this wire for the length of the read timeout.
	return e.bus.recv(timeout_ms)
}

fn (mut h SharedHandle) health() BusHealth {
	if h.closed {
		return .unknown
	}
	mut e := h.entry
	return e.bus.health()
}

// close drops THIS handle's reference. The driver handle is released when the last one goes.
// Idempotent: the app closes a bus twice on at least one race path, and a second decrement
// would close the wire out from under the callers still using it.
fn (mut h SharedHandle) close() {
	if h.closed {
		return
	}
	h.closed = true
	mut last := ?Bus(none)
	lock shared_reg {
		if mut e := shared_reg.entries[h.key] {
			e.refs--
			if e.refs <= 0 {
				last = e.bus
				shared_reg.entries.delete(h.key)
			}
		}
	}
	// Outside the lock: a vendor close talks to the driver, and the registry should not be
	// held shut for the duration.
	if mut b := last {
		b.close()
	}
}
