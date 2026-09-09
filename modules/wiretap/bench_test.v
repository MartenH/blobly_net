module wiretap

import transport
import time
import os

// bench_frame is a frame nothing on the bench will claim, keyed so ids and payloads vary.
fn bench_frame(id u32, b u8) transport.CanFrame {
	return transport.CanFrame{
		id:   id
		data: [b, 0, 0, 0, 0, 0, 0, 0]
	}
}

// full_ring is a ring filled to its cap with watched records nothing will claim — the steady
// state on a busy bench, and the one both benchmarks measure against.
fn full_ring() Ring {
	mut r := Ring{}
	for i in 0 .. default_cap {
		r.note(u64(i), 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)), 0, [
			0,
		], '', false)
	}
	assert r.outstanding() == default_cap
	return r
}

// allocated_bytes is Boehm's monotonic allocation counter — a collection does not deflate it —
// through vlib's guarded wrapper, so a `-gc none` build links and the tests that read it skip.
fn allocated_bytes() u64 {
	return u64(gc_heap_usage().total_bytes)
}

// How expensive is the claim path when the ring is FULL? Every received frame walks the pending
// records, so the answer decides whether an index is worth having. Measured before optimising —
// the numbers, not the shape of the loop, decide.
fn test_claim_cost_when_the_ring_is_full() {
	mut r := full_ring()

	// WORST case: a frame that matches nothing, so the scan runs to the end every time
	mut miss := 0
	t0 := time.ticks()
	for i in 0 .. 2000 {
		if _ := r.claim(0, 'vcan0', bench_frame(0x7FF, u8(i % 256)), 1) {
			miss++
		}
	}
	worst_us := f64(time.ticks() - t0) * 1000.0 / 2000.0
	assert miss == 0

	// TYPICAL: our own echo, which matches an early record (oldest-first, and the oldest are the
	// ones still waiting) — the case that actually runs on a bench
	mut hit := 0
	t1 := time.ticks()
	for i in 0 .. 1000 {
		if _ := r.claim(0, 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)), 1) {
			hit++
		}
	}
	typical_us := f64(time.ticks() - t1) * 1000.0 / 1000.0

	println('claim cost @ ${default_cap} pending: worst ${worst_us:.2}us/frame, typical ${typical_us:.2}us/frame (${hit} hits)')
	assert hit == 1000

	// The number above is INFORMATIONAL by default. time.ticks() measures the machine and the
	// scheduler as much as it measures claim(), so a preempted shared runner would fail this on a
	// perfectly good build. Set WIRETAP_BENCH=1 on a quiet machine to hold it to the budget: a
	// 1 Mbit CAN bus tops out around 15k frames/s, i.e. ~66us between frames even back to back,
	// and a single claim must not eat a meaningful share of that.
	if os.getenv('WIRETAP_BENCH') != '' {
		assert worst_us < 20.0, 'claim is too slow to keep up with a saturated bus: ${worst_us}us'
	}
}

// How much does note() ALLOCATE when the ring is full? Every emitted frame lands here, and at
// replay rates that is thousands of times a second — so bytes per note is the number that
// decides whether the GUI's collector runs every minute or every second. Measured in BYTES
// rather than time, because allocation is deterministic where the scheduler is not.
//
// This is the class that produced the once-a-second replay stutter: eviction rebuilt the whole
// ring (a map of indices, three passes, a fresh cap-sized copy) to make room for ONE record,
// ~150 KB of garbage per frame, ~1 GB/s inside the GUI. In-place eviction allocates only the
// record itself. The bound is loose on purpose: it has to catch a rebuild, never a field.
fn test_note_cost_when_the_ring_is_full() {
	$if !gcboehm ? {
		println('note cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut r := full_ring()
	// steady state: the ring is full and every note must evict one record to stay so
	n := 2000
	before := allocated_bytes()
	for i in 0 .. n {
		r.note(u64(default_cap + i), 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)),
			0, [0], '', false)
	}
	after := allocated_bytes()
	assert r.outstanding() == default_cap
	per := f64(after - before) / f64(n)
	println('note cost @ ${default_cap} pending: ${per:.0f} bytes allocated per note')
	assert per < 4096, 'note() at cap allocates ${per:.0f} bytes each -- the ring is being rebuilt per record'
}

