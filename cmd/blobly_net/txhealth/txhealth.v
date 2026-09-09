module txhealth

// WHICH WIRES DOES A RUN TRANSMIT ON WITHOUT EVER READING?
//
// Bus health — warning, error-passive, BUS-OFF — advances inside the driver and is polled by
// `rx_loop`, which exists only for a MONITORABLE row. A wire this app only writes to therefore
// has nobody asking: a generator targeting a bare wire (`bus: pcan:…@250000`, which #97 kept
// legal precisely because it names a wire no row mentions) can blast into a shorted bus and the
// app reports nothing at all. That is #142, and it is the case where the verdict matters most,
// because there is no traffic coming back to look wrong.
//
// The census is a SET DIFFERENCE and nothing more: the wires with a transmit tap, less the wires
// somebody reads. It is asked once a second by one watcher rather than baked into a list at
// Start, because both halves move while a run goes — a tap opens on a worker when a generator is
// added or retargeted (#257), and a reader is retired when its adapter fails (workers.v) — so a
// wire can become unread long after it was opened, which is exactly when it stops being narrated
// by anything else.
//
// DEDUPED BY WIRE, not by tap. A wire carries a NAMED tap per channel and a shared anonymous one,
// so the same bus arrives here several times and a naive walk would narrate one transition once
// per tap. And the key is the DESTINATION key, not the interface spelling: `vector:1` and
// `vector:ch1` are one transceiver, so a reader on either covers both.

// watched returns the wires to poll: the distinct entries of `taps` that no reader in `read`
// covers, in first-seen order.
//
// FIRST-SEEN ORDER, deliberately. The result drives Log narration, and a set whose order depended
// on a map walk would report the same two wires in a different order on every pass — which reads
// like something changed when nothing did.
pub fn watched(taps []string, read []string) []string {
	mut is_read := map[string]bool{}
	for r in read {
		if r != '' {
			is_read[r] = true
		}
	}
	mut seen := map[string]bool{}
	mut out := []string{}
	for t in taps {
		if t == '' || t in is_read || t in seen {
			continue
		}
		seen[t] = true
		out << t
	}
	return out
}
