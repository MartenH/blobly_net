// Fault injection: making a simulated ECU misbehave on purpose.
//
// Feeding an ECU correct traffic proves it works when everything else does. What a bench
// actually has to answer is the opposite question — does it notice when something is wrong,
// and does it do the right thing about it? That means provoking the failures a real network
// produces: a message that stops arriving, a checksum that does not match, a counter that
// stops advancing, a signal outside its declared range.
//
// End-to-end protection (e2e.v) is the precondition for half of this: a checksum cannot be
// corrupted before there is one to corrupt.
//
// Faults are applied to the frame LAST, after the generators have encoded it and after
// protection has stamped it, because that is the only order in which "corrupt the checksum"
// means what it says — a checksum computed over already-corrupted data is simply a valid
// checksum for different data, which the receiver accepts.
module sim

import candb
import sync
import time

// FaultKind is what to do to a message.
pub enum FaultKind {
	none_       // transmit normally
	drop        // do not transmit at all — provokes the receiver's timeout handling
	bad_crc     // transmit with the checksum inverted
	freeze_ctr  // transmit, but stop advancing the alive counter
	out_of_range // transmit with one signal forced outside its declared min/max
}

// Fault is one injected failure on one message.
//
// `remaining_ms` counts down when set, so a fault can be a burst rather than a permanent state:
// "drop this for three seconds and watch the DTC appear" is the common bench gesture, and a
// fault that has to be switched off by hand gets left on.
pub struct Fault {
pub mut:
	kind         FaultKind = .none_
	signal       string // which signal to force out of range (out_of_range only)
	remaining_ms int    // 0 = until switched off; >0 = expires after this long
}

// active reports whether this fault does anything.
pub fn (f Fault) active() bool {
	return f.kind != .none_
}

// tick expires a timed fault. Returns true while the fault is still in force.
pub fn (mut f Fault) tick(elapsed_ms int) bool {
	if f.kind == .none_ {
		return false
	}
	if f.remaining_ms <= 0 {
		return true // indefinite
	}
	f.remaining_ms -= elapsed_ms
	if f.remaining_ms <= 0 {
		f.kind = .none_
		f.remaining_ms = 0
		return false
	}
	return true
}

// apply_pre mutates the payload BEFORE protection is stamped.
//
// Only `out_of_range` belongs here, and the reason is the whole point of the fault: a signal
// forced past its limit must arrive with a VALID checksum, or the receiver rejects the frame as
// a checksum error and never reaches its range handling — the fault would test the opposite of
// what it claims. Corrupting the checksum is a different fault, and it goes after.
pub fn (f Fault) apply_pre(msg candb.Message, mut data []u8) {
	if f.kind != .out_of_range {
		return
	}
	for sig in msg.active_signals(data) {
		if sig.name != f.signal {
			continue
		}
		if v := illegal_raw(sig) {
			sig.set_raw(mut data, v)
		}
		break
	}
}

// apply_post mutates the payload AFTER protection. Returns false when the frame must not be
// sent at all.
pub fn (f Fault) apply_post(msg candb.Message, e2e E2e, mut data []u8) bool {
	match f.kind {
		.drop {
			return false
		}
		.bad_crc {
			// Invert the checksum field. Inverting rather than zeroing because zero is a
			// legitimate checksum value: a receiver that happened to compute 0 would accept
			// the "corrupted" frame and the test would silently pass.
			for sig in msg.active_signals(data) {
				if sig.name == e2e.crc && e2e.crc != '' {
					sig.set_raw(mut data, ~sig.raw_value(data) & mask_of(sig.length))
					break
				}
			}
			return true
		}
		else {
			// freeze_ctr is handled by the caller holding the E2E counter back, which is what
			// a stuck sender looks like; out_of_range has already been applied pre-protection.
			return true
		}
	}
}

fn mask_of(bits int) u64 {
	return if bits >= 64 { ~u64(0) } else { (u64(1) << bits) - 1 }
}

// illegal_raw returns a raw value that decodes OUTSIDE the signal's declared range, or none.
//
// Both extremes are considered, because for a SIGNED signal all-ones decodes as -1 — inside
// almost any range — while the largest positive value sits at 0x7F.., and for a signal
// declared `[-10|10]` it is the positive extreme that violates. Testing only the maximum
// rejected signals that plainly do have an illegal endpoint.
pub fn illegal_raw(sig candb.Signal) ?u64 {
	if sig.minimum == 0 && sig.maximum == 0 {
		return none // no declared range to exceed
	}
	full := mask_of(sig.length)
	// BOTH raw endpoints, whatever the signedness. A negative factor puts the physical maximum
	// at raw ZERO — an 8-bit unsigned signal with factor -1, offset 255 and range [0|200] has
	// its illegal value at raw 0, not at 0xFF — so testing all-ones alone reported "no illegal
	// value" for a signal that plainly has one.
	mut candidates := [full, u64(0)]
	if sig.is_signed && sig.length >= 2 {
		candidates << full >> 1 // largest positive
		candidates << (full >> 1) + 1 // most negative
	}
	for c in candidates {
		v := sig.phys_from_raw(c)
		if v > sig.maximum || v < sig.minimum {
			return c
		}
	}
	return none
}

