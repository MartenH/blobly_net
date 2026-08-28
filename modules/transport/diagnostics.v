module transport

// BusDiagnostics is what a backend knows that is neither a frame nor a rung on the health ladder
// (#213): records it dropped because nobody read fast enough, controller errors the device
// reported as records (an isolated ACK, CRC, bit, form or stuffing error), and records it could
// not decode (incompatible firmware). None of these belongs in health() -- its rungs are the
// controller's own fault ladder, and `warning` is defined as "error counters above 96", so
// synthesising it from a handful of error frames would report a register value the controller
// never had. COUNTS SINCE OPEN, monotonic for the life of one open, so a reader that polls can
// narrate what changed; a reopened backend starts again at zero, and a reader that sees a count
// fall knows that is what happened.
//
// Twice on #204 a review finding was answered by counting one of these and nothing ever read the
// count -- write-only state that looked like a fix and changed nothing observable. This is the
// seam those counts were waiting for: the GUI's RX loop polls it beside health, the Buses row
// shows it, the Log narrates it, and the headless runner prints it at close. COUNTS ONLY: the
// text of a first error rides the backend's own error message, where an operator is looking
// when a call has just failed; a value that is diffed once a second carries no strings.
pub struct BusDiagnostics {
pub mut:
	// dropped is frames lost before delivery: a receiver that fell behind, a driver overrun, a
	// hub ring overwritten under a slow cursor.
	dropped u64
	// bus_errors is controller error records the device reported. Not a fault-ladder rung.
	bus_errors u64
	// decode_errors is records the backend could not parse.
	decode_errors u64
}

pub fn (d BusDiagnostics) is_empty() bool {
	return d.dropped == 0 && d.bus_errors == 0 && d.decode_errors == 0
}

// plus folds two sources of one wire's diagnostics -- a hub's ring gaps with its driver's
// counters. Sums, because these are counts of distinct events, not two views of one event.
pub fn (d BusDiagnostics) plus(o BusDiagnostics) BusDiagnostics {
	return BusDiagnostics{
		dropped:       d.dropped + o.dropped
		bus_errors:    d.bus_errors + o.bus_errors
		decode_errors: d.decode_errors + o.decode_errors
	}
}

// minus is what is new in `d` since `o`, clamped at zero: a count that FELL is a backend that
// was reopened, and the caller asks `fell` about that rather than reading a wrapped delta.
pub fn (d BusDiagnostics) minus(o BusDiagnostics) BusDiagnostics {
	return BusDiagnostics{
		dropped:       if d.dropped > o.dropped { d.dropped - o.dropped } else { 0 }
		bus_errors:    if d.bus_errors > o.bus_errors { d.bus_errors - o.bus_errors } else { 0 }
		decode_errors: if d.decode_errors > o.decode_errors {
			d.decode_errors - o.decode_errors
		} else {
			0
		}
	}
}

// fell is whether any count in `d` is below the one in `o`: counts only grow for the life of an
// open, so this is a backend that has been reopened since `o` was read.
pub fn (d BusDiagnostics) fell(o BusDiagnostics) bool {
	return d.dropped < o.dropped || d.bus_errors < o.bus_errors || d.decode_errors < o.decode_errors
}

// The one vocabulary, walked by str and short: a fourth counter is one line here.
struct BusDiagnosticPart {
	n     u64
	long  string
	short string
}

fn (d BusDiagnostics) parts() []BusDiagnosticPart {
	return [
		BusDiagnosticPart{d.dropped, 'record(s) dropped — the receiver fell behind', 'dropped'},
		BusDiagnosticPart{d.bus_errors, 'controller error(s)', 'err'},
		BusDiagnosticPart{d.decode_errors, 'undecodable record(s)', 'undecoded'},
	]
}

// str is the sentence form, for the Log and an error message: empty when there is nothing to say.
pub fn (d BusDiagnostics) str() string {
	return d.parts().filter(it.n > 0).map('${it.n} ${it.long}').join('; ')
}

// short is the chip form for a Buses row: counts only, the sentence is the tooltip.
pub fn (d BusDiagnostics) short() string {
	return d.parts().filter(it.n > 0).map('${it.n} ${it.short}').join(' · ')
}
