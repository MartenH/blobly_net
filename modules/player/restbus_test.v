module player

import canlog
import candb
import transport

// A small stand-in for a vehicle bus: two nodes that send, one message nobody is credited with,
// and one id the database never heard of. Every case the subtraction has to distinguish, in a
// database small enough to reason about by hand.
fn sample_db() candb.Database {
	return candb.Database{
		nodes:    ['VCM_C', 'EBS']
		messages: [
			candb.Message{
				name:   'VcmStatus'
				id:     0x100
				sender: 'VCM_C'
			},
			candb.Message{
				name:   'VcmSpeed'
				id:     0x101
				sender: 'VCM_C'
			},
			candb.Message{
				name:   'BrakeStatus'
				id:     0x200
				sender: 'EBS'
			},
			candb.Message{
				name:   'Orphan' // defined, but the DBC names no transmitter
				id:     0x300
				sender: ''
			},
		]
	}
}

fn entry(iface string, id u32, t f64) canlog.LogEntry {
	return canlog.LogEntry{
		t_s:   t
		iface: iface
		frame: transport.CanFrame{
			id:   id
			data: [u8(1), 2, 3, 4]
		}
	}
}

fn sample() []canlog.LogEntry {
	return [
		entry('mf4:group25', 0x100, 0.00), // VCM_C
		entry('mf4:group25', 0x200, 0.01), // EBS
		entry('mf4:group25', 0x300, 0.02), // unattributed
		entry('mf4:group25', 0x999, 0.03), // not in the database at all
		entry('mf4:group25', 0x101, 0.04), // VCM_C
		entry('mf4:group37', 0x200, 0.05), // another bus entirely
	]
}

fn test_only_the_named_bus_is_replayed() {
	got := on_bus(sample(), 'mf4:group25')
	assert got.len == 5
	for e in got {
		assert e.iface == 'mf4:group25'
	}
}

// The point of the whole exercise: the ECU under test stops being replayed at itself.
fn test_the_excluded_nodes_frames_are_withheld() {
	src := on_bus(sample(), 'mf4:group25')
	kept, rep := without_senders(src, sample_db(), ['VCM_C'], true)
	mut ids := []u32{}
	for e in kept {
		ids << e.frame.id
	}
	assert 0x100 !in ids, 'the SUT is still transmitting from the recording'
	assert 0x101 !in ids
	assert 0x200 in ids, 'the rest of the bus must keep running'
	assert rep.withheld_excluded == 2
	assert rep.withheld_unattributed == 0, 'the unattributed policy must not be counted as the SUT'
	assert rep.kept == 3
}

// An id the database does not define is still evidence: the recording proves it was on the wire.
// Dropping what the database omits would quietly gut a rest bus wherever the database is
// incomplete, which is the normal state of affairs.
fn test_an_id_the_database_never_heard_of_is_still_replayed() {
	src := on_bus(sample(), 'mf4:group25')
	kept, rep := without_senders(src, sample_db(), ['VCM_C'], true)
	assert kept.filter(it.frame.id == 0x999).len == 1
	assert rep.unknown == 1
	assert rep.unknown_ids == [u32(0x999)]
}

// The messages a database defines but does not attribute. There is no safe default, so the
// caller picks and BOTH answers must actually work.
fn test_unattributed_messages_follow_the_callers_choice() {
	src := on_bus(sample(), 'mf4:group25')
	with, rep_with := without_senders(src, sample_db(), ['VCM_C'], true)
	assert with.filter(it.frame.id == 0x300).len == 1
	assert rep_with.unattributed == 1
	assert rep_with.unattributed_ids == [u32(0x300)]

	without, rep_without := without_senders(src, sample_db(), ['VCM_C'], false)
	assert without.filter(it.frame.id == 0x300).len == 0
	assert rep_without.unattributed == 1, 'still reported when withheld — the count is the point'
	// the two reasons stay apart: 2 frames are the SUT's, 1 is the unattributed policy
	assert rep_without.withheld_excluded == 2
	assert rep_without.withheld_unattributed == 1
}

// A misspelled node subtracts NOTHING, and the result looks exactly like a working rest bus
// until the SUT starts losing arbitration against a recording of itself.
fn test_an_unknown_node_name_is_caught() {
	assert check_nodes(sample_db(), ['VCM_C']) == []
	assert check_nodes(sample_db(), ['VCM']) == ['VCM'], 'a typo must not pass silently'
	assert check_nodes(sample_db(), ['VCM_C', 'EBS']) == []
	assert check_nodes(sample_db(), ['VCM_C', 'nope']) == ['nope']
}

