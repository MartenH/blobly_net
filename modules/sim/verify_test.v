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

// #95: only a `verify:` entry describes somebody ELSE's traffic. A node's `protect:` entry
// describes a message that node SENDS, so our own frames carrying it are the normal case — the
// thing the simulation exists to produce. Warning about those would fire on every correct
// project with a protected simulated node, and docs/simulation.md's `protect:` example has no
// `verify:` block at all.
fn test_only_verify_entries_can_be_self_sent_by_mistake() {
	mut m := vmsg()
	m.name = 'Protected'
	m.sender = 'SimNode'
	db := candb.Database{ nodes: ['SimNode'], messages: [m] }
	prot := project.ProtectCfg{ message: 'Protected', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }

	// from a node's protect: -- ours by construction, never a mistake
	from_protect := verifiers_for(db, [project.NodeCfg{ name: 'SimNode', protect: [prot] }], [])
	assert from_protect.by_key.len == 1, 'the verifier is still built'
	assert build_coverage([db], from_protect.from_verify).covers(0x123, false) == none
	assert build_coverage([db], from_protect.from_verify).name_of(vkey(0x123, false)) == ''

	// from channel-level verify: -- describes the ECU under test, so a frame of ours is the bug
	from_verify := verifiers_for(db, [], [prot])
	assert from_verify.by_key.len == 1
	assert build_coverage([db], from_verify.from_verify).covers(0x123, false) != none
}

// Merging the channel entries that share a wire must carry the provenance with the verifier, or
// a set merged from a second entry loses which of its keys describe somebody else's traffic.
fn test_merge_carries_which_keys_came_from_verify() {
	mut m := vmsg()
	m.name = 'Protected'
	db := candb.Database{ nodes: ['N'], messages: [m] }
	prot := project.ProtectCfg{ message: 'Protected', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut dst := VerifySet{}
	dst.merge_into(verifiers_for(db, [], [prot]))
	assert build_coverage([db], dst.from_verify).covers(0x123, false) != none, 'provenance must survive the merge'
}

// The wording states what happened and what follows, without claiming to know whether the entry
// checks nothing — a message with a real sender beside ours is still genuinely checked for the
// other sender's frames, and one frame cannot tell the two apart.
fn test_self_sent_warning_claims_only_what_one_frame_proves() {
	w := self_sent_warning('Protected', 0x123, false)
	assert w.contains('Protected'), 'the message must be named: ${w}'
	assert w.contains('0x123')
	assert w.contains('a frame this app sent'), 'reports the frame, not the configuration: ${w}'
	assert w.contains('checks only frames somebody else sends')
	// A one-off Quick Send is `ours` too, so the text must not assert a permanent property of
	// the project -- it observed one transmission and knows nothing about what caused it.
	assert !w.contains('this project transmits itself')
	assert !w.contains('nothing at all')
	assert !w.contains(' ext')
	assert self_sent_warning('EEC1', 0x18FEF100, true).contains('18FEF100 ext')
}

// The same message reaching one wire from a node's `protect:` on one channel entry and from
// `verify:` on another must not depend on which entry app.sims lists first. verifiers_for
// resolves that collision in favour of `verify:` by building those keys first; the merge has to
// agree, including on the paths where it keeps the verifier it already had.
fn test_merge_provenance_does_not_depend_on_order() {
	mut m := vmsg()
	m.name = 'Protected'
	m.sender = 'SimNode'
	db := candb.Database{ nodes: ['SimNode'], messages: [m] }
	prot := project.ProtectCfg{ message: 'Protected', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	from_protect := verifiers_for(db, [project.NodeCfg{ name: 'SimNode', protect: [prot] }], [])
	from_verify := verifiers_for(db, [], [prot])
	k := vkey(0x123, false)

	// verify: first, then the identical protect: entry -- the `continue` path
	mut a := VerifySet{}
	a.merge_into(from_verify)
	a.merge_into(from_protect)
	assert build_coverage([db], a.from_verify).covers(0x123, false) != none, 'verify: provenance must survive an identical merge'

	// and the other way round
	mut b := VerifySet{}
	b.merge_into(from_protect)
	b.merge_into(from_verify)
	assert build_coverage([db], b.from_verify).covers(0x123, false) != none, 'order must not decide it'
}

// The self-sent question asked of a LIVE J1939 id — the case our own frames actually present.
// Our transmissions never call resolve (that would adopt, keying a verifier on our own source
// address), so the exact key is all the caller has, and for J1939 it never matches: a live frame
// carries a priority and source address the DBC does not. verify_covers is what closes that.
fn test_verify_covers_answers_for_a_live_j1939_id() {
	mut m := vmsg()
	m.name = 'EEC1'
	m.id = 0x0CF00400
	m.ext = true
	m.j1939 = true // the file declares it: BA_ "VFrameFormat" ... J1939PG
	db := candb.Database{ nodes: ['Ecu'], messages: [m] }
	set := verifiers_for(db, [], [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }])

	// the DBC's own id, and the same PGN from another source address
	assert build_coverage([db], set.from_verify).covers(0x0CF00400, true) != none
	assert build_coverage([db], set.from_verify).covers(0x0CF00421, true) or { '' } == vkey(0x0CF00400, true), 'a live SA matches, and returns the MESSAGE key so the notice latches once'
	// a different PGN is not covered
	assert build_coverage([db], set.from_verify).covers(0x0CF00500, true) == none
	// and it stays READ-ONLY: no verifier keyed on our own source address is created
	assert vkey(0x0CF00421, true) !in set.by_key
	assert vkey(0x0CF00421, true) !in set.from_verify
}

// A `protect:` message reaching verify_covers must still answer no — the provenance split has to
// hold through the PGN path too, or a simulated J1939 node reports itself every run.
fn test_verify_covers_keeps_the_provenance_split() {
	mut m := vmsg()
	m.name = 'EEC1'
	m.id = 0x0CF00400
	m.ext = true
	m.j1939 = true // the file declares it: BA_ "VFrameFormat" ... J1939PG
	m.sender = 'SimNode'
	db := candb.Database{ nodes: ['SimNode'], messages: [m] }
	set := verifiers_for(db, [project.NodeCfg{
		name:    'SimNode'
		protect: [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }]
	}], [])
	assert set.by_key.len == 1, 'the verifier is built'
	assert build_coverage([db], set.from_verify).covers(0x0CF00421, true) == none, 'ours by construction: never reported'
}

