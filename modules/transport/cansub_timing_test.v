module transport

// The solver against the VENDOR'S OWN bit-timing table, not against itself.
//
// Each row below is copied from the CANsub.4 documentation: nominal rate, data rate, sample point,
// then BRP/SEG1/SEG2/SJW. Reproducing them is the strongest check available without a scope on the
// bus — the numbers were computed by the people who built the controller.

struct TimingRow {
	rate int
	sp   int
	brp  int
	seg1 int
	seg2 int
	sjw  int
}

// Nominal-phase rows from the vendor's table.
const vendor_nominal_rows = [
	// 1 Mbit/s
	TimingRow{1000000, 80, 4, 15, 4, 4},
	// 500 kbit/s
	TimingRow{500000, 80, 4, 31, 8, 4},
	// 250 kbit/s — and the factory setting of every channel on a new device
	TimingRow{250000, 80, 4, 63, 16, 4},
]

fn test_the_solver_reproduces_the_vendors_table() {
	for r in vendor_nominal_rows {
		t := cansub_timing_for(r.rate, r.sp) or {
			assert false, '${r.rate} at ${r.sp}%: ${err}'
			continue
		}
		// The bitrate and sample point are what must match. A different but equivalent
		// BRP/SEG split is not wrong, so those are checked through the values they produce.
		assert t.bitrate() == r.rate, '${r.rate}@${r.sp}%: solved to ${t.bitrate()}'
		assert t.sample_point_pct() == f64(r.sp), '${r.rate}@${r.sp}%: sample point ${t.sample_point_pct()}'
		assert t.sjw <= t.seg2, 'SJW ${t.sjw} exceeds seg2 ${t.seg2}'
	}
}

// A factory CANsub.4 reads back exactly this on every channel — captured from a real device on
// firmware 02.04.00. It is the vendor's `250.000 | 1.000.000 | 80.0%` row, so the hardware and the
// table agree, and this pins that our reading of the formula agrees with both.
fn test_the_factory_settings_decode_to_250k_and_1m() {
	nominal := CansubTiming{
		brp:  4
		seg1: 63
		seg2: 16
		sjw:  4
	}
	assert nominal.bitrate() == 250_000
	assert nominal.sample_point_pct() == 80.0
	data := CansubTiming{
		brp:  4
		seg1: 15
		seg2: 4
		sjw:  4
	}
	assert data.bitrate() == 1_000_000
	assert data.sample_point_pct() == 80.0
}

// Every rate a CAN bus is normally run at must be reachable, at both of the sample points in
// common use. A backend that cannot configure 125 kbit/s is not finished.
fn test_the_ordinary_bitrates_all_solve() {
	for rate in [10_000, 20_000, 50_000, 100_000, 125_000, 250_000, 500_000, 800_000, 1_000_000] {
		for sp in [75, 80, 87] {
			t := cansub_timing_for(rate, sp) or {
				assert false, '${rate} at ${sp}%: ${err}'
				continue
			}
			assert t.bitrate() == rate, '${rate}@${sp}%: got ${t.bitrate()}'
			assert t.seg1 >= 1 && t.seg2 >= 1
			assert t.sjw >= 1 && t.sjw <= t.seg2
		}
	}
}

// The CAN-FD data rates the device's own table covers, through the DATA solver — whose segment
// bounds are much tighter than the nominal ones.
fn test_the_fd_data_rates_solve() {
	for rate in [1_000_000, 2_000_000, 4_000_000, 5_000_000] {
		t := cansub_timing_for_data(rate, 80) or {
			assert false, '${rate}: ${err}'
			continue
		}
		assert t.bitrate() == rate
		assert t.seg1 <= 32 && t.seg2 <= 16, '${rate}: seg1 ${t.seg1} seg2 ${t.seg2} will not fit the data registers'
	}
}

// THE REASON THE TWO SOLVERS EXIST, stated as the numbers rather than as a rule.
//
// The nominal solver prefers the smallest prescaler, which at 250 kbit/s means 320 time quanta and
// seg1 255 — perfectly good in `timing`, and far too wide for `timing_data`, whose registers are a
// few bits each. Sending that as the data phase is what the device answers with an HTTP 500,
// naming neither the field nor the reason.
//
// The same rate solves fine in the data phase when the search is bounded to it: a bigger prescaler
// and fewer quanta. So the difference is not which rates are possible, it is which SOLUTION is
// chosen — which is exactly the kind of thing that looks like a device fault from outside.
fn test_the_two_solvers_choose_differently_for_one_rate() {
	nominal := cansub_timing_for(250_000, 80)!
	data := cansub_timing_for_data(250_000, 80)!
	assert nominal.bitrate() == 250_000
	assert data.bitrate() == 250_000
	assert nominal.seg1 > cansub_max_data_seg1, 'the nominal solution should be too wide for the data registers — that is the whole problem'
	assert data.seg1 <= cansub_max_data_seg1
	assert data.seg2 <= cansub_max_data_seg2
	assert data.brp > nominal.brp, 'the data phase buys its narrower segments with a bigger prescaler'
}

