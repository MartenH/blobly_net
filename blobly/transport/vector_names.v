// Vector channel NAMES, deliberately not in vector_windows.v — same reason as pcan_names.v:
// the mapping from a spelling to a channel is pure string logic, it is the identity two
// mappings are compared on (destination_key), and kept beside the driver it would compile only
// on the machine that runs no tests.
module transport

import math

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
	// Every option after the first comma (the mode, a sample point) goes with it.
	body := if s.contains(',') { s.all_before(',') } else { s }
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

// vector_fd_timing picks the bit timing for ONE phase at one rate (vector_phase_timing at the
// default split; a chosen sample point searches the same divisions).
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
	return vector_phase_timing(rate, .arbitration, 0)
}

// vector_fd_timing_data is the data phase's narrower search. Kept as its own entry point so a
// caller cannot pass the wrong ceiling by getting an argument order wrong.
fn vector_fd_timing_data(rate int) !FdTiming {
	return vector_phase_timing(rate, .data, 0)
}

// VectorPhase is the register set a timing is solved for: an FD channel's two phases, or a
// classic channel's, which xlCanSetChannelParams takes in its own register shape.
enum VectorPhase {
	arbitration
	data
	classic
}

// vector_classic_clock_hz is the clock XLchipParams' segments divide: the SJA1000-style bit
// timing of a 16 MHz controller (python-can fills XLchipParams only for that clock), with its
// register ranges — prescaler 1..64, tseg1 1..16, tseg2 1..8, sjw 1..4.
const vector_classic_clock_hz = 16_000_000

fn (p VectorPhase) clock_hz() int {
	return match p {
		.arbitration, .data { vector_fd_clock_hz }
		.classic { vector_classic_clock_hz }
	}
}

fn (p VectorPhase) tq_max() int {
	return match p {
		.arbitration { fd_tq_max_arbitration }
		.data { fd_tq_max_data }
		.classic { 1 + 16 + 8 }
	}
}

fn (p VectorPhase) brp_max() int {
	return match p {
		.arbitration, .data { 256 }
		.classic { 64 }
	}
}

// fits is whether the phase's segment registers hold `t`; the FD phases' bound is the quanta
// count alone.
fn (p VectorPhase) fits(t FdTiming) bool {
	return match p {
		.arbitration, .data { true }
		.classic { t.tseg1 <= 16 && t.tseg2 <= 8 && t.sjw <= 4 }
	}
}

// vector_sample_point_tolerance is how far the realised sample point may sit from the one asked
// for, in percentage points: the allowance PCAN's solver gives, so one row samples alike on both.
const vector_sample_point_tolerance = f64(pcan_sample_point_tolerance)

