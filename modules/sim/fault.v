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

// apply mangles an already-built payload. Returns false when the frame should not be sent.
//
// `e2e` is the message's protection, needed to know WHICH bits carry the checksum and the
// counter — corrupting a checksum means changing the field the receiver will recompute, not
// changing arbitrary bytes and hoping.
pub fn (f Fault) apply(msg candb.Message, e2e E2e, mut data []u8) bool {
	match f.kind {
		.none_ {
			return true
		}
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
		.freeze_ctr {
			// Nothing to do here: the caller holds the counter back by not advancing send_n,
			// which is what a stuck sender actually looks like on the wire. Re-stamping a
			// frozen value here would fight the protection that has already run.
			return true
		}
		.out_of_range {
			for sig in msg.active_signals(data) {
				if sig.name != f.signal {
					continue
				}
				// All ones is out of range for any signal whose DBC maximum is below its full
				// width, which is the ordinary case. Where a signal genuinely uses its whole
				// range there is no out-of-range value to send, and the fault is reported as
				// inapplicable rather than sending something valid and calling it a fault.
				sig.set_raw(mut data, mask_of(sig.length))
				break
			}
			return true
		}
	}
}

fn mask_of(bits int) u64 {
	return if bits >= 64 { ~u64(0) } else { (u64(1) << bits) - 1 }
}

// can_force_out_of_range reports whether the named signal HAS an out-of-range raw value.
//
// A signal using its full width has none: every encodable value is legal, so the fault would
// transmit something the receiver must accept. Better to say so than to inject nothing and
// leave the tester waiting for a reaction that cannot come.
pub fn can_force_out_of_range(msg candb.Message, name string) bool {
	for sig in msg.signals {
		if sig.name != name {
			continue
		}
		if sig.maximum == 0 && sig.minimum == 0 {
			return false // no declared range to exceed
		}
		return sig.phys_from_raw(mask_of(sig.length)) > sig.maximum
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
pub fn inject(node string, msg string, f Fault) {
	injected.set(fault_key(node, msg), f)
}

pub fn injected_fault(node string, msg string) Fault {
	return injected.get(fault_key(node, msg))
}

// apply_injected ages timed faults by `elapsed_ms` and stamps the table onto an engine.
//
// The ageing happens HERE, on the shared table, not on the engine's copy: the engine is
// re-stamped from the table every pass, so a countdown kept on the copy would be overwritten
// with its original value each time and a timed fault would never expire. That is exactly what
// happened — `tick` existed and nothing called it, so "drop for 500 ms" dropped forever.
pub fn apply_injected(mut e Engine) {
	injected.age_to(time.ticks())
	injected.apply_to(mut e)
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

// key names one message on one node: 'NodeName:MessageName'.
pub fn fault_key(node string, msg string) string {
	return '${node}:${msg}'
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
pub fn (mut t FaultTable) apply_to(mut e Engine) {
	t.mu.lock()
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
			k := '${e.ecus[i].name}:${e.ecus[i].messages[j].msg.name}'
			e.ecus[i].messages[j].fault = t.faults[k] or { Fault{} }
		}
	}
	t.mu.unlock()
}
