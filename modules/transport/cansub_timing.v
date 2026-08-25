// A CANsub is configured in time quanta, not in bits per second.
//
// Every other backend here takes a bitrate and hands it to a driver that works out the segments.
// The CANsub's REST API does not: `/api/can/{ch}/phy` takes `brp`, `seg1`, `seg2` and `sjw`, for
// the nominal phase and again for the CAN-FD data phase. So the arithmetic that a vendor DLL
// normally hides has to happen here — which is a good thing, because it is arithmetic and belongs
// where a test can see it rather than inside a bench.
//
//     bitrate      = clock / (brp * (1 + seg1 + seg2))
//     sample point = (1 + seg1) / (1 + seg1 + seg2)
//
// The CANsub.4 runs an 80 MHz CAN clock, which the vendor states and which their published
// bit-timing table is computed against. `cansub_timing_test.v` reproduces rows from that table, so
// the solver is checked against the manufacturer's own numbers rather than against itself.
//
// SAMPLE POINT. The default is 80%, because that is what the device ships with — a factory
// CANsub.4 reads back `brp:4, seg1:63, seg2:16` on every channel, which is 250 kbit/s at exactly
// 80%, and it is the figure most of the vendor's table is built around. It is a parameter because
// a sample point is a property of the BUS, agreed between every node on it: a segment that
// disagrees with the rest of the vehicle produces a controller that mostly works and occasionally
// does not, which is the worst way for this to be wrong.
module transport

// cansub_clock_hz is the CAN clock the CANsub.4 runs. Stated by the vendor, and the divisor every
// row of their bit-timing table is computed against.
pub const cansub_clock_hz = 80_000_000

// cansub_default_sample_point is what the hardware arrives set to.
pub const cansub_default_sample_point = 80

// Segment bounds. The API documents only a minimum of 1 for each field and names no maximum, so
// these come from the widest values the vendor's own table uses — seg1 reaches 255 and seg2 64 in
// the 250 kbit/s rows. Refusing beyond that is better than sending a controller a register value
// nobody has published as working.
// The prescaler bound is OURS, not the vendor's: the API documents a minimum of 1 and names no
// maximum. Their table demonstrates only 1 to 8, but it only covers 250 kbit/s and above — the low
// rates need more. 10 kbit/s is 8000 time quanta of 80 MHz clock, which no prescaler below 21 can
// reach inside the segment bounds, so a limit taken from that table would refuse a bitrate CAN
// buses genuinely run at. 32 reaches every rate below, and the device is left to object to
// anything it dislikes rather than being second-guessed here.
const cansub_max_brp = 32
const cansub_max_seg1 = 255
const cansub_max_seg2 = 128

// THE DATA PHASE IS NARROWER, and by a lot. Across the vendor's entire table the data segments
// never exceed DSEG1 17 and DSEG2 10, against 255 and 128 for the nominal phase — which is what a
// CAN-FD controller looks like, the data-phase registers being a few bits wide because the phase
// is short by design. Learned the hard way: a classic channel configured with its nominal timing
// repeated as the data phase (brp 1, seg1 255, seg2 64 at 250 kbit/s) is answered with HTTP 500 by
// a device that accepts the same numbers happily in `timing`.
const cansub_max_data_seg1 = 32
const cansub_max_data_seg2 = 16

// cansub_factory_data_timing is 1 Mbit/s at 80% — brp 4, seg1 15, seg2 4 — which is what every
// channel of a CANsub.4 ships set to, so it is known to be accepted by the hardware.
//
// It fills the `timing_data` a classic channel must still send. The device requires the field and
// the frames never use it, so what matters is only that it is VALID: a rate that cannot be
// expressed in the data registers at all — 250 kbit/s is one — would fail the whole configuration
// over a phase nothing will ever transmit in.
pub const cansub_factory_data_timing = CansubTiming{
	brp:  4
	seg1: 15
	seg2: 4
	sjw:  4
}

// CansubTiming is one phase's bit timing, in the device's own terms.
pub struct CansubTiming {
pub:
	brp  int
	seg1 int
	seg2 int
	sjw  int
}

// tq is the number of time quanta in a bit: the sync segment plus both phases.
pub fn (t CansubTiming) tq() int {
	return 1 + t.seg1 + t.seg2
}

// bitrate is what this timing actually produces. The inverse of the solver, so a test can check a
// solution rather than trusting it.
pub fn (t CansubTiming) bitrate() int {
	d := t.brp * t.tq()
	if d == 0 {
		return 0
	}
	return cansub_clock_hz / d
}

// sample_point_pct is where in the bit the controller samples, as a percentage.
pub fn (t CansubTiming) sample_point_pct() f64 {
	total := t.tq()
	if total == 0 {
		return 0
	}
	return 100.0 * f64(1 + t.seg1) / f64(total)
}

