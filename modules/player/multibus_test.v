module player

import canlog
import candb
import transport

fn mb_db(sender string, ids []u32) candb.Database {
	mut msgs := []candb.Message{}
	for i, id in ids {
		msgs << candb.Message{
			name:   'M${i}'
			id:     id
			sender: sender
		}
	}
	return candb.Database{
		nodes:    [sender, 'SUT_ECU']
		messages: msgs
	}
}

fn mb_entry(iface string, id u32, t f64) canlog.LogEntry {
	return canlog.LogEntry{
		t_s:   t
		iface: iface
		frame: transport.CanFrame{
			id:   id
			data: [u8(1)]
		}
	}
}

// Two recorded buses, interleaved in time, each with one SUT_ECU message to subtract.
fn mb_sample() []canlog.LogEntry {
	return [
		mb_entry('mf4:group1', 0x100, 0.00), // bus A, EBS
		mb_entry('mf4:group2', 0x200, 0.01), // bus B, TCM
		mb_entry('mf4:group1', 0x101, 0.02), // bus A, SUT_ECU
		mb_entry('mf4:group2', 0x201, 0.03), // bus B, SUT_ECU
		mb_entry('mf4:group1', 0x100, 0.04),
		mb_entry('mf4:group3', 0x300, 0.05), // a bus nobody mapped
	]
}

fn mb_specs() []BusSpec {
	mut a := mb_db('EBS', [u32(0x100)])
	a.messages << candb.Message{
		name:   'VcmA'
		id:     0x101
		sender: 'SUT_ECU'
	}
	mut b := mb_db('TCM', [u32(0x200)])
	b.messages << candb.Message{
		name:   'VcmB'
		id:     0x201
		sender: 'SUT_ECU'
	}
	return [
		BusSpec{
			src:     'mf4:group1'
			dst:     'vcan0'
			db:      a
			exclude: ['SUT_ECU']
		},
		BusSpec{
			src:     'mf4:group2'
			dst:     'vcan1'
			db:      b
			exclude: ['SUT_ECU']
		},
	]
}

// ONE stream, in recorded order, with every frame relabelled to where it must go. If the buses
// were replayed by separate players the interleaving below would be whatever the scheduler chose.
fn test_buses_merge_into_one_time_ordered_stream() {
	p := build_multi(mb_sample(), mb_specs())
	assert p.entries.len == 3, 'got ${p.entries.len}'
	mut prev := -1.0
	for e in p.entries {
		assert e.t_s >= prev, 'stream is not time-ordered'
		prev = e.t_s
	}
	assert p.entries[0].iface == 'vcan0' && p.entries[0].t_s == 0.00
	assert p.entries[1].iface == 'vcan1' && p.entries[1].t_s == 0.01
	assert p.entries[2].iface == 'vcan0' && p.entries[2].t_s == 0.04
}

// The SUT is subtracted on every mapped bus, not just the first.
fn test_the_sut_is_subtracted_on_every_bus() {
	p := build_multi(mb_sample(), mb_specs())
	for e in p.entries {
		assert e.frame.id != 0x101, 'SUT_ECU survived on bus A'
		assert e.frame.id != 0x201, 'SUT_ECU survived on bus B'
	}
	assert p.buses.len == 2
	for b in p.buses {
		assert b.report.withheld_excluded == 1, '${b.src}: ${b.report.withheld_excluded}'
	}
}

// An unmapped bus contributes nothing — a recording holds buses this bench does not have.
fn test_an_unmapped_bus_is_left_out() {
	p := build_multi(mb_sample(), mb_specs())
	for e in p.entries {
		assert e.frame.id != 0x300, 'a bus nobody mapped reached the wire'
	}
}

// The span is the SOURCE span across every selected bus. Taken from what survived, a loop would
// shorten; taken per bus, several buses in one stream would each want a different origin.
fn test_the_span_covers_every_selected_bus_before_subtraction() {
	p := build_multi(mb_sample(), mb_specs())
	assert p.t0_s == 0.00, 'got ${p.t0_s}'
	assert p.end_s == 0.04, 'got ${p.end_s}' // bus A's last SOURCE frame; group3 is unmapped
}

