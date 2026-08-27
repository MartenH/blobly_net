module transport

import sync

// silence.v — what each WIRE's transceiver was last told, and who has to tell it.
//
// WHY THIS IS NOT A FIELD ON THE BUS. Listen-only at the transceiver is a property of the
// CHANNEL, not of a handle: `canSetBusOutputControl` and `CAN_SetValue(PCAN_LISTEN_ONLY)` both
// configure the controller, and every handle open on that wire sees the result. Remembering it
// per bus therefore gets two things wrong at once, in opposite directions:
//
//   - TOO MANY WRITES. The app opens each wire several times per Start (a reader, transmit taps,
//     a diagnostics bus), and on Kvaser a mode change must be bracketed by canBusOff/canBusOn —
//     so one operator tick became one bus bounce per handle, each of them dropping traffic, to
//     apply a setting the first one had already applied.
//   - TOO FEW. A handle that is only ever SENT on never reaches its own reconcile, so on a wire
//     with no reader nothing would notice a mark being lifted and the controller stayed silent
//     while `send` reported success (self-review of #219).
//
// Keyed by wire and consulted by every entry point instead, both stop being possible: whichever
// handle touches the wire first does the write, once, and the rest see it is done.
//
// EMPTY AT PROCESS START, WHICH IS THE POINT. The controller's mode outlives the process that set
// it — Kvaser's `canClose` does not reset it (measured; PCAN's `CAN_Uninitialize` does) — so a run
// that ended while a wire was marked leaves the next one opening a channel that is already silent,
// with no mark to say so. An empty table means the first claim on every wire ALWAYS writes,
// whatever the answer, which is exactly the reconciliation that case needs.
struct SilenceApplied {
mut:
	mu    sync.Mutex
	wires map[string]bool
}

// silence_applied is process-wide for the reason listen_tbl is: the side that decides and the
// sides that carry it out are several call chains apart, and a pointer threaded between them
// would have to reach every backend's open.
__global silence_applied = &SilenceApplied{}

// claim_silence answers whether the CALLER is the one that must tell this wire's controller about
// `want`, and records that it is about to.
//
// RECORDED BEFORE THE CALL, NOT AFTER, so two threads reaching the same change do not both
// reconfigure the wire — the second is told it is already handled. The driver call itself happens
// outside the lock: #211 tracks what holding a process-wide lock across I/O costs, and this write
// is idempotent, so there is nothing to buy by serialising it.
//
// A caller that claims and then FAILS must say so with `release_silence_claim`, or the wire is
// recorded as being in a state it never reached.
pub fn claim_silence(iface string, want bool) bool {
	k := wire_key(iface)
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	if have := silence_applied.wires[k] {
		if have == want {
			return false
		}
	}
	silence_applied.wires[k] = want
	return true
}

// release_silence_claim undoes a claim whose driver call did not succeed.
//
// It makes the wire UNKNOWN again rather than restoring the previous value, because a failed
// reconfiguration leaves the controller in a state nobody measured. Unknown is the honest record
// and it is also the useful one: the next caller writes unconditionally instead of comparing
// against a guess.
//
// Guarded on the value, so a claim that has since been superseded by a different one is not
// erased by a straggler reporting an old failure.
pub fn release_silence_claim(iface string, want bool) {
	k := wire_key(iface)
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	if have := silence_applied.wires[k] {
		if have == want {
			silence_applied.wires.delete(k)
		}
	}
}

// forget_silence_claims drops every record, so the next claim on any wire writes.
//
// For tests, and for anything that has reason to believe the controllers were reconfigured behind
// this process's back. Not called on close: the mode survives a handle, so what was applied is
// still what the wire is doing.
pub fn forget_silence_claims() {
	silence_applied.mu.lock()
	defer {
		silence_applied.mu.unlock()
	}
	silence_applied.wires.clear()
}
