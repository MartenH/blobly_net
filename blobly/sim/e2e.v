// End-to-end protection for simulated frames: an alive counter and a checksum,
// applied AFTER the signal generators have encoded the payload.
//
// Why this exists: a real ECU does not accept a frame just because the bits are in the
// right places. Production networks protect safety-relevant messages with a counter that
// must advance every cycle and a checksum over the payload, and the receiver rejects — and
// usually DTC-flags — anything that fails either test. Without this, a rest-bus simulation
// can drive a demo bus but cannot talk to the ECU you actually want to test.
//
// Scope: the frame-level mechanics (counter wrap, checksum coverage, the order the two are
// applied in). Two kinds of profile:
//  - `autosar_p01`: AUTOSAR E2E Profile 1 as specified — the one to use against an AUTOSAR (or
//    blobly_emb) receiver. Pinned by vectors taken from an independent implementation
//    (autosar-e2e, sut/e2e_oracle.py);
//  - `autosar_p05`: AUTOSAR E2E Profile 5 as specified — a 16-bit CRC and an 8-bit counter, the
//    profile CAN-FD payloads usually carry. Pinned by vectors from the same implementation;
//  - the checksum PRIMITIVES (`crc8_j1850`, `crc8_autosar`, `sum8`, `xor8`) under blobly's own
//    coverage rule (below), for the OEM schemes no AUTOSAR profile describes.
module sim

import blobly.candb
import blobly.project

// crc8_j1850 — CRC-8/SAE-J1850: poly 0x1D, init 0xFF, final xor 0xFF, no reflection. AUTOSAR
// E2E Profile 1 uses the same polynomial with start 0x00 and no final XOR (`p01_crc`).
// Check value: crc8_j1850('123456789') == 0x4B, pinned in e2e_test.v.
pub fn crc8_j1850(data []u8) u8 {
	return crc8_with(data, 0x1D, 0xFF, 0xFF)
}

// crc8_autosar — CRC-8/AUTOSAR ("CRC8H2F"): poly 0x2F, otherwise as above. Better error
// detection over short payloads, and what AUTOSAR E2E profile 2 uses — picking crc8_j1850 for
// a profile-2 receiver produces a different checksum and it rejects every frame.
// Check value: 0xDF.
pub fn crc8_autosar(data []u8) u8 {
	return crc8_with(data, 0x2F, 0xFF, 0xFF)
}

// crc16_ccitt_false — CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no final XOR, no
// reflection; AUTOSAR's Crc_CalculateCRC16, which E2E Profile 5 uses. Check value:
// crc16_ccitt_false('123456789') == 0x29B1, pinned in e2e_p05_test.v.
pub fn crc16_ccitt_false(data []u8) u16 {
	mut crc := u16(0xFFFF)
	for b in data {
		crc ^= u16(b) << 8
		for _ in 0 .. 8 {
			crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 }
		}
	}
	return crc
}

// crc8_with is CRC-8 over `poly`, unreflected, from `init`, XORed with `xorout` at the end.
fn crc8_with(data []u8, poly u8, init u8, xorout u8) u8 {
	mut crc := init
	for b in data {
		crc ^= b
		for _ in 0 .. 8 {
			// bit-at-a-time; a table would buy nothing at CAN payload sizes (≤64 bytes)
			crc = if crc & 0x80 != 0 { (crc << 1) ^ poly } else { crc << 1 }
		}
	}
	return crc ^ xorout
}

// sum8 — the low byte of the arithmetic sum. Not a CRC; included because a large number of
// OEM-specific "checksum" signals are exactly this, and calling it a CRC would misdescribe it.
pub fn sum8(data []u8) u8 {
	mut s := u32(0)
	for b in data {
		s += b
	}
	return u8(s & 0xFF)
}

// xor8 — all bytes XORed together. As above: simple, common, and not a CRC.
pub fn xor8(data []u8) u8 {
	mut x := u8(0)
	for b in data {
		x ^= b
	}
	return x
}