// can_force_out_of_range reports whether this signal can actually carry a range violation onto
// the wire — which is more than "an illegal value exists for it".
//
// `e2e` is the message's protection, because a violation written into the counter or checksum
// field is overwritten moments later when protection is stamped: the frame goes out perfectly
// valid and the fault silently tests nothing.
pub fn can_force_out_of_range(msg candb.Message, name string, e2e E2e) bool {
	if name == '' || name == e2e.counter || name == e2e.crc {
		return false
	}
	for sig in msg.signals {
		if sig.name != name {
			continue
		}
		if sig.is_multiplexed {
			// only present when its selector is active, and apply_pre writes only active
			// signals — so this may never reach the wire at all
			return false
		}
		illegal_raw(sig) or { return false }
		return true
	}
	return false
}

// injected is THE fault table for the process.
//
// A global because the two sides that must agree — the Lua primitive that injects and the
// simulation loop that applies — are reached through different call chains that would
// otherwise both need a pointer threaded through them. The in-process bus is already a
// process-wide singleton for the same reason, and the repo builds with -enable-globals.
__global injected = &FaultTable{}

// inject / clear_injected / apply_injected are the process-wide fault table's public face.
//
// Functions rather than an exported variable because V does not export globals across modules
// — and it reads better anyway: the two sides that must agree, the injector and the simulation
// loop, name the same operation instead of both reaching into shared state.
pub fn inject(iface string, node string, msg string, f Fault) {
	injected.set(fault_key(iface, node, msg), f)
}

pub fn injected_fault(iface string, node string, msg string) Fault {
	return injected.get(fault_key(iface, node, msg))
}

// clear_all drops every injected fault — used when a project is replaced, so a fault armed
// against the old one does not silently apply to a new project that happens to reuse a name.
pub fn clear_all() {
	injected.clear()
}

// apply_injected ages timed faults by `elapsed_ms` and stamps the table onto an engine.
//
// The ageing happens HERE, on the shared table, not on the engine's copy: the engine is
// re-stamped from the table every pass, so a countdown kept on the copy would be overwritten
// with its original value each time and a timed fault would never expire. That is exactly what
// happened — `tick` existed and nothing called it, so "drop for 500 ms" dropped forever.
pub fn apply_injected(iface string, mut e Engine) {
	injected.age_to(time.ticks())
	injected.apply_to(iface, mut e)
}

// FaultTable is a fault set shared between whoever injects faults and the loop that applies
// them. Held behind a mutex because a script writes it from one thread while the simulation
// reads it from another, and a fault arriving mid-frame must not tear.
pub struct FaultTable {
mut:
	mu      sync.Mutex
	faults  map[string]Fault
	last_ms i64 // wall clock at the last ageing, 0 = not started
}

// fault_key names one message on one node ON ONE BUS.
//
// The interface is part of the identity because a multi-bus project may run the same node and
// message names on two channels: without it, dropping `Gateway/Status` dropped it everywhere
// and invalidated observations on a network nobody was testing.
pub fn fault_key(iface string, node string, msg string) string {
	return '${iface}:${node}:${msg}'
}

pub fn (mut t FaultTable) set(key string, f Fault) {
	t.mu.lock()
	t.faults[key] = f
	t.mu.unlock()
}

pub fn (mut t FaultTable) get(key string) Fault {
	t.mu.lock()
	f := t.faults[key] or { Fault{} }
	t.mu.unlock()
	return f
}

// age_to ages the table to a wall-clock instant, and is IDEMPOTENT across callers.
//
// Every simulation loop calls this, one per bus. Taking an elapsed-time argument made each
// loop subtract the same interval again, so a two-bus project aged every timed fault twice as
// fast and a "drop for 1500 ms" lasted 750. The table owns the clock instead: whoever calls
// first advances it, everyone else sees zero elapsed and changes nothing.
pub fn (mut t FaultTable) age_to(now_ms i64) {
	t.mu.lock()
	if t.last_ms == 0 {
		t.last_ms = now_ms
		t.mu.unlock()
		return
	}
	elapsed_ms := int(now_ms - t.last_ms)
	if elapsed_ms <= 0 {
		t.mu.unlock()
		return
	}
	t.last_ms = now_ms
	// Two passes: V's map iteration hands out a COPY, so ticking in place updated nothing, and
	// deleting while iterating is not safe either. Compute, then write.
	mut expired := []string{}
	mut updated := map[string]Fault{}
	for k, f in t.faults {
		mut c := f
		if c.tick(elapsed_ms) {
			updated[k] = c
		} else {
			expired << k
		}
	}
	for k, f in updated {
		t.faults[k] = f
	}
	for k in expired {
		t.faults.delete(k)
	}
	t.mu.unlock()
}

// apply_to stamps the current table onto an engine — called after each rebuild, and cheap
// enough to call every loop iteration.
pub fn (mut t FaultTable) clear() {
	t.mu.lock()
	t.faults.clear()
	t.mu.unlock()
}

pub fn (mut t FaultTable) apply_to(iface string, mut e Engine) {
	t.mu.lock()
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
			k := '${iface}:${e.ecus[i].name}:${e.ecus[i].messages[j].msg.name}'
			e.ecus[i].messages[j].fault = t.faults[k] or { Fault{} }
		}
	}
	t.mu.unlock()
}
