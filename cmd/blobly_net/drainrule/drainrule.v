module drainrule

// WHEN MAY THE RUNTIME VIEW BE REPLACED? `rebuild_from_proj` swaps app.chans, app.dbs,
// app.sims and app.senders wholesale, and the workers iterate those arrays lock-free. The
// question to ask first is "is anyone still reading", and app.running USED to be the wrong
// answer to it: stop() cleared the flag, closed the buses and RETURNED while every worker it
// ended was still on its way out — inside a 200 ms recv, a driver close, or a last batch — so
// `!running` was true for a window in which a rebuild freed what a live worker was reading.
// Measured on sim-demo, that window had nine workers in it, every run.
//
// That window is #107 and the second half of #125, and it is also what the DBC editor and the
// System panel each discovered separately and each answered with their own copy of the check
// (codex #65 r4, #133 r3).
//
// THE FIX IS THAT THE REBUILD NOW WAITS — rebuild_from_proj drains the run's workers before it
// touches anything, so every caller's `!running` check leads somewhere safe and none of them had
// to learn a new question. Not in stop(), which would put the wait on the GUI thread for every
// Stop; the rebuild is the operation the drain exists for and the one that can afford it. Two designs were tried and taken apart by review first: gating each affordance that
// leads to a rebuild (it missed four, and gave Save a way to go silently stale), and deferring
// the rebuild (its own window — app.proj new, app.chans old — broke the index alignment the
// Buses tick and start() rely on). Both were the same mistake in different clothes: keeping the
// window and teaching more code about it, instead of closing it. The drain costs ~200 ms on
// Stop, nearly all of it rx_loop's own recv timeout.
//
// What is left for this rule to answer is the case the drain deliberately does NOT cover: a Lua
// script reads the same arrays, is not part of a run, is allowed to outlive Stop and can run for
// minutes, so stop() must not wait for one. That is the pre-existing case the two panels have
// always gated on, stated once here — the shape ../saverule set for Save (#250) and ../taprule
// for the tap lifecycle (#260).
//
// The census this reads is reserved by the SPAWNING thread and released by the worker: see
// App.run_workers for why a worker cannot be trusted to count itself.

// Census is the runtime as the rules see it: is a run on, and how many workers still hold the
// runtime view. Nothing here knows what a channel or a database is — that is the point.
pub struct Census {
pub:
	running bool
	readers int
}

// may_rebuild reports whether the runtime view may be replaced right now.
//
// BOTH CONDITIONS, and neither implies the other. `running` alone misses the drain window
// above; a census of zero alone would permit a rebuild in the middle of a healthy run, before
// any worker has registered — at Start the spawner reserves as it goes, so there is an instant
// where the run is on and the census is still climbing.
//
// `<= 0`, not `== 0`, so this and why() cannot disagree about a count below zero. Neither should
// ever see one — every reservation is paired — but a verdict of "unsafe" beside a text saying
// "nothing is in the way" is a contradiction nobody would think to test for, and the two are
// read together at the one call site.
pub fn (c Census) may_rebuild() bool {
	return !c.running && c.readers <= 0
}

// why states, for a human, what is in the way — '' when nothing is. One text, so the menu's
// greyed-out label, the refusal a caller notifies with and the Log line cannot drift apart.
//
// The two states read differently on purpose. A run in progress is a thing the operator did
// and can undo (Stop); a held slot is a thing they are waiting out, and saying "stop first" to
// someone who has already pressed Stop is an instruction they cannot act on.
//
// AND THE SECOND TEXT DOES NOT SAY WHY THE SLOT IS HELD, because the census does not know. It
// is usually a run that has been stopped and whose workers have not finished, but a Lua script
// holds one for as long as it runs, and telling somebody with a script running that "the
// previous run is still shutting down" is a confident wrong answer about the one thing they
// cannot check. What every holder does have in common is the only thing claimed here.
pub fn (c Census) why() string {
	if c.running {
		return 'stop the measurement first'
	}
	if c.readers > 0 {
		return '${c.readers} background worker${plural(c.readers)} still using this project'
	}
	return ''
}

fn plural(n int) string {
	return if n == 1 { '' } else { 's' }
}