// THE INVARIANT THE NOTICE'S "once per message" RESTS ON: whatever source address a J1939 frame
// carries, verify_covers answers with the SAME key — the message's, never the wire's. It failed
// this once: resolve() marked an adopted live key as verify:-sourced, so a frame at an address
// some foreign frame had already adopted took the exact-key fast path and came back keyed on the
// wire id, while every other address came back keyed on the message. One entry, two latches, the
// line said twice. Neither of the two tests around it compared the answers, so both passed.
fn test_verify_covers_answers_with_one_key_for_every_source_address() {
	mut m := vmsg()
	m.name = 'EEC1'
	m.id = 0x0CF00400
	m.ext = true
	m.j1939 = true // the file declares it: BA_ "VFrameFormat" ... J1939PG
	db := candb.Database{ nodes: ['Ecu'], messages: [m] }
	mut set := verifiers_for(db, [], [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }])
	want := vkey(0x0CF00400, true)

	// a foreign frame arrives first and resolve adopts its address into the VERIFIER set
	set.resolve([db], 0x0CF00421, true) or { assert false, 'the PGN must be adopted' }

	// the index is built from the provenance half, which the adoption must not have touched:
	// every address, including the adopted one, answers with the MESSAGE's key
	cover := build_coverage([db], set.from_verify)
	for live in [u32(0x0CF00421), 0x0CF00422, 0x0CF004FE, 0x0CF00400] {
		got := cover.covers(live, true) or {
			assert false, 'must be covered: 0x${live:X}'
			return
		}
		assert got == want, '0x${live:X} answered ${got}, not the message key ${want}'
	}
}

// A defined message wins over anything sharing its PGN, whichever database it is in. j1939_pgn
// applies to EVERY 29-bit id with nothing testing that the bus is J1939 — a UDS request and its
// response (0x18DA10F1 / 0x18DAF110) share one — so transmitting the response must not be read
// as the request the project asked to verify.
fn test_a_defined_message_beats_a_shared_pgn() {
	mut req := vmsg()
	req.name = 'UdsReq'
	req.id = 0x18DA10F1
	req.ext = true
	mut rsp := vmsg()
	rsp.name = 'UdsRsp'
	rsp.id = 0x18DAF110
	rsp.ext = true
	db := candb.Database{ nodes: ['Ecu'], messages: [req, rsp] }
	set := verifiers_for(db, [], [project.ProtectCfg{ message: 'UdsReq', counter: 'AliveCounter' }])
	assert build_coverage([db], set.from_verify).covers(0x18DA10F1, true) != none, 'the verified one is covered'
	assert build_coverage([db], set.from_verify).covers(0x18DAF110, true) == none, 'a DEFINED message sharing its PGN is not'
}

