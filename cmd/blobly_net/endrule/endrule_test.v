module endrule

const begin = u64(1_000_000_000)

fn test_nothing_to_close_when_the_sampler_never_ran() {
	assert !final_interval(0, begin + settle_ns, begin, 0, 0).record
}

// A sampler admitted just before the close can publish a boundary AFTER it. That interval is
// already in the histogram; closing to an earlier endpoint would record a second, negative one.
fn test_a_boundary_at_or_past_the_endpoint_leaves_nothing_to_close() {
	end := begin + settle_ns
	assert !final_interval(end, end, begin, 0, 0).record
	assert !final_interval(end + 1, end, begin, 0, 0).record
}

fn test_the_interval_is_prev_to_the_endpoint_in_milliseconds() {
	end := begin + settle_ns
	c := final_interval(end - 250_000_000, end, begin, 0, 0)
	assert c.record
	assert c.ms == 250.0
	// and a sub-millisecond tail, which is what an ordinary run's last stretch is
	d := final_interval(end - 700_000, end, begin, 0, 0)
	assert d.record
	assert d.ms == 0.7
}

// THE CLASS #302 EXISTS FOR: a stop-the-world that begins inside the run and ends after it. The
// sampler wakes to a closed gate and cannot record it, so if this said "nothing to close" the
// worst sample a run can produce would be the one it always loses.
fn test_a_stall_crossing_the_endpoint_is_recorded_with_its_collection() {
	end := begin + settle_ns + u64(500_000_000)
	c := final_interval(end - 480_000_000, end, begin, 7, 8)
	assert c.record
	assert c.ms == 480.0
	assert c.collected
	assert c.sample_live
}

fn test_an_unchanged_count_is_not_a_collection() {
	end := begin + settle_ns
	c := final_interval(end - 1_000_000, end, begin, 7, 7)
	assert c.record
	assert !c.collected
	assert !c.sample_live // no collection, so no live figure to attribute to one
}

// The live set is a separate answer from the collection: before the settle delay a collection is
// still counted, but its live set says nothing about the steady state and is not sampled.
fn test_an_early_collection_counts_but_its_live_set_does_not() {
	end := begin + settle_ns - 1
	c := final_interval(end - 1_000_000, end, begin, 1, 2)
	assert c.record
	assert c.collected
	assert !c.sample_live
	// one nanosecond past the delay, it is sampled
	late := begin + settle_ns + 1
	d := final_interval(late - 1_000_000, late, begin, 1, 2)
	assert d.collected
	assert d.sample_live
}

// A wrapped or restarted counter is still "not the same count", which is all this asks.
fn test_any_change_in_the_count_is_a_collection() {
	end := begin + settle_ns + 1
	assert final_interval(end - 1000, end, begin, 4294967295, 0).collected
}