// Reported per bus, never summed: one bus subtracting to silence while the others look healthy
// is the case a total would hide.
fn test_each_bus_reports_separately() {
	p := build_multi(mb_sample(), mb_specs())
	mut by := map[string]BusPlan{}
	for b in p.buses {
		by[b.src] = b
	}
	a := by['mf4:group1'] or { panic('missing') }
	assert a.dst == 'vcan0'
	assert a.source == 3
	assert a.report.kept == 2
	b := by['mf4:group2'] or { panic('missing') }
	assert b.source == 2
	assert b.report.kept == 1
}

// A bus that is mapped but carries nothing is reported, not silently dropped: on a real capture
// this is how you learn the mapping is wrong.
fn test_a_mapped_bus_with_no_frames_is_still_reported() {
	specs := [
		BusSpec{
			src: 'mf4:nosuch'
			dst: 'vcan9'
			db:  mb_db('EBS', [u32(0x100)])
		},
	]
	p := build_multi(mb_sample(), specs)
	assert p.entries.len == 0
	assert p.buses.len == 1
	assert p.buses[0].source == 0
}

// Two mappings that cannot both be honoured. Either produces a plausible-looking run, which is
// why they are refused rather than warned about.
fn test_conflicting_mappings_are_named() {
	dup_src := [
		BusSpec{
			src: 'mf4:group1'
			dst: 'vcan0'
		},
		BusSpec{
			src: 'mf4:group1'
			dst: 'vcan1'
		},
	]
	assert conflicts(dup_src).len == 1
	assert conflicts(dup_src)[0].contains('sent twice')

	dup_dst := [
		BusSpec{
			src: 'mf4:group1'
			dst: 'vcan0'
		},
		BusSpec{
			src: 'mf4:group2'
			dst: 'vcan0'
		},
	]
	assert conflicts(dup_dst).len == 1
	assert conflicts(dup_dst)[0].contains('collide')

	ok := mb_specs()
	assert conflicts(ok) == []
}

// Frames sharing a timestamp must keep their RECORDED order across buses. Filtering bus by bus
// and sorting the concatenation by timestamp loses it — and simultaneous cross-bus stimuli are
// exactly what a gateway is watching, so their order would be decided by --map order or by the
// sort's tie behaviour instead of by the car.
fn test_simultaneous_cross_bus_frames_keep_their_recorded_order() {
	// B before A in the recording, at the SAME timestamp, while the specs list A first
	src := [
		mb_entry('mf4:group2', 0x200, 1.0),
		mb_entry('mf4:group1', 0x100, 1.0),
		mb_entry('mf4:group2', 0x200, 1.0),
	]
	p := build_multi(src, mb_specs())
	assert p.entries.len == 3
	assert p.entries[0].iface == 'vcan1', 'the bus recorded FIRST must go out first'
	assert p.entries[1].iface == 'vcan0'
	assert p.entries[2].iface == 'vcan1'
}

// Two spellings of one software bus are one destination. transport.canonical_iface exists so an
// identity is not decided by a spelling; comparing raw strings let two recorded buses land on
// the same live bus with the conflict check reporting nothing.
fn test_equivalent_destination_spellings_are_one_destination() {
	c := conflicts([
		BusSpec{
			src: 'mf4:group1'
			dst: 'udp'
		},
		BusSpec{
			src: 'mf4:group2'
			dst: 'udp:239.63.42.1:20000'
		},
	])
	assert c.len == 1, 'equivalent spellings were treated as different buses: ${c}'
	assert c[0].contains('collide')
}

// Per-bus counts must still balance after the single-pass rewrite: recorded = withheld + replay.
fn test_the_per_bus_numbers_balance() {
	p := build_multi(mb_sample(), mb_specs())
	for b in p.buses {
		r := b.report
		// EVERY BUCKET, including remote requests. This assertion holds trivially -- `kept` is
		// computed by subtracting exactly these terms -- so its real job is to go stale loudly
		// when a bucket is added and this line is not told. It did not when the remote bucket
		// arrived, which is how the multi-bus path kept counting withheld frames as replayed
		// (self-review).
		assert b.source == r.kept + r.withheld_excluded + r.withheld_unattributed +
			r.withheld_remote, '${b.src}: ${b.source} != ${r.kept}+${r.withheld_excluded}+${r.withheld_unattributed}+${r.withheld_remote}'
	}
}

