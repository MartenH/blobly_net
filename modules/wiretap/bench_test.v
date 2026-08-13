module wiretap

import transport
import time
import os

// How expensive is the claim path when the ring is FULL? Every received frame walks the pending
// records, so the answer decides whether an index is worth having. Measured before optimising —
// the numbers, not the shape of the loop, decide.
fn test_claim_cost_when_the_ring_is_full() {
	mut r := Ring{}
	f := fn (id u32, b u8) transport.CanFrame {
		return transport.CanFrame{
			id:   id
			data: [b, 0, 0, 0, 0, 0, 0, 0]
		}
	}
	// fill to the cap with records nothing will claim
	for i in 0 .. default_cap {
		r.note(u64(i), 'vcan0', f(u32(0x100 + (i % 0x400)), u8(i % 256)), 0, [0], '', false)
	}
	assert r.outstanding() == default_cap

	// WORST case: a frame that matches nothing, so the scan runs to the end every time
	mut miss := 0
	t0 := time.ticks()
	for i in 0 .. 2000 {
		if _ := r.claim(0, 'vcan0', f(0x7FF, u8(i % 256)), 1) {
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
		if _ := r.claim(0, 'vcan0', f(u32(0x100 + (i % 0x400)), u8(i % 256)), 1) {
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
