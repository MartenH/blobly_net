// perfrule — the Performance panel's numbers: one sample per rendered frame, kept in a fixed
// ring, and what a window of them says. Pure: the caller reads the clock and the collector and
// hands the readings in, so the rules are tested on synthetic time.
module perfrule

// Reading is what the caller measured for one frame: when its work began and ended (monotonic
// ns; neither the event-driven wait before a frame nor the vsync wait after it is work), and the
// collector's counters — the collection count at both ends, so a collection that completed while
// the thread waited is not blamed on the frame after it.
pub struct Reading {
pub:
	begin_ns    u64
	end_ns      u64
	gc_begin    u64 // collections so far, when the work began
	gc_no       u64 // collections so far, when it ended
	alloc_total u64 // bytes allocated so far
	heap        u64 // heap size, bytes
	free        u64 // free bytes in the heap
	since_gc    u64 // bytes allocated since the last collection
}

// Sample is one frame as the panel draws it.
pub struct Sample {
pub:
	t_s        f64 // the frame's end, seconds on the caller's clock
	work_ms    f32 // the frame's work, wait excluded
	gc         bool // a collection completed during the frame's work
	heap_mb    f32
	since_mb   f32 // allocated since the last collection, not yet collected
	alloc_mb_s f32 // allocation rate over the last rate_window_s
}

// rate_window_s is how long the allocation rate is averaged over: per frame it is all noise.
pub const rate_window_s = 0.5

// Sampler turns readings into samples and keeps the last `cap` of them, oldest first.
pub struct Sampler {
mut:
	buf     []Sample
	head    int // where the next sample goes once the ring is full
	primed  bool
	gc_prev u64
	rate_t  f64
	rate_b  u64
	rate    f32
pub mut:
	live_after_gc_mb f32 // heap less free at the first reading after the last collection
	gcs              u64 // collections seen since the first reading
}

pub fn new_sampler(cap int) Sampler {
	return Sampler{
		buf: []Sample{cap: if cap > 0 { cap } else { 1 }}
	}
}

const mib = f32(1048576.0)

// step records one frame. The first reading only primes the totals: a collection count with no
// previous one to compare says nothing about the stretch before it.
pub fn (mut s Sampler) step(r Reading) Sample {
	t := f64(r.end_ns) / 1e9
	gc := r.gc_no != r.gc_begin
	// any collection since the last reading, in the frame or in the wait before it
	collected := s.primed && r.gc_no != s.gc_prev
	if !s.primed {
		s.rate_t = t
		s.rate_b = r.alloc_total
	} else if r.gc_no > s.gc_prev {
		s.gcs += r.gc_no - s.gc_prev
	}
	s.primed = true
	s.gc_prev = r.gc_no
	if t - s.rate_t >= rate_window_s {
		s.rate = if r.alloc_total >= s.rate_b {
			f32(f64(r.alloc_total - s.rate_b) / (t - s.rate_t)) / mib
		} else {
			0
		}
		s.rate_t = t
		s.rate_b = r.alloc_total
	}
	live := if r.heap >= r.free { f32(r.heap - r.free) / mib } else { 0 }
	if collected {
		s.live_after_gc_mb = live
	}
	work := if r.end_ns >= r.begin_ns { f32(f64(r.end_ns - r.begin_ns) / 1e6) } else { 0 }
	smp := Sample{
		t_s:        t
		work_ms:    work
		gc:         gc
		heap_mb:    f32(r.heap) / mib
		since_mb:   f32(r.since_gc) / mib
		alloc_mb_s: s.rate
	}
	if s.buf.len < s.buf.cap {
		s.buf << smp
	} else {
		s.buf[s.head] = smp
		s.head = (s.head + 1) % s.buf.len
	}
	return smp
}

pub fn (s &Sampler) len() int {
	return s.buf.len
}

// at is the i-th sample, oldest first.
pub fn (s &Sampler) at(i int) Sample {
	return s.buf[(s.head + i) % s.buf.len]
}

// Summary is what a window of samples says, for the line above the plots.
pub struct Summary {
pub:
	frames    int
	worst_ms  f32
	worst_gc  bool // the worst frame had a collection in it
	gcs       int  // frames a collection completed in
	spikes    int  // frames over the spike threshold
	gc_spikes int  // of those, the ones a collection completed in
}

// summary covers the samples whose frame ended at or after t0. A spike is a frame whose work
// took spike_ms or more — the one a collection explains when it completed in that frame.
pub fn (s &Sampler) summary(t0 f64, spike_ms f32) Summary {
	mut frames, mut gcs, mut spikes, mut gc_spikes := 0, 0, 0, 0
	mut worst := f32(0)
	mut worst_gc := false
	for i in 0 .. s.buf.len {
		x := s.at(i)
		if x.t_s < t0 {
			continue
		}
		frames++
		if x.gc {
			gcs++
		}
		if x.work_ms >= spike_ms {
			spikes++
			if x.gc {
				gc_spikes++
			}
		}
		if x.work_ms > worst {
			worst = x.work_ms
			worst_gc = x.gc
		}
	}
	return Summary{
		frames:    frames
		worst_ms:  worst
		worst_gc:  worst_gc
		gcs:       gcs
		spikes:    spikes
		gc_spikes: gc_spikes
	}
}
