// Vector channel NAMES, deliberately not in vector_windows.v — same reason as pcan_names.v:
// the mapping from a spelling to a channel is pure string logic, it is the identity two
// mappings are compared on (destination_key), and kept beside the driver it would compile only
// on the machine that runs no tests.
module transport

// vector_app_channel resolves the channel part of `vector:<channel>[@<bitrate>]` to an XL
// APPLICATION channel number.
//
// Application channels, not hardware indices, because that is what the XL library addresses and
// what the operator already sees: Vector Hardware Configuration assigns a physical channel to
// an application's channel 1, 2, … and every XL program from CANoe down asks for its own
// channel by that number. Addressing the hardware directly would mean reproducing
// XLdriverConfig — some forty packed fields whose exact size decides where the channel array
// starts — from documentation, and an error there reads out of bounds rather than failing.
//
// ONE-BASED in the spelling, because Vector Hardware Config numbers them from 1 and an
// interface string the operator cannot match against the dialog in front of them is a trap.
// The API is 0-based, so the conversion happens here, once.
fn vector_app_channel(s string) !int {
	t := s.trim_space()
	if t == '' {
		return error('empty Vector channel — use vector:1 (the application channel in Vector Hardware Config)')
	}
	low := t.to_lower()
	mut body := low
	for p in ['channel', 'chan', 'ch', 'app'] {
		if body.starts_with(p) {
			body = body[p.len..].trim_space()
			break
		}
	}
	if body == '' || !body[0].is_digit() {
		return error('unknown Vector channel "${t}" (use vector:1, vector:ch1 or vector:app1)')
	}
	for c in body {
		if !c.is_digit() {
			return error('unknown Vector channel "${t}" (use vector:1, vector:ch1 or vector:app1)')
		}
	}
	n := body.int()
	// XL_CONFIG_MAX_CHANNELS is 64, and 0 is not a channel anybody is offered: rejecting it
	// here turns a spelling mistake into a message instead of an open against channel -1.
	if n < 1 || n > 64 {
		return error('Vector channel ${n} out of range (1..64)')
	}
	return n
}

// vector_key is the canonical channel part for destination_key: the application channel as a
// number, so `vector:1`, `vector:ch1` and `vector:app01` are ONE destination. Two mappings that
// address the same wire through different spellings must collide, or the conflict check waves
// them through and two recordings reach one bus.
fn vector_key(s string) string {
	// The MODE is not part of the address. destination_key strips it for free when a bitrate is
	// present (it reduces everything after `@` to a number), and not at all when one is absent —
	// so `vector:1` and `vector:1,silent` keyed differently and the check that stops two owners
	// reaching one bus waved them through. Stripped here, where both paths pass.
	body := if s.contains(',') { s.all_before_last(',') } else { s }
	if n := vector_app_channel(body) {
		return n.str()
	}
	return body.trim_space().to_lower() // unresolvable: identical bad strings still collide
}

// vector_fd_clock_hz is the CAN controller clock the FD segment arithmetic below assumes.
//
// STATED, because it is the one number here that is a property of the hardware rather than of the
// standard, and it is not discoverable: XLcanFdConf takes the two bitrates and the segment counts
// and the DRIVER derives the prescaler, so nothing in the API reports what it divided. 80 MHz is
// what the VN family runs its CAN controllers at, and every VN device this backend has been used
// on. Where it is wrong the consequence is contained and loud — no integer prescaler exists, the
// driver refuses xlCanFdSetConfiguration, and the open reports that refusal with both rates in it
// rather than running the bus at something nobody asked for.
const vector_fd_clock_hz = 80_000_000

// FdTiming is one phase's bit timing: how many quanta the bit is divided into, and where in it
// the controller samples.
struct FdTiming {
	tseg1 int
	tseg2 int
	sjw   int
}

// vector_fd_timing picks the bit timing for ONE phase at one rate.
//
// WHY THIS IS OURS TO CHOOSE AT ALL. XLcanFdConf has no prescaler field and no "just give me this
// bitrate" form — it takes the rates AND tseg1/tseg2/sjw, and the driver computes
// brp = clock / (bitrate * (1 + tseg1 + tseg2)). So the segment count is not a refinement on top
// of a working configuration; without it there is no configuration, and a count that does not
// divide the clock exactly is refused outright.
//
// PER PHASE, which is how the struct is shaped and — as it turns out — the only way that works.
// The first version searched for ONE quanta count satisfying both rates, on the reasoning that
// CiA 601-3 wants the same sample point in both phases. That conflates the sample POINT with the
// quanta COUNT: the point is a ratio and each phase reaches it with its own count and its own
// prescaler. Requiring a shared count refuses combinations the hardware can do — 800k/5M is exact
// at 20 quanta for arbitration and 16 for data, and their only common counts are below the
// minimum, so a rate pair the parser accepts could never be opened (codex #181 r3).
//
// Searched from the finest downwards, because more quanta per bit means a smaller prescaler and
// so a finer resynchronisation step, which is what a bus with reflections on it wants.
fn vector_fd_timing(rate int) FdTiming {
	// 25 down to 8: below eight quanta a bit there is not enough resolution to place an 80%
	// sample point at all, and above 25 the prescaler reaches 1 for the rates FD is used at.
	for tq := 25; tq >= 8; tq-- {
		if rate > 0 && vector_fd_clock_hz % (rate * tq) == 0 {
			return vector_fd_split(tq)
		}
	}
	// NOTHING DIVIDES. Returning a shape anyway, rather than an error, because the driver is the
	// authority on what it will accept and its refusal names the channel and the rates; inventing
	// a failure here would report "unsupported" for a combination some future controller clock
	// takes. 20 quanta is the default shape, and it is what the common rates resolve to.
	return vector_fd_split(20)
}