// E2e describes the protection applied to ONE simulated message.
//
// `counter` and `crc` name signals of that message, so the placement, width and byte order
// all come from the DBC — this struct never re-states them, and a signal moved in the DBC
// moves here too.
pub struct E2e {
pub mut:
	counter string // signal carrying the alive counter ('' = no counter)
	crc     string // signal carrying the checksum ('' = no checksum)
	profile string // 'autosar_p01' | 'autosar_p05' | 'crc8_j1850' | 'crc8_autosar' | 'sum8' | 'xor8'
	// Mixed into the checksum. For a primitive, as four trailing little-endian bytes; for
	// autosar_p01, as its 16-bit Data ID per `data_id_mode`; for autosar_p05, low byte then high. An OPTION, not a plain u32 with
	// 0 meaning "unset": 0 is a legitimate Data ID, and a receiver using it expects it in the
	// checksum input — omitting it yields a different CRC and rejects every frame.
	data_id ?u32
	// autosar_p01's DataIDMode: 'both' (default: low byte, then high), 'low', or 'alt' (the
	// low byte when the counter is even, the high byte when odd). NIBBLE is not supported.
	data_id_mode string
	// The WINDOW it protects (#615): `length` bytes from `offset`, the bytes its checksum covers
	// and its CRC and counter lie in; `length` 0 is the message's whole payload. `group` names it
	// (a signal group's, or the entry's CRC signal), '' for the whole payload.
	group  string
	offset int
	length int
}

// label is the window's name as a script reads it: its group's, else the message's.
pub fn (e E2e) label(m candb.Message) string {
	return if e.group != '' { e.group } else { m.name }
}

// bytes is the first byte of the window and the one past its last, within the message's payload.
pub fn (e E2e) bytes(m candb.Message) (int, int) {
	if e.length == 0 {
		return 0, m.payload_len()
	}
	return e.offset, e.offset + e.length
}

// window_of clips the window to `n`, the bytes the profile covers of the frame as it stands.
fn (e E2e) window_of(n int) (int, int) {
	if e.length == 0 {
		return 0, n
	}
	start := if e.offset < n { e.offset } else { n }
	end := if e.offset + e.length < n { e.offset + e.length } else { n }
	return start, end
}

// any_active: any window of a message's protection protects something.
pub fn any_active(ws []E2e) bool {
	return ws.any(it.active())
}

// window_problem says why `e`'s window cannot be stamped or checked on `m`, if it cannot: past the
// payload, or not holding its CRC and counter whole.
pub fn window_problem(m candb.Message, e E2e) ?string {
	if e.length == 0 {
		return none
	}
	if e.offset < 0 || e.length < 0 {
		return 'its window (offset ${e.offset}, length ${e.length}) is not one'
	}
	n := m.payload_len()
	if e.offset + e.length > n {
		return 'its window, bytes ${e.offset}..${e.offset + e.length - 1}, lies past the ${n}-byte payload of ${m.name}'
	}
	for name in [e.crc, e.counter] {
		if name == '' {
			continue
		}
		sig := m.signal_named(name) or { continue }
		a, b := sig.byte_range()
		if a < e.offset || b >= e.offset + e.length {
			return '"${name}" (bytes ${a}..${b}) is not inside its window, bytes ${e.offset}..${e.offset + e.length - 1}'
		}
	}
	return none
}

// shape_problem says why `e` cannot be stamped or checked on `m` at all, if it cannot: its window,
// then e2e_problem (a counter or checksum with no number, then the AUTOSAR profile it names) — the
// ONE rule the protect: and verify: validation, a DBC declaration (stated_problem), protection_for
// and the verifiers ask.
pub fn shape_problem(m candb.Message, e E2e) ?string {
	if why := window_problem(m, e) {
		return why
	}
	return e2e_problem(m, e)
}

// clash_with says why `e` (its group named) cannot be one of `m`'s windows beside `kept`, if it
// cannot: a message's windows are disjoint, or one window's CRC would be covered by another's
// computed first; and each has a name of its own, which a script reads its verdict and a fault
// targets it by.
pub fn clash_with(kept []E2e, m candb.Message, e E2e) ?string {
	a0, a1 := e.bytes(m)
	for k in kept {
		b0, b1 := k.bytes(m)
		if a0 < b1 && b0 < a1 {
			return 'its window overlaps the one of ${k.label(m)}'
		}
		if k.label(m) == e.label(m) {
			return 'its window is named ${e.label(m)}, as another one is'
		}
	}
	return none
}

