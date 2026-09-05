module restorerule

// THE BORROW-AND-RESTORE LEDGER, AS RULES. vectorcheck borrows Vector application channels,
// points them at test hardware, and must put every one back — from a deferred cleanup, from a
// Ctrl-C handler on another thread, or from both racing each other — and then say truthfully
// what happened: clean, failed, or unknown because a restore was still in flight when the process
// had to end. #278 took four consecutive review rounds in exactly that path (who owns a record,
// what an empty claim means, what a timed-out wait may claim, what a handler that stalled leaves
// behind), because it lived among the driver calls in main.v where nothing tests it. Here it is
// pure state over plain inputs, the driver calls stay in main.v, and the rounds' interleavings are
// the test table — the shape ../../blobly_net/taprule set.

// Entry is one borrowed application channel as the ledger sees it: which channel, and what it
// is to be put back to — a hardware triple as text, or '' when it had no mapping and is to be
// cleared. What the FAIL line and the unknown-state report name.
pub struct Entry {
pub:
	app    int
	target string
}

// Ledger is the shared state. The caller holds ONE lock around every call; the ledger itself
// knows nothing about threads, which is what makes it testable.
pub struct Ledger {
pub mut:
	borrowed  []Entry // recorded, and not yet claimed by a restorer
	in_flight []Entry // claimed and being written back — the records an exit must still name
	restoring int // restorers at work: claims that have not finished
	failed    int // restores the driver refused
	closed    bool // no new borrows: the handler has taken its snapshot
}

// record books a borrow BEFORE the driver write, so a Ctrl-C between the two still knows to undo
// it (undoing a borrow never made restores what already is). Refused once the ledger is closed —
// the handler has snapshotted, and a borrow after that would be one nothing restores.
pub fn (mut l Ledger) record(e Entry) bool {
	if l.closed {
		return false
	}
	l.borrowed << e
	return true
}

// unrecord takes back a record whose driver write failed: there is nothing to restore.
pub fn (mut l Ledger) unrecord(app int) {
	for i, b in l.borrowed {
		if b.app == app {
			l.borrowed.delete(i)
			return
		}
	}
}

// close stops new borrows and hands back what the handler is to restore.
pub fn (mut l Ledger) close() []Entry {
	l.closed = true
	return l.borrowed.clone()
}

// claim gives a restorer the entries among `want` that nobody has claimed yet — EXACTLY ONCE
// PER CHANNEL, whoever gets there first — and, if it got any, counts it as a restorer at work
// with those entries in flight. An empty claim starts no flight: a count with no record behind
// it read as a restore that never finished (round 4).
pub fn (mut l Ledger) claim(want []Entry) []Entry {
	mut mine := []Entry{}
	for w in want {
		for i, b in l.borrowed {
			if b.app == w.app {
				mine << b
				l.borrowed.delete(i)
				break
			}
		}
	}
	if mine.len > 0 {
		l.restoring++
		l.in_flight << mine
	}
	return mine
}

// fail counts one restore the driver refused.
pub fn (mut l Ledger) fail() {
	l.failed++
}

// finish ends a claim: the restorer is done and its entries are no longer in flight, whether the
// writes succeeded or were counted by fail.
pub fn (mut l Ledger) finish(mine []Entry) {
	if mine.len == 0 {
		return
	}
	l.restoring--
	for m in mine {
		for i, f in l.in_flight {
			if f.app == m.app {
				l.in_flight.delete(i)
				break
			}
		}
	}
}

pub enum Outcome {
	clean
	failed // at least one restore was refused; the FAIL lines say which
	unknown // a restore is still in flight and this exit will end it
}

// Verdict is what an exit path says and exits with.
pub struct Verdict {
pub:
	outcome Outcome
	exit    int
	failed  int
	pending []Entry // the restores this exit ends, for the unknown outcome
}

// verdict decides an exit, after the caller has waited (bounded) for restorers to finish.
// UNKNOWN beats FAILED beats CLEAN: a restore still in flight makes even a counted failure the
// lesser news, because the exit ends a driver call mid-write and the assignment's state is then
// neither. Exit 3 for both bad outcomes — distinct from 1 (the test failed) and 2 (usage), since
// a wrapper that retries on 1 would borrow the misassigned channels again and cement them — and
// for the clean one 130 after an interrupt, 0 otherwise.
pub fn (l Ledger) verdict(interrupted bool) Verdict {
	if l.restoring > 0 {
		return Verdict{
			outcome: .unknown
			exit: 3
			failed: l.failed
			pending: l.in_flight.clone()
		}
	}
	if l.failed > 0 {
		return Verdict{
			outcome: .failed
			exit: 3
			failed: l.failed
		}
	}
	return Verdict{
		outcome: .clean
		exit: if interrupted { 130 } else { 0 }
	}
}
