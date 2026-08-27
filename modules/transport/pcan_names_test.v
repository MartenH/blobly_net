module transport

// CAN_InitializeFD takes a STRING of register values rather than a rate, so something has to solve
// for them. This is that arithmetic, and it lives outside `pcan_windows.v` precisely so these tests
// can reach it — a `_windows.v` file compiles only where CI runs nothing.

// The pair this bench uses. Asserted by what the registers MEAN rather than by the exact numbers:
// PEAK's own example for 500k/2M picks brp=2, this solver picks brp=1 for the same rate, and both
// are exact — more time quanta per bit is the better answer, which is what the solver prefers and
// what its comment claims. Pinning PEAK's literal choice would fail on a correct improvement.
//
// Corroboration that the numbers are sane rather than merely self-consistent: the CANsub, which
// also runs an 80 MHz CAN clock, reports brp=1 seg1=127 seg2=32 for its own 500 kbit/s nominal
// phase — the identical solution, from a different vendor's firmware.
fn test_the_common_pair_is_exact_at_the_requested_sample_point() {
	s := pcan_fd_bitrate(500_000, 2_000_000, 80)!
	assert s.contains('f_clock=80000000'), s
	nom_tq := 1 + field(s, 'nom_tseg1') + field(s, 'nom_tseg2')
	dat_tq := 1 + field(s, 'data_tseg1') + field(s, 'data_tseg2')
	assert pcan_fd_clock_hz / (field(s, 'nom_brp') * nom_tq) == 500_000, s
	assert pcan_fd_clock_hz / (field(s, 'data_brp') * dat_tq) == 2_000_000, s
	assert (1 + field(s, 'nom_tseg1')) * 100 / nom_tq == 80, s
	assert (1 + field(s, 'data_tseg1')) * 100 / dat_tq == 80, s
}

// Every rate the solver claims must actually come back out of the registers it chose. This is the
// assertion a hand-written table cannot make about itself.
fn test_every_solved_rate_reproduces_itself() {
	for nominal in [125_000, 250_000, 500_000, 1_000_000] {
		for data in [1_000_000, 2_000_000, 4_000_000, 5_000_000, 8_000_000] {
			if data < nominal {
				continue
			}
			s := pcan_fd_bitrate(nominal, data, 80) or { continue }
			nom_tq := 1 + field(s, 'nom_tseg1') + field(s, 'nom_tseg2')
			dat_tq := 1 + field(s, 'data_tseg1') + field(s, 'data_tseg2')
			assert pcan_fd_clock_hz / (field(s, 'nom_brp') * nom_tq) == nominal, '${nominal}: ${s}'
			assert pcan_fd_clock_hz / (field(s, 'data_brp') * dat_tq) == data, '${data}: ${s}'
		}
	}
}

// The sample point asked for is the one configured, within the rounding a whole number of quanta
// allows. A controller half a percent off its bus fails under load and nowhere else.
fn test_the_sample_point_is_honoured() {
	for sp in [75, 80, 87] {
		s := pcan_fd_bitrate(500_000, 2_000_000, sp)!
		tq := 1 + field(s, 'nom_tseg1') + field(s, 'nom_tseg2')
		got := (1 + field(s, 'nom_tseg1')) * 100 / tq
		assert got >= sp - 2 && got <= sp + 2, 'asked ${sp}%, got ${got}%: ${s}'
	}
}

// EQUAL PHASES ARE A REAL CONFIGURATION: 64-byte payloads at the arbitration rate, with no
// bit-rate switch. The data registers are much narrower than the nominal ones, but the solver
// searches prescalers, so what decides is whether the CLOCK divides, not the register width.
// (I assumed the reverse when writing this test; the solver was right and the test was wrong.)
fn test_equal_phases_are_solvable() {
	s := pcan_fd_bitrate(500_000, 500_000, 80)!
	tq := 1 + field(s, 'data_tseg1') + field(s, 'data_tseg2')
	assert pcan_fd_clock_hz / (field(s, 'data_brp') * tq) == 500_000, s
}

