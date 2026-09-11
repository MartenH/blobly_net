module endrule

// THE END OF A MEASUREMENT, AS A RULE. The probe's hiccup histogram claims that every instant
// between the start and the endpoint lies inside exactly one interval, and the last one is the
// awkward one: the sampler cannot record it (waking to a closed gate, it may not write — that is
// the race #299 round 5 closed), so the driver closes it after every admitted writer has left.
//
// EXTRACTED BECAUSE IT WAS REPAIRED SIX TIMES IN ONE REVIEW (#302, codex rounds 1-6): closing to
// the wrong endpoint so it never fired at all, a sampler's interval running past the close, a
// collection counted without its live set, a live set read after the drain, a snapshot split by
// a collection, and the order of the reads that make up that snapshot. Every one was a question
// about what this function should do with the numbers it is given, and none of them could be
// asked of it directly, because it read globals and wrote globals inside the GUI's main package.
// The guide's own rule: cover a path rather than patch it a seventh time.
//
// Pure, so the scenarios are the test. The caller owns the counters and the bucket table.

// Close is what the final interval contributes, or `record: false` when there is nothing to add.
pub struct Close {
pub:
	// record is false when there is no interval left to close: either the sampler never ran, or
	// it published a boundary at or after the endpoint. A sampler admitted just before the close
	// can publish just after it, and that interval is already counted.
	record bool
	// ms is the interval's length, for the caller to bucket with its own edges.
	ms f64
	// collected says a collection happened across the interval. Compared against the count
	// SNAPSHOTTED at the endpoint, never one read later: the driver's inflight drain sits between
	// the two, and a collection during it is outside this interval.
	collected bool
	// sample_live says to fold the endpoint live set into the live-after-GC extrema. Only with a
	// collection — the figure is meaningless without one — and only past `settle_ns`, the same
	// delay the sampler applies, so a startup collection is not sampled by either.
	//
	// It is a SEPARATE answer from `collected` on purpose. A run whose only observed collection
	// was the endpoint one used to report `hic_with_gc=1` beside `collections_sampled=0` and no
	// live figures at all — a summary disagreeing with itself about whether a collection
	// happened (codex round 3 on #302).
	sample_live bool
}

// settle_ns is how long after the start a collection has to happen before its live set is worth
// recording: a young heap collecting for the first time says nothing about the steady state.
pub const settle_ns = u64(10_000_000_000)

// final_interval answers what the driver should record for the stretch from `prev` — where the
// sampler's last COMPLETE interval ended — to `closed_ns`, the endpoint.
//
// `gc_prev` is the collection count as of `prev`, `gc_closed` the count snapshotted at the
// endpoint. `begin_ns` is the start of the measurement.
pub fn final_interval(prev u64, closed_ns u64, begin_ns u64, gc_prev u32, gc_closed u32) Close {
	if prev == 0 || closed_ns <= prev {
		return Close{}
	}
	collected := gc_closed != gc_prev
	return Close{
		record:      true
		ms:          f64(closed_ns - prev) / 1e6
		collected:   collected
		sample_live: collected && closed_ns - begin_ns > settle_ns
	}
}