// vector_phase_timing is the segments for one phase at `rate`, the sample point at
// `sample_point` percent (0: the default split, ~80%), or why this clock cannot produce them.
//
// A chosen sample point takes the division of the bit whose realised point is NEAREST to it
// (a tie to the finer division), and is refused, naming the nearest it can manage, when that is
// further than vector_sample_point_tolerance away.
fn vector_phase_timing(rate int, phase VectorPhase, sample_point f64) !FdTiming {
	if rate <= 0 {
		return error('${rate} is not a bitrate')
	}
	if sample_point != 0 && (sample_point < 50 || sample_point > 95) {
		return error('sample point ${pct_text(sample_point)}% is outside 50-95%')
	}
	tq_max := phase.tq_max()
	clock := phase.clock_hz()
	brp_max := phase.brp_max()
	mut best := FdTiming{}
	mut best_off := 0.0
	mut found := false
	mut divided := false
	// Downwards from the ceiling: more quanta per bit means a smaller prescaler and so a finer
	// resynchronisation step. Below eight there is not enough resolution to place a sample point.
	for tq := tq_max; tq >= 8; tq-- {
		if clock % (rate * tq) != 0 {
			continue
		}
		// THE PRESCALER HAS TO FIT. A whole brp is not the same as a usable one: the low end of
		// the accepted range divides cleanly and then asks for a value the field cannot hold.
		brp := clock / (rate * tq)
		if brp < 1 || brp > brp_max {
			continue
		}
		divided = true
		if sample_point == 0 {
			d := vector_fd_split(tq)
			if phase.fits(d) {
				return d
			}
			continue
		}
		t := vector_split_at(tq, sample_point, phase) or { continue }
		off := math.abs(t.sample_point() - sample_point)
		if !found || off < best_off {
			best, best_off, found = t, off, true
		}
	}
	if !found && divided {
		return error("${rate} bit/s cannot be sampled at ${pct_text(sample_point)}% from this controller's ${clock / 1_000_000} MHz clock: no division of the bit fits its segment registers")
	}
	if !found {
		return error("${rate} bit/s cannot be produced from this controller's ${clock / 1_000_000} MHz clock: no whole prescaler of ${brp_max} or less divides it at 8 to ${tq_max} quanta per bit")
	}
	if best_off > vector_sample_point_tolerance {
		return error("${rate} bit/s cannot be sampled at ${pct_text(sample_point)}% from this controller's ${clock / 1_000_000} MHz clock — the nearest it can manage is ${pct_text(best.sample_point())}%")
	}
	return best
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
	return vector_segments(tq - 1 - t2, t2)
}

// vector_split_at divides a bit of `tq` quanta so it samples nearest `sample_point` percent, of
// the divisions the phase's segment registers hold (a tie to the later point); none when no
// division has both segments non-empty and held.
fn vector_split_at(tq int, sample_point f64, phase VectorPhase) ?FdTiming {
	mut best := FdTiming{}
	mut best_off := 0.0
	mut found := false
	for t1 := tq - 2; t1 >= 1; t1-- {
		t := vector_segments(t1, tq - 1 - t1)
		if !phase.fits(t) {
			continue
		}
		off := math.abs(t.sample_point() - sample_point)
		if !found || off < best_off {
			best, best_off, found = t, off, true
		}
	}
	if !found {
		return none
	}
	return best
}

fn vector_segments(t1 int, t2 int) FdTiming {
	// sjw cannot exceed tseg2 — it is the amount phase 2 may be shortened by — and there is
	// nothing to gain from more than 4.
	return FdTiming{
		tseg1: t1
		tseg2: t2
		sjw:   if t2 > 4 { 4 } else { t2 }
	}
}

// sample_point is where in the bit this timing samples, as a percentage.
fn (t FdTiming) sample_point() f64 {
	return f64(1 + t.tseg1) * 100 / f64(1 + t.tseg1 + t.tseg2)
}

// pct_text is a percentage as an address and a message spell it: no trailing zeros.
fn pct_text(v f64) string {
	return '${v:.2f}'.trim_right('0').trim_right('.')
}

// VectorTimings is the segments an open hands the driver: both phases for CAN-FD, the
// arbitration phase alone for a classic channel with a chosen sample point, none (all zero) for
// a classic channel the driver times itself.
struct VectorTimings {
	arb FdTiming
	dat FdTiming
}

// describe is where these timings sample, as a pin clash names it.
fn (t VectorTimings) describe(fd bool) string {
	if t.arb.tseg1 == 0 {
		return "at the driver's own classic timing"
	}
	if !fd {
		return 'at ${pct_text(t.arb.sample_point())}%'
	}
	return 'at ${pct_text(t.arb.sample_point())}% (data phase ${pct_text(t.dat.sample_point())}%)'
}

// VectorSampling is where an address samples, as rows sharing a wire are compared: `key` the
// segments its open configures (what the ports pin), `text` where they sample.
pub struct VectorSampling {
pub:
	key  string
	text string
}

