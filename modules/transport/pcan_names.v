// PCAN channel NAMES, deliberately not in pcan_windows.v.
//
// The mapping from a spelling to a channel handle is pure string logic — no vendor DLL, no
// Windows API — and it is the identity two mappings are compared on (destination_key). Kept in
// a platform-neutral file so it can be unit-tested on the machine anyone actually develops on;
// living beside the driver made it compile only where nothing runs the tests, and a second
// implementation of these rules had already drifted once.
module transport

fn pcan_handle(s string) !u16 {
	t := s.trim_space()
	// EMPTY FIRST. `adapter: pcan` with no address composes to `pcan:`, and this used to index
	// t[0] on an empty string — a panic, in a validation pass whose whole job is to report a bad
	// configuration rather than die on one. It only became reachable when the resolver stopped
	// being Windows-only, which is the kind of thing widening a guard exposes.
	if t == '' {
		return error('empty PCAN channel — give the row an address (PCAN_USBBUS1, usb1, 1, or 0x51)')
	}
	low := t.to_lower()
	if low.starts_with('0x') {
		return u16(t.all_after('0x').parse_uint(16, 16) or {
			return error('bad PCAN handle "${t}"')
		})
	}
	mut n := -1
	if low.starts_with('pcan_usbbus') {
		n = low.all_after('pcan_usbbus').int()
	} else if low.starts_with('usb') {
		n = low.all_after('usb').int()
	} else if t[0].is_digit() {
		n = t.int()
	}
	if n >= 1 && n <= 8 {
		return u16(0x50 + n) // PCAN_USBBUS1 == 0x51
	}
	return error('unknown PCAN channel "${t}" (use PCAN_USBBUS1..8, usb1.., 1.., or 0x51)')
}

// CAN-FD bit timing for PCANBasic, solved rather than tabulated.
//
// `CAN_InitializeFD` does not take a rate. It takes a STRING of register values — clock, prescaler
// and segment counts for both phases — so something has to turn "500000/2000000" into
// `f_clock=80000000,nom_brp=2,nom_tseg1=63,...`. A table of the half-dozen rates somebody thought
// of is the tempting version and it is how a bench ends up unable to run at a rate the hardware
// could manage perfectly well.
//
// PURE, AND OUTSIDE `_windows.v`, for the reason kvaser_names.v gives: a `_windows.v` file compiles
// only where CI runs nothing, so the arithmetic that decides what the controller is configured to
// would be the part no test could reach.

// pcan_fd_clock_hz is the clock PCANBasic's FD string is expressed against. The Pro FD can be told
// to use several, and 80 MHz is the one PEAK's own examples use and the only one every FD-capable
// PEAK device offers.
pub const pcan_fd_clock_hz = 80_000_000

// The FD register widths, from PCANBasic's documented ranges. The DATA phase is much narrower than
// the nominal one, which is what makes a solution for one phase useless for the other.
const pcan_nom_max_tseg1 = 256

const pcan_nom_max_tseg2 = 128

const pcan_data_max_tseg1 = 32

const pcan_data_max_tseg2 = 16

const pcan_max_brp = 1024

// PcanTiming is one solved phase.
pub struct PcanTiming {
pub:
	brp   int
	tseg1 int
	tseg2 int
	sjw   int
}

// pcan_sample_point_tolerance is how far the achievable sample point may sit from the one asked
// for, in percentage points, before the rate is refused instead.
//
// Two, and the number is set by what the verified rates need rather than by taste: 500k, 1M, 2M, 4M
// and 8M all land on 80.00% exactly, and 5 Mbit/s -- sixteen quanta -- lands on 81.25%, the coarsest
// placement any rate this bench has run at. One point would refuse 5M for no reason anybody can
// measure; five would let 10 Mbit/s through at 75%, which is the defect this constant exists for.
const pcan_sample_point_tolerance = 2

