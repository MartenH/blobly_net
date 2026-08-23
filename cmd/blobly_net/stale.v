module main

import transport

// When a wire goes quiet, nothing in the hardware says so (issue #156).
//
// CAN has no link detection — no carrier, no PHY link state — so to a RECEIVER a disconnected
// bus and an idle bus are bit-for-bit identical, on every vendor. A controller only learns
// something is wrong when it TRANSMITS and nobody acknowledges; a monitor-only channel can
// never be told its cable is out. Pulling a connector on the bench produced exactly that: the
// frames stopped and not one thing on screen changed.
//
// The only honest indicator left is that traffic which was arriving has stopped, and this file
// is the whole of that policy.
//
// PER WIRE, not per message. An earlier version of this also marked individual messages STALE,
// inferring a cadence from the DBC or from what a message had been doing. Review found six
// separate ways for that to raise a false alarm — an event-driven id seen five times, an RTR
// request inheriting its data message's cycle, a group whose frames were all refused, a text
// filter hiding the newest frames, the same id defined differently on two buses, and resuming a
// pause — and they were not six bugs so much as one wrong foundation: it measured the TRACE
// VIEW, which is filtered, capped, origin-split and pausable, none of which a measurement
// should depend on. The wire's own counters have none of those properties. Message-level
// staleness is worth having, but it has to be built on the unfiltered stream with its own
// tests, not bolted to the panel that displays it.

// Three cycles missed before a wire is called quiet: one late frame is traffic, three is a
// pattern. The floor matters more than the factor — on a bus carrying five messages at 100 ms
// the mean gap is 20 ms, and three of those is inside the jitter of a host-stamped arrival time
// (#149) and shorter than the gap between repaints, so without it the verdict would flicker and
// teach the reader to ignore it.
const stale_factor = 3.0
const stale_floor_ms = 500.0

// RECURRENCE, not a count. Silence is only evidence of a fault on a wire that has shown itself
// to carry traffic regularly, and "five frames arrived" does not show that: five frames of one
// diagnostic burst, milliseconds apart, gave a tiny mean gap and had the toolbar declaring a
// perfectly healthy event-driven bus quiet forever half a second later. That false-positive
// class survived the rewrite from per-message to per-wire — codex found it on both — so it is
// answered here, at the class, rather than at either symptom.
//
// Three things must hold, and each rules out a different impostor:
//   samples  — one frame has no gap to measure at all
//   window   — a burst is not a cadence: five frames in 40 ms say nothing about what this wire
//              does over seconds, so it has to have been talking for a real interval first
//   max gap  — silence is measured against the LONGEST gap this wire has actually left, not its
//              mean. A bus that regularly pauses three seconds between bursts is not broken at
//              four; the mean would have accused it at half a second.
const stale_min_samples = 5
const stale_min_window_ms = 2000.0

// stale_threshold_ms is how long a wire may be silent before it is called quiet: a multiple of
// the worst silence it has already shown, never below the floor.
fn stale_threshold_ms(worst_gap_ms f64) f64 {
	t := worst_gap_ms * stale_factor
	return if t < stale_floor_ms { stale_floor_ms } else { t }
}

// quiet_ms is how long this wire has been silent, in ms — or 0 when it is not quiet.
//
// Takes the DESTINATION's folded cadence, not a row's own. Only the reader-owning alias records
// frames, so a row-by-row answer would leave every other alias of one wire looking healthy
// while the wire it names is dead — the exact defect DestState.health exists to prevent, and
// the reason `down` was folded here before it.
fn (app &App) quiet_ms(st DestState) f64 {
	if !app.staleness_live() || !st.read {
		return 0
	}
	if st.rx_seen < stale_min_samples {
		return 0
	}
	if st.rx_last - st.rx_first < stale_min_window_ms {
		return 0 // a burst, not a cadence
	}
	age := app.since_ms() - st.rx_last
	if age > stale_threshold_ms(st.rx_max_gap) {
		return age
	}
	return 0
}

// quietest_wire names the wire that has been silent longest, with its silence in ms (0 = none
// is quiet). One line for the toolbar: with several buses down, the worst one is the headline
// and the Buses panel carries the rest.
//
// Takes the frame's SNAPSHOT of the rows, like every other panel: the RX workers write
// health/running/link_down and now the cadence fields under app.mu, and reading the live array
// past the clone the frame already took races them.
//
// Names a RUNNING alias. Folding is by destination, so a disabled row shares its key with the
// enabled one that supplied the state — and naming the disabled row would blame a channel the
// operator can see is off.
fn (app &App) quietest_wire(chans []Chan) (string, f64) {
	dests := read_destinations(chans)
	mut worst := f64(0)
	mut name := ''
	for c in chans {
		if !c.enabled || !c.running {
			continue
		}
		st := dests[transport.destination_key(c.iface)] or { continue }
		q := app.quiet_ms(st)
		if q > worst {
			worst = q
			name = c.name
		}
	}
	return name, worst
}

// staleness_live reports whether absence means anything RIGHT NOW. It does not, unless a
// measurement is actually running: a paused capture and a loaded recording both hold state whose
// timestamps recede from a clock that keeps going, so everything would turn quiet a few seconds
// after it was opened — an alarm about a file, which is nonsense.
fn (app &App) staleness_live() bool {
	return app.running && !app.paused && app.viewing_rec == ''
}