// window_name is what a protect: or verify: entry's window is called: the signal group of `m`
// holding its CRC (else its counter) signal, else that signal's name; '' for the whole payload.
pub fn window_name(m candb.Message, e E2e) string {
	if e.length == 0 {
		return ''
	}
	anchor := if e.crc != '' { e.crc } else { e.counter }
	g := m.group_holding(anchor) or { return anchor }
	return g.name
}

// windows_of is the protection the usable entries for one message describe, one window each: an
// entry naming no window is the whole payload, and an entry whose window clashes with one taken
// before it (clash_with) is left out — so of several naming none, the first applies (validate_protection and
// validate_verify say so).
pub fn windows_of(m candb.Message, entries []project.ProtectCfg) []E2e {
	mut out := []E2e{}
	for p in entries {
		mut e := e2e_of(p)
		e.group = window_name(m, e)
		if clash_with(out, m, e) != none {
			continue
		}
		out << e
	}
	return out
}

pub const p01 = 'autosar_p01'
pub const p05 = 'autosar_p05'

// crc_width is the number of bits the profile's checksum has: Profile 5's 16, every other's 8.
pub fn crc_width(profile string) int {
	return if profile == p05 { 16 } else { 8 }
}

// declared_e2e is the protection a message's DBC declares (#271), one window per usable
// declaration (#615): what its sender stamps when no protect: entry says otherwise. Empty when it
// declares none it can apply.
pub fn declared_e2e(m candb.Message) []E2e {
	ws, _ := declared_set(m)
	return ws
}

// declared_set is the windows a message's declarations give, and why each one left out was:
// it cannot be applied (declared_problem), or its window clashes with one given before it — each
// reason with its declaration (candb.E2eDecl.where_in).
pub fn declared_set(m candb.Message) ([]E2e, []DeclRefusal) {
	mut out := []E2e{}
	mut refused := []DeclRefusal{}
	for d in m.e2e {
		if !d.declared() {
			continue
		}
		why := declared_problem(m, d)
		if why != '' {
			refused << DeclRefusal{d, why}
			continue
		}
		e := e2e_of_decl(m, d) or { continue }
		if o := clash_with(out, m, e) {
			refused << DeclRefusal{d, o}
			continue
		}
		out << e
	}
	return out, refused
}

// DeclRefusal is a declaration declared_set leaves out, and why.
pub struct DeclRefusal {
pub:
	decl candb.E2eDecl
	why  string
}

// e2e_of_decl is the protection a DBC declaration states — the one conversion: its window the
// signal group its attributes sit on (candb.Message.e2e_window).
pub fn e2e_of_decl(m candb.Message, d candb.E2eDecl) !E2e {
	w := m.e2e_window(d)!
	return E2e{
		counter: d.counter
		crc:     d.crc
		profile: d.profile
		data_id: if d.has_data_id { ?u32(d.data_id) } else { none }
		group:   w.name
		offset:  w.offset
		length:  w.length
	}
}

// declared_problem says why a DBC E2E declaration of `m` cannot be stamped — '' when it can.
// Every shape a protect: entry is warned about is REFUSED here: an entry is the operator's own
// word, applied with a warning, but a declaration is applied with none, so it must be exact.
pub fn declared_problem(m candb.Message, d candb.E2eDecl) string {
	if d.bad_data_id != '' {
		return 'its E2EDataId ${d.bad_data_id} is not a Data ID'
	}
	e := e2e_of_decl(m, d) or { return err.msg() }
	return stated_problem(m, e)
}

