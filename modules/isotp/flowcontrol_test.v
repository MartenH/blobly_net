module isotp

// THE THREE LEVERS, DECODED. Until #226 the software channel masked the PCI nibble and read
// nothing else, so every one of these cases was "carry on, at full rate".

fn test_clear_to_send_carries_block_size_and_stmin() {
	fc := parse_flow_control([u8(0x30), 4, 10]) or {
		assert false, err.msg()
		return
	}
	assert fc.status == .cts
	assert fc.block_size == 4
	assert fc.stmin_us == 10_000
}

fn test_wait_and_overflow_are_not_clear_to_send() {
	w := parse_flow_control([u8(0x31), 0, 0]) or {
		assert false, err.msg()
		return
	}
	assert w.status == .wait
	o := parse_flow_control([u8(0x32), 0, 0]) or {
		assert false, err.msg()
		return
	}
	assert o.status == .overflow
}

// 0x33..0x3F are reserved. Read as CTS — which is what masking the nibble does — a receiver
// saying something this sender does not understand is answered by transmitting anyway.
fn test_a_reserved_flow_status_is_refused() {
	for fs in u8(3) .. 16 {
		parse_flow_control([0x30 | fs, 0, 0]) or {
			assert err.msg().contains('reserved Flow Control status'), err.msg()
			continue
		}
		assert false, 'flow status ${fs} must be refused'
	}
}

// The two bytes AFTER the PCI are the whole point of the frame. A truncated FC accepted as one
// would be read as block size 0 / STmin 0 — the permissive answer, invented rather than received.
fn test_a_truncated_flow_control_is_refused() {
	for n in 1 .. 3 {
		parse_flow_control([]u8{len: n, init: if index == 0 { u8(0x30) } else { u8(0) }}) or {
			assert err.msg().contains('carries no block size or STmin'), err.msg()
			continue
		}
		assert false, 'a ${n}-byte Flow Control must be refused'
	}
}

// Kept as its own message rather than folded into the PCI check: formatting data[0] for an empty
// frame is an out-of-bounds panic where an ISO-TP error is owed (codex round 3 on #225), and the
// existing test asserts on this wording.
fn test_an_empty_frame_is_not_a_flow_control() {
	parse_flow_control([]u8{}) or {
		assert err.msg().contains('empty frame')
		return
	}
	assert false, 'an empty frame must be refused'
}

fn test_a_frame_that_is_not_flow_control_says_what_it_was() {
	parse_flow_control([u8(0x21), 1, 2]) or {
		assert err.msg().contains('got 0x21')
		return
	}
	assert false, 'a Consecutive Frame is not a Flow Control'
}

// STmin IS TWO SCALES AND TWO RESERVED RANGES. The milliseconds are the common case; the
// 100–900 µs codes exist for fast buses; and the gaps are not "invalid" — ISO tells the SENDER to
// use 0x7F for them, the SLOWEST legal value, because a code it does not understand must not be
// answered by transmitting at full rate.
fn test_stmin_covers_both_scales_and_falls_back_on_the_reserved_ones() {
	assert stmin_micros(0) == 0
	assert stmin_micros(1) == 1000
	assert stmin_micros(0x7F) == 127_000

	assert stmin_micros(0xF1) == 100
	assert stmin_micros(0xF5) == 500
	assert stmin_micros(0xF9) == 900

	// reserved: 0x80..0xF0 and 0xFA..0xFF
	for code in [u8(0x80), 0xA0, 0xF0, 0xFA, 0xFF] {
		assert stmin_micros(code) == 127_000, 'reserved 0x${code:02X} must fall back to 0x7F'
	}
}

// The whole 0..255 domain answers, and never negatively: a negative separation would be a sleep
// this code cannot express and a pace it cannot keep.
fn test_every_stmin_code_has_a_non_negative_answer() {
	for code in u8(0) .. 255 {
		assert stmin_micros(code) >= 0, 'code 0x${code:02X}'
	}
	assert stmin_micros(255) >= 0
}

// A WAIT THE PLATFORM CANNOT EXPRESS IS NOT A WAIT. V's Windows sleep is
// `C.Sleep(int(duration / millisecond))` — integer division — so every sub-millisecond duration
// is Sleep(0), and STmin's whole 100..900 us scale lands there. Windows is the platform this
// software state machine exists FOR: Linux has the kernel ISO-TP socket (codex on #226).
fn test_a_sub_millisecond_pace_is_rounded_up_to_something_that_sleeps() {
	// the 0xF1..0xF9 scale, every one of which is Sleep(0) untreated
	for code in u8(0xF1) .. 0xFA {
		want := stmin_micros(code)
		assert want > 0 && want < 1000, 'code 0x${code:02X} should be sub-millisecond'
		assert pacing_sleep_us(want) == 1000, 'code 0x${code:02X} must round up to a whole ms'
	}
}

// UP, NEVER DOWN, and never invented: STmin is a MINIMUM separation, so a longer sleep conforms
// and a shorter one does not. A wait of zero stays zero — that is a receiver asking for no pacing
// at all, not one asking for something too small to express.
fn test_pacing_never_shortens_a_wait_and_never_invents_one() {
	assert pacing_sleep_us(0) == 0
	assert pacing_sleep_us(-5) == 0
	// A WHOLE number of milliseconds is already expressible and must not move.
	for us in [1000, 30_000, 127_000] {
		assert pacing_sleep_us(us) == us, '${us} us must not move'
	}
	// ANY remainder rounds up — this is the case the first cut missed. The delay handed over is
	// STmin less the time already spent, so 29_900 is what a 30 ms separation actually asks for,
	// and truncating it to 29 ms sends the next frame early.
	assert pacing_sleep_us(29_900) == 30_000
	assert pacing_sleep_us(1001) == 2000
	assert pacing_sleep_us(1) == 1000
	// never shortened, at any magnitude
	for us in [1, 100, 500, 999, 1001, 29_900, 126_001] {
		assert pacing_sleep_us(us) >= us, '${us} us must never be shortened'
		assert pacing_sleep_us(us) % 1000 == 0, '${us} us must land on a whole millisecond'
	}
}
