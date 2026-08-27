module player

import canlog
import candb
import transport

// A small stand-in for a vehicle bus: two nodes that send, one message nobody is credited with,
// and one id the database never heard of. Every case the subtraction has to distinguish, in a
// database small enough to reason about by hand.
fn sample_db() candb.Database {
	return candb.Database{
		nodes:    ['SUT_ECU', 'EBS']
		messages: [
			candb.Message{
				name:   'VcmStatus'
				id:     0x100
				sender: 'SUT_ECU'
			},
			candb.Message{
				name:   'VcmSpeed'
				id:     0x101
				sender: 'SUT_ECU'
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
		entry('mf4:group25', 0x100, 0.00), // SUT_ECU
		entry('mf4:group25', 0x200, 0.01), // EBS
		entry('mf4:group25', 0x300, 0.02), // unattributed
		entry('mf4:group25', 0x999, 0.03), // not in the database at all
		entry('mf4:group25', 0x101, 0.04), // SUT_ECU
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
	kept, rep := without_senders(src, sample_db(), ['SUT_ECU'], true)
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
	kept, rep := without_senders(src, sample_db(), ['SUT_ECU'], true)
	assert kept.filter(it.frame.id == 0x999).len == 1
	assert rep.unknown == 1
	assert rep.unknown_ids == ['0x999']
}

// The messages a database defines but does not attribute. There is no safe default, so the
// caller picks and BOTH answers must actually work.
fn test_unattributed_messages_follow_the_callers_choice() {
	src := on_bus(sample(), 'mf4:group25')
	with, rep_with := without_senders(src, sample_db(), ['SUT_ECU'], true)
	assert with.filter(it.frame.id == 0x300).len == 1
	assert rep_with.unattributed == 1
	assert rep_with.unattributed_ids == ['0x300']

	without, rep_without := without_senders(src, sample_db(), ['SUT_ECU'], false)
	assert without.filter(it.frame.id == 0x300).len == 0
	assert rep_without.unattributed == 1, 'still reported when withheld — the count is the point'
	// the two reasons stay apart: 2 frames are the SUT's, 1 is the unattributed policy
	assert rep_without.withheld_excluded == 2
	assert rep_without.withheld_unattributed == 1
}

// A misspelled node subtracts NOTHING, and the result looks exactly like a working rest bus
// until the SUT starts losing arbitration against a recording of itself.
fn test_an_unknown_node_name_is_caught() {
	assert check_nodes(sample_db(), ['SUT_ECU']) == []
	assert check_nodes(sample_db(), ['VCM']) == ['VCM'], 'a typo must not pass silently'
	assert check_nodes(sample_db(), ['SUT_ECU', 'EBS']) == []
	assert check_nodes(sample_db(), ['SUT_ECU', 'nope']) == ['nope']
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
		nodes:    ['SUT_ECU', 'EBS']
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
				sender: 'SUT_ECU'
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
	kept, rep := without_senders([std, ext], db, ['SUT_ECU'], true)
	assert rep.withheld_excluded == 1, 'exactly the extended one belongs to the SUT'
	assert kept.len == 1
	assert !kept[0].frame.extended, 'the standard frame is EBS traffic and must survive'
	assert rep.unknown == 0, 'both ids are defined; neither should read as unknown'
}

// A DBC may declare EXTRA transmitters with BO_TX_BU_. If the SUT is one of them, matching only
// the BO_ transmitter leaves its frames in the replay and sends them back at it — the exact
// failure this module exists to prevent, arrived at through the half of the database nobody
// reads.
fn test_an_additional_transmitter_still_counts_as_the_sender() {
	db := candb.Database{
		nodes:    ['SUT_ECU', 'EBS']
		messages: [
			candb.Message{
				name:     'SharedMsg'
				id:       0x400
				sender:   'EBS'       // the BO_ line names EBS...
				tx_nodes: ['SUT_ECU'] // ...and BO_TX_BU_ adds the SUT
			},
		]
	}
	kept, rep := without_senders([entry('a', 0x400, 0.0)], db, ['SUT_ECU'], true)
	assert rep.withheld_excluded == 1, 'the SUT transmits this too, so it must be withheld'
	assert kept.len == 0
}

// Filtering must not change the recording's cadence. Drop the first and last surviving frames
// and a loop built on the leftovers plays a SHORTER recording, starts immediately, and drifts
// against every other bus replayed alongside it.
fn test_a_filtered_loop_keeps_the_sources_span() {
	// source spans 0..10 s; only 1 s and 9 s survive the subtraction
	kept := [entry('a', 1, 1.0), entry('a', 2, 9.0)]
	mut p := player_over(kept, 0.0, 10.0)
	p.play(0.0)
	assert p.duration_s() == 10.0, 'the loop is the source span, got ${p.duration_s()}'
	// the first surviving frame is due 1 s in, NOT immediately
	assert p.due(0.0).len == 0, 'a frame at t=1s must not fire at t=0'
	assert p.due(1000.0).len == 1
	// and without the span it would wrongly be an 8 s loop starting at once
	mut q := new_player(kept, 1.0, true)
	q.play(0.0)
	assert q.duration_s() == 8.0
	assert q.due(0.0).len == 1
}

fn player_over(entries []canlog.LogEntry, t0 f64, end f64) Player {
	return new_player_over(entries, 1.0, true, t0, end)
}

// The order restored in mf4's demux and in build_multi has to survive the LAST step. new_player
// sorts defensively by timestamp with no tie-break, so constructing the player through it would
// discard the cross-bus sequence of equal-timestamp frames immediately before transmission —
// undoing both earlier fixes at the point where it stops being observable.
fn test_new_player_over_does_not_reorder_the_plan() {
	// three frames at the SAME timestamp, in an order a timestamp sort cannot reconstruct
	plan := [entry('b', 2, 1.0), entry('a', 1, 1.0), entry('c', 3, 1.0)]
	mut p := new_player_over(plan, 1.0, false, 0.0, 2.0)
	p.play(0.0)
	due := p.due(2000.0)
	assert due.len == 3
	assert due[0].iface == 'b' && due[0].frame.id == 2, 'plan order lost at the player'
	assert due[1].iface == 'a' && due[1].frame.id == 1
	assert due[2].iface == 'c' && due[2].frame.id == 3
}

fn db_with_node(node string) candb.Database {
	return candb.Database{
		nodes:    [node]
		messages: []
	}
}

// The gateway case the GUI used to refuse: the SUT transmits on ONE of the mapped buses. That
// is the ordinary shape of a multi-bus recording, not a mistake.
fn test_node_declared_by_one_database_is_not_unknown() {
	dbs := [db_with_node('SUT_ECU'), db_with_node('OTHER')]
	assert unknown_everywhere(dbs, ['SUT_ECU']) == []
}

// Declared by NONE of them is the typo worth refusing -- it subtracts nothing anywhere.
fn test_node_declared_nowhere_is_reported() {
	dbs := [db_with_node('A'), db_with_node('B')]
	assert unknown_everywhere(dbs, ['SUT_ECU']) == ['SUT_ECU']
}

// A name repeated on the command line is one name, reported once.
fn test_repeated_exclusion_is_judged_once() {
	dbs := [db_with_node('A')]
	assert unknown_everywhere(dbs, ['GHOST', 'GHOST']) == ['GHOST']
}

// With no databases at all there is nothing to contradict; the caller's own checks apply.
fn test_no_databases_reports_nothing() {
	assert unknown_everywhere([]candb.Database{}, ['ANY']) == []
}

fn test_census_counts_by_attribution() {
	c := census(on_bus(sample(), 'mf4:group25'), sample_db())
	assert c.total == 5
	assert c.nodes['SUT_ECU'] == 2
	assert c.nodes['EBS'] == 1
	assert c.unattributed == 1
	assert c.unknown == 1
	// a frame with several declared senders counts for each — exclusion is per node, and
	// excluding either node withholds this frame
	mut db := sample_db()
	db.messages << candb.Message{
		name:     'Shared'
		id:       0x400
		sender:   'SUT_ECU'
		tx_nodes: ['EBS']
	}
	c2 := census([entry('b', 0x400, 0.0)], db)
	assert c2.nodes['SUT_ECU'] == 1
	assert c2.nodes['EBS'] == 1
	// an 11-bit and a 29-bit 0x100 are different messages — the census may not conflate them
	xe := canlog.LogEntry{
		iface: 'b'
		frame: transport.CanFrame{
			id:       0x100
			extended: true
		}
	}
	cx := census([xe], sample_db())
	assert cx.unknown == 1
	assert cx.nodes.len == 0
}

// AN ID IS NOT AN IDENTITY WITHOUT ITS WIDTH. An 11-bit 0x100 and a 29-bit 0x100 are two different
// messages with two different senders — `key()` exists because conflating them is silent
// corruption — and the tallies were keyed on the number alone, so two requests on two messages
// were reported as two frames on ONE id, printed in a form that could not say which (codex round 2
// on #210). The same defect was in the unattributed and unknown tallies; all three are keyed by
// identity now.
fn test_two_widths_of_one_number_are_two_ids_in_the_report() {
	// An id the database does not define, at BOTH widths. They are two different messages that
	// may have two different senders — which is why `key()` exists — so a report that folded them
	// into one entry would claim one id where two were involved, and print something that cannot
	// say which.
	d := new_decider(sample_db(), ['SUT_ECU'], true)
	mut t := Tally{}
	std := transport.CanFrame{
		id: 0x999
	}
	ext := transport.CanFrame{
		id:       0x999
		extended: true
	}
	t.add(d.verdict(std), std)
	t.add(d.verdict(ext), ext)
	rep := t.done(2)

	assert rep.unknown == 2, 'two frames'
	assert rep.unknown_ids.len == 2, 'and two distinct messages, not one counted twice'
	assert rep.unknown_ids == ['0x999', '0x00000999'], 'got ${rep.unknown_ids}'
}

// The width shows in the label the way a trace prints it: three hex digits standard, eight
// extended. A report that printed both as `0x100` could not be acted on.
fn test_an_id_label_carries_its_width() {
	assert id_label(0x100, false) == '0x100'
	assert id_label(0x100, true) == '0x00000100'
	assert id_label(0x7FF, false) == '0x7FF'
	assert id_label(0x1FFFFFFF, true) == '0x1FFFFFFF'
}

// Sorted by the identity, not by the text: 0x090 must come before 0x100, which a lexicographic
// sort of the labels would also give, but 0x00000100 sorting before 0x090 would be wrong.
fn test_ids_are_sorted_by_identity_not_by_text() {
	mut t := Tally{}
	for id in [u32(0x100), 0x090, 0x7FF] {
		f := transport.CanFrame{
			id: id
		}
		t.add(Verdict.keep_unknown, f)
	}
	rep := t.done(3)
	assert rep.unknown_ids == ['0x090', '0x100', '0x7FF'], 'got ${rep.unknown_ids}'
}

// A REMOTE FRAME IS REFUSED BEFORE THE DATABASE IS CONSULTED. Whether the DBC defines the id has
// no bearing on it — the frame cannot be transmitted either way — so a verdict of `keep_` for one
// hands the replay a frame `send()` will refuse. Placed after the `defined` lookup it caught only
// the ids a database happened to name, and with NO DBC attached `defined` is empty, so every
// remote frame in a recording was kept and failed at the wire: a run reporting "not replayed" and
// then counting failures for the same frames (self-review of #215).
fn test_a_remote_frame_on_an_unknown_id_is_still_not_replayed() {
	d := new_decider(sample_db(), ['SUT_ECU'], true)
	v := d.verdict(transport.CanFrame{ id: 0x7AB, rtr: true })
	assert v == .drop_remote, 'got ${v}'
}

// The case that matters most, because it is the default one: a replay with no database at all.
fn test_with_no_database_every_remote_frame_is_still_refused() {
	d := new_decider(candb.Database{}, [], true)
	for f in [transport.CanFrame{ id: 0x100, rtr: true }, transport.CanFrame{
		id:       0x1FFFFFFF
		extended: true
		rtr:      true
	}] {
		v := d.verdict(f)
		assert v == .drop_remote, 'id 0x${f.id:X}: got ${v}'
	}
	// And an ordinary frame is still kept, so this did not simply refuse everything.
	assert d.verdict(transport.CanFrame{ id: 0x100, data: [u8(1)] }) == .keep_unknown
}

// THE PREVIEW MUST AGREE WITH WHAT START DOES. `census` is what the editor shows while somebody
// decides what to exclude, and it classified in a different ORDER from `verdict`: asking `defined`
// first put a remote frame on an undefined id into `unknown`, which the editor labels "replays
// regardless", while the replay drops every remote frame before it looks at the database. With no
// DBC attached -- where `defined` is empty -- the preview said the opposite of the truth for every
// remote frame in the recording (codex on #216).
fn test_the_census_agrees_with_the_verdict_about_remote_frames() {
	d := new_decider(sample_db(), [], true)
	for f in [transport.CanFrame{ id: 0x100, rtr: true }, transport.CanFrame{ id: 0x7AB, rtr: true }] {
		entries := [canlog.LogEntry{
			t_s:   0.0
			iface: 'can0'
			frame: f
		}]
		c := census(entries, sample_db())
		assert c.remote == 1, 'id 0x${f.id:X}: the preview must call it a remote request'
		assert c.unknown == 0, 'id 0x${f.id:X}: and not something that replays regardless'
		assert d.verdict(f) == .drop_remote, 'and the replay agrees'
	}
}

// With no database at all, which is the default and the case that was wrong for every frame
// rather than some of them.
fn test_the_census_classifies_remote_frames_with_no_database() {
	entries := [
		canlog.LogEntry{
			t_s:   0.0
			iface: 'can0'
			frame: transport.CanFrame{
				id:  0x100
				rtr: true
			}
		},
		canlog.LogEntry{
			t_s:   0.1
			iface: 'can0'
			frame: transport.CanFrame{
				id:   0x100
				data: [u8(1)]
			}
		},
	]
	c := census(entries, candb.Database{})
	assert c.remote == 1, 'the request'
	assert c.unknown == 1, 'and the ordinary frame, which really is on an unknown id'
	assert c.total == 2
}
