module main

// When a wire goes quiet, nothing in the hardware says so (issue #156).
//
// CAN has no link detection — no carrier, no PHY link state — so to a RECEIVER a disconnected
// bus and an idle bus are bit-for-bit identical, on every vendor. A controller only learns
// something is wrong when it TRANSMITS and nobody acknowledges; a monitor-only channel can
// never be told its cable is out. Pulling a connector on the bench produced exactly that: the
// frames stopped and not one thing on screen changed.
//
// The only honest indicator left is at this level: messages that were arriving have stopped.
// That is what this file decides, and it is deliberately the whole policy in one place — the
// trace marks a row with it and the header counts it, and those two must never disagree about
// what "stale" means.

// Three cycles missed before a message is called stale: one late frame is traffic, three is a
// pattern. The floor matters more than the factor — at a 10 ms cadence three cycles is 30 ms,
// which is inside the jitter of a host-stamped arrival time (#149) and shorter than the gap
// between repaints, so without it a fast message would flicker between stale and fine and the
// marker would teach the reader to ignore it.
const stale_factor = 3.0
const stale_floor_ms = 500.0

// A cadence has to be OBSERVED this many times before absence means anything. The cycle column
// needs two frames to show a number; staleness needs more, because an event-driven message
// that legitimately fires twice and never again is not a fault, and reporting it as one is how
// a warning indicator becomes furniture.
const stale_min_samples = 5

// stale_threshold_ms is how long a message may be absent before it is called stale.
fn stale_threshold_ms(expected_ms f64) f64 {
	t := expected_ms * stale_factor
	return if t < stale_floor_ms { stale_floor_ms } else { t }
}

// expected_cycle_ms answers "how often SHOULD this message arrive?".
//
// The database first: `GenMsgCycleTime` is the specified cadence, and a message that is late
// against its own specification is the finding, whatever it has been doing lately. Failing
// that — the bench case that raised #156 ran with no DBC at all — the cadence actually
// observed, once there is enough of it to call the message cyclic. Zero means "not known to be
// cyclic", and nothing that returns zero can ever be reported stale.
fn expected_cycle_ms(dbc_cycle_ms int, observed_ms f64, samples int) f64 {
	if dbc_cycle_ms > 0 {
		return f64(dbc_cycle_ms)
	}
	if samples >= stale_min_samples && observed_ms > 0 {
		return observed_ms
	}
	return 0
}

// is_stale: has this message been absent for longer than its cadence allows?
fn is_stale(age_ms f64, expected_ms f64) bool {
	if expected_ms <= 0 {
		return false
	}
	return age_ms > stale_threshold_ms(expected_ms)
}

// --- the WIRE's verdict ---------------------------------------------------------------
//
// Per message is the evidence; per bus is the answer. Pulling one connector on the bench put
// STALE on five rows with the identical age — five statements of one fact, and the fact
// itself ("CAN1 went quiet 45 s ago") stated nowhere.
//
// Measured on the WIRE, not by aggregating the messages on it. That is not a shortcut: a bus
// is silent whether or not its rows are still in the trace ring, which is capped and filtered,
// and the wire's own first/last/count are three fields the RX loop already has in hand. It
// also means this needs no access to the trace at all, so the toolbar and the Buses panel can
// state it without the trace panel being open.

// quiet_ms is how long this wire has been silent, in ms — or 0 when it is not quiet.
//
// The threshold is the wire's own mean gap between frames, times the same factor a message
// gets, under the same floor. A bus carrying five messages at 100 ms has a mean gap of 20 ms,
// so the floor is what actually decides there — which is right: 500 ms of total silence on a
// bus that has never been silent that long IS the event, and waiting three mean gaps (60 ms)
// would fire on one late frame.
fn (app &App) quiet_ms(c Chan) f64 {
	if !app.staleness_live() || !c.running {
		return 0
	}
	// Same eligibility as a message: a wire has to have been talking before its silence means
	// anything. A bus that never carried traffic is not quiet, it is unused — and saying
	// otherwise about a correctly-configured listen-only wire is how an indicator gets ignored.
	if c.rx_seen < stale_min_samples {
		return 0
	}
	span := c.rx_last - c.rx_first
	mean_gap := if span > 0 { span / f64(c.rx_seen - 1) } else { f64(0) }
	age := app.since_ms() - c.rx_last
	if age > stale_threshold_ms(mean_gap) {
		return age
	}
	return 0
}

// quietest_wire names the wire that has been silent longest, with its silence in ms (0 = none
// is quiet). One line for the toolbar: with several buses down, the worst one is the headline
// and the Buses panel carries the rest.
fn (app &App) quietest_wire() (string, f64) {
	mut worst := f64(0)
	mut name := ''
	for c in app.chans {
		q := app.quiet_ms(c)
		if q > worst {
			worst = q
			name = c.name
		}
	}
	return name, worst
}

// stale_age is how long this group has been silent, in ms — or 0 when it is not stale, so the
// caller has one call to make and one thing to test. The cadence it is judged against is the
// database's if there is one, otherwise the one this group has actually been keeping, which is
// computed here from the SAME span and count the `cycle (ms)` column shows: the number on
// screen and the number the marker is decided by must be the same number.
fn stale_age(app &App, g GAgg) f64 {
	if !app.staleness_live() {
		return 0
	}
	span_ms := g.last.t_ms - g.first_t
	observed := if g.count >= 2 && span_ms > 0 { span_ms / f64(g.count - 1) } else { f64(0) }
	mut spec := 0
	if m := app.find_message(g.id, g.ext) {
		spec = m.cycle_ms
	}
	age := app.since_ms() - g.last.t_ms
	if is_stale(age, expected_cycle_ms(spec, observed, g.count)) {
		return age
	}
	return 0
}

// staleness_live reports whether absence means anything RIGHT NOW. It does not, unless a
// measurement is actually running: a paused capture and a loaded recording both hold rows whose
// timestamps recede from a clock that keeps going, so every row in them would turn stale a few
// seconds after it was opened — an alarm about a file, which is nonsense.
fn (app &App) staleness_live() bool {
	return app.running && !app.paused && app.viewing_rec == ''
}