// pcan_solve_phase finds the smallest prescaler that hits `bitrate` EXACTLY at `sample_point`.
//
// Exactly, because a rate the clock cannot produce is refused rather than rounded: a controller
// half a percent off its bus is a fault that appears under load and nowhere else. The smallest
// prescaler is preferred because more time quanta per bit put the sample point closer to the one
// asked for and leave the jump width more room.
fn pcan_solve_phase(bitrate int, sample_point int, max_tseg1 int, max_tseg2 int) !PcanTiming {
	if bitrate <= 0 {
		return error('bitrate ${bitrate} is not a rate')
	}
	if sample_point < 50 || sample_point > 95 {
		return error('sample point ${sample_point}% is outside 50-95%')
	}
	// A rate above a quarter of the clock leaves no room for four time quanta in a bit, whatever
	// the prescaler. Refused in words here rather than as arithmetic that wanders off below.
	if i64(bitrate) > i64(pcan_fd_clock_hz) / 4 {
		return error('bitrate ${bitrate} is above a quarter of the ${pcan_fd_clock_hz} Hz clock — there are not four time quanta in a bit at that rate')
	}
	// The closest sample point any prescaler managed, kept so a refusal can say what the rate CAN
	// do instead of only that it cannot have what was asked.
	mut closest := 0
	mut have_closest := false
	for brp in 1 .. pcan_max_brp + 1 {
		divisor := i64(brp) * i64(bitrate)
		if i64(pcan_fd_clock_hz) % divisor != 0 {
			continue // not an exact division: this prescaler cannot make this rate
		}
		total := int(i64(pcan_fd_clock_hz) / divisor)
		if total < 4 {
			continue
		}
		// Rounded to nearest rather than truncated, so 80% of 20 quanta is 16 and not 15.
		tseg1 := (total * sample_point + 50) / 100 - 1
		tseg2 := total - 1 - tseg1
		if tseg1 < 1 || tseg2 < 1 || tseg1 > max_tseg1 || tseg2 > max_tseg2 {
			continue
		}
		// AND THE ROUNDING IS CHECKED, because the bit being exact does not make the SAMPLE POINT
		// exact and this function's whole promise is both. A bit divided into few time quanta can
		// only place the sample at coarse fractions of itself: 10 Mbit/s off an 80 MHz clock is
		// eight quanta, and the nearest placement to 80% is 6/8 — 75%, delivered silently while
		// the project refuses any sample point but 80 (codex round 2 on #217). Nodes that disagree
		// about where in the bit to look are a fault that appears under load and nowhere else,
		// which is exactly the class this file already refuses inexact rates to avoid.
		//
		// A LARGER PRESCALER CANNOT HELP: total = clock / (brp * bitrate), so every later brp has
		// FEWER quanta and strictly coarser placement. The loop continues anyway rather than
		// asserting that here — the register limits above can reject the first candidates, so the
		// first ACCEPTABLE brp is not always brp 1.
		achieved := (1 + tseg1) * 100 / total
		if !have_closest || abs_diff(achieved, sample_point) < abs_diff(closest, sample_point) {
			closest = achieved
			have_closest = true
		}
		if abs_diff(achieved, sample_point) > pcan_sample_point_tolerance {
			continue
		}
		return PcanTiming{
			brp:   brp
			tseg1: tseg1
			tseg2: tseg2
			// SJW cannot exceed tseg2 — it is how much of the phase-2 segment may be swallowed to
			// resynchronise. Four wherever there is room, which is what PEAK's own examples use.
			sjw: if tseg2 < 4 { tseg2 } else { 4 }
		}
	}
	if have_closest {
		return error('${bitrate} bit/s divides the ${pcan_fd_clock_hz} Hz clock into too few time quanta to place the sample point at ${sample_point}% — the closest it can manage is ${closest}%')
	}
	return error('${pcan_fd_clock_hz} Hz cannot be divided into ${bitrate} bit/s at ${sample_point}% with these registers')
}

fn abs_diff(a int, b int) int {
	return if a > b { a - b } else { b - a }
}

// pcan_fd_bitrate builds the string CAN_InitializeFD takes, or explains why it cannot.
pub fn pcan_fd_bitrate(nominal int, data int, sample_point int) !string {
	nom := pcan_solve_phase(nominal, sample_point, pcan_nom_max_tseg1, pcan_nom_max_tseg2) or {
		return error('arbitration ${nominal}: ${err.msg()}')
	}
	dat := pcan_solve_phase(data, sample_point, pcan_data_max_tseg1, pcan_data_max_tseg2) or {
		return error('data phase ${data}: ${err.msg()}')
	}
	return 'f_clock=${pcan_fd_clock_hz},nom_brp=${nom.brp},nom_tseg1=${nom.tseg1},nom_tseg2=${nom.tseg2},nom_sjw=${nom.sjw},data_brp=${dat.brp},data_tseg1=${dat.tseg1},data_tseg2=${dat.tseg2},data_sjw=${dat.sjw}'
}

// pcan_baud maps a bit rate to the PCANBasic BTR0BTR1 baudrate code.
//
// HERE RATHER THAN BESIDE THE DRIVER, for the reason the rest of this file gives: a `_windows.v`
// file compiles only where CI runs nothing, and these are transcribed register values — the one
// kind of constant a review cannot check by reading and a test can.
pub fn pcan_baud(bitrate int) !u16 {
	return match bitrate {
		1000000 { u16(0x0014) }
		800000 { u16(0x0016) }
		500000 { u16(0x001C) }
		250000 { u16(0x011C) }
		125000 { u16(0x031C) }
		100000 { u16(0x432F) }
		50000 { u16(0x472F) }
		20000 { u16(0x532F) }
		10000 { u16(0x672F) }
		else { error('unsupported PCAN bitrate ${bitrate} (use 10k/20k/50k/100k/125k/250k/500k/800k/1M)') }
	}
}