// …and across databases, where lookup_frame cannot see the other one: asked per database, a PGN
// match in the first beat a defined message in the second, so the answer depended on DBC order.
fn test_the_exact_match_wins_whichever_database_holds_it() {
	mut verified := vmsg()
	verified.name = 'EEC1'
	verified.id = 0x0CF00400
	verified.ext = true
	verified.j1939 = true
	mut other := vmsg()
	other.name = 'SomethingElse'
	other.id = 0x0CF00421
	other.ext = true
	first := candb.Database{ nodes: ['A'], messages: [verified] }
	second := candb.Database{ nodes: ['B'], messages: [other] }
	set := verifiers_for(first, [], [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }])
	assert build_coverage([first, second], set.from_verify).covers(0x0CF00421, true) == none, 'the defined message in the SECOND database must win'
}

// The NAME the notice prints comes from the `verify:` entry, not from whichever Verifier survived
// a merge collision. Two channel entries on one wire can describe one CAN id from databases that
// name it differently; with equal E2E settings merge_into keeps the first, so reading the name
// back off the Verifier made the line depend on channel order and could name a message `verify:`
// does not list (codex on #289).
fn test_the_notice_name_does_not_depend_on_which_verifier_won() {
	e2e := project.ProtectCfg{ message: 'TheirName', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut theirs := vmsg()
	theirs.name = 'TheirName'
	their_db := candb.Database{ nodes: ['Ecu'], messages: [theirs] }
	mut ours := vmsg()
	ours.name = 'OurName'
	ours.sender = 'SimNode'
	our_db := candb.Database{ nodes: ['SimNode'], messages: [ours] }

	// the protect: side lands FIRST and keeps the Verifier; the verify: side follows
	mut set := VerifySet{}
	set.merge_into(verifiers_for(our_db, [project.NodeCfg{
		name:    'SimNode'
		protect: [project.ProtectCfg{ message: 'OurName', counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }]
	}], []))
	set.merge_into(verifiers_for(their_db, [], [e2e]))

	k := vkey(0x123, false)
	assert build_coverage([their_db, our_db], set.from_verify).covers(0x123, false) != none, 'the verify: entry is recorded'
	assert build_coverage([their_db, our_db], set.from_verify).name_of(k) == 'TheirName', 'the notice must name what verify: listed'
	assert set.by_key[k] or { Verifier{} }.msg.name == 'OurName', 'the FIRST verifier is kept -- which is why the name is not read from it'
}

// The index is built once and read for the life of a run, so what it does with an id NOTHING
// describes matters as much as what it does with one that is described. A standard-format id
// has no PGN at all, and an extended one whose PGN belongs to nobody is not covered.
fn test_the_index_answers_none_for_what_verify_never_named() {
	mut m := vmsg()
	m.name = 'EEC1'
	m.id = 0x0CF00400
	m.ext = true
	m.j1939 = true // the file declares it: BA_ "VFrameFormat" ... J1939PG
	db := candb.Database{ nodes: ['Ecu'], messages: [m] }
	set := verifiers_for(db, [], [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }])
	cover := build_coverage([db], set.from_verify)

	assert cover.covers(0x0CF00421, true) != none, 'the same PGN, another source address'
	assert cover.covers(0x0CF00400, false) == none, 'standard format is a different message'
	assert cover.covers(0x18FEF100, true) == none, 'another PGN entirely'
	assert cover.covers(0x123, false) == none
	assert cover.name_of('nonsense') == ''
}

// An empty `verify:` is most projects, and the notice must cost them nothing: an index with no
// names answers none for everything without consulting the PGN table.
fn test_an_empty_verify_covers_nothing() {
	mut m := vmsg()
	m.ext = true
	m.id = 0x0CF00400
	db := candb.Database{ nodes: ['Ecu'], messages: [m] }
	cover := build_coverage([db], map[string]VerifyOrigin{})
	assert cover.names.len == 0
	assert cover.covers(0x0CF00400, true) == none
	assert cover.covers(0x0CF00421, true) == none
}

// CODEX'S COUNTER-CASE, AS A TEST. A database defining only the verified UDS request; our own
// simulation hosts the response on an id defined NOWHERE. The two share a computed PGN, so with
// the PGN table built from every extended id, transmitting the response was reported as the
// request the project asked to verify — a definite claim about the operator's configuration,
// from nothing but a bit pattern (#289).
fn test_an_undeclared_extended_id_is_not_matched_by_pgn() {
	mut req := vmsg()
	req.name = 'UdsReq'
	req.id = 0x18DA10F1
	req.ext = true // extended, and NOT declared J1939 — because it is not
	db := candb.Database{ nodes: ['Ecu'], messages: [req] }
	set := verifiers_for(db, [], [project.ProtectCfg{ message: 'UdsReq', counter: 'AliveCounter' }])
	cover := build_coverage([db], set.from_verify)

	assert candb.j1939_pgn(0x18DA10F1) == candb.j1939_pgn(0x18DAF110), 'the premise: they share a PGN'
	assert cover.covers(0x18DA10F1, true) != none, 'the verified message itself is still covered'
	assert cover.covers(0x18DAF110, true) == none, 'a response defined nowhere must not be read as the request'
	assert cover.pgns.len == 0, 'an undeclared frame earns no PGN entry at all'
}