// The label is the identity; the acquisition name is free text a writer chose. There were two
// implementations of this rule (GUI and CLI) and they had already drifted, which is why it lives
// here now — deciding which bus a recording means is a fact about the file, not a front end's.
fn test_resolve_bus_prefers_the_label() {
	buses := [
		BusName{
			iface: 'mf4:group1'
			name:  'CAN1'
		},
		BusName{
			iface: 'mf4:group2'
			name:  'mf4:group1' // this bus's NAME collides with the other's LABEL
		},
	]
	labels := ['mf4:group1', 'mf4:group2']
	// the label wins, so the collision cannot divert group1's traffic to group2
	assert resolve_bus(buses, labels, 'mf4:group1')! == 'mf4:group1'
	assert resolve_bus(buses, labels, 'CAN1')! == 'mf4:group1'
}

fn test_resolve_bus_refuses_what_it_cannot_decide() {
	two := [
		BusName{
			iface: 'a'
			name:  'CAN1'
		},
		BusName{
			iface: 'b'
			name:  'CAN1'
		},
	]
	// one name, two buses: refused rather than resolved by picking one
	if _ := resolve_bus(two, ['a', 'b'], 'CAN1') {
		assert false, 'an ambiguous name must not resolve'
	}
	// no name given and several buses present: the caller has to choose
	if _ := resolve_bus(two, ['a', 'b'], '') {
		assert false, 'a multi-bus recording needs a bus named'
	}
	// no name given and exactly one bus: nothing to choose
	assert resolve_bus([BusName{
		iface: 'only'
		name:  ''
	}], ['only'], '')! == 'only'
	// a name nothing carries
	if _ := resolve_bus(two, ['a', 'b'], 'nope') {
		assert false, 'an unknown bus must be refused'
	}
}

// A WITHHELD REMOTE REQUEST MUST LEAVE THE STREAM AND THE COUNT TOGETHER. `kept` is computed on
// this path by subtracting the withheld buckets from the source count, so a bucket the arithmetic
// has not been told about is one whose frames vanish from `entries` and stay in `kept` — the run
// then reports replaying frames it never sent, and a bus silenced entirely by that bucket never
// trips the "all frames withheld" diagnosis (self-review of #179's first commit).
//
// The conservation test above cannot see this on its own: with no remote frame in the sample it
// balances whatever the arithmetic does. This is the case that gives it something to weigh.
fn test_a_withheld_remote_request_leaves_both_the_stream_and_the_kept_count() {
	mut entries := mb_sample()
	// A request for 0x101 — VcmA, which SUT_ECU produces on bus A.
	entries << canlog.LogEntry{
		t_s:   0.06
		iface: 'mf4:group1'
		frame: transport.CanFrame{
			id:  0x101
			rtr: true
		}
	}
	mut specs := mb_specs()
	// Policy says withhold what the DBC cannot attribute, which now includes the request.
	specs[0] = BusSpec{
		...specs[0]
		replay_unattributed: false
	}
	p := build_multi(entries, specs)

	mut a := p.buses[0]
	assert a.report.withheld_remote == 1, 'the request was withheld'
	assert a.report.remote == 1
	assert a.report.remote_ids == ['0x101'], 'and it is reported on the multi-bus path too'
	assert a.source == a.report.kept + a.report.withheld_excluded + a.report.withheld_unattributed +
		a.report.withheld_remote, 'recorded = withheld + replay'
	// And it really is absent from the stream, which is what `kept` claims about it.
	for e in p.entries {
		assert !e.frame.rtr, 'a withheld request must not reach the wire'
	}
}

// The same request with the default policy is replayed, reported, and counted as kept.
fn test_a_replayed_remote_request_is_reported_on_the_multi_bus_path() {
	mut entries := mb_sample()
	entries << canlog.LogEntry{
		t_s:   0.06
		iface: 'mf4:group1'
		frame: transport.CanFrame{
			id:  0x101
			rtr: true
		}
	}
	p := build_multi(entries, mb_specs())
	a := p.buses[0]
	assert a.report.remote == 1
	assert a.report.withheld_remote == 0
	assert p.entries.filter(it.frame.rtr).len == 1, 'stimulus reaches the bench'
}