// A node that transmits without being declared in BU_ is still a real node. Rejecting it would
// refuse a legitimate exclusion on a technicality of how the database was written.
fn test_a_sender_missing_from_bu_still_counts_as_known() {
	db := candb.Database{
		nodes:    [] // no BU_ at all
		messages: [candb.Message{
			name:   'X'
			id:     0x10
			sender: 'GHOST'
		}]
	}
	assert check_nodes(db, ['GHOST']) == []
}

// Excluding nothing must leave the recording untouched — the identity case, which is what a
// user gets before they have decided what the SUT is.
fn test_excluding_nothing_keeps_everything() {
	src := on_bus(sample(), 'mf4:group25')
	kept, rep := without_senders(src, sample_db(), [], true)
	assert kept.len == src.len
	assert rep.withheld_excluded == 0
}

// next_due_ms has to agree with due(): whatever it names as the next due time, due() must emit
// exactly then and not before. Disagreement would make a sleeping sender either spin or stall.
fn test_next_due_agrees_with_due() {
	entries := [entry('a', 1, 0.0), entry('a', 2, 0.010), entry('a', 3, 0.025)]
	mut p := new_player(entries, 1.0, false)
	p.play(1000.0)
	nd := p.next_due_ms() or {
		assert false, 'something is pending right after play'
		return
	}
	assert nd == 1000.0, 'the first entry is due at the base, got ${nd}'
	p.due(1000.0)
	n2 := p.next_due_ms() or {
		assert false, 'the second entry is still pending'
		return
	}
	assert n2 > 1000.0 && n2 <= 1011.0, 'expected ~1010 ms, got ${n2}'
	// nothing comes out before that moment, and something does at it
	assert p.due(n2 - 1.0).len == 0, 'a frame was emitted early'
	assert p.due(n2).len == 1, 'the frame was not emitted when it came due'
}

fn test_nothing_is_due_when_not_playing() {
	mut p := new_player([entry('a', 1, 0.0)], 1.0, false)
	assert p.next_due_ms() == none, 'a stopped player has nothing pending'
}

// At the end of a non-looping recording there is nothing further; a looping one wraps to the
// next pass rather than reporting itself permanently idle.
fn test_the_end_of_the_recording_is_reported() {
	entries := [entry('a', 1, 0.0), entry('a', 2, 0.010)]
	mut p := new_player(entries, 1.0, false)
	p.play(0.0)
	p.due(1000.0) // drain
	assert p.next_due_ms() == none

	mut q := new_player(entries, 1.0, true)
	q.play(0.0)
	q.due(5.0) // first only
	nd := q.next_due_ms() or {
		assert false, 'a looping player always has something pending'
		return
	}
	assert nd > 0
}

// An 11-bit 0x100 and a 29-bit 0x100 are two different messages that may have two different
// senders. Keyed on the number alone, whichever definition was parsed last decided for both —
// so either the rest bus goes silent or the SUT's own frames get replayed at it, and the report
// shows neither.
fn test_a_standard_and_an_extended_id_are_not_the_same_message() {
	db := candb.Database{
		nodes:    ['VCM_C', 'EBS']
		messages: [
			candb.Message{
				name:   'StdFromEbs'
				id:     0x100
				ext:    false
				sender: 'EBS'
			},
			candb.Message{
				name:   'ExtFromVcm'
				id:     0x100
				ext:    true
				sender: 'VCM_C'
			},
		]
	}
	std := entry('a', 0x100, 0.0)
	ext := canlog.LogEntry{
		t_s:   0.01
		iface: 'a'
		frame: transport.CanFrame{
			id:       0x100
			extended: true
			data:     [u8(1), 2, 3, 4]
		}
	}
	kept, rep := without_senders([std, ext], db, ['VCM_C'], true)
	assert rep.withheld_excluded == 1, 'exactly the extended one belongs to the SUT'
	assert kept.len == 1
	assert !kept[0].frame.extended, 'the standard frame is EBS traffic and must survive'
	assert rep.unknown == 0, 'both ids are defined; neither should read as unknown'
}
