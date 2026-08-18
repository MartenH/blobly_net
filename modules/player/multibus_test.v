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
		nodes:    [sender, 'VCM_C']
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

// Two recorded buses, interleaved in time, each with one VCM_C message to subtract.
fn mb_sample() []canlog.LogEntry {
	return [
		mb_entry('mf4:group1', 0x100, 0.00), // bus A, EBS
		mb_entry('mf4:group2', 0x200, 0.01), // bus B, TCM
		mb_entry('mf4:group1', 0x101, 0.02), // bus A, VCM_C
		mb_entry('mf4:group2', 0x201, 0.03), // bus B, VCM_C
		mb_entry('mf4:group1', 0x100, 0.04),
		mb_entry('mf4:group3', 0x300, 0.05), // a bus nobody mapped
	]
}

fn mb_specs() []BusSpec {
	mut a := mb_db('EBS', [u32(0x100)])
	a.messages << candb.Message{
		name:   'VcmA'
		id:     0x101
		sender: 'VCM_C'
	}
	mut b := mb_db('TCM', [u32(0x200)])
	b.messages << candb.Message{
		name:   'VcmB'
		id:     0x201
		sender: 'VCM_C'
	}
	return [
		BusSpec{
			src:     'mf4:group1'
			dst:     'vcan0'
			db:      a
			exclude: ['VCM_C']
		},
		BusSpec{
			src:     'mf4:group2'
			dst:     'vcan1'
			db:      b
			exclude: ['VCM_C']
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
		assert e.frame.id != 0x101, 'VCM_C survived on bus A'
		assert e.frame.id != 0x201, 'VCM_C survived on bus B'
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
	specs := [BusSpec{
		src: 'mf4:nosuch'
		dst: 'vcan9'
		db:  mb_db('EBS', [u32(0x100)])
	}]
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
