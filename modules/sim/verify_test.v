module sim

import candb
import project

fn vmsg() candb.Message {
	return candb.Message{
		name: 'Protected'
		id:   0x123
		dlc:  8
		signals: [
			candb.Signal{ name: 'AliveCounter', start_bit: 0, length: 4, byte_order: .little_endian, factor: 1 },
			candb.Signal{ name: 'Payload', start_bit: 8, length: 16, byte_order: .little_endian, factor: 1 },
			candb.Signal{ name: 'CRC', start_bit: 56, length: 8, byte_order: .little_endian, factor: 1 },
		]
	}
}

// A well-formed stream must pass: the verifier has to agree with the stamper, or every real
// frame reads as a fault and the feature is worse than useless.
fn test_a_correctly_protected_stream_passes() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850', data_id: u32(42) }
	mut v := Verifier{ msg: m, e2e: e }
	for n in 0 .. 20 {
		mut d := []u8{len: 8}
		e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'frame ${n} rejected a valid stream'
	}
	assert v.bad == 0
	assert v.seen == 20
}

// The counter wraps at its width, and a wrap is NOT a skip.
fn test_counter_wrap_is_not_a_violation() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	for n in 14 .. 19 { // 14, 15, 0, 1, 2 across a 4-bit wrap
		mut d := []u8{len: 8}
		e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'wrap at n=${n} was reported as a violation'
	}
}

// The three faults this exists to catch. (Corrupted by hand here so the verifier does not
// depend on the fault injector living in the same branch.)
fn test_it_catches_what_fault_injection_produces() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }

	// bad_crc
	mut v1 := Verifier{ msg: m, e2e: e }
	mut d1 := []u8{len: 8}
	e.apply(m, mut d1, 0)
	assert v1.check(d1) == .ok
	mut bad := []u8{len: 8}
	e.apply(m, mut bad, 1)
	bad[7] = ~bad[7] // corrupt the checksum field, as fault injection does
	assert v1.check(bad) == .bad_crc, 'a corrupted checksum must be caught'

	// a stalled counter
	mut v2 := Verifier{ msg: m, e2e: e }
	mut a := []u8{len: 8}
	e.apply(m, mut a, 5)
	assert v2.check(a) == .ok
	assert v2.check(a) == .stalled_ctr, 'a repeated counter must be caught'

	// a skipped counter
	mut v3 := Verifier{ msg: m, e2e: e }
	mut p := []u8{len: 8}
	e.apply(m, mut p, 1)
	assert v3.check(p) == .ok
	mut q := []u8{len: 8}
	e.apply(m, mut q, 4) // 1 -> 4
	assert v3.check(q) == .skipped_ctr
	assert v3.bad == 1
}

// A wrong checksum must not be read as a counter verdict: those bits are as likely to be
// corrupt as any others, so the checksum is judged first and alone.
fn test_a_bad_checksum_is_reported_before_the_counter() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	mut first := []u8{len: 8}
	e.apply(m, mut first, 0)
	assert v.check(first) == .ok

	// both wrong at once: counter repeated AND checksum corrupted
	mut both := []u8{len: 8}
	e.apply(m, mut both, 0)
	both[7] = ~both[7]
	assert v.check(both) == .bad_crc, 'the checksum verdict must win'
}

// The first frame has nothing to compare against, and must not be reported as a stall.
fn test_first_frame_is_never_a_counter_violation() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	mut d := []u8{len: 8}
	e.apply(m, mut d, 7) // arriving mid-stream, counter already at 7
	assert v.check(d) == .ok
	assert v.bad == 0
}