// stated_problem says why protection `e` stated by a declaration cannot be stamped on `m` exactly —
// '' when it can.
pub fn stated_problem(m candb.Message, e E2e) string {
	if e.profile !in candb.e2e_profiles {
		return 'its profile "${e.profile}" is not one this app implements'
	}
	if e.counter == '' && e.crc == '' {
		return 'it names neither a counter nor a crc signal'
	}
	if e.counter != '' && e.counter == e.crc {
		return 'it names "${e.counter}" as both counter and crc'
	}
	for name in [e.counter, e.crc] {
		if name == '' {
			continue
		}
		sig := m.signals.filter(it.name == name)
		if sig.len == 0 {
			return '"${name}" is not a signal of ${m.name}'
		}
		if sig[0].is_multiplexed {
			return '"${name}" is multiplexed, so it is written only when its branch is active'
		}
		if why := past_payload(m, name) {
			return why
		}
		if name == e.crc && sig[0].length != crc_width(e.profile) {
			return 'its crc "${name}" is ${sig[0].length} bits, and its profile produces ${crc_width(e.profile)}'
		}
	}
	if why := shape_problem(m, e) {
		return why
	}
	return ''
}

// e2e_of is the protection a protect: or verify: entry describes — the ONE place an entry
// becomes an E2e, so the stamping, the checking and the panels cannot each carry a subset.
pub fn e2e_of(p project.ProtectCfg) E2e {
	return E2e{
		counter:      p.counter
		crc:          p.crc
		profile:      p.profile
		data_id:      p.data_id
		data_id_mode: p.data_id_mode
		offset:       p.offset or { 0 }
		length:       p.length or { 0 }
	}
}

// p01_counter_span: a Profile 1 counter runs 0..14 and wraps to 0 — 15 is invalid.
const p01_counter_span = u64(15)

// p05_counter_span: a Profile 5 counter runs 0..255 and wraps to 0.
const p05_counter_span = u64(256)

// counter_span is the counter's modulus: P01's, P05's, or what the signal's width holds.
fn (e E2e) counter_span(sig candb.Signal) u64 {
	if e.profile == p01 {
		return p01_counter_span
	}
	if e.profile == p05 {
		return p05_counter_span
	}
	return if sig.length >= 64 { u64(0) } else { u64(1) << sig.length }
}

// crc_byte is the byte an 8-bit, byte-aligned checksum signal occupies — the only shape
// Profile 1 defines, since its CRC skips that byte of the frame.
pub fn crc_byte(sig candb.Signal) ?int {
	if sig.length != 8 {
		return none
	}
	aligned := if sig.byte_order == .little_endian { sig.start_bit % 8 == 0 } else { sig.start_bit % 8 == 7 }
	return if aligned { sig.start_bit / 8 } else { none }
}

// crc16_byte is the first byte of a 16-bit little-endian (Intel), byte-aligned checksum signal —
// the only shape Profile 5 defines: its CRC goes low byte first, at that byte and the next.
pub fn crc16_byte(sig candb.Signal) ?int {
	if sig.length != 16 || sig.byte_order != .little_endian || sig.start_bit % 8 != 0 {
		return none
	}
	return sig.start_bit / 8
}

// past_payload says that the signal `name` of `m` does not lie whole in the payload the message
// is sent in, if it does not: no carried signal is written there, so nothing stamps or forces it.
pub fn past_payload(m candb.Message, name string) ?string {
	sig := m.signal_named(name) or { return none }
	n := m.payload_len()
	if m.holds(sig, n) {
		return none
	}
	what := if sig.fits(n) { 'the multiplexor selecting "${name}"' } else { '"${name}"' }
	return '${what} lies past the ${n}-byte payload of ${m.name}, so nothing writes it'
}

// p01_problem says why `e` cannot be stamped or checked as AUTOSAR Profile 1 on `msg`, if it
// cannot — asked through e2e_problem, the one rule.
pub fn p01_problem(msg candb.Message, e E2e) ?string {
	if e.profile != p01 {
		return none
	}
	id := e.data_id or { return 'autosar_p01 needs a data_id' }
	if why := p01_params_problem(id, e.data_id_mode) {
		return why
	}
	if e.crc == '' {
		return 'autosar_p01 needs a crc signal'
	}
	if e.counter == '' {
		return 'autosar_p01 needs a counter signal (a 4-bit alive counter is part of the profile)'
	}
	for sig in msg.signals {
		if sig.name == e.crc && crc_byte(sig) == none {
			return 'autosar_p01 needs "${e.crc}" to be one whole byte (8 bits, byte-aligned)'
		}
		if sig.name == e.counter && sig.length != 4 {
			return 'autosar_p01 needs a 4-bit counter; "${e.counter}" is ${sig.length} bits'
		}
	}
	return none
}

