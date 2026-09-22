// flowcontrol.v — what a Flow Control frame TELLS THE SENDER, decoded once.
//
// ISO 15765-2 gives the receiver three levers over a segmented transfer, and until #226 the
// software channel read none of them: it accepted any `0x3x` as "carry on" and sent every
// Consecutive Frame back to back. Against the in-process bus that is invisible — nothing there
// is paced or blocked — but `isotp.open` routes to this state machine on every non-Linux host,
// so it is what `cmd/flash`, the shell, scripts and the GUI's diagnostics have been using
// against REAL ECUs on Windows. A bootloader that asks for spacing or blocks gets neither, and
// answers by dropping the transfer — flash's data blocks are exactly this path.
//
// The decode is here, pure and tested, rather than inline in `send`: the three levers are a wire
// format with reserved ranges and a stated fallback, and that is the kind of rule this repo keeps
// out of the code that acts on it.
module isotp

// FlowStatus is the receiver's answer to a First Frame.
pub enum FlowStatus {
	cts      // 0 — Clear To Send: send the next block
	wait     // 1 — not yet; another Flow Control will follow
	overflow // 2 — this PDU will not fit; the transfer is over
}

// FlowControl is one decoded FC frame.
pub struct FlowControl {
pub:
	status     FlowStatus
	block_size u8  // Consecutive Frames before the next FC; 0 = the whole remainder, no more FCs
	stmin_us   int // minimum separation between Consecutive Frames, in MICROSECONDS
}

// n_wft_max bounds how many consecutive WAIT frames a sender accepts before giving up.
//
// ISO 15765-2 leaves the value to the implementer and says only that the sender aborts once it
// has seen more than N_WFTmax of them. A bound is the whole point: WAIT re-arms the wait, so a
// peer that answers every Flow Control request with one holds this transfer open for as long as
// it keeps talking — and unlike a silent peer it never trips the timeout, because a frame keeps
// arriving. Without a count, `send` would block for as long as the ECU cared to stall it.
pub const n_wft_max = 16

// fc_timeout_ms bounds the wait for ONE Flow Control (ISO's N_BS). Re-armed per FC, so a WAIT
// buys the peer another full window rather than eating into the first one.
pub const fc_timeout_ms = 1000

// stmin_micros converts the STmin byte to microseconds.
//
// The encoding is not a single scale, and the gaps are not "invalid" — ISO 15765-2 names them
// reserved and tells the SENDER what to do with one: treat it as 0x7F, the slowest legal value.
// That is deliberately the safe direction. A reserved code read as 0 would send at full rate at
// the one peer that asked for something the sender did not understand.
//
//	0x00..0x7F — 0..127 milliseconds
//	0x80..0xF0 — reserved
//	0xF1..0xF9 — 100..900 microseconds
//	0xFA..0xFF — reserved
pub fn stmin_micros(code u8) int {
	if code <= 0x7F {
		return int(code) * 1000
	}
	if code >= 0xF1 && code <= 0xF9 {
		return (int(code) - 0xF0) * 100
	}
	return 127 * 1000
}

// pacing_sleep_us is how long to actually sleep for a wanted separation of `want_us`.
//
// A WAIT SHORTER THAN A MILLISECOND IS ROUNDED UP, because on Windows there is no such wait:
//
//	// vlib/time/time_windows.c.v
//	pub fn sleep(duration Duration) {
//		C.Sleep(int(duration / millisecond))
//	}
//
// Integer division, so every duration below a millisecond is `Sleep(0)` — and STmin's whole
// sub-millisecond scale (0xF1..0xF9, 100..900 us) lands there. That is the one platform this
// software state machine exists for: Linux has the kernel ISO-TP socket and does not come
// through here, and its nanosleep would honour the value anyway. So an ECU asking for 200 us
// got no separation at all on the only host that would ask this code for one (codex on #226).
//
// EVERY POSITIVE DELAY, not only the ones below a millisecond. That truncation applies at any
// magnitude, and the value handed to it here is a REMAINDER — STmin less the time already spent
// waiting for the Flow Control — so a 30 ms separation with 100 us already elapsed asks for
// 29,900 us, sleeps 29 ms, and sends the next frame early. The first cut rounded up only below a
// millisecond and left exactly that case short (codex on #226).
//
// UP, never down: STmin is a MINIMUM separation, so sleeping longer always conforms and sleeping
// short does not. The overshoot is under one millisecond per frame.
//
// UNCONDITIONALLY, not `$if windows`. The rounding costs a Linux caller up to 999 us per frame it
// does not need — this state machine is reached there only when a caller asks for it by name,
// since `open` takes the kernel socket — and that is the cheaper of the two prices: a pure
// function with a platform branch is one whose test can only ever be right on one platform, which
// is the trap CLAUDE.md records for `vendor_iface`.
pub fn pacing_sleep_us(want_us int) int {
	if want_us <= 0 {
		return 0
	}
	return ((want_us + 999) / 1000) * 1000
}