// cansub_timing_for solves for a bitrate at a sample point, or explains why it cannot.
//
// The smallest prescaler that works is chosen, because a larger one buys nothing and costs
// resolution: with more time quanta per bit the sample point lands closer to the one asked for,
// and the synchronisation jump width has more room. It also has to divide EXACTLY — a rate the
// clock cannot produce is refused rather than rounded, since a controller half a percent off its
// bus is a fault that appears under load and nowhere else.
pub fn cansub_timing_for(bitrate int, sample_point_pct int) !CansubTiming {
	return cansub_solve(bitrate, sample_point_pct, cansub_max_seg1, cansub_max_seg2)
}

// cansub_timing_for_data solves the CAN-FD data phase, whose registers are narrower. Separate
// from the nominal solver because a solution the nominal phase accepts is rejected outright in
// the data phase — with an HTTP 500, from a device that gave no hint which half was wrong.
pub fn cansub_timing_for_data(bitrate int, sample_point_pct int) !CansubTiming {
	return cansub_solve(bitrate, sample_point_pct, cansub_max_data_seg1, cansub_max_data_seg2) or {
		error('the CANsub cannot produce a ${bitrate} bit/s DATA phase at ${sample_point_pct}% — its data-phase segments are much shorter than its nominal ones')
	}
}

fn cansub_solve(bitrate int, sample_point_pct int, max_seg1 int, max_seg2 int) !CansubTiming {
	if bitrate <= 0 {
		return error('bitrate ${bitrate} is not a rate')
	}
	if sample_point_pct < 50 || sample_point_pct > 95 {
		return error('sample point ${sample_point_pct}% is outside 50-95%')
	}
	for brp in 1 .. cansub_max_brp + 1 {
		divisor := brp * bitrate
		if cansub_clock_hz % divisor != 0 {
			continue // not an exact division: this prescaler cannot make this rate
		}
		total := cansub_clock_hz / divisor
		if total < 4 {
			continue // too few quanta to place a sample point in
		}
		// Round to nearest rather than truncating, so 87.5% of 16 quanta is 14 and not 13.
		seg1 := (total * sample_point_pct + 50) / 100 - 1
		seg2 := total - 1 - seg1
		if seg1 < 1 || seg2 < 1 || seg1 > max_seg1 || seg2 > max_seg2 {
			continue
		}
		return CansubTiming{
			brp:  brp
			seg1: seg1
			seg2: seg2
			// SJW cannot exceed seg2 — it is how much of the phase-2 segment may be swallowed to
			// resynchronise. 4 is what the vendor's table uses wherever there is room for it, and
			// where there is not the table drops to seg2 exactly, which this reproduces.
			sjw: if seg2 < 4 { seg2 } else { 4 }
		}
	}
	return error('the CANsub cannot produce ${bitrate} bit/s at ${sample_point_pct}% from its ${cansub_clock_hz} Hz clock')
}

// cansub_phy_json is the body of a PUT to `/api/can/{channel}/phy`.
//
// `listen_only` is the hardware half of this repo's listen-only promise. The process-wide table in
// listen.v already refuses a send from every emitter (see `silenced`), and that stays: it moves
// with a row toggled mid-run, which a controller register cannot. Setting the register too means a
// silenced channel does not even ACK, which is the difference between a tester that is quiet and a
// tester that is not there — and on a bus with one other node, an ACK from us is the difference
// between its frames succeeding and it going error-passive.
//
// `error_frames` is on: `health()` has nothing else to report from. `tx_ack_frames` is on so a
// transmit can be confirmed on the wire rather than assumed, which is what `wiretap` wants.
// EVERY FIELD, ALWAYS — including `timing_data` on a channel that will never send an FD frame.
// The device requires the complete object and answers 400 "Incomplete or invalid request" to
// anything less; established by trying it, since the vendor's schema marks nothing as required and
// their example simply shows all of it. A classic channel gets its nominal timing as the data
// phase: valid, ignored in practice because `CansubBus.send` refuses an FD frame on a classic
// address, and honest — it describes a data phase that does not switch rate.
pub fn cansub_phy_json(nominal CansubTiming, data ?CansubTiming, listen_only bool) string {
	// A classic channel still has to name a data phase, and it must be one the DATA registers can
	// hold — the nominal timing repeated there is refused with a 500 at ordinary bitrates.
	phase := data or { cansub_factory_data_timing }
	mut s := '{"listen_only":${listen_only},"auto_reset":true,"error_frames":true,"tx_ack_frames":true'
	s += ',"timing":${timing_json(nominal)}'
	s += ',"timing_data":${timing_json(phase)}'
	return s + '}'
}

fn timing_json(t CansubTiming) string {
	return '{"brp":${t.brp},"seg1":${t.seg1},"seg2":${t.seg2},"sjw":${t.sjw}}'
}