// THE EVIDENCE IS THE FILE'S, NOT THE ID'S. The same message, once undeclared and once carrying
// `BA_ "VFrameFormat" … J1939PG`: only the declared one gets source-address matching.
fn test_the_pgn_table_follows_the_declaration() {
	mut plain := vmsg()
	plain.name = 'EEC1'
	plain.id = 0x0CF00400
	plain.ext = true
	undeclared := candb.Database{ nodes: ['Ecu'], messages: [plain] }

	mut declared_msg := plain
	declared_msg.j1939 = true
	declared := candb.Database{ nodes: ['Ecu'], messages: [declared_msg] }

	entry := [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }]
	no_decl := build_coverage([undeclared], verifiers_for(undeclared, [], entry).from_verify)
	with_decl := build_coverage([declared], verifiers_for(declared, [], entry).from_verify)

	// the exact key is covered either way — that needs no evidence beyond the entry itself
	assert no_decl.covers(0x0CF00400, true) != none
	assert with_decl.covers(0x0CF00400, true) != none
	// another source address is covered ONLY where the file said the bus is J1939
	assert no_decl.covers(0x0CF00421, true) == none, 'undeclared: exact-key matching only'
	assert with_decl.covers(0x0CF00421, true) != none, 'declared: the PGN is real evidence'
}

// TWO VERIFIED MESSAGES ON ONE PGN. Source-specific definitions of a parameter group, or PDU1
// messages differing by destination, both reduce to one PGN. A single-valued table kept whichever
// was visited last, so a frame at some THIRD source address was reported and latched under a name
// that may not be the one it belongs to. Neither candidate is more right, and the notice's whole
// contract is that it names the message `verify:` listed (codex on #289).
fn test_an_ambiguous_pgn_earns_no_coverage() {
	mut a := vmsg()
	a.name = 'EEC1_FromEngine'
	a.id = 0x0CF00400
	a.ext = true
	a.j1939 = true
	mut b := vmsg()
	b.name = 'EEC1_FromRetarder'
	b.id = 0x0CF00410 // same PGN (0xF004), another source address
	b.ext = true
	b.j1939 = true
	assert candb.j1939_pgn(a.id) == candb.j1939_pgn(b.id), 'the premise: one PGN'
	db := candb.Database{ nodes: ['Ecu'], messages: [a, b] }
	set := verifiers_for(db, [], [
		project.ProtectCfg{ message: 'EEC1_FromEngine', counter: 'AliveCounter' },
		project.ProtectCfg{ message: 'EEC1_FromRetarder', counter: 'AliveCounter' },
	])
	cover := build_coverage([db], set.from_verify)

	// each is still covered by its own exact key — that needs no PGN
	assert cover.covers(0x0CF00400, true) != none
	assert cover.covers(0x0CF00410, true) != none
	// but a third address belongs to neither name, so nothing is claimed
	assert cover.covers(0x0CF00421, true) == none, 'an ambiguous PGN must claim nothing'
	assert cover.pgns.len == 0
}

// THE DECLARATION TRAVELS WITH THE MESSAGE THAT SATISFIED THE ENTRY. Two databases on one wire
// may define the same (id, ext); the merge keeps the FIRST. Re-matching the key across every
// database let the verified message inherit a J1939 declaration from the duplicate that was
// discarded — reinstating the false warning the declaration guard exists to prevent (codex #289).
fn test_a_discarded_duplicate_cannot_lend_its_declaration() {
	mut plain := vmsg()
	plain.name = 'EEC1'
	plain.id = 0x0CF00400
	plain.ext = true // the verified definition: NOT declared J1939
	first := candb.Database{ nodes: ['A'], messages: [plain] }

	mut declared := plain
	declared.j1939 = true // a sibling database's duplicate, which the merge discards
	second := candb.Database{ nodes: ['B'], messages: [declared] }

	set := verifiers_for(first, [], [project.ProtectCfg{ message: 'EEC1', counter: 'AliveCounter' }])
	cover := build_coverage([first, second], set.from_verify)

	assert cover.covers(0x0CF00400, true) != none, 'the verified message is still covered'
	assert cover.covers(0x0CF00421, true) == none, 'the discarded duplicate must not lend its declaration'
	assert cover.pgns.len == 0
}
