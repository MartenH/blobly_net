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

// VectorSpec is the parsed interface string.
//
// HERE, not in vector_windows.v, and the difference is not cosmetic: written beside the driver
// it compiled only on Windows, where nothing runs these tests — so the rule that a malformed
// bitrate is refused had no test at all, and the project migration was preserving malformed
// rates on the strength of a rejection that did not exist. This file is the one that gets to
// be checked.
struct VectorSpec {
	channel int // application channel, 1-based as the operator sees it
	bitrate int
	silent  bool
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
	chan_part, bitrate := vendor_split_rate(body, 500000) or { return error('Vector: ${err}') }
	ch := vector_app_channel(chan_part)!
	// A bitrate the hardware cannot produce is a configuration error worth catching here: on a
	// live bus the consequence of getting it wrong is error frames, not a quiet failure.
	if bitrate < 5000 || bitrate > 1000000 {
		return error('Vector bitrate ${bitrate} out of range (5000..1000000)')
	}
	return VectorSpec{
		channel: ch
		bitrate: bitrate
		silent:  silent
	}
}