// e2e_problem says why `e` cannot be stamped or checked on `msg`, if it cannot, its window aside
// (shape_problem, the one rule, asks it after the window): a counter or checksum with no number
// (candb.Signal.is_scalar), which no stamp writes and no check reads, so it would pass as
// protected and checked while it is neither; then the AUTOSAR profile's own (autosar_problem).
pub fn e2e_problem(msg candb.Message, e E2e) ?string {
	for sig in msg.signals {
		if sig.name != '' && (sig.name == e.counter || sig.name == e.crc) && !sig.is_scalar() {
			role := if sig.name == e.crc { 'checksum' } else { 'counter' }
			return '${role} ${sig.scalar_refusal()}, so nothing stamps or checks it'
		}
	}
	return autosar_problem(msg, e)
}

// p05_problem says why `e` cannot be stamped or checked as AUTOSAR Profile 5 on `msg`, if it
// cannot: a 16-bit Data ID, the CRC a 16-bit little-endian byte-aligned signal, and the counter
// an 8-bit byte-aligned signal in the byte after the CRC's two.
pub fn p05_problem(msg candb.Message, e E2e) ?string {
	if e.profile != p05 {
		return none
	}
	id := e.data_id or { return 'autosar_p05 needs a data_id' }
	if id > 0xFFFF {
		return 'autosar_p05 data_id 0x${id:X} does not fit its 16 bits'
	}
	if e.crc == '' {
		return 'autosar_p05 needs a crc signal'
	}
	if e.counter == '' {
		return 'autosar_p05 needs a counter signal (an 8-bit counter is part of the profile)'
	}
	crc := msg.signal_named(e.crc) or { return none }
	ctr := msg.signal_named(e.counter) or { return none }
	at := crc16_byte(crc) or {
		return 'autosar_p05 needs "${e.crc}" to be 16 bits, little-endian (low byte first) and byte-aligned'
	}
	ctr_at := crc_byte(ctr) or {
		return 'autosar_p05 needs an 8-bit byte-aligned counter; "${e.counter}" is ${ctr.length} bits at bit ${ctr.start_bit}'
	}
	if ctr_at != at + 2 {
		return 'autosar_p05 needs the counter in the byte after the CRC (byte ${at + 2}); "${e.counter}" is in byte ${ctr_at}'
	}
	return none
}

// autosar_problem says why `e` cannot be stamped or checked as the AUTOSAR profile it names, if
// it cannot: Profile 1's rule (p01_problem), then Profile 5's (p05_problem). e2e_problem asks it
// after the scalar rule.
pub fn autosar_problem(msg candb.Message, e E2e) ?string {
	if why := p01_problem(msg, e) {
		return why
	}
	return p05_problem(msg, e)
}

// p01_modes are the Data ID modes Profile 1 is implemented for ('' is the default, both).
pub const p01_modes = ['', 'both', 'low', 'alt']

// p01_params_problem: why a Data ID and mode are not Profile 1's — the ONE rule the simulation's
// validation and a script's e2e helpers both ask.
pub fn p01_params_problem(data_id u32, mode string) ?string {
	if data_id > 0xFFFF {
		return 'autosar_p01 data_id 0x${data_id:X} does not fit its 16 bits'
	}
	if mode !in p01_modes {
		return 'autosar_p01 data_id_mode "${mode}" is not both, low or alt'
	}
	return none
}

