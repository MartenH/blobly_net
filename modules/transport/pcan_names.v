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
		return PcanTiming{
			brp:   brp
			tseg1: tseg1
			tseg2: tseg2
			// SJW cannot exceed tseg2 — it is how much of the phase-2 segment may be swallowed to
			// resynchronise. Four wherever there is room, which is what PEAK's own examples use.
			sjw: if tseg2 < 4 { tseg2 } else { 4 }
		}
	}
	return error('${pcan_fd_clock_hz} Hz cannot be divided into ${bitrate} bit/s at ${sample_point}% with these registers')
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
	_, arb, data, fd := pcan_split_fd(body, 500000) or { return err.msg() }
	if !fd {
		return none // a classic rate is a BTR code, checked by pcan_baud when the channel opens
	}
	pcan_fd_bitrate(arb, data, pcan_default_sample_point) or { return err.msg() }
	return none
}