// pcan_classic_sample_point is where in the bit a CLASSIC PCAN channel samples, decoded from the
// BTR code it will actually be opened with.
//
// THE CLASSIC RATES ARE NOT SOLVED, THEY ARE LOOKED UP — and the fixed codes above do not agree on
// a sample point: 1 Mbit/s samples at 75%, 800k at 80%, 125k-500k at 87.5% and 10k-100k at 85%.
// So the FD default of 80% says nothing at all about a classic row, and a validator that applied
// it to one refused `sample_point: 87.5` at 500 kbit/s — which is exactly what that channel does —
// while accepting a request for 80%, which it does not (codex round 3 on #217).
//
// BTR1 is the SJA1000 layout PCANBasic inherited: bits 0-3 are TSEG1-1, bits 4-6 are TSEG2-1, and
// the bit is 1 + TSEG1 + TSEG2 time quanta with the sample taken at the end of TSEG1. BTR0 carries
// the prescaler and SJW, which move the RATE and not the sample point, and are not read here.
pub fn pcan_classic_sample_point(bitrate int) !f64 {
	code := pcan_baud(bitrate)!
	btr1 := u8(code & 0xFF)
	tseg1 := int(btr1 & 0x0F) + 1
	tseg2 := int((btr1 >> 4) & 0x07) + 1
	total := 1 + tseg1 + tseg2
	return f64(1 + tseg1) * 100.0 / f64(total)
}

// pcan_default_sample_point is where both phases are placed when the address does not say. 80% is
// what CiA recommends above 500 kbit/s and what every FD example from PEAK and CSS uses.
pub const pcan_default_sample_point = 80

// pcan_split_fd separates `<channel>[@<arbitration>[/<data>]]`.
//
// Pure, so the address rule is testable without a driver — and it applies the SAME two rules the
// other vendor backends do: at most one bitrate, and a data phase that is not slower than the
// arbitration one. `vendor_split_fd_rate` states the second once for everybody.
pub fn pcan_split_fd(spec string, default_rate int) !(string, int, int, bool) {
	body := spec.trim_space()
	parts := body.split('@')
	if parts.len > 2 {
		return error('"${body}" has more than one bitrate — a CAN-FD address is <channel>@<arbitration>/<data>')
	}
	chan_part := parts[0].trim_space()
	if chan_part == '' {
		return error('no channel in "${body}" — pcan:PCAN_USBBUS1, pcan:usb1, …')
	}
	if parts.len == 1 {
		return chan_part, default_rate, 0, false
	}
	arb, data, fd := vendor_split_fd_rate(parts[1], default_rate)!
	return chan_part, arb, data, fd
}

// pcan_address_error reports why a PCAN address could not be opened as configured, or none.
//
// THE EDITOR HAS TO BE ABLE TO ASK. Every other vendor backend has one of these, and without it a
// PCAN FD rate the 80 MHz clock cannot divide exactly — a 3 Mbit/s data phase, say — was accepted
// by the editor, saved, and refused only when somebody pressed Start. That is verbatim the failure
// the CANsub and Kvaser validators exist to prevent, and it was recurring one adapter over
// (self-review of #217).
//
// Composed through the row's own `iface_with_bitrate()`, so whatever this accepts, the open
// accepts: it asks the same parser and the same solver the open path does.
pub fn pcan_address_error(iface string) ?string {
	body := if iface.to_lower().starts_with('pcan:') { iface['pcan:'.len..] } else { iface }
	// `chan_tok` and not `chan`: V reserves that word for the channel type.
	chan_tok, arb, data, fd := pcan_split_fd(body, 500000) or { return err.msg() }
	// THE CHANNEL, THROUGH THE PARSER THE OPEN USES. pcan_split_fd only checks that the token is
	// non-empty, so this discarded it and validated the timing alone: `pcan:bogus@500000/2000000`
	// was accepted by the editor, saved, and then refused by pcan_handle at Start — the validator
	// contradicting its own promise two lines above (codex round 4 on #217).
	pcan_handle(chan_tok) or { return err.msg() }
	if !fd {
		// AND THE CLASSIC RATE TOO, for the same reason. "checked by pcan_baud when the channel
		// opens" is exactly the deferral this function exists to end; pcan_baud is in this file
		// now, so there is nothing left to defer to.
		pcan_baud(arb) or { return err.msg() }
		return none
	}
	pcan_fd_bitrate(arb, data, pcan_default_sample_point) or { return err.msg() }
	return none
}
