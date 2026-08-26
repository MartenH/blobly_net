// kvaser_names.v — the Kvaser address and its bitrate codes, as PURE decisions.
//
// HERE, not in kvaser_windows.v, and the difference is not cosmetic: written beside the driver
// this logic compiles only on Windows, where nothing runs the tests — which is how the Vector
// backend once ended up with a "a malformed bitrate is refused" rule that had no test at all.
// This file is the one that gets to be checked, on every push, by a CI runner with no adapter in
// it. `kvaser_windows.v` keeps the parts that genuinely need canlib.
module transport

// KvaserSpec is a parsed `kvaser:<channel>[@<arb>[/<data>]]`.
pub struct KvaserSpec {
pub:
	channel int
	bitrate int // arbitration
	// CAN-FD, spelled `@<arb>/<data>`. `fd` and a zero `data_bitrate` cannot occur together:
	// naming the data rate is what turns FD on, so there is no way to ask for one without the
	// other and no state where the driver would have to guess a payload phase.
	fd           bool
	data_bitrate int
}

// kvaser_spec parses the interface body after `kvaser:`.
pub fn kvaser_spec(body string) !KvaserSpec {
	// SPLIT ON `@` FIRST, then on `/` inside the rate: "at most one bitrate" is a rule about the
	// `@` separator and still holds — `kvaser:0@500000@250000` is as wrong as it ever was — while
	// `/` divides the two phases of the ONE rate an FD address carries.
	parts := body.split('@')
	if parts.len > 2 {
		return error('Kvaser: "${body}" has more than one bitrate — the rate belongs in the channel\'s bitrate field, not in its address')
	}
	chan_tok := parts[0].trim_space()
	if chan_tok == '' {
		return error('Kvaser: no channel in "${body}" — kvaser:0, kvaser:1, …')
	}
	// DIGITS ONLY, for the reason vendor_bitrate gives about rates: V's `.int()` takes a numeric
	// prefix, so `kvaser:0abc` opened channel 0 while the project believed something else.
	for c in chan_tok {
		if !c.is_digit() {
			// NAMED, because this one used to "work". `kvaser:virtual0` was documented as the
			// no-hardware path, and the old parser's `.int()` turned it into channel 0 — which
			// is a PHYSICAL channel on any bench that has an adapter, so the documented address
			// silently opened the wrong wire and only behaved on a machine with no Kvaser
			// hardware at all. Refusing it is the fix; refusing it without saying where the
			// number comes from would just move the confusion.
			if chan_tok.to_lower().starts_with('virtual') {
				return error('Kvaser: "${chan_tok}" is not a canlib channel — canlib numbers virtual channels alongside physical ones, and `virtual0` used to parse as channel 0 (a physical channel wherever an adapter is fitted). Run `kvasercheck --list` for the numbers and which are virtual')
			}
			return error('Kvaser: "${chan_tok}" is not a channel number — canlib counts them from 0 (`kvasercheck --list`)')
		}
	}
	mut bitrate := 500000
	mut dbr := 0
	mut fd := false
	if parts.len > 1 {
		bitrate, dbr, fd = vendor_split_fd_rate(parts[1], 500000) or {
			return error('Kvaser: ${err}')
		}
	}
	return KvaserSpec{
		channel:      chan_tok.int()
		bitrate:      bitrate
		fd:           fd
		data_bitrate: dbr
	}
}

// kvaser_bitrate_code maps an ARBITRATION bit rate to a canBITRATE_* code (negative constants
// canlib accepts directly as the freq arg of canSetBusParams).
pub fn kvaser_bitrate_code(bitrate int) !int {
	return match bitrate {
		1000000 { -1 } // canBITRATE_1M
		500000 { -2 } // canBITRATE_500K
		250000 { -3 } // canBITRATE_250K
		125000 { -4 } // canBITRATE_125K
		100000 { -5 } // canBITRATE_100K
		62500 { -6 } // canBITRATE_62K
		50000 { -7 } // canBITRATE_50K
		83000 { -8 } // canBITRATE_83K
		10000 { -9 } // canBITRATE_10K
		else { error('unsupported Kvaser bitrate ${bitrate} (use 10k/50k/62k/83k/100k/125k/250k/500k/1M)') }
	}
}

