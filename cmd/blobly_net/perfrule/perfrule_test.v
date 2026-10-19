module perfrule

const ms = u64(1_000_000)

// rd is a frame from begin_ms to end_ms, the collection count gc0 when its work began and gc1
// when it ended
fn rd(begin_ms u64, end_ms u64, gc0 u64, gc1 u64, alloc u64) Reading {
	return Reading{
		begin_ns:    begin_ms * ms
		end_ns:      end_ms * ms
		gc_begin:    gc0
		gc_no:       gc1
		alloc_total: alloc
		heap:        64 * 1048576
		free:        16 * 1048576
		since_gc:    1048576
	}
}

fn test_a_frame_is_a_gc_frame_only_if_the_collection_completed_in_its_work() {
	mut s := new_sampler(8)
	a := s.step(rd(0, 5, 41, 41, 0))
	assert !a.gc
	assert s.gcs == 0
	// collected while the thread waited for the next frame: counted, not blamed on the frame
	b := s.step(rd(16, 70, 42, 42, 0))
	assert !b.gc
	assert s.gcs == 1
	assert s.live_after_gc_mb == 48
	c := s.step(rd(80, 138, 42, 44, 0))
	assert c.gc
	assert s.gcs == 3
	assert c.work_ms == 58
	assert c.since_mb == 1
}

fn test_ring_keeps_the_newest_oldest_first() {
	mut s := new_sampler(3)
	for i in 0 .. 5 {
		s.step(rd(u64(i) * 10, u64(i) * 10 + 1, 0, 0, 0))
	}
	assert s.len() == 3
	assert s.at(0).t_s == 0.021
	assert s.at(2).t_s == 0.041
}

fn test_allocation_rate_is_averaged_over_its_window() {
	mut s := new_sampler(16)
	s.step(rd(0, 0, 0, 0, 0))
	// 100 ms in: not a window yet, so no rate
	assert s.step(rd(90, 100, 0, 0, 1048576)).alloc_mb_s == 0
	// 500 ms in: 5 MiB over half a second
	assert s.step(rd(490, 500, 0, 0, 5 * 1048576)).alloc_mb_s == 10
	// held until the next window closes
	assert s.step(rd(590, 600, 0, 0, 9 * 1048576)).alloc_mb_s == 10
}

fn test_summary_tells_collection_spikes_from_others() {
	mut s := new_sampler(16)
	s.step(rd(0, 5, 0, 0, 0))
	s.step(rd(10, 15, 0, 0, 0))
	s.step(rd(20, 80, 0, 1, 0)) // a 60 ms frame a collection completed in
	s.step(rd(90, 140, 1, 1, 0)) // a 50 ms frame with none: something else
	s.step(rd(150, 155, 1, 2, 0)) // a collection that cost nothing visible
	sm := s.summary(0.01, 33)
	assert sm.frames == 4
	assert sm.spikes == 2
	assert sm.gc_spikes == 1
	assert sm.gcs == 2
	assert sm.worst_ms == 60
	assert sm.worst_gc
	assert s.summary(0.1, 33).spikes == 1
}