// parse_flow_control decodes an FC frame's data, or says why it is not one.
//
// THREE BYTES ARE REQUIRED, not one. The old code checked the PCI nibble alone and then read
// nothing else, so a truncated FC was indistinguishable from a complete one — and it is the two
// bytes AFTER the PCI that carry everything this function exists to read. A sender that assumed
// block size 0 and STmin 0 from a two-byte frame would be inventing the permissive answer.
//
// A RESERVED FLOW STATUS IS AN ERROR, not a CTS. Reading 0x33..0x3F as "carry on" is the shape
// the whole issue is about: the nibble was masked off and every value meant go.
pub fn parse_flow_control(data []u8) !FlowControl {
	if data.len == 0 {
		// Kept as its own message: this is what a padding-only or zero-length frame looks like,
		// and it was already called out separately (codex round 3 on #225) because formatting
		// data[0] for it is an out-of-bounds panic where an ISO-TP error is owed.
		return error('ISO-TP: expected Flow Control, got an empty frame')
	}
	if (data[0] & 0xF0) != 0x30 {
		return error('ISO-TP: expected Flow Control, got 0x${data[0]:02X}')
	}
	if data.len < 3 {
		return error('ISO-TP: Flow Control of ${data.len} bytes carries no block size or STmin')
	}
	fs := data[0] & 0x0F
	status := match fs {
		0 { FlowStatus.cts }
		1 { FlowStatus.wait }
		2 { FlowStatus.overflow }
		else { return error('ISO-TP: reserved Flow Control status ${fs}') }
	}
	return FlowControl{
		status:     status
		block_size: data[1]
		stmin_us:   stmin_micros(data[2])
	}
}

// fc_total_wait_ms bounds how long ONE transfer may spend waiting for its peer, across every
// Flow Control it asks for.
//
// WHY A SECOND BOUND AT ALL. The two above are per-block and answer a per-block question, and
// `await_flow_control` resets its wait count on every call -- deliberately, because a receiver
// that asks to wait, is given time and then accepts a block has done nothing wrong, and a count
// carried across blocks would abort a long, legitimately paced transfer partway through. That
// reasoning is right and it leaves NO TOTAL BOUND: at BS=1 a maximum PDU is 585 blocks, so a
// peer answering `n_wft_max` WAITs per block holds one `send` for 585 x 16 x 1000 ms, about two
// and a half hours. It does not even need WAIT -- answering every Flow Control at 999 ms is ten
// minutes. Before #226 the worst case was about a second (#296).
//
// WAITING, NOT ELAPSED TIME, and the difference is the whole design. A transfer may legitimately
// take minutes: 585 Consecutive Frames at the slowest legal separation (STmin 0x7F, 127 ms) is
// 74 seconds of pacing that ISO 15765-2 entitles the receiver to ask for. Those sleeps are OURS
// and are not counted. What is counted is time spent blocked on the peer, which a healthy
// receiver answers in single-digit milliseconds.
//
// THE VALUE IS SIZED BY FLASH, which is the real caller and cannot raise it: `flash.program`
// takes the `Channel` INTERFACE, so no per-channel field is reachable from there, and a bound
// that aborts a firmware download is worse than the stall it prevents. A maximum PDU at BS=1
// asks for 584 Flow Controls, so this permits an average of ~205 ms of waiting for each one --
// a bootloader busy erasing may take tens of milliseconds to answer, and this is an order of
// magnitude above that. A peer slower than that ON AVERAGE, for the whole transfer, is not
// working; it is stalling. The per-block bounds still apply and are what an ordinarily slow
// peer trips first; this one exists for the peer that never trips them.
//
// 30 s was the first choice and was too tight by exactly this reasoning: it left ~51 ms per
// Flow Control, which a real bootloader can exceed without being at fault (self-review).
//
// IT DOES NOT MAKE A SEND STOP-RESPONSIVE, which is worth saying plainly: `rebuild_from_proj`
// waits `drain_budget_ms` = 1500 ms for a run worker, and no bound that accommodates a legal
// 74-second transfer can also respect that. A parked worker wants `uds.Server.serve` to check
// `stop` mid-request, which is a different module and a different change.
pub const fc_total_wait_ms = 120_000

// WaitBudget is what is left of that allowance. Threaded through one transfer, not held on the
// channel: it belongs to the transfer, and a channel reused for the next one starts again.
pub struct WaitBudget {
pub mut:
	left_us i64
}

pub fn new_wait_budget() WaitBudget {
	return new_wait_budget_ms(fc_total_wait_ms)
}

// new_wait_budget_ms is the allowance a caller states. A value of 0 or less is NOT "no bound" --
// it is the smallest allowance there is, so a channel field left at zero by a struct literal
// that forgot it cannot silently restore the two-and-a-half-hour case this exists to close.
pub fn new_wait_budget_ms(ms int) WaitBudget {
	if ms <= 0 {
		return WaitBudget{
			left_us: 0
		}
	}
	return WaitBudget{
		left_us: i64(ms) * 1000
	}
}

// window_ms is how long the next read may block: the caller's own remaining window, clamped by
// what is left of the transfer's allowance. Zero or less means the allowance is gone -- the
// caller reports that rather than reading, since a read of 0 ms is not a refusal.
pub fn (b WaitBudget) window_ms(want_ms int) int {
	if b.left_us <= 0 {
		return 0
	}
	left_ms := b.left_us / 1000
	// A remainder under a millisecond is still time left, and rounding it to 0 would report the
	// allowance as spent while it is not. One millisecond is the smallest read that means
	// anything.
	if left_ms <= 0 {
		return if want_ms < 1 { want_ms } else { 1 }
	}
	if i64(want_ms) > left_ms {
		return int(left_ms)
	}
	return want_ms
}

// spend_ns subtracts time actually spent blocked. A negative reading -- a clock that went
// backwards, which is not this clock's contract but costs nothing to refuse -- spends nothing
// rather than REFUNDING the budget, since a refund is how a bound stops being one.
pub fn (mut b WaitBudget) spend_ns(ns i64) {
	if ns <= 0 {
		return
	}
	b.left_us -= ns / 1000
}

pub fn (b WaitBudget) spent() bool {
	return b.left_us <= 0
}

// exhausted_note says which bound was hit, because `timeout` here would name the per-block one
// and send the reader to the wrong constant.
pub fn exhausted_note(ms int) string {
	return 'ISO-TP: transfer spent its ${ms} ms of waiting on the receiver (fc_total_wait_ms) — giving up'
}
