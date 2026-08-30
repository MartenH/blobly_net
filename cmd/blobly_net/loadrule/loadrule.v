// loadrule: WHAT A WIRE'S LOAD SECOND IS MADE OF, per row state — the rule behind the Buses
// row's strip and number, GUI-free so a test can reach it. Codex #263 landed findings in this
// one path four rounds running (r3 unmonitored zeros, r4 owner window, r5 spawning rolled as
// idle, r6 the spawning-to-running rebase), which is the repeat rule's signal: the path was
// being designed one repair at a time in a file nothing tests. The bit-times themselves are
// transport.busload's; this is only when an interval closes and what happens to the one in
// progress.
module loadrule

// Owner is what the row is to its wire right now.
pub enum Owner {
	// nobody reads this wire through this row: disabled, failed to open, between runs
	unread
	// a reader is on its way up and has not opened the bus
	spawning
	// the reader runs
	running
}

// Wire is a row's load state: the interval in progress and the history behind it.
pub struct Wire {
pub mut:
	// nominal bit-times seen on the wire since `at`
	bits f64
	// when the interval in progress opened, ms; 0 = not yet
	at f64
	// the last closed interval, percent
	pct f32
	// the last `keep` closed intervals, oldest first
	hist []f32
	// what a handoff left unclosed — bits and the milliseconds they were seen over — folded
	// into the next interval this row closes, so a partial interval is never a sample of
	// its own (codex #263 r11) and never lost (r7, r9)
	carry_bits f64
	carry_ms   f64
}

// keep is how many closed intervals the strip shows.
pub const keep = 60

// interval_ms is how long an interval runs before it closes.
pub const interval_ms = 1000.0

// Percent turns an interval's bits and its length into a load percentage — the caller's
// transport.load_percent, passed in so this module imports nothing from modules/ (the CI test
// line resolves no -path) and the formula lives in one place.
pub type Percent = fn (bits f64, ms i64) f32

// roll advances `w` to `now` for a row in state `owner`, and reports whether an interval
// closed.
//
//   unread    — a wire nobody reads has no load to report: interval AND history go, so a gap
//               nobody observed cannot come back as an idle trough when the row is re-enabled.
//   spawning  — the reader has not opened the bus, so nothing it would have read is in the
//               bits; nothing closes. The interval is REBASED to now each time, so the first
//               interval closed once the reader runs starts where the spawn ended and not at
//               Start — a slow open (a CANsub's, a reconnect's) would otherwise dilute the
//               first sample into idle time. The sends filed onto the row meanwhile STAY and
//               land in that first interval: they were on the wire.
//   running   — closes an interval once `interval_ms` has passed, into `pct` and `hist`.
pub fn roll(mut w Wire, owner Owner, now f64, pct Percent) bool {
	match owner {
		.unread {
			w.bits = 0
			w.at = now
			w.carry_bits = 0
			w.carry_ms = 0
			if w.hist.len > 0 {
				w.hist = []f32{}
				w.pct = 0
			}
			return false
		}
		.spawning {
			w.at = now
			return false
		}
		.running {
			if w.at == 0 {
				w.at = now
				return false
			}
			elapsed := now - w.at
			if elapsed < interval_ms {
				return false
			}
			// plus whatever a handoff left unclosed, over the time it covered
			w.pct = pct(w.bits + w.carry_bits, i64(elapsed + w.carry_ms))
			w.carry_bits = 0
			w.carry_ms = 0
			w.hist << w.pct
			if w.hist.len > keep {
				w.hist.delete(0)
			}
			w.bits = 0
			w.at = now
			return true
		}
	}
}

// handoff moves the interval in progress across when a wire's reader moves to another row:
// what the outgoing reader measured — bits, and the milliseconds it watched them over — is
// CARRIED into the next interval the successor closes rather than closed as a sample of its
// own. Carried as bits alone, they were rebased through the successor's spawn and divided by
// its first second — 900 ms of traffic read as a spike in an idle second (codex #263 r7); an
// idle stretch carries as zero bits over its time, so it is still observed (r9); and closed as
// a sample, a 100 ms interval took a full column of a strip labelled sixty seconds (r11). The
// successor's first sample is a little longer than a second and true.
pub fn handoff(mut w Wire, now f64) {
	if w.at > 0 && now > w.at {
		w.carry_bits += w.bits
		w.carry_ms += now - w.at
	}
	w.bits = 0
	w.at = now
}