// checksum is what `sig` (the checksum signal) must hold for `data` as it stands, whatever the
// field holds now: the stamping and the checking path both ask this, so the rule exists once.
fn (e E2e) checksum(msg candb.Message, sig candb.Signal, data []u8) u16 {
	if e.profile == p01 {
		return u16(e.p01_crc(msg, sig, data))
	}
	if e.profile == p05 {
		return e.p05_crc(msg, sig, data)
	}
	// the message's payload, never padding past it: an FD length rounded up is the wire's
	n := if data.len < msg.payload_len() { data.len } else { msg.payload_len() }
	mut whole := data[..n].clone()
	sig.set_raw(mut whole, 0) // a checksum cannot cover itself: computed with its field zeroed
	start, end := e.window_of(n)
	mut input := whole[start..end].clone()
	if id := e.data_id {
		// ALL FOUR bytes, little-endian. Appending only the low byte made 0x012A and 0x022A
		// produce identical checksums — two messages the data id exists to keep apart.
		// blobly's own convention for the primitives, not AUTOSAR's (that is autosar_p01).
		input << u8(id & 0xFF)
		input << u8((id >> 8) & 0xFF)
		input << u8((id >> 16) & 0xFF)
		input << u8((id >> 24) & 0xFF)
	}
	return u16(e.checksum_of(input))
}

// p01_crc is AUTOSAR E2E Profile 1's CRC: CRC-8 over poly 0x1D with start value 0x00 and no
// final XOR (AUTOSAR's chained Crc_CalculateCRC8 calls cancel the catalogue's 0xFF/0xFF), over
// the Data ID bytes the mode names, then every byte of the message's DLC except the CRC's own —
// bytes before it included.
fn (e E2e) p01_crc(msg candb.Message, sig candb.Signal, data []u8) u8 {
	at := crc_byte(sig) or { return 0 } // refused by p01_problem; nothing sensible to stamp
	// the counter as this frame carries it, which only ALT's byte choice reads
	mut ctr := u64(0)
	if e.data_id_mode == 'alt' {
		for c in msg.active_signals(data) {
			if c.name == e.counter {
				ctr = c.raw_value(data)
				break
			}
		}
	}
	// the profile's DataLength is the window's, of the message: bytes a frame carries past its
	// DBC length (padding, an FD length rounded up) are not the sender's to have covered
	n := if data.len < msg.dlc { data.len } else { msg.dlc }
	start, end := e.window_of(n)
	return p01_crc_bytes(data[start..end], at - start, u16(e.data_id or { u32(0) }), e.data_id_mode,
		u8(ctr)) or {
		0 // refused by p01_problem before anything is stamped
	}
}

// p01_crc_bytes is AUTOSAR E2E Profile 1's CRC over a frame's bytes: the Data ID bytes `mode`
// names ('' or 'both': low then high; 'low'; 'alt': low when `counter` is even, high when odd),
// then every byte but the CRC's at `crc_at` — CRC-8 poly 0x1D, start 0x00, no final XOR. The ONE
// computation: the simulation stamps and checks through it, and a script's e2e.p01_crc asks it.
pub fn p01_crc_bytes(data []u8, crc_at int, data_id u16, mode string, counter u8) !u8 {
	if why := p01_params_problem(data_id, mode) {
		return error(why)
	}
	if crc_at < 0 || crc_at >= data.len {
		return error('autosar_p01: the CRC byte ${crc_at} is not in the ${data.len}-byte frame')
	}
	mut input := []u8{cap: 2 + data.len}
	match mode {
		'low' {
			input << u8(data_id)
		}
		'alt' {
			input << if counter % 2 == 0 { u8(data_id) } else { u8(data_id >> 8) }
		}
		else {
			input << u8(data_id)
			input << u8(data_id >> 8)
		}
	}
	for i, b in data {
		if i != crc_at {
			input << b
		}
	}
	return crc8_with(input, 0x1D, 0x00, 0x00)
}

// p05_crc is AUTOSAR E2E Profile 5's CRC over the message's DLC (bytes past it are not the
// sender's to have covered), the CRC at the checksum signal's first byte.
fn (e E2e) p05_crc(msg candb.Message, sig candb.Signal, data []u8) u16 {
	at := crc16_byte(sig) or { return 0 } // refused by p05_problem; nothing sensible to stamp
	n := if data.len < msg.dlc { data.len } else { msg.dlc }
	start, end := e.window_of(n)
	return p05_crc_bytes(data[start..end], at - start, u16(e.data_id or { u32(0) })) or {
		0 // refused by p05_problem before anything is stamped
	}
}