// A rate the clock cannot divide exactly is refused rather than rounded.
fn test_a_rate_the_clock_cannot_divide_is_refused() {
	if _ := pcan_fd_bitrate(333_333, 2_000_000, 80) {
		assert false, '333333 does not divide 80 MHz'
	}
}

fn test_an_absurd_rate_is_refused_rather_than_overflowing() {
	for r in [1_073_741_824, 2_147_483_647, 21_000_000] {
		if _ := pcan_fd_bitrate(r, r, 80) {
			assert false, '${r} bit/s is not producible from an 80 MHz clock'
		}
	}
}

// field pulls one `name=value` out of the bitrate string, so the tests check what was actually
// emitted rather than what the solver believed it emitted.
fn field(s string, name string) int {
	for part in s.split(',') {
		kv := part.split('=')
		if kv.len == 2 && kv[0] == name {
			return kv[1].int()
		}
	}
	return 0
}

// THE SAMPLE POINT IS PART OF THE PROMISE, not just the bit rate. A rate the clock divides exactly
// can still be unable to PLACE the sample where it was asked, because few time quanta means coarse
// placement — and that used to be delivered silently while the project refused any sample point but
// 80% (codex round 2 on #217). Checked by reading the registers back rather than by trusting the
// solver's own arithmetic.
fn test_every_accepted_rate_actually_lands_near_the_sample_point() {
	// Every rate this backend has been run at on the bench, plus the arbitration rates.
	for r in [125_000, 250_000, 500_000, 1_000_000, 2_000_000, 4_000_000, 5_000_000, 8_000_000] {
		s := pcan_fd_bitrate(500_000, r, 80) or {
			assert false, '${r} bit/s should be producible: ${err.msg()}'
			continue
		}
		tseg1 := field(s, 'data_tseg1')
		tseg2 := field(s, 'data_tseg2')
		total := 1 + tseg1 + tseg2
		achieved := (1 + tseg1) * 100 / total
		assert achieved >= 78 && achieved <= 82, '${r} bit/s lands at ${achieved}%, not 80% (${s})'
	}
}

// AND A RATE THAT CANNOT IS REFUSED, IN WORDS. 10 Mbit/s divides 80 MHz exactly — into eight time
// quanta, where the nearest placement to 80% is 6/8 = 75%. The refusal names the number it can
// reach, because that is the only thing the operator can act on.
fn test_a_rate_with_too_few_quanta_for_the_sample_point_is_refused() {
	if s := pcan_fd_bitrate(500_000, 10_000_000, 80) {
		assert false, '10 Mbit/s cannot hold an 80% sample point on an 80 MHz clock: ${s}'
	} else {
		assert err.msg().contains('75%'), 'the refusal should say what it CAN reach: ${err.msg()}'
	}
}

// The tolerance is not a way in for a sample point the rate cannot approach. Ten time quanta can
// place the sample at tenths of a bit and nowhere else, so 85% is five points from the nearest
// either way and is refused — while 50%, which IS a tenth, is produced exactly. (The first draft of
// this test asserted that 8 Mbit/s could not hold 50%; the solver was right and the test was wrong.)
fn test_the_tolerance_does_not_admit_a_sample_point_the_rate_cannot_reach() {
	if s := pcan_fd_bitrate(500_000, 8_000_000, 85) {
		assert false, '8 Mbit/s is ten quanta — 85% is not one of the placements it has: ${s}'
	}
	exact := pcan_fd_bitrate(500_000, 8_000_000, 50) or {
		assert false, '50% IS a tenth of a bit and should be produced exactly: ${err.msg()}'
		return
	}
	assert field(exact, 'data_tseg1') == 4 && field(exact, 'data_tseg2') == 5, exact
}