// The same class one function over: at rates BELOW the cap-per-window (about 500 frames/s at
// the defaults) the ring never fills, so the eviction path above never runs — instead records
// AGE out, one or a few per call, and both `expire` (the emit path) and `drop_expired` (the
// claim path, every received frame) used to copy the whole remaining ring to drop the prefix.
// ~100 KB per frame at 800 pending, on the RX thread, under the app lock. Measured with a
// steady trickle: one record ages out per step while one is noted and one claim misses, so the
// ring holds its size and every step takes both paths.
fn test_cost_when_records_age_out() {
	$if !gcboehm ? {
		println('age-out cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut r := Ring{}
	held := 800
	for i in 0 .. held {
		r.note(u64(i), 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)), f64(i), [
			0,
		], '', false)
	}
	n := 2000
	mut aged := 0
	before := allocated_bytes()
	for i in 0 .. n {
		// one ms per step, the clock starting just past the window, so the record stamped k
		// ages out at step k: the originals over the first `held` steps, then the ones noted
		// here — stamped `held` ms behind the clock, in time order, so each ages exactly
		// `held` steps after it was noted and the ring holds its size throughout
		t := f64(r.window_ms) + 1.0 + f64(i)
		aged += r.expire(t).len
		if _ := r.claim(0, 'vcan0', bench_frame(0x7FF, u8(i % 256)), t) {
			assert false, 'nothing on this bench is claimable'
		}
		r.note(u64(held + i), 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)), f64(
			held + i), [0], '', false)
	}
	after := allocated_bytes()
	assert aged == n, 'one watched record should age out per step, ${aged} did over ${n}'
	assert r.outstanding() == held
	per := f64(after - before) / f64(n)
	println('age-out cost @ ${held} pending: ${per:.0f} bytes allocated per step (expire + claim + note)')
	assert per < 4096, 'aging out one record allocates ${per:.0f} bytes -- the ring is being copied to drop a prefix'
}

// And the RECEIVE side of aging out on its own: the test above runs `expire` before every
// `claim`, so `drop_expired` (the claim path's own prefix drop) always finds nothing aged and
// its allocation-sensitive branch is never entered — reverting only that branch to slice-and-
// clone left the test green (codex on #299 round 2). Here nothing calls `expire`: each step's
// claim is what ages a record out.
fn test_claim_cost_when_records_age_out() {
	$if !gcboehm ? {
		println('claim age-out cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut r := Ring{}
	held := 800
	for i in 0 .. held {
		r.note(u64(i), 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)), f64(i), [
			0,
		], '', false)
	}
	n := 2000
	before := allocated_bytes()
	for i in 0 .. n {
		t := f64(r.window_ms) + 1.0 + f64(i)
		if _ := r.claim(0, 'vcan0', bench_frame(0x7FF, u8(i % 256)), t) {
			assert false, 'nothing on this bench is claimable'
		}
		assert r.outstanding() == held - 1, 'the claim at step ${i} should have dropped exactly one aged record'
		r.note(u64(held + i), 'vcan0', bench_frame(u32(0x100 + (i % 0x400)), u8(i % 256)), f64(
			held + i), [0], '', false)
	}
	after := allocated_bytes()
	per := f64(after - before) / f64(n)
	println('claim age-out cost @ ${held} pending: ${per:.0f} bytes allocated per step (claim + note)')
	assert per < 4096, 'dropping one aged record on the claim path allocates ${per:.0f} bytes -- the ring is being copied to drop a prefix'
}
