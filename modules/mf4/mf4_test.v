module mf4

import os

// Hermetic test against the committed samples/demo.mf4 (a python-can MF4Writer
// file: master named 'time' as float64 seconds, DataBytes as a fixed inline
// array). 60 frames: 30×0x100 (8-byte powertrain) + 30×0x700 (1-byte heartbeat),
// interleaved. Validated against the asammdf oracle (sut/mf4_bridge.py).
const demo_path = @VMODROOT + '/samples/demo.mf4'

fn test_loads_demo_frame_count() {
	entries := load_file(demo_path) or {
		assert false, 'load_file failed: ${err}'
		return
	}
	assert entries.len == 60
	mut ids := map[u32]int{}
	for e in entries {
		ids[e.frame.id]++
	}
	assert ids.len == 2
	assert ids[0x100] == 30
	assert ids[0x700] == 30
}

fn test_first_frames_decode() {
	entries := load_file(demo_path) or {
		assert false, '${err}'
		return
	}
	// Sorted by time; the first two frames are 0x100 (8 bytes) then 0x700 (1 byte).
	first := entries[0]
	assert first.frame.id == 0x100
	assert first.frame.data.len == 8
	assert !first.frame.extended
	second := entries[1]
	assert second.frame.id == 0x700
	assert second.frame.data.len == 1
}

fn test_timestamps_monotonic_and_spaced() {
	entries := load_file(demo_path) or {
		assert false, '${err}'
		return
	}
	// Times are sorted ascending; the recording spans ~2.9s (30 cycles @ 100ms).
	mut prev := entries[0].t_s
	for e in entries {
		assert e.t_s >= prev - 1e-9
		prev = e.t_s
	}
	span := entries[entries.len - 1].t_s - entries[0].t_s
	assert span > 2.5 && span < 3.5, 'span was ${span}'
}

fn test_rejects_non_mdf() {
	parse([u8(1), 2, 3, 4]) or {
		assert err.msg().contains('MDF')
		return
	}
	assert false, 'expected an error for non-MDF input'
}

// Real-data regression vs the asammdf-validated ground truth (2026-06-04):
// the CSS Electronics J1939 driving log is UNFINALIZED ("UnFinMF "), UNSORTED
// (CAN_DataFrame + error/remote CGs interleaved with record ids) and
// bit-packed, with DataBytes in a VLSD channel GROUP. asammdf extracted
// 145534 frames with EngineSpeed 913-1761 rpm x19584 — we must match.
// Skipped when the (git-ignored) sample isn't fetched; get it with
// scripts/setup_mf4_tools.sh.
fn test_unfinalized_unsorted_canedge() {
	path := @VMODROOT + '/samples/driving.mf4'
	if !os.exists(path) {
		println('skip: ${path} not present (run scripts/setup_mf4_tools.sh)')
		return
	}
	entries := load_file(path) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 145534
	mut prev := entries[0].t_s
	mut all_ext := true
	for e in entries {
		assert e.t_s >= prev - 1e-9
		prev = e.t_s
		all_ext = all_ext && e.frame.extended
	}
	assert all_ext // J1939: every frame uses a 29-bit id
}

// samples/two_buses.mf4 (python-can MF4Writer): ONE CAN_DataFrame group whose records carry a
// BusChannel column of 0 and 2 — the common real shape, and the one that used to collapse. Every
// frame was labelled 'can', so 0x100 from one bus and 0x100 from the other became a single
// interleaved stream, and a single row in the grouped view whose count added two different
// messages together.
const two_bus_path = @VMODROOT + '/samples/two_buses.mf4'

fn test_two_buses_stay_two_buses() {
	entries := load_file(two_bus_path) or {
		assert false, 'load_file failed: ${err}'
		return
	}
	assert entries.len == 12
	mut per_iface := map[string]int{}
	for e in entries {
		per_iface[e.iface]++
	}
	assert per_iface.len == 2, 'the buses were merged: ${per_iface}'
	// `mf4:` because a recording's bus numbers are NOT this project's interface names: a bare
	// `can1` would match a project channel called can1 and silently adopt its protection rules.
	assert per_iface['mf4:bus0'] == 6
	assert per_iface['mf4:bus2'] == 6
}