// A rate genuinely out of the data phase's reach is refused with a message that says which phase
// failed, rather than a bare 500 from the device several seconds later.
fn test_an_impossible_data_phase_names_the_data_phase() {
	cansub_timing_for_data(10_000, 80) or {
		assert err.msg().contains('data-phase'), 'the error should say which half could not be solved: ${err}'
		return
	}
	assert false, '10 kbit/s should not fit registers this narrow'
}

// The smallest prescaler that works, because more quanta per bit place the sample point more
// precisely and leave more room for resynchronisation.
fn test_the_smallest_workable_prescaler_is_chosen() {
	t := cansub_timing_for(1_000_000, 80)!
	assert t.bitrate() == 1_000_000
	// 80 MHz / 1 Mbit/s = 80 quanta at brp 1, and 80 quanta needs seg1 63 — inside the bounds,
	// so nothing larger should have been reached for.
	assert t.brp == 1, 'chose brp ${t.brp} when 1 works'
	assert t.tq() == 80
}

// A rate the clock cannot divide exactly is refused, not rounded. Half a percent off its bus is a
// controller that works until the bus is busy.
fn test_a_rate_the_clock_cannot_make_is_refused() {
	cansub_timing_for(33_333, 80) or { return }
	assert false, 'accepted a bitrate the 80 MHz clock cannot divide to'
}

fn test_nonsense_arguments_are_refused() {
	cansub_timing_for(0, 80) or {
		cansub_timing_for(-1, 80) or {
			cansub_timing_for(500_000, 200) or {
				cansub_timing_for(500_000, 10) or { return }
				assert false, 'accepted a 10% sample point'
				return
			}
			assert false, 'accepted a 200% sample point'
			return
		}
		assert false, 'accepted a negative bitrate'
		return
	}
	assert false, 'accepted a zero bitrate'
}

// The PHY body is what actually reaches the device, so its shape is pinned here rather than
// discovered by a 400 on the bench.
// The device rejects an INCOMPLETE object — 400 "Incomplete or invalid request" — so a classic
// channel still has to name a data phase. Found by trying it against a CANsub.4 on 02.04.00:
// omitting `timing_data` fails, omitting the booleans fails, and the full object succeeds. The
// vendor's schema marks nothing required, so nothing but the device could have said so.
fn test_phy_json_is_complete_even_for_a_classic_channel() {
	j := cansub_phy_json(CansubTiming{ brp: 4, seg1: 63, seg2: 16, sjw: 4 }, none, false)
	assert j.contains('"timing":{"brp":4,"seg1":63,"seg2":16,"sjw":4}')
	// The filler is the FACTORY data timing, not the nominal repeated: the data-phase registers are
	// far narrower, and a nominal solution copied into them is refused with an HTTP 500 at ordinary
	// bitrates — 250 kbit/s solves to seg1 255, which the data phase cannot hold.
	assert j.contains('"timing_data":{"brp":4,"seg1":15,"seg2":4,"sjw":4}'), 'a classic channel needs a data phase the DATA registers can actually hold'
	assert j.contains('"listen_only":false')
	assert j.contains('"auto_reset":true')
	assert j.contains('"tx_ack_frames":true'), 'a transmit must be confirmable, not assumed'
	assert j.contains('"error_frames":true'), 'health() has nothing to report without these'
}

fn test_phy_json_fd_carries_both_phases() {
	j := cansub_phy_json(CansubTiming{ brp: 4, seg1: 63, seg2: 16, sjw: 4 },
		CansubTiming{ brp: 4, seg1: 15, seg2: 4, sjw: 4 }, false)
	assert j.contains('"timing":{"brp":4,"seg1":63,"seg2":16,"sjw":4}')
	assert j.contains('"timing_data":{"brp":4,"seg1":15,"seg2":4,"sjw":4}')
}

// Listen-only is set in the CONTROLLER as well as in this process's table. The table is what moves
// when a row is toggled mid-run; the register is what stops the channel acknowledging, and on a
// bus with one other node an ACK from us is the difference between its frames succeeding and it
// going error-passive.
fn test_phy_json_can_silence_the_controller() {
	j := cansub_phy_json(CansubTiming{ brp: 4, seg1: 63, seg2: 16, sjw: 4 }, none, true)
	assert j.contains('"listen_only":true')
}
