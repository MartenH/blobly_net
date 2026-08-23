module main

import transport

// How long has this wire been silent? (issue #156)
//
// CAN has no link detection — no carrier, no PHY link state — so to a RECEIVER a disconnected
// bus and an idle bus are bit-for-bit identical, on every vendor. A controller only learns
// something is wrong when it TRANSMITS and nobody acknowledges; a monitor-only channel can
// never be told its cable is out. Pulling a connector on the bench produced exactly that: the
// frames stopped and not one thing on screen changed.
//
// THIS REPORTS A FACT AND MAKES NO JUDGEMENT, and that is the whole design.
//
// Three successive attempts here tried to decide whether silence was a FAULT, and review took
// each one apart with the same counter-example: a message seen five times, then a wire seen
// five times, then a wire seen five times over two seconds with its worst gap remembered. Five
// diagnostic requests a second apart defeat all three. They had to, because the question is not
// answerable from timing alone — "traffic that stopped" and "traffic that finished" look
// identical on the wire, and no amount of observation separates them. Only a DECLARATION can:
// a DBC's GenMsgCycleTime says a message is expected every N ms, and a wire carrying one is
// expected to keep talking.
//
// So this states the observation — "last frame 45 s ago" — and leaves the verdict to whoever
// has the declaration. On a bus with a DBC that is a real alarm somebody can build; on the
// bench that raised #156, which runs with no database at all, the fact alone is already the
// answer, because CAN1 reading `last RX 45s` beside CAN2 reading `0.1s` IS the disconnection.
//
// The controller's fault ladder is the other half and is NOT this: that one is the driver
// reporting a real fault, so it stays a warning, in colour. See worst_wire_health.

// Below this, silence is just a gap between frames and not worth a line of chrome. A display
// threshold, deliberately not a diagnosis: nothing above it is claimed to be wrong.
const silence_notice_ms = 2000.0

// silent_ms is how long this wire has been silent, in ms — 0 when it has never received, when
// the gap is too short to mention, or when silence cannot mean anything (see staleness_live).
//
// Takes the DESTINATION's folded state, not a row's own: only the reader-owning alias records
// frames, so a row-by-row answer would leave every other alias of one wire looking fine while
// the wire it names is dead — the defect DestState.health exists to prevent.
fn (app &App) silent_ms(st DestState) f64 {
	if !app.staleness_live() || !st.read || st.rx_seen == 0 {
		return 0
	}
	age := app.since_ms() - st.rx_last
	return if age > silence_notice_ms { age } else { 0 }
}

// quietest_wire names the wire silent longest, with that silence in ms (0 = none worth
// mentioning). One line for the toolbar; the Buses panel carries the rest.
//
// Takes the frame's SNAPSHOT of the rows, like every other panel: the RX workers write these
// fields under app.mu, and reading the live array past the clone the frame already took races
// them. Names a RUNNING alias — folding is by destination, so a disabled row shares its key
// with the enabled one that supplied the state, and naming the disabled row would point at a
// channel the operator can see is off.
fn (app &App) quietest_wire(chans []Chan) (string, f64) {
	dests := read_destinations(chans)
	mut worst := f64(0)
	mut name := ''
	for c in chans {
		if !c.enabled || !c.running {
			continue
		}
		st := dests[transport.destination_key(c.iface)] or { continue }
		q := app.silent_ms(st)
		if q > worst {
			worst = q
			name = c.name
		}
	}
	return name, worst
}

// staleness_live reports whether silence means anything RIGHT NOW. It does not unless a
// measurement is actually running: a paused capture and a loaded recording both hold state whose
// timestamps recede from a clock that keeps going, so every wire would look silent a few seconds
// after it was opened — a statement about a file, which is nonsense.
fn (app &App) staleness_live() bool {
	return app.running && !app.paused && app.viewing_rec == ''
}
