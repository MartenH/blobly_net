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
// REFUSES rather than guessing. The first version returned a default shape when nothing divided,
// on the reasoning that the driver is the authority on what it accepts. That reasoning was wrong
// in a way worth keeping: a shape that does not divide is not a configuration the driver might
// take a different view of — it CANNOT produce the requested bitrate, arithmetically, and the
// driver's only possible answer is a bare XL status against an address the parser had accepted.
//
// Two ways a rate can be unusable on this clock, and both are reachable from addresses
// parse_vector_spec allows (codex #181 r4):
//   - NO WHOLE PRESCALER AT ANY COUNT. 750000 needs brp*tq = 80e6/750e3 = 106.67, which is not an
//     integer at all, so no division of the bit can produce it.
//   - A PRESCALER THE CONTROLLER CANNOT HOLD. 5000 bit/s at 25 quanta needs brp 640, over the
//     8-bit field's 256.
// THE TWO PHASES DO NOT HAVE THE SAME LIMITS, which is why this takes the phase rather than only
// the rate. An FD controller's NOMINAL segment fields are wide — the arbitration phase is ordinary
// CAN and its tseg1 is an 8-bit field on the usual silicon — while the DATA phase's are narrow,
// because it has to switch fast. Applying the data phase's ceiling to both refused arbitration
// timings the hardware can do: 5 kbit/s is exact at 64 quanta with prescaler 250, well inside the
// nominal fields, and was rejected only because 25 was being used as a universal bound. The claim
// in the round-4 message that 5 kbit/s "needs prescaler 640" was true only under that self-imposed
// ceiling (codex #181 r5).
//
// The ceilings below are deliberately conservative rather than the widest any controller allows:
// XLcanFdConf declares its fields as plain unsigned ints and states no ranges, so these are chosen
// to sit inside what the common FD silicon accepts for each phase rather than to be maximal.
const fd_tq_max_arbitration = 64
const fd_tq_max_data = 25

fn vector_fd_timing(rate int) !FdTiming {
	return vector_fd_timing_for(rate, fd_tq_max_arbitration)
}

// vector_fd_timing_data is the data phase's narrower search. Kept as its own entry point so a
// caller cannot pass the wrong ceiling by getting an argument order wrong.
fn vector_fd_timing_data(rate int) !FdTiming {
	return vector_fd_timing_for(rate, fd_tq_max_data)
}