// kvaser_fd_arb_code maps the ARBITRATION rate of a CAN-FD channel to a canFD_BITRATE_* code.
//
// NOT kvaser_bitrate_code, and this is the subtle one. canlib's classic canBITRATE_500K samples
// at 62.5%; the canFD_BITRATE_*_80P family samples at 80%, and Kvaser's own FD examples pass an
// FD constant to BOTH canSetBusParams and canSetBusParamsFd. Mixing them gives a channel whose
// arbitration phase samples at 62.5% while its data phase samples at 80% — legal, and quietly
// different from every partner configured the ordinary way, including our own Vector backend
// which targets ~80% in both.
//
// A LOOPBACK BENCH CANNOT CATCH THIS: both ends share the timing, so the wrong sample point
// passes every frame. It was caught in review, not on the wire, which is the reason it is written
// down here rather than left as two constants that happen to differ.
//
// FD arbitration is therefore 500k or 1M — the rates the 80% family offers at or below the
// 1 Mbit/s ceiling arbitration has whatever the payload phase does. A classic channel is
// unaffected and keeps the full classic range.
pub fn kvaser_fd_arb_code(rate int) !int {
	return match rate {
		500000 { -1000 } // canFD_BITRATE_500K_80P
		1000000 { -1001 } // canFD_BITRATE_1M_80P
		else { error('unsupported Kvaser CAN-FD arbitration bitrate ${rate} (use 500k or 1M — the 80% sample-point family canlib offers for an arbitration phase; a classic channel takes the full range)') }
	}
}

// kvaser_fd_data_code maps a CAN-FD DATA-phase bit rate to a canFD_BITRATE_* code.
//
// A SEPARATE FAMILY from the arbitration codes above, not an extension of it: different
// constants for a different phase, with different sample points. Both families are small
// negative numbers, so confusing them compiles, runs, and configures the wrong phase — which is
// why there is a test holding the two apart.
//
// canlib publishes 80% sample points for 500k..4M and only a 60% one at 8M, where the
// propagation segment no longer fits an 80% point.
pub fn kvaser_fd_data_code(rate int) !int {
	return match rate {
		500000 { -1000 } // canFD_BITRATE_500K_80P
		1000000 { -1001 } // canFD_BITRATE_1M_80P
		2000000 { -1002 } // canFD_BITRATE_2M_80P
		4000000 { -1003 } // canFD_BITRATE_4M_80P
		8000000 { -1004 } // canFD_BITRATE_8M_60P — canlib offers no 80% point at 8M
		else { error('unsupported Kvaser CAN-FD data bitrate ${rate} (use 500k/1M/2M/4M/8M)') }
	}
}

// kvaser_address_error reports why this address could not be opened, or none when it can.
//
// THE SAME RULES `open_kvaser` APPLIES, run without touching canlib, so an editor can refuse a
// rate before it is persisted rather than at Start. Vector has this and the reason is the same:
// a front end that reproduces the rules keeps producing a SUBSET of them, and the subset is
// always missing the case somebody just hit. Everything here is a call into the functions the
// open path itself uses, so anything this accepts, the open accepts.
pub fn kvaser_address_error(iface string) ?string {
	i := iface.trim_space()
	body := if i.to_lower().starts_with('kvaser:') { i['kvaser:'.len..] } else { i }
	s := kvaser_spec(body) or { return err.msg() }
	if s.fd {
		kvaser_fd_arb_code(s.bitrate) or { return err.msg() }
		kvaser_fd_data_code(s.data_bitrate) or { return err.msg() }
	} else {
		kvaser_bitrate_code(s.bitrate) or { return err.msg() }
	}
	return none
}

// kvaser_open_refusal turns a canStatus from canOpenChannel into something an operator can act
// on, for the one status that lies.
//
// MEASURED, not guessed (bench, USBcan Pro 5xHS, canlib 8.52):
//
//   classic + classic on one channel      both open
//   FD + FD at the same data rate         both open
//   classic then FD, or FD then classic   SECOND REFUSED, canStatus -3
//   FD at 2M then FD at 4M                both open
//
// So canlib pins the PROTOCOL across the handles on a channel and does not pin the data rate.
// The refusal is loud, which is the good half; the status is canERR_NOTFOUND and canlib renders
// it "Specified device not found", which is the bad half — the device is plainly present, and an
// operator reading that goes looking for a cable or a driver. The likely truth is that this
// process already holds the channel in the other protocol: a disabled row keeps its transmit tap
// open on purpose (#165), so a classic tap outlives its row and refuses the FD opens that follow.
//
// It says "likely" because canlib gives one status for a family of causes and nothing separates
// them from outside. Naming the probable one with its remedy beats repeating a sentence that is
// false on its face.
pub fn kvaser_open_refusal(st int, ch int, fd bool) string {
	if st != -3 {
		return 'canStatus ${st}'
	}
	other := if fd { 'classic' } else { 'CAN-FD' }
	want := if fd { 'CAN-FD' } else { 'classic' }
	return 'canStatus -3 (canERR_NOTFOUND). canlib reports that as "device not found", but channel ${ch} is enumerated — it refuses a second handle in a different protocol, and this process may already hold it as ${other} while this row asks for ${want}. A disabled row keeps its transmit tap open, so one can outlive the row that made it: Stop and Start to change a wire\'s protocol'
}