// vector_sampling is an address's VectorSampling; none where the address cannot be opened, which
// vector_address_error says.
pub fn vector_sampling(iface string) ?VectorSampling {
	i := iface.trim_space()
	body := if i.to_lower().starts_with('vector:') { i['vector:'.len..] } else { i }
	s := parse_vector_spec(body) or { return none }
	t := vector_open_timings(s) or { return none }
	a, d := t.arb, t.dat
	return VectorSampling{
		key:  '${a.tseg1}/${a.tseg2}/${a.sjw} ${d.tseg1}/${d.tseg2}/${d.sjw}'
		text: t.describe(s.fd)
	}
}

// vector_open_timings is the ONE derivation of what an address configures, which open_vector
// hands the driver, vector_timing_error judges and the port pin records.
fn vector_open_timings(s VectorSpec) !VectorTimings {
	if !s.fd {
		// CLASSIC WITHOUT A SAMPLE POINT DERIVES NOTHING: xlCanSetChannelBitrate lets the driver
		// work the timing out, which keeps rates like 83333 — that no prescaler produces from
		// this clock — openable (#182 r1). A chosen one goes through xlCanSetChannelParams, which
		// takes the segments, so it must divide the clock like an FD phase.
		if s.sample_point == 0 {
			return VectorTimings{}
		}
		return VectorTimings{
			arb: vector_phase_timing(s.bitrate, .classic, s.sample_point) or {
				return error('classic ${err.msg()}')
			}
		}
	}
	// The data phase samples where the arbitration phase does unless the address says otherwise.
	dsp := if s.data_sample_point != 0 { s.data_sample_point } else { s.sample_point }
	return VectorTimings{
		arb: vector_phase_timing(s.bitrate, .arbitration, s.sample_point) or {
			return error('arbitration ${err.msg()}')
		}
		dat: vector_phase_timing(s.data_bitrate, .data, dsp) or {
			return error('CAN-FD data phase ${err.msg()}')
		}
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
	vector_open_timings(s) or { return err.msg() }
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
// WireReach is what `physical_wire` could establish about the hardware behind an address. Here
// rather than beside either resolver, because alias_windows.v and alias_nix.v must both return
// it and only one of them compiles on any given machine.
//
// THE SAME LESSON AS AppSlot, one layer up: `physical_wire_key` had two very different failures
// sharing one `none`, and the caller could only read that as "no opinion" — right for a channel
// that reaches nothing, wrong for one the driver would not describe, which may be aliased onto
// another row (#194).
pub enum WireReach {
	resolved   // the key names the physical channel this address reaches
	nothing    // the driver answered: no hardware behind it, so it can alias nothing
	unreadable // the driver would not say; anything could be behind it
}

// AppSlot is what the driver says about ONE application channel. Four states, not three, and the
// split of the old `unknown` into `unreadable` and `absent` is the whole of what r6 fixed: those
// were two different facts sharing one name, and no rule over the merged state could be right for
// both. See ct_vector_appl_get in vector_shim.h for the measurement.
pub enum AppSlot {
	unreadable // the driver could not be reached at all. Nothing is known; never write.
	absent     // the driver answered: it has no such channel for this application. Writing CREATES
	// it, which is the documented way to extend an application — and the state 57 of
	// 64 channels are in on an ordinary bench.
	empty // registered, pointing at nothing. The ordinary free channel.
	taken // registered, pointing at hardware. Writing would retarget somebody's mapping.
}

// slot_of turns one ct_vector_appl_get return code into the four-state answer. The ONE place that
// mapping lives, so vector_app_slot and vector_app_slots cannot drift apart about what a code means.
//
// HERE RATHER THAN BESIDE THE DRIVER, for the reason this file's own header gives: written in
// vector_windows.v it would compile only on Windows, where CI runs no tests — and the codes it
// interprets are the ones six rounds of review turned on. The C function that produces them is in
// vector_shim.h; keep the two in step.
//
// ONLY -3 IS `absent`. The shim maps exactly one measured XL status to it and returns every other
// failing status as -(1000 + status), so an unexpected driver answer arrives here as a large
// negative and falls to `unreadable` — which refuses. That default is the whole safety property:
// a code this function has never heard of must never come out as permission to write (codex #192
// r7). The encoded status is preserved rather than flattened so a bench whose driver answers
// differently can be diagnosed from the number instead of from a shrug.
// @[markused]: called from vector_windows.v; here so a test reaches it
@[markused]
fn slot_of(rc int) AppSlot {
	return match rc {
		0 { AppSlot.taken }
		-2 { AppSlot.empty }
		-3 { AppSlot.absent }
		else { AppSlot.unreadable }
	}
}

// reconcile_absent settles two readings of the same channel, where the first said `absent`.
//
// The rule is one line, and it is here rather than beside the driver so it can be tested: any second
// answer that DESCRIBES the channel beats `absent`, which is only ever a generic error. Two of the
// three (`taken`, `unreadable`) refuse, and the third (`empty`) permits on evidence rather than on
// the absence of it — so every disagreement resolves in the safe direction. Agreement on `absent`
// is the only way a write stays authorized (codex #192 r8).
// @[markused]: called from vector_windows.v; here so a test reaches it
@[markused]
fn reconcile_absent(first AppSlot, second AppSlot) AppSlot {
	if first != .absent {
		return first
	}
	return if second == .absent { AppSlot.absent } else { second }
}

// assign_refusal reports why an application channel must not be written, or none when it may be.
//
// THE OPERATOR NAMES THE CHANNEL; NOTHING GUESSES IT. Rounds 3 and 4 tried to infer which channels
// were free and produced a contradictory pair of findings; the guess is gone rather than refined
// (#192, option 3). What replaces it is a check on the ONE channel the operator actually named,
// which is evidence rather than an inference from what other channels did or did not answer.
//
// SIX ROUNDS LANDED IN THIS FUNCTION, and the reason was never the rule — it was the input. `slot`
// carried a state called `unknown` that meant two incompatible things, so r5 refused it (to protect
// an occupied channel) and r6 showed that refusing it also blocked the extension this dialog is
// for. Neither was wrong about its own case. The fix is upstream, in ct_vector_appl_get: the driver
// distinguishes "I cannot answer" from "no such channel", and once those are separate states the
// rule is obvious and needs no `app_present` inference to prop it up.
//
//   unreadable -> refuse. Nothing is known, so anything could be under there.
//   taken      -> refuse. The driver says, about this exact channel, that it points at hardware.
//   empty      -> permit. Registered and pointing at nothing; the driver said so positively.
//   absent     -> permit ONLY IF the operator asked to create. See below.
//
// That `app_present` argument is deliberately gone. It existed to guess which reading of `unknown`
// applied, it was derived from whether the application was seen (application_seen_in), whose
// `false` is not proof of absence — so the guess turned "nothing answered" into "safe to create",
// which is exactly the P1 r6 reported. A question the driver can answer directly is not one to
// infer from a sweep of other channels.
//
// `create_ok` IS NOT ANOTHER GUESS. It is the operator saying what they meant, and that is a
// different kind of input entirely — the earlier argument was this code inferring a fact about the
// world from evidence that did not support it.
//
// It exists because `absent` cannot be made trustworthy, and four rounds of review disagreeing
// about it is the evidence. The driver reports "no such channel" as 255, which is XL_ERROR, its
// GENERIC failure — so "this channel is not registered" and "this one call failed" are the SAME
// BYTES. No retry separates them (a persistent transient error repeats), and no other XL call
// exposes an application's channel count. Rounds 6 and 8/9 each demanded the opposite default and
// each were right about their own case:
//
//   - refuse it, and a fresh bench cannot bootstrap: an application that does not exist yet answers
//     255 for all 64 channels, so nothing could ever be created. That is #186's entire purpose.
//   - permit it silently, and one momentary failure on an occupied channel retargets a persistent
//     mapping that survives reboots.
//
// Neither is a defect in the rule; the rule is being asked to know something unknowable. So it is
// not decided here. Default REFUSE — a generic error never authorizes a write on its own — and the
// operator may state the intent explicitly, at which point creating is what they asked for and the
// message has already told them what it might replace.
pub fn assign_refusal(app int, slot AppSlot, create_ok bool) ?string {
	if app < 1 || app > 64 {
		return 'Vector application channels are numbered 1 to 64'
	}
	if slot == .taken {
		return 'vector:${app} already points at hardware — release it first, or choose another channel'
	}
	if slot == .unreadable {
		return 'the Vector driver would not say what vector:${app} points at — refusing rather than overwriting a mapping that may be there. Try again in a moment.'
	}
	if slot == .absent && !create_ok {
		return 'vector:${app} is not registered under "blobly_net". Assigning it CREATES it, which is how a channel is added — but the driver reports that with a generic error, which is also what a momentary read failure on an occupied channel looks like. Tick "create unregistered channel" in Discover (create = true from a script) to say that is what you mean, or pick one of the channels listed as free.'
	}
	return none
}

// AssignWhileRunning is why an application channel is not assigned while a run is started (#288):
// the mapping is the driver's, persistent and machine-wide, and the run may hold ports open on the
// very channel it would retarget. Typed, so a host answers it as its own state refusal (the C
// ABI's BB_ERR_STATE) rather than as a refused argument.
pub struct AssignWhileRunning {
	Error
}

pub fn (e AssignWhileRunning) msg() string {
	return 'not while a run is started: an assignment rewrites the Vector driver\'s persistent channel mapping under ports the run may hold open — stop the run first'
}

// assign_run_refusal is the one rule for assigning during a run, which the GUI's Discover dialog,
// Lua's vector.assign and the C ABI's bb_vector_assign all go by (vector_assign_checked asks it
// first): refused while `running`, none otherwise.
pub fn assign_run_refusal(running bool) ?AssignWhileRunning {
	return if running { AssignWhileRunning{} } else { none }
}

// vector_not_registered is the shim's open-path code for a channel the application does not have:
// xlGetApplConfig answered CT_XL_ERR_NO_SUCH_CHANNEL (255) for it.
const vector_not_registered = -1013

// lookup_refusal is why application channel `channel` did not open, from the shim's answer to the
// application-config lookup ct_vector_mask_why makes; none for a code that is not that lookup's.
// 255 is XL's generic error too, so the not-registered message names the remedy — an explicit
// Assign, which refuses an `absent` channel unless creating it is asked for — and never a retry
// that registers on its own.
pub fn lookup_refusal(channel int, rc int) ?string {
	return match rc {
		vector_not_registered {
			'vector:${channel} is not registered in application blobly_net — map it in Discover → Assign (ticking "create unregistered channel"; from a script, vector.assign with create). The driver says this with its generic error, so if vector:${channel} is mapped already, try again.'
		}
		-1007 {
			'Vector application channel ${channel}: the driver would not report what it is assigned to. Nothing was changed; try again, and check that no other XL application is mid-restart.'
		}
		else {
			none
		}
	}
}

// vector_mappings_of pairs every physical channel in `hw` with the application channel — if any —
// pointing at it, from ONE sweep's `slots` (index i is vector:<i+1>). `assignment_of` reads what a
// `taken` channel points at. A channel that is `unreadable`, or `taken` and then not read, may own
// any row, so every row without a found owner is marked `owner_known: false`: reported as free,
// an Assign would map a second application channel onto one physical wire (#167).
pub fn vector_mappings_of(hw []VectorChannel, slots []AppSlot, assignment_of fn (int) !(VectorChannel, bool)) []VectorMapping {
	mut owner := map[string]int{}
	mut known := true
	for i, s in slots {
		if s == .unreadable {
			known = false
			continue
		}
		if s != .taken {
			continue
		}
		a, ok := assignment_of(i + 1) or {
			known = false
			continue
		}
		if ok {
			owner['${a.hw_type}:${a.hw_index}:${a.hw_channel}'] = i + 1
		}
	}
	mut out := []VectorMapping{cap: hw.len}
	for c in hw {
		app := owner['${c.hw_type}:${c.hw_index}:${c.hw_channel}'] or { 0 }
		out << VectorMapping{
			hw:  c
			app: app
			// a found owner is positive evidence, which no unreadable channel takes away
			owner_known: known || app > 0
		}
	}
	return out
}

// application_seen_in is whether `slots` show the application registered: some channel answered
// `empty` or `taken`, which only a registered application's channels can. `false` is not proof of
// absence — `absent` is also what XL's generic error reads as, and `unreadable` is silence.
pub fn application_seen_in(slots []AppSlot) bool {
	return slots.any(it == .empty || it == .taken)
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
	// Where each phase samples, in percent; 0 is the backend's default split (~80%). The data
	// phase's 0 means "where the arbitration phase samples" (vector_open_timings).
	sample_point      f64
	data_sample_point f64
}

fn parse_vector_spec(spec string) !VectorSpec {
	mut body := spec.trim_space()
	mut silent := false
	mut sp := 0.0
	mut dsp := 0.0
	// The options are suffixes, not part of the address: `vector:1@500000` and
	// `vector:1@500000,silent,sp=75` are the SAME wire, and destination_key must see them collide
	// or the conflict check lets two owners onto one bus.
	if body.contains(',') {
		opts := body.all_after(',').split(',')
		body = body.all_before(',')
		mut seen := map[string]bool{}
		for raw in opts {
			o := raw.trim_space().to_lower()
			key := if o.contains('=') { o.all_before('=').trim_space() } else { 'mode' }
			if seen[key] {
				return error('Vector: ",${o}" repeats an option already given')
			}
			seen[key] = true
			match key {
				'mode' {
					match o {
						'silent', 'listen_only', 'listenonly' { silent = true }
						'normal' { silent = false }
						else { return error('unknown Vector mode ",${o}" (use ,silent)') }
					}
				}
				'sp' {
					sp = sample_point_option(o)!
				}
				'dsp' {
					dsp = sample_point_option(o)!
				}
				else {
					return error('unknown Vector option ",${o}" (use ,silent, ,sp=<percent> or ,dsp=<percent>)')
				}
			}
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
	if dsp != 0 && !fd {
		return error('Vector: ",dsp=" places the sample point of a CAN-FD data phase, and a classic address has none')
	}
	return VectorSpec{
		channel:           ch
		bitrate:           bitrate
		silent:            silent
		fd:                fd
		data_bitrate:      dbr
		sample_point:      sp
		data_sample_point: dsp
	}
}

// sample_point_option reads the percentage of a `sp=<percent>` / `dsp=<percent>` option: digits
// with at most one decimal point. Its range is the solver's to judge.
fn sample_point_option(o string) !f64 {
	v := o.all_after('=').trim_space()
	if v == '' || v.count('.') > 1 || v == '.' || !v.bytes().all(it.is_digit() || it == `.`) {
		return error('Vector: ",${o}" is not a sample point — a percentage, like ,sp=75 or ,sp=87.5')
	}
	return v.f64()
}

// driver_refusal_of is why the Vector XL driver cannot be used, from vector_driver_status's code
// on Windows; none when it can.
pub fn driver_refusal_of(status int) ?string {
	return match status {
		0 { none }
		-1 { 'vxlapi64.dll was not found: it is the Vector XL Driver Library, a separate download from the hardware drivers' }
		-2 { 'vxlapi64.dll is missing functions this backend needs; update the Vector Driver Setup' }
		else { 'vxlapi64.dll loaded, but xlOpenDriver failed (XL status ${-status}): no Vector hardware connected, or another application holds it exclusively' }
	}
}

// vector_driver_refusal is why the Vector driver cannot be used on this machine; none when it can.
pub fn vector_driver_refusal() ?string {
	$if windows {
		return driver_refusal_of(vector_driver_status())
	} $else {
		return 'the Vector XL backend is Windows-only'
	}
}

// vector_channel_of is the channel `hw` lists at (hw_type, hw_index, hw_channel).
pub fn vector_channel_of(hw []VectorChannel, hw_type int, hw_index int, hw_channel int) ?VectorChannel {
	for c in hw {
		if c.hw_type == hw_type && c.hw_index == hw_index && c.hw_channel == hw_channel {
			return c
		}
	}
	return none
}

// hw_owner_refusal is why physical channel `hw` must not be given a(nother) application channel,
// by `mappings` (vector_mappings): one already points at it, or a channel that would not answer
// may — a second would alias one wire under two addresses (#167). None when it is free.
pub fn hw_owner_refusal(hw VectorChannel, mappings []VectorMapping) ?string {
	for m in mappings {
		if m.hw.hw_type == hw.hw_type && m.hw.hw_index == hw.hw_index
			&& m.hw.hw_channel == hw.hw_channel {
			if m.app > 0 {
				return '${hw.name} is already assigned to vector:${m.app}'
			}
			if !m.owner_known {
				break
			}
			return none
		}
	}
	return 'could not confirm whether ${hw.name} is already assigned — the Vector driver did not answer for every application channel. Try again.'
}

// VectorRxQueue is the receive queue a port asks xlOpenPort for, and the smaller one it asks for
// when the driver refuses that. The size is EVENTS on a classic (V3) port and BYTES on a CAN-FD
// (V4) port: the same argument with two units, so the protocol picks the pair and nothing else
// may. Only the caller's reads empty a port's queue (Vector is not behind the shared reader), so
// it is the whole buffer a script has while it does something else.
pub struct VectorRxQueue {
pub:
	size     u32
	fallback u32
}

// The XL Driver Library's ceilings: a classic queue is a power of two up to 32768 events, an FD
// one 8192 (RX_FIFO_CANFD_QUEUE_SIZE_MIN) to 524288 bytes (RX_FIFO_CANFD_QUEUE_SIZE_MAX). At
// 2000 frames a second that is about 16 s classic and 4096 maximum-size FD events. The cost is
// driver memory per port: 32768 events of 48 bytes is 1.5 MiB. The fallbacks are what a port
// asked for before, so a driver that refuses the ceiling still opens.
const vector_rx_queue_events = u32(32768)
const vector_rx_queue_events_fallback = u32(256)
const vector_rx_queue_bytes_fd = u32(524288)
const vector_rx_queue_bytes_fd_fallback = u32(65536)

// vector_rx_queue is the queue a port of that protocol asks for.
pub fn vector_rx_queue(fd bool) VectorRxQueue {
	return if fd {
		VectorRxQueue{vector_rx_queue_bytes_fd, vector_rx_queue_bytes_fd_fallback}
	} else {
		VectorRxQueue{vector_rx_queue_events, vector_rx_queue_events_fallback}
	}
}

// vector_rx_queue_note says that a port opened with the fallback queue, or nothing when it got
// the size it asked for.
pub fn vector_rx_queue_note(channel int, fd bool, granted u32) ?string {
	q := vector_rx_queue(fd)
	if granted == q.size {
		return none
	}
	unit := if fd { 'bytes' } else { 'events' }
	return 'Vector channel ${channel}: the driver refused a receive queue of ${q.size} ${unit}; opened with ${granted}, which a reader that pauses fills sooner — update the XL Driver Library'
}

// The bit in an event's header that says the port's receive queue overflowed before it: the
// classic XLevent's `flags` byte (XL_EVENT_FLAG_OVERRUN) and the CAN-FD XLcanRxEvent's
// `flagsChip` word (XL_CAN_QUEUE_OVERFLOW). It says events were lost, not how many.
const vector_event_flag_overrun = u32(0x01)
const vector_can_queue_overflow = u32(0x100)

// vector_overrun_mask is the bit of the event header's flags field that marks an overflow on a
// port of that protocol; the shim counts each event taken with it set.
pub fn vector_overrun_mask(fd bool) u32 {
	return if fd { vector_can_queue_overflow } else { vector_event_flag_overrun }
}