// p05_crc_bytes is AUTOSAR E2E Profile 5's CRC over a frame's bytes: every byte but the CRC's own
// two at `offset` (bytes before it included), then the Data ID low byte and high byte —
// CRC-16/CCITT-FALSE. The frame must hold the 3-byte header (CRC and counter) at `offset`. The
// ONE computation: the simulation stamps and checks through it, and a script's e2e.p05_crc asks it.
pub fn p05_crc_bytes(data []u8, offset int, data_id u16) !u16 {
	if offset < 0 || offset + 3 > data.len {
		return error('autosar_p05: the header (CRC and counter) at byte ${offset} is not in the ${data.len}-byte frame')
	}
	mut input := []u8{cap: data.len}
	input << data[..offset]
	input << data[offset + 2..]
	input << u8(data_id)
	input << u8(data_id >> 8)
	return crc16_ccitt_false(input)
}

// p05_frame_crc is Profile 5's CRC for a frame a script built itself, as it stands: the header
// (CRC low byte, CRC high byte, counter) at byte `offset`. Lua's e2e.p05_crc and the C ABI's
// bb_e2e_p05_crc ask it.
pub fn p05_frame_crc(data []u8, data_id i64, offset i64) !u16 {
	if why := p05_frame_problem(data.len, data_id, offset) {
		return error(why)
	}
	return p05_crc_bytes(data, int(offset), u16(data_id))
}

// p05_protect is `data` with `counter` (0..255) in byte `offset` + 2 and then the CRC of
// p05_frame_crc stamped at `offset`, low byte first.
pub fn p05_protect(data []u8, data_id i64, counter i64, offset i64) ![]u8 {
	if counter < 0 || counter > 255 {
		return error('a Profile 5 counter is 0..255, not ${counter}')
	}
	if why := p05_frame_problem(data.len, data_id, offset) {
		return error(why)
	}
	at := int(offset)
	mut out := data.clone()
	out[at + 2] = u8(counter)
	crc := p05_crc_bytes(out, at, u16(data_id))!
	out[at] = u8(crc)
	out[at + 1] = u8(crc >> 8)
	return out
}

// p05_frame_problem: why a frame of `n` bytes cannot carry Profile 5 as asked.
fn p05_frame_problem(n int, data_id i64, offset i64) ?string {
	if data_id < 0 || data_id > 0xFFFF {
		return 'autosar_p05 data_id ${data_id} does not fit its 16 bits'
	}
	if offset < 0 || offset + 3 > n {
		return 'offset ${offset} leaves no room for the 3-byte header (CRC and counter) in the ${n}-byte frame'
	}
	return none
}

// p01_frame_crc is Profile 1's CRC for a frame a script built itself, as it stands: the CRC at
// byte `crc_pos`, the counter in the low nibble of byte `counter_pos` (which ALT mode's byte
// choice reads). Lua's e2e.p01_crc and the C ABI's bb_e2e_p01_crc ask it.
pub fn p01_frame_crc(data []u8, data_id i64, crc_pos i64, counter_pos i64, mode string) !u8 {
	if why := p01_frame_problem(data.len, data_id, crc_pos, counter_pos, mode) {
		return error(why)
	}
	return p01_crc_bytes(data, int(crc_pos), u16(data_id), mode, data[int(counter_pos)] & 0x0F)
}

// p01_protect is `data` with `counter` (0..14) in the low nibble of byte `counter_pos`, its high
// nibble kept, and then the CRC of p01_frame_crc stamped at `crc_pos`.
pub fn p01_protect(data []u8, data_id i64, crc_pos i64, counter_pos i64, counter i64, mode string) ![]u8 {
	if counter < 0 || counter > 14 {
		return error('a Profile 1 counter is 0..14, not ${counter}')
	}
	if why := p01_frame_problem(data.len, data_id, crc_pos, counter_pos, mode) {
		return error(why)
	}
	mut out := data.clone()
	out[int(counter_pos)] = (out[int(counter_pos)] & 0xF0) | u8(counter)
	out[int(crc_pos)] = p01_crc_bytes(out, int(crc_pos), u16(data_id), mode, u8(counter))!
	return out
}

