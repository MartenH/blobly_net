module mf4

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