fn vector_fd_timing_for(rate int, tq_max int) !FdTiming {
	if rate <= 0 {
		return error('${rate} is not a bitrate')
	}
	// Downwards from the ceiling: more quanta per bit means a smaller prescaler and so a finer
	// resynchronisation step. Below eight there is not enough resolution to place an 80% sample
	// point at all.
	for tq := tq_max; tq >= 8; tq-- {
		if vector_fd_clock_hz % (rate * tq) != 0 {
			continue
		}
		// THE PRESCALER HAS TO FIT. A whole brp is not the same as a usable one: the low end of
		// the accepted range divides cleanly and then asks for a value the field cannot hold.
		brp := vector_fd_clock_hz / (rate * tq)
		if brp < 1 || brp > 256 {
			continue
		}
		return vector_fd_split(tq)
	}
	return error('${rate} bit/s cannot be produced from this controller\'s ${vector_fd_clock_hz / 1_000_000} MHz clock: no whole prescaler of 256 or less divides it at 8 to ${tq_max} quanta per bit')
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

// vector_address_error reports why a `vector:` interface string could not be opened, or none when
// it can. The scheme prefix is optional, so a caller may pass either what it stores or what it
// opens with.
//
// THE WHOLE RULE, not a piece of it. This exists because a front end that wanted to check a rate
// pair before Start reached for vendor_split_fd_rate — which enforces the ORDERING and leaves the
// RANGES to parse_vector_spec, so a 9 Mbit/s data phase passed the editor and was refused at open
// (codex #183 r1, caught by its own test). Running the real parser is the only check that cannot
// be a subset of the real check.
pub fn vector_address_error(iface string) ?string {
	i := iface.trim_space()
	body := if i.to_lower().starts_with('vector:') { i['vector:'.len..] } else { i }
	s := parse_vector_spec(body) or { return err.msg() }
	return vector_timing_error(s)
}

// vector_timing_error is the SECOND half of "can this address be opened" — whether this
// controller's clock can actually produce the rates the parser accepted.
//
// SPLIT OUT SO BOTH CALLERS RUN IT. open_vector derives the same timings and refuses on the same
// condition; a front end that wanted to check an address before Start therefore had to reproduce
// that, and every attempt so far has been a SUBSET of it. Three rounds running:
//   - the first checked ordering via vendor_split_fd_rate and missed the ranges;
//   - the second ran parse_vector_spec and got syntax, ordering and range — and missed timing, so
//     `500000/750000` was accepted by the editor, saved, and refused only while opening, at a
//     rate this file's own test pins as unproducible (codex #183 r2);
//   - so the answer is not a third hand-written approximation but ONE function that both the
//     editor and the open consult.
// Whatever this accepts, open_vector accepts.
fn vector_timing_error(s VectorSpec) ?string {
	// CLASSIC DERIVES NOTHING, and must not be judged as though it did: xlCanSetChannelBitrate
	// lets the driver work the timing out, which is what keeps ordinary rates like 83333 — that
	// no prescaler produces from this clock — perfectly openable (#182 r1).
	if !s.fd {
		return none
	}
	vector_fd_timing(s.bitrate) or { return 'arbitration ${err.msg()}' }
	vector_fd_timing_data(s.data_bitrate) or { return 'CAN-FD data phase ${err.msg()}' }
	return none
}

// AppSlot is what the driver said about ONE application channel — three states, because the third
// is the one this code kept losing.
//
// FOUR ROUNDS OF THE SAME BUG put this here. Every version of the free-channel search and the
// mapping sweep folded "the driver would not answer" into either "empty" or "taken", and each time
// the consequence was a write over something real: a mapping retargeted, or a second application
// channel aliased onto one physical wire (#167's exact prohibition). The decision was never the
// hard part — it was that the decision lived inside the driver calls, where it could not be
// tested, so each fix was checked by reasoning about it and the reasoning was wrong four times.
//
// So the DECISION is pure and lives here, in the file that gets tested; the driver I/O that
// produces the slots stays in vector_windows.v. That is the same split vector_names.v already
// exists for, and its own header says why: written beside the driver, a rule compiles only on
// Windows, where nothing runs these tests.
pub enum AppSlot {
	unknown // the driver would not answer for this channel
	empty   // the driver says it is unassigned
	taken   // the driver says it points at hardware
}

// pick_free_app_channel chooses the application channel to offer, given what the driver said about
// each one. `slots[i]` describes application channel `i + 1`.
//
// AN EXPLICIT EMPTY ALWAYS WINS. Anything else risks writing over a mapping somebody made, and no
// convenience is worth that.
//
// NOTHING ANSWERED AT ALL is the one case where an unknown may be offered, and it is safe for a
// reason rather than by assumption: if not a single channel could be read, there is no application
// to damage — every write creates rather than replaces — and that is exactly the fresh bench this
// feature exists for. A bench where SOME channels answer is a working driver with a real
// application, and there an unexplained failure is never written to.
//
// The conservative corner is deliberate: an application whose free channels all lie outside its
// channel list gets `none` rather than a proposal. That costs a manual `vectorcheck --assign`; the
// alternative costs somebody's mapping.
pub fn pick_free_app_channel(slots []AppSlot) ?int {
	mut answered := false
	for s in slots {
		if s != .unknown {
			answered = true
			break
		}
	}
	for i, s in slots {
		if s == .empty {
			return i + 1
		}
	}
	if !answered && slots.len > 0 {
		return 1
	}
	return none
}

// HwOwner is what is known about one PHYSICAL channel's ownership.
//
// `unknown` is not a nicety. A physical channel whose owning application channel could not be read
// looks unowned, and offering to assign it creates a SECOND application channel pointing at one
// physical wire — which destination_conflicts refuses a project for (#167), produced here by the
// dialog meant to set the bench up.
pub enum HwOwner {
	unowned // no application channel points here, and every channel answered
	owned   // an application channel points here
	unknown // at least one channel could not be read, so this cannot be claimed unowned
}

// hw_owner decides one physical channel's ownership from the sweep.
//
// `owner_app` is the application channel found pointing at this hardware, or 0. `any_answered` is
// whether ANY channel in the sweep answered at all.
//
// KEYED ON "DID ANYTHING ANSWER", not on "did anything fail", and the difference was measured
// rather than reasoned. The obvious reading — a channel that would not answer might be this
// hardware's owner, so treat every unowned row as unknown — is safe and useless: on a VN1630A the
// channels that answer are exactly the application's channel LIST
//
//     application channels that ANSWER: [1, 5, 40, 61, 62, 63, 64]
//
// and the rest are outside it. Outside the list means the channel is not configured, so it points
// at nothing and can own nothing. Since every real application has fewer than 64 channels, "any
// failed" is true on every bench that exists, and the dialog would offer nothing, ever.
//
// So an unreadable channel is taken to own nothing, and `unknown` is reserved for the case where
// NOTHING answered — where we genuinely know nothing about ownership. The residual risk is a
// TRANSIENT failure on a channel that really is an owner: we would then offer its hardware and
// create a second application channel on one wire. That is caught rather than silent —
// destination_conflicts refuses the project at Start (#167) and `vectorcheck --release` undoes it
// — which is a different order of harm from the write this function's caller could otherwise make
// over a live mapping, and that one stays strictly refused in pick_free_app_channel.
pub fn hw_owner(owner_app int, any_answered bool) HwOwner {
	if owner_app > 0 {
		return .owned
	}
	return if any_answered { .unowned } else { .unknown }
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