// The payloads must travel with the right bus, not merely be counted separately.
fn test_each_bus_keeps_its_own_frames() {
	entries := load_file(two_bus_path) or {
		assert false, '${err}'
		return
	}
	for e in entries {
		assert e.frame.id == 0x100
		match e.iface {
			'mf4:bus0' { assert e.frame.data[0] == 1, 'a bus2 frame was filed under bus0' }
			'mf4:bus2' { assert e.frame.data[0] == 2, 'a bus0 frame was filed under bus2' }
			else { assert false, 'unexpected bus ${e.iface}' }
		}
	}
}

// A single-bus recording keeps ONE label — the demo file has no BusChannel variation, and the
// fix must not split a file that was never split.
fn test_a_single_bus_file_stays_one_bus() {
	entries := load_file(demo_path) or {
		assert false, '${err}'
		return
	}
	mut ifaces := map[string]bool{}
	for e in entries {
		ifaces[e.iface] = true
	}
	assert ifaces.len == 1, 'one bus became several: ${ifaces.keys()}'
}

// A recorded BusChannel and this decoder's fallback ordinal are different things, so they must
// not share a name: a BusChannel-less group #1 and another group's BusChannel 1 would otherwise
// merge again — the same collapse, one level down.
fn test_a_recorded_bus_and_a_fallback_ordinal_cannot_collide() {
	assert bus_iface(1, 0) != bus_iface(-1, 1)
	assert bus_iface(1, 0) == 'mf4:bus1'
	assert bus_iface(-1, 1) == 'mf4:group1'
	// the FIRST fallback group is group0, not a special case: a documented naming rule with an
	// exception at index 0 is a rule people get wrong in searches and tooling
	assert bus_iface(-1, 0) == 'mf4:group0'
}

// And neither can be mistaken for a project interface.
fn test_an_imported_label_is_not_a_project_interface() {
	for label in [bus_iface(0, 0), bus_iface(3, 0), bus_iface(-1, 0), bus_iface(-1, 2)] {
		assert label.starts_with('mf4:'), '${label} could match a project channel by that name'
	}
}

// A record may declare a channel INVALID in its invalidation area, and the raw bits are then
// undefined. Reading them anyway invents a bus number — which either merges those frames into a
// genuine mf4:busN stream or conjures a bus the recording never had.
fn test_an_invalidated_field_is_not_read() {
	c := Chan{
		flags:     0x02 // has an invalidation bit
		inval_bit: 3
	}
	// record layout: 4 data bytes then 1 invalidation byte; bit 3 set = invalid
	raw := [u8(0), 0, 0, 0, 0b0000_1000]
	assert chan_invalid(raw, 0, 4, 1, c)
	clear := [u8(0), 0, 0, 0, 0b0000_0000]
	assert !chan_invalid(clear, 0, 4, 1, c)
}

fn test_a_channel_without_an_invalidation_bit_is_always_valid() {
	c := Chan{
		flags:     0 // the bit is not in use
		inval_bit: 3
	}
	raw := [u8(0), 0, 0, 0, 0b0000_1000] // set, but it does not belong to this channel
	assert !chan_invalid(raw, 0, 4, 1, c)
}

// A malformed file must not take the frame with it: out-of-range means "cannot tell", and the
// value is used, not the record dropped.
fn test_an_out_of_range_invalidation_bit_reads_as_valid() {
	c := Chan{
		flags:     0x02
		inval_bit: 999
	}
	assert !chan_invalid([u8(0), 0, 0, 0, 0], 0, 4, 1, c)
}

// CN flag bit 0 says every sample of the channel is invalid, whatever the per-record bits hold.
// Missing it merged those frames into an unrelated bus, or invented one.
fn test_a_channel_wide_invalid_flag_wins() {
	c := Chan{
		flags: 0x01 // all values invalid
	}
	assert chan_invalid([u8(0), 0, 0, 0, 0], 0, 4, 1, c)
	// and it wins even where a per-record bit exists and is clear
	both := Chan{
		flags:     0x03
		inval_bit: 3
	}
	assert chan_invalid([u8(0), 0, 0, 0, 0b0000_0000], 0, 4, 1, both)
}