// vector_fd_split places the sample point at ~80% of a bit divided into `tq` quanta.
fn vector_fd_split(tq int) FdTiming {
	// The bit is 1 (sync) + tseg1 + tseg2 quanta, and the sample point sits at the end of tseg1 —
	// so (1 + tseg1) / tq is the figure being aimed at. Rounded, and floored at 2 quanta of
	// tseg2: a single-quantum phase-2 segment leaves no room to shorten on resynchronisation.
	mut t2 := (tq + 2) / 5 // round(tq * 0.2)
	if t2 < 2 {
		t2 = 2
	}
	t1 := tq - 1 - t2
	// sjw cannot exceed tseg2 — it is the amount phase 2 may be shortened by — and there is
	// nothing to gain from more than 4.
	mut sjw := t2
	if sjw > 4 {
		sjw = 4
	}
	return FdTiming{
		tseg1: t1
		tseg2: t2
		sjw:   sjw
	}
}

// VectorSpec is the parsed interface string.
//
// HERE, not in vector_windows.v, and the difference is not cosmetic: written beside the driver
// it compiled only on Windows, where nothing runs these tests — so the rule that a malformed
// bitrate is refused had no test at all, and the project migration was preserving malformed
// rates on the strength of a rejection that did not exist. This file is the one that gets to
// be checked.
struct VectorSpec {
	channel int // application channel, 1-based as the operator sees it
	bitrate int // the arbitration rate; the only rate a classic address has
	silent  bool
	// CAN-FD, spelled `@<arb>/<data>`. `fd` and a zero `data_bitrate` cannot occur together:
	// vendor_split_fd_rate derives the flag FROM the second rate, so there is no state in which
	// the backend is asked for FD without being told what its payload phase runs at.
	fd           bool
	data_bitrate int
}

fn parse_vector_spec(spec string) !VectorSpec {
	mut body := spec.trim_space()
	mut silent := false
	// The mode is a suffix, not part of the address: `vector:1@500000` and
	// `vector:1@500000,silent` are the SAME wire, and destination_key must see them collide or
	// the conflict check lets two owners onto one bus.
	if body.contains(',') {
		mode := body.all_after_last(',').trim_space().to_lower()
		body = body.all_before_last(',')
		match mode {
			'silent', 'listen_only', 'listenonly' { silent = true }
			'normal' { silent = false }
			else { return error('unknown Vector mode ",${mode}" (use ,silent)') }
		}
	}
	// BOTH RULES live in vendor_spec.v now, because each of them has been got wrong once per
	// backend when it lived beside a single caller.
	// SPLIT ON `@` FIRST, then on `/` inside the rate: the "at most one rate" rule is about the
	// `@` separator and still holds — `vector:1@500000@250000` is as wrong as it ever was — while
	// `/` divides the two phases of the ONE rate an FD address carries.
	parts := body.split('@')
	if parts.len > 2 {
		return error('Vector: "${body}" has more than one bitrate — the rate belongs in the channel\'s bitrate field, not in its address')
	}
	chan_part := parts[0]
	mut bitrate := 500000
	mut fd := false
	mut dbr := 0
	if parts.len > 1 {
		bitrate, dbr, fd = vendor_split_fd_rate(parts[1], 500000) or {
			return error('Vector: ${err}')
		}
	}
	ch := vector_app_channel(chan_part)!
	// A bitrate the hardware cannot produce is a configuration error worth catching here: on a
	// live bus the consequence of getting it wrong is error frames, not a quiet failure.
	if bitrate < 5000 || bitrate > 1000000 {
		return error('Vector bitrate ${bitrate} out of range (5000..1000000)')
	}
	// THE DATA PHASE HAS ITS OWN CEILING, and it is the reason FD exists: 8 Mbit/s is what
	// ISO 11898-1 allows and what a VN device's controller will accept. The arbitration limit
	// above stays at 1 Mbit/s, because that phase is still classic CAN however fast the payload
	// goes — checked separately rather than sharing one range, which would let an address ask for
	// arbitration at 4 Mbit/s.
	if fd && (dbr < 5000 || dbr > 8000000) {
		return error('Vector CAN-FD data bitrate ${dbr} out of range (5000..8000000)')
	}
	return VectorSpec{
		channel:      ch
		bitrate:      bitrate
		silent:       silent
		fd:           fd
		data_bitrate: dbr
	}
}
