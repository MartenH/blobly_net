module transport

import sync

// listen-only — the wires the operator marked "never transmit", and the ONE place that is
// enforced.
//
// WHY NOT AT EACH EMITTER. Quick Send, the generators, the simulated ECUs, replay, diagnostics,
// the shell, the Lua runner and the restbus tool all put frames on a wire, and each opens its
// own bus to do it. A rule checked at every emitter holds until somebody adds the ninth: issue
// #117 found it checked in exactly one of them (replay) while the checkbox's tooltip promised
// all of them. Checked inside `open`, an emitter cannot opt out, because it never sees the
// decision -- it is simply handed a bus that refuses.
//
// WHY NOT IN THE ADDRESS. `,silent` already reaches the Vector transceiver through the interface
// string, so spelling it that way for every backend looks like the smaller change. It is not.
// destination_key and wire_key_for reduce an address to a WIRE IDENTITY, and they strip a mode
// suffix only for `vector:` -- so `pcan:PCAN_USBBUS1,silent` and `pcan:PCAN_USBBUS1` would key
// as two different wires, and the refcounted single-open that issue #147 exists for would open
// one channel twice and lose a reader. Listen-only is a policy ON a wire, not part of its name,
// and this table is what keeps it out of the name.
//
// Process-wide, like sim's fault table and for the same reason: the GUI, a script and a CLI tool
// must not be able to disagree about whether a bus is allowed to transmit.

pub struct ListenTable {
mut:
	mu    sync.Mutex
	wires map[string]bool
}

// listen_tbl is THE listen-only table for the process. A global for the reason sim.injected is
// one: the side that decides (a project being applied) and the side that enforces (every open,
// down every call chain there is) would otherwise need a pointer threaded between them.
__global listen_tbl = &ListenTable{}

// wire_key names the WIRE this address reaches, with the bitrate removed -- one physical bus,
// however many rows point at it and whatever rate each asks for.
//
// NOT wire_key_for, and the difference is load-bearing. That one takes the project's `adapter`
// field, so code READING a foreign project can resolve a vendor name the local platform would
// not recognise, and it cuts at `@` unconditionally. Here the address is one we are about to
// open on THIS machine, and `@` is a bitrate suffix only on a vendor address: `inproc:bench@A`
// is a bus NAME, and cutting it there names a different hub than the one the operator marked.
pub fn wire_key(iface string) string {
	if vendor_iface(iface.trim_space()) {
		return vendor_destination_key(iface).all_before('@')
	}
	// UNTRIMMED on this path, deliberately. canonical_iface does not trim either, and says why:
	// the dispatcher does not, so `inproc:bench` and `inproc:bench ` are two separate hubs.
	// Trimming here would let one tick silence a bus nobody ticked.
	return canonical_iface(iface)
}

// set_listen_only marks (or unmarks) a wire. Called where a project is APPLIED, once per
// channel, rather than where a frame is sent.
pub fn set_listen_only(iface string, on bool) {
	k := wire_key(iface)
	listen_tbl.mu.lock()
	if on {
		listen_tbl.wires[k] = true
	} else {
		listen_tbl.wires.delete(k)
	}
	listen_tbl.mu.unlock()
}

// is_listen_only reports whether this wire refuses transmission.
pub fn is_listen_only(iface string) bool {
	k := wire_key(iface)
	listen_tbl.mu.lock()
	v := listen_tbl.wires[k] or { false }
	listen_tbl.mu.unlock()
	return v
}

// replace_listen_only swaps the WHOLE set under one lock.
//
// Not clear-then-set. Those are two locked operations with a gap between them, and a bus opened
// in that gap -- by a script worker, the shell, a replay spawn, anything holding no lock of its
// own -- reads an empty table and gets a transmitting bus for its whole lifetime. The window is
// microseconds and the consequence is a wire the operator ticked silent transmitting until Stop,
// which is the failure this whole change exists to remove.
pub fn replace_listen_only(ifaces []string) {
	mut next := map[string]bool{}
	for i in ifaces {
		next[wire_key(i)] = true
	}
	listen_tbl.mu.lock()
	listen_tbl.wires = next.move()
	listen_tbl.mu.unlock()
}

// clear_listen_only drops every mark. Used when a project is replaced -- a wire marked by the
// old one must not silence a new project that happens to reuse the interface, which is the same
// hazard sim.clear_all() exists for and the same answer.
pub fn clear_listen_only() {
	listen_tbl.mu.lock()
	listen_tbl.wires.clear()
	listen_tbl.mu.unlock()
}

// SilentBus is a bus that hears everything and says nothing.
//
// It REFUSES rather than silently dropping. A send that vanishes without a word is
// indistinguishable from a bus that is broken, and this repo has already paid for that once --
// #141 exists because a channel that failed to open said nothing. The error travels the path a
// refusal already travels: the trace marks the row NOT SENT, which is a state its legend
// already explains.
struct SilentBus {
mut:
	inner Bus
	iface string
}

fn (mut s SilentBus) send(frame CanFrame) ! {
	// ASKED NOW, not at open. See silenced() below for why the answer is not cached.
	if !is_listen_only(s.iface) {
		s.inner.send(frame)!
		return
	}
	return error('${s.iface}: listen-only — nothing is transmitted on this wire')
}

fn (mut s SilentBus) recv(timeout_ms int) !CanFrame {
	return s.inner.recv(timeout_ms)!
}

fn (mut s SilentBus) close() {
	s.inner.close()
}

fn (mut s SilentBus) health() BusHealth {
	return s.inner.health()
}

// silenced wraps every bus `open` hands out. ALWAYS, and the decision is deferred to the send.
//
// It used to wrap only wires marked at open time, which reads as the cheaper thing and is a
// different promise: it freezes the policy into the handle. Everything that changes the marks
// afterwards then cannot reach a bus that is already open -- enabling a listen-only row mid-run
// gives its fresh taps a writable bus, disabling one leaves the running taps refusing, and a Lua
// script (explicitly allowed to outlive Stop, holding its bus across a project edit) keeps
// transmitting on a wire the operator has since ticked silent. All three are the same bug
// (codex #164 r1, two P1s), and asking per send is the only version with no stale copy in it.
//
// The cost is one map read behind an uncontended mutex per frame. The replay dispatcher already
// takes an app-wide lock per frame for a comparable reason and records the arithmetic: tens of
// nanoseconds against a send, on a path already doing a syscall.
fn silenced(iface string, b Bus) Bus {
	return &SilentBus{
		inner: b
		iface: iface
	}
}