// p01_frame_problem: why a frame of `n` bytes cannot carry Profile 1 as asked.
fn p01_frame_problem(n int, data_id i64, crc_pos i64, counter_pos i64, mode string) ?string {
	if data_id < 0 || data_id > 0xFFFF_FFFF {
		return 'data_id ${data_id} is not a Data ID'
	}
	if why := p01_params_problem(u32(data_id), mode) {
		return why
	}
	if crc_pos < 0 || crc_pos >= n || counter_pos < 0 || counter_pos >= n || crc_pos == counter_pos {
		return 'crc_pos ${crc_pos} / counter_pos ${counter_pos} must be distinct bytes of the ${n}-byte frame'
	}
	return none
}

// active reports whether anything is protected — a zero E2e is the common case and must cost
// nothing on the send path.
pub fn (e E2e) active() bool {
	return e.counter != '' || e.crc != ''
}

// checksum_of dispatches on the profile. An unknown profile returns a plain sum rather than
// erroring: the alternative is a simulation that silently stops transmitting because of a
// typo in a config field, which is harder to diagnose on a bench than a wrong checksum.
fn (e E2e) checksum_of(data []u8) u8 {
	return match e.profile {
		'crc8_j1850' { crc8_j1850(data) }
		'crc8_autosar' { crc8_autosar(data) }
		'xor8' { xor8(data) }
		else { sum8(data) }
	}
}

// apply stamps the counter and checksum onto an already-encoded payload.
//
// Order is not arbitrary and is the part worth getting right:
//  1. the counter is written first, so it is INSIDE the data the checksum covers — a receiver
//     that validated the checksum but not the counter's contribution would accept a replayed
//     frame with a stale counter;
//  2. the checksum never covers its own bits (`checksum`: zeroed for a primitive, skipped for
//     autosar_p01 and autosar_p05), so the result does not depend on what the previous cycle left there;
//  3. `data_id` is mixed into the CHECKSUM INPUT ONLY — it never occupies payload space; it
//     exists so two messages with identical bytes produce different checksums, which is what
//     stops a frame being replayed onto a different id.
//
// `n` is the send index; the counter is `n` modulo `counter_span` — what its DBC signal can
// hold, Profile 1's 0..14 or Profile 5's 0..255 — so it wraps exactly where the receiver expects.
pub fn (e E2e) apply(msg candb.Message, mut data []u8, n int) {
	if !e.active() {
		return
	}
	// Only signals ACTUALLY PRESENT in this payload. A multiplexed message's branches may
	// legally reuse the same bits, so writing a checksum field belonging to an inactive branch
	// would corrupt the active one. For a non-multiplexed message active_signals returns
	// everything, so this costs nothing in the ordinary case.
	if e.counter != '' {
		for sig in msg.active_signals(data) {
			if sig.name == e.counter {
				span := e.counter_span(sig)
				v := if span == 0 { u64(n) } else { u64(n) % span }
				// set_raw, NOT encode: a counter is a raw field value, not a physical
				// quantity. encode() would divide by the signal's factor and subtract its
				// offset, so a DBC that declares the counter with factor 0.5 — legal, and
				// nothing stops it — would transmit 2n and fail every receiver check.
				sig.set_raw(mut data, v)
				break
			}
		}
	}
	if e.crc == '' {
		return
	}
	// recomputed after the counter write: if the counter is itself the multiplexor switch,
	// the active branch has just changed
	for sig in msg.active_signals(data) {
		if sig.name != e.crc {
			continue
		}
		// raw again — the checksum byte must land in the field bit-for-bit
		sig.set_raw(mut data, u64(e.checksum(msg, sig, data)))
		break
	}
}