// A standard and an extended message may share a raw id. Keyed on the number alone, one
// verifier judged both formats and merged two independent counter streams into reported skips.
fn test_verifiers_are_keyed_by_id_and_format() {
	mut std_m := vmsg()
	std_m.name = 'Std'
	std_m.sender = 'N'
	mut ext_m := vmsg()
	ext_m.name = 'Ext'
	ext_m.ext = true
	ext_m.sender = 'N'
	db := candb.Database{ nodes: ['N'], messages: [std_m, ext_m] }
	nodes := [project.NodeCfg{
		name:    'N'
		protect: [
			project.ProtectCfg{ message: 'Std', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' },
			project.ProtectCfg{ message: 'Ext', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' },
		]
	}]
	set := verifiers_for(db, nodes, [])
	assert set.by_key.len == 2, 'both formats must have their own verifier'
	assert vkey(0x123, false) in set.by_key
	assert vkey(0x123, true) in set.by_key
}

// A counter wider than 30 bits must still wrap. Forcing the modulus to zero turned a legal
// 31-bit wrap into a reported skip, and narrowing the state into a signed int made a high-bit
// value look like "nothing seen yet".
fn test_wide_counter_wraps_instead_of_reporting_a_skip() {
	m := candb.Message{
		name: 'Wide'
		id:   0x200
		dlc:  8
		signals: [
			candb.Signal{ name: 'Ctr', start_bit: 0, length: 31, byte_order: .little_endian, factor: 1 },
		]
	}
	e := E2e{ counter: 'Ctr' }
	mut v := Verifier{ msg: m, e2e: e }
	span := u64(1) << 31
	mut a := []u8{len: 8}
	m.signals[0].set_raw(mut a, span - 2)
	assert v.check(a) == .ok
	mut b := []u8{len: 8}
	m.signals[0].set_raw(mut b, span - 1)
	assert v.check(b) == .ok
	mut c := []u8{len: 8}
	m.signals[0].set_raw(mut c, 0) // the wrap
	assert v.check(c) == .ok, 'a 31-bit wrap must not be reported as a skip'
}

// A frame shorter than its DBC message cannot be judged: the missing checksum and counter bits
// read as zero, and an EMPTY payload computes zero for every supported checksum — which then
// matches the absent field and passes the first-counter rule as clean. A malformed frame must
// not be able to look better than a well-formed one.
fn test_truncated_frames_are_rejected_not_silently_accepted() {
	m := vmsg() // dlc 8
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	assert v.check([]u8{len: 0}) == .truncated, 'an empty payload must not read as clean'
	assert v.check([]u8{len: 4}) == .truncated
	assert v.bad == 2
	// and a full-length frame still passes
	mut ok := []u8{len: 8}
	e.apply(m, mut ok, 0)
	assert v.check(ok) == .ok
}

// The stamping path scopes messages to the configured sender. Verification must do the same, or
// a merged database with one message name on two transmitters verifies against the wrong id and
// layout while the configuration validates cleanly.
fn test_verifier_binds_to_the_configured_senders_message() {
	mut a := vmsg()
	a.name = 'Shared'
	a.id = 0x111
	a.sender = 'NodeA'
	mut b := vmsg()
	b.name = 'Shared'
	b.id = 0x222
	b.sender = 'NodeB'
	db := candb.Database{ nodes: ['NodeA', 'NodeB'], messages: [a, b] }
	nodes := [project.NodeCfg{
		name:    'NodeB'
		protect: [project.ProtectCfg{ message: 'Shared', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }]
	}]
	set := verifiers_for(db, nodes, [])
	assert vkey(0x222, false) in set.by_key, 'must bind to NodeB\'s message, not the first match'
	assert vkey(0x111, false) !in set.by_key
}

// The ECU under test is the one node a rest-bus setup does NOT simulate, so its protection can
// never be described by a simulated node's protect: — and it is exactly that ECU whose counter
// and checksum a bench needs checked. Channel-level `verify:` covers it.
fn test_channel_verify_covers_an_unsimulated_ecu() {
	mut m := vmsg()
	m.name = 'BenchEcuStatus'
	m.id = 0x321
	m.sender = 'BenchEcu' // a transmitter we do NOT simulate
	db := candb.Database{ nodes: ['BenchEcu'], messages: [m] }
	verify := [project.ProtectCfg{
		message: 'BenchEcuStatus'
		counter: 'AliveCounter'
		crc:     'CRC'
		profile: 'crc8_j1850'
	}]
	// no simulated nodes at all — the rest-bus is elsewhere or this is a pure monitor
	set := verifiers_for(db, [], verify)
	assert vkey(0x321, false) in set.by_key, 'the bench ECU must be verifiable without simulating it'
}

// A checksum field narrower or wider than 8 bits must be compared at ITS width: narrowing threw
// away a wide field's upper bits, and comparing a narrow field against the full byte labelled
// the sender's own frames as corrupt.
fn test_checksum_compared_at_the_declared_width() {
	m := candb.Message{
		name: 'Narrow'
		id:   0x400
		dlc:  8
		signals: [
			candb.Signal{ name: 'CRC4', start_bit: 0, length: 4, byte_order: .little_endian, factor: 1 },
			candb.Signal{ name: 'Data', start_bit: 8, length: 8, byte_order: .little_endian, factor: 1 },
		]
	}
	e := E2e{ crc: 'CRC4', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	// a frame the STAMPER produced must verify, even though the field holds only 4 bits of it
	mut d := []u8{len: 8}
	e.apply(m, mut d, 0)
	assert v.check(d) == .ok, 'the sender\'s own frame must not be reported corrupt'
	// and corrupting those 4 bits is still caught
	mut bad := d.clone()
	bad[0] = bad[0] ^ 0x0F
	assert v.check(bad) == .bad_crc
}

// A `verify:` entry that checks nothing must SAY so. Node-level protect: goes through
// validate_protection; these did not, so a misspelled name produced no verifier and every frame
// came back clean — disabling the bench check the user believes is running.
fn test_validate_verify_reports_entries_that_check_nothing() {
	mut m := vmsg()
	m.name = 'Status'
	db := candb.Database{ messages: [m] }

	bad_msg := [project.ProtectCfg{ message: 'Nope', crc: 'CRC' }]
	assert validate_verify(db, bad_msg).any(it.contains('no message "Nope"'))

	bad_sig := [project.ProtectCfg{ message: 'Status', counter: 'NoSuch', crc: 'AlsoNo' }]
	assert validate_verify(db, bad_sig).len == 2

	empty := [project.ProtectCfg{ message: 'Status' }]
	assert validate_verify(db, empty).any(it.contains('neither counter nor crc'))

	good := [project.ProtectCfg{ message: 'Status', counter: 'AliveCounter', crc: 'CRC' }]
	assert validate_verify(db, good).len == 0
}

// A merged database can carry one message name at two ids. Binding to whichever came first left
// the intended ECU frame unchecked, so the ambiguity is reported and `id:` resolves it.
fn test_ambiguous_verify_names_need_an_id() {
	mut a := vmsg()
	a.name = 'Status'
	a.id = 0x111
	mut b := vmsg()
	b.name = 'Status'
	b.id = 0x222
	db := candb.Database{ messages: [a, b] }

	ambiguous := [project.ProtectCfg{ message: 'Status', crc: 'CRC' }]
	assert validate_verify(db, ambiguous).any(it.contains('matches several messages'))

	pinned := [project.ProtectCfg{ message: 'Status', crc: 'CRC', id: u32(0x222) }]
	assert validate_verify(db, pinned).len == 0
	set := verifiers_for(db, [], pinned)
	assert vkey(0x222, false) in set.by_key, 'the id: must select the intended message'
	assert vkey(0x111, false) !in set.by_key
}

// The classes already fixed for protect: and uds: apply here too — a verify: entry was added
// without carrying them over, so each could silently disable the check it configures.
fn test_validate_verify_catches_the_familiar_configuration_traps() {
	mut a := vmsg()
	a.name = 'Status'
	a.id = 0x111
	db := candb.Database{ messages: [a] }

	// an unknown profile: checksum_of falls back to sum8 and real traffic reads as corrupt
	bad_prof := [project.ProtectCfg{ message: 'Status', crc: 'CRC', profile: 'typo' }]
	assert validate_verify(db, bad_prof).any(it.contains('unknown profile'))

	// two entries for one message: the second replaced the first, disabling half the checks
	split := [
		project.ProtectCfg{ message: 'Status', counter: 'AliveCounter', profile: 'crc8_j1850' },
		project.ProtectCfg{ message: 'Status', crc: 'CRC', profile: 'crc8_j1850' },
	]
	assert validate_verify(db, split).any(it.contains('only the first applies'))
	set := verifiers_for(db, [], split)
	assert set.by_key[vkey(0x111, false)] or { panic('none') }.e2e.counter == 'AliveCounter',
		'the FIRST entry must win, deterministically'

	// a malformed id binds to whatever lives at the repaired value
	bad_id := [project.ProtectCfg{ message: 'Status', crc: 'CRC', profile: 'crc8_j1850', id_malformed: true }]
	assert validate_verify(db, bad_id).any(it.contains('not a valid number'))
}

// One id can exist in BOTH formats, so an id: alone cannot disambiguate it.
fn test_verify_selects_on_frame_format_too() {
	mut std_m := vmsg()
	std_m.name = 'Dual'
	std_m.id = 0x300
	mut ext_m := vmsg()
	ext_m.name = 'Dual'
	ext_m.id = 0x300
	ext_m.ext = true
	db := candb.Database{ messages: [std_m, ext_m] }

	just_id := [project.ProtectCfg{ message: 'Dual', crc: 'CRC', profile: 'crc8_j1850', id: u32(0x300) }]
	assert validate_verify(db, just_id).any(it.contains('matches several')), 'id alone is ambiguous here'

	pinned := [project.ProtectCfg{
		message:  'Dual'
		crc:      'CRC'
		profile:  'crc8_j1850'
		id:       u32(0x300)
		extended: true
	}]
	assert validate_verify(db, pinned).len == 0
	set := verifiers_for(db, [], pinned)
	assert vkey(0x300, true) in set.by_key
	assert vkey(0x300, false) !in set.by_key
}

// Validation and construction must agree. They did not: a malformed id was reported as
// "ignored" while a verifier was built for the repaired value, so the run logged a warning and
// then checked the wrong frame — worse than either failure alone.
fn test_validation_and_construction_agree() {
	mut m := vmsg()
	m.name = 'Status'
	m.id = 0x111
	mut mux := vmsg()
	mux.name = 'Muxed'
	mux.id = 0x112
	mux.signals[0].is_multiplexed = true // AliveCounter only present on one branch
	db := candb.Database{ messages: [m, mux] }

	cases := [
		project.ProtectCfg{ message: 'Status', crc: 'CRC', profile: 'crc8_j1850', id_malformed: true },
		project.ProtectCfg{ message: 'Status', crc: 'CRC', profile: 'crc8_j1850', data_id_malformed: true },
		project.ProtectCfg{ message: 'Status', counter: 'CRC', crc: 'CRC', profile: 'crc8_j1850' },
		project.ProtectCfg{ message: 'Status', crc: 'CRC', profile: 'nonsense' },
		project.ProtectCfg{ message: 'Muxed', counter: 'AliveCounter', profile: 'crc8_j1850' },
	]
	for c in cases {
		assert validate_verify(db, [c]).len > 0, 'must be reported: ${c.message}/${c.profile}'
		assert verifiers_for(db, [], [c]).by_key.len == 0,
			'must NOT be built while reported: ${c.message}/${c.profile}'
	}

	// and a good entry is both silent and built
	ok := project.ProtectCfg{ message: 'Status', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	assert validate_verify(db, [ok]).len == 0
	assert verifiers_for(db, [], [ok]).by_key.len == 1
}

// Two channel entries on one bus, each valid on its own, describing the same frame differently:
// insert-if-absent kept the first and silently dropped the second check.
fn test_conflicting_verifiers_on_a_shared_bus_are_reported() {
	mut m := vmsg()
	m.name = 'Status'
	m.id = 0x111
	db := candb.Database{ messages: [m] }

	mut a := verifiers_for(db, [], [project.ProtectCfg{
		message: 'Status'
		counter: 'AliveCounter'
		profile: 'crc8_j1850'
	}])
	b := verifiers_for(db, [], [project.ProtectCfg{
		message: 'Status'
		crc:     'CRC'
		profile: 'crc8_j1850'
	}])
	w := a.merge_into(b)
	assert w.len == 1, '${w}'
	assert w[0].contains('configured differently')
	assert a.by_key.len == 1

	// the SAME entry twice is not a conflict
	c := verifiers_for(db, [], [project.ProtectCfg{
		message: 'Status'
		counter: 'AliveCounter'
		profile: 'crc8_j1850'
	}])
	assert a.merge_into(c).len == 0
}

// `.bool()` coerces an unrecognised scalar to false, so a typo became a standard-frame selector
// and verification quietly checked the wrong frame.
fn test_malformed_extended_selector_is_rejected() {
	mut m := vmsg()
	m.name = 'Dual'
	db := candb.Database{ messages: [m] }
	bad := [project.ProtectCfg{
		message:            'Dual'
		crc:                'CRC'
		profile:            'crc8_j1850'
		extended_malformed: true
	}]
	assert validate_verify(db, bad).any(it.contains('not true/false'))
	assert verifiers_for(db, [], bad).by_key.len == 0, 'reported AND not built'
}

// data_id is mixed into the checksum, so two entries agreeing on every other field but
// differing here expect DIFFERENT checksums. Treating them as identical kept the first and
// reported the other's traffic as !CRC with no conflict warning.
fn test_data_id_is_part_of_verifier_identity() {
	mut m := vmsg()
	m.name = 'Status'
	m.id = 0x111
	db := candb.Database{ messages: [m] }
	mk := fn (db candb.Database, id ?u32) VerifySet {
		return verifiers_for(db, [], [project.ProtectCfg{
			message: 'Status'
			crc:     'CRC'
			profile: 'crc8_j1850'
			data_id: id
		}])
	}
	mut a := mk(db, u32(7))
	assert a.merge_into(mk(db, u32(9))).len == 1, 'a different data_id is a conflict'

	mut b := mk(db, u32(7))
	assert b.merge_into(mk(db, u32(7))).len == 0, 'the same data_id is not'

	mut c := mk(db, none)
	assert c.merge_into(mk(db, u32(7))).len == 1, 'present vs absent is a conflict'

	mut d := mk(db, none)
	assert d.merge_into(mk(db, none)).len == 0, 'both absent is not'
}
