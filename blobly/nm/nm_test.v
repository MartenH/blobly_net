module nm

fn cfg_declaring() Config {
	return Config{
		lo:         0x500
		hi:         0x53F
		timeout_ms: 300
		source:     .system
		declared:   [Declared{
			name: 'sysnode'
			nid:  0x11
			id:   0x511
		}, Declared{
			name: 'domain'
			nid:  0x13
			id:   0x513
		}, Declared{
			name: 'zone_a'
			nid:  0x15
			id:   0x515
		}]
	}
}

fn frame(nid u8, cbv u8) []u8 {
	return [nid, cbv, u8(0), 0, 0, 0, 0, 0]
}

fn test_parse_reads_nid_cbv_and_the_pn_mask_only_when_said() {
	p := parse([u8(0x12), 0x48, 0x05, 0, 0, 0, 0, 0x80]) or { panic(err) }
	assert p.nid == 0x12
	assert p.ready_to_sleep()
	assert p.has_pn
	assert p.pn == u64(0x05) | (u64(0x80) << 40)
	plain := parse([u8(0x12), 0x08, 0xFF, 0xFF]) or { panic(err) }
	assert !plain.has_pn
	assert plain.pn == 0, 'bytes 2..7 are not a mask without PN info'
	short := parse([u8(0x13), 0x00]) or { panic(err) }
	assert short.phase() == .requesting
	// a mask of fewer bytes reads what is there
	part := parse([u8(1), 0x40, 0x01, 0x02]) or { panic(err) }
	assert part.pn == 0x0201
}

fn test_parse_refuses_what_cannot_be_read() {
	if _ := parse([u8(0x12)]) {
		assert false, 'one byte has no control bit vector'
	} else {
		assert err.msg().contains('need 2')
	}
	if _ := parse([]u8{}) {
		assert false
	}
	if _ := parse([u8(0x12), 0x40]) {
		assert false, 'PN info with no mask byte'
	} else {
		assert err.msg().contains('no mask byte')
	}
}

fn test_bit_words() {
	assert bit_words(0x00) == ['wants network']
	assert bit_words(0x08) == ['ready to sleep']
	assert bit_words(0x11) == ['wants network', 'active wake-up', 'repeat request']
}

fn test_frames_outside_the_range_or_kind_are_not_taken() {
	mut t := new_tracker(cfg_declaring())
	assert !t.note(0x4FF, false, frame(0x11, 0), 0)
	assert !t.note(0x540, false, frame(0x11, 0), 0)
	assert !t.note(0x511, true, frame(0x11, 0), 0), 'an extended 0x511 is another frame'
	assert t.nodes.len == 0
	assert t.note(0x511, false, frame(0x11, 0), 0)
	assert t.nodes.len == 1
}

fn test_a_malformed_frame_in_range_is_counted_not_a_node() {
	mut t := new_tracker(cfg_declaring())
	assert t.note(0x511, false, [u8(0x11)], 10)
	assert t.malformed == 1
	assert t.last_error.contains('0x511')
	assert t.nodes.len == 0
	assert t.state(10) == .asleep
}

fn test_bus_state_awake_releasing_asleep() {
	mut t := new_tracker(cfg_declaring())
	assert t.state(0) == .asleep, 'nothing heard yet'
	t.note(0x511, false, frame(0x11, cbv_active_wakeup | cbv_repeat_request), 1000)
	t.note(0x513, false, frame(0x13, 0), 1050)
	assert t.state(1100) == .awake
	assert t.keepers(1100).map(t.name_of(it)) == ['sysnode', 'domain']
	assert t.with_bit(1100, cbv_active_wakeup).map(t.name_of(it)) == ['sysnode']
	assert t.with_bit(1100, cbv_repeat_request).map(t.name_of(it)) == ['sysnode']
	w := t.woke or { panic('no wake') }
	assert t.name_of(w.node) == 'sysnode'
	assert w.active
	// sysnode releases; domain still asks
	t.note(0x511, false, frame(0x11, cbv_ready_to_sleep), 1100)
	assert t.state(1150) == .awake
	assert t.keepers(1150).map(t.name_of(it)) == ['domain']
	// domain releases too: every node heard is ready to sleep
	t.note(0x513, false, frame(0x13, cbv_ready_to_sleep), 1150)
	assert t.state(1200) == .releasing
	assert t.keepers(1200).len == 0
	// a node silent past the timeout no longer counts, either way
	assert t.state(1150 + 300) == .releasing, 'at the timeout it still counts'
	assert t.state(1150 + 301) == .asleep
}

fn test_a_silent_requester_stops_keeping_the_bus_awake() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, 0), 0)
	assert t.state(310) == .asleep
	t.note(0x513, false, frame(0x13, cbv_ready_to_sleep), 500)
	assert t.state(600) == .releasing, 'sysnode timed out; domain is heard and released'
	assert t.keepers(600).len == 0
}

fn test_a_frame_after_a_silence_is_the_wake() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x513, false, frame(0x13, 0), 0)
	t.note(0x511, false, frame(0x11, 0), 100)
	assert t.woke == none, 'listening began on an awake bus: nobody was seen waking it'
	t.note(0x513, false, frame(0x13, 0), 1000)
	w1 := t.woke or { panic('') }
	assert t.name_of(w1.node) == 'domain', 'the frame after a silence woke it'
	assert !w1.active
	t.note(0x511, false, frame(0x11, cbv_active_wakeup), 5000)
	w2 := t.woke or { panic('') }
	assert t.name_of(w2.node) == 'sysnode'
	assert w2.t_ms == 5000
	assert w2.active
}

fn test_cadence_counts_intervals_within_the_timeout_only() {
	mut t := new_tracker(cfg_declaring())
	for k in 0 .. 5 {
		t.note(0x511, false, frame(0x11, 0), f64(k) * 100)
	}
	n := t.nodes[0]
	assert n.count == 5
	assert n.mean_ms() == 100
	assert n.last_iv_ms == 100
	// a sleep between two frames is not the node's cycle
	t.note(0x511, false, frame(0x11, 0), 10_000)
	assert t.nodes[0].mean_ms() == 100
	assert t.nodes[0].last_iv_ms == 9600
	assert t.nodes[0].first_ms == 0
	assert t.nodes[0].last_ms == 10_000
}

fn test_pn_request_is_kept_per_node_and_cleared_by_a_frame_without_it() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, [u8(0x11), 0x40, 0x05, 0, 0, 0, 0, 0], 0)
	assert t.nodes[0].has_pn
	assert t.nodes[0].pn == 5
	t.note(0x511, false, frame(0x11, 0), 100)
	assert !t.nodes[0].has_pn
	assert t.nodes[0].pn == 0
}

fn test_missing_and_unknown() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, 0), 0)
	t.note(0x522, false, frame(0x22, 0), 0) // nothing declares NID 0x22
	assert t.missing().map(t.cfg.declared[it].name) == ['domain', 'zone_a']
	assert !t.unknown(0)
	assert t.unknown(1)
	assert t.name_of(1) == 'NID 0x22'
	v := t.view(10, 4)
	assert v.rows.len == 4
	assert v.rows[1].unknown
	assert v.rows[2].missing && v.rows[2].name == 'domain' && v.rows[2].id == 0x513
	assert v.rows[3].missing && v.rows[3].timeline == [Phase.silent, .silent, .silent, .silent]
	// a configuration that declares nobody makes nobody unknown
	mut own := new_tracker(Config{
		lo:     0x500
		hi:     0x53F
		source: .project
	})
	own.note(0x522, false, frame(0x22, 0), 0)
	assert !own.unknown(0)
	assert own.missing().len == 0
}

fn test_a_declaration_matches_by_nid_and_id_both() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, 0), 0)
	t.note(0x520, false, frame(0x11, 0), 0) // sysnode's NID on another id
	t.note(0x513, false, frame(0x14, 0), 0) // domain's id with another NID
	assert t.name_of(0) == 'sysnode'
	assert t.unknown(1) && t.name_of(1) == 'NID 0x11'
	assert t.unknown(2)
	assert t.missing().map(t.cfg.declared[it].name) == ['domain', 'zone_a']
}

fn test_a_declaration_without_a_nid_matches_by_id() {
	mut t := new_tracker(Config{
		lo:       0x600
		hi:       0x610
		source:   .arxml
		declared: [Declared{
			name: 'ECU_A'
			id:   0x601
		}]
	})
	t.note(0x601, false, frame(0x01, 0), 0)
	t.note(0x602, false, frame(0x01, 0), 0) // the same NID on another id is another reporter
	assert t.nodes.len == 2
	assert t.name_of(0) == 'ECU_A'
	assert t.unknown(1)
}

fn test_timeline_phases_and_bounds() {
	mut t := new_tracker(cfg_declaring())
	// requesting 0..10 s every 100 ms, ready 10..20 s, then silent
	mut ms := 0.0
	for ms < 10_000 {
		t.note(0x511, false, frame(0x11, 0), ms)
		ms += 100
	}
	for ms < 20_000 {
		t.note(0x511, false, frame(0x11, cbv_ready_to_sleep), ms)
		ms += 100
	}
	assert t.nodes[0].segs.len == 2
	// at 60 s: columns of 1 s from 0 s; 0..10 green, 10..20 grey (+ the timeout), rest empty
	s := t.strip(0, 60_000, 60)
	assert s.len == 60
	assert s[0] == .requesting && s[9] == .requesting
	assert s[10] == .ready && s[19] == .ready
	assert s[20] == .ready, 'the last frame holds its phase for the timeout'
	assert s[21] == .silent && s[59] == .silent
	// the window moves on: at 70 s the first ten seconds are gone
	s2 := t.strip(0, 70_000, 60)
	assert s2[0] == .ready && s2[9] == .ready
	assert s2[11] == .silent
	// a column touching both phases shows the greater one
	s3 := t.strip(0, 60_000, 3) // 0..20, 20..40, 40..60
	// 0..20 s holds both, and the ready phase's timeout reaches into 20..40
	assert s3 == [Phase.requesting, .ready, .silent]
}

fn test_timeline_segments_are_dropped_past_the_window_and_capped() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, 0), 0)
	t.note(0x511, false, frame(0x11, cbv_ready_to_sleep), 100)
	t.note(0x511, false, frame(0x11, 0), 200_000)
	assert t.nodes[0].segs.len == 1, 'what ended before the window is dropped'
	// a node flipping on every frame is held to the cap
	mut f := new_tracker(cfg_declaring())
	for k in 0 .. max_segments + 100 {
		cbv := if k % 2 == 0 { u8(0) } else { cbv_ready_to_sleep }
		f.note(0x511, false, frame(0x11, cbv), f64(k))
	}
	assert f.nodes[0].segs.len == max_segments
	assert f.nodes[0].segs.last().from_ms == f64(max_segments + 99)
	assert f.nodes[0].segs[0].from_ms == 0, 'the oldest are folded, not dropped'
	assert f.nodes[0].segs[0].phase == .requesting
	assert f.nodes[0].segs[1].from_ms - f.nodes[0].segs[0].last_ms == 1, 'no fabricated silence: the folded history reaches the next segment'
}

fn test_a_silence_shorter_than_the_timeout_continues_a_segment() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, 0), 0)
	t.note(0x511, false, frame(0x11, 0), 250)
	assert t.nodes[0].segs.len == 1
	t.note(0x511, false, frame(0x11, 0), 600) // 350 ms: past the 300 ms timeout
	assert t.nodes[0].segs.len == 2
}

fn test_reporters_are_bounded() {
	mut t := new_tracker(Config{
		lo: 0x500
		hi: 0x5FF
	})
	for k in 0 .. max_nodes + 3 {
		t.note(u32(0x500 + k % 256), false, frame(u8(k / 256 + 1), 0), 0)
	}
	assert t.nodes.len == max_nodes
	assert t.dropped == 3
}

fn test_view_header() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, cbv_active_wakeup), 0)
	t.note(0x513, false, frame(0x13, cbv_repeat_request), 50)
	v := t.view(250, 10)
	assert v.state == .awake
	assert v.keepers == ['sysnode', 'domain']
	assert v.woke == 'sysnode' && v.woke_active && v.woke_ago == 250
	assert v.repeaters == ['domain']
	assert v.heard && v.last_ago == 200
	assert !v.rows[0].stale
	late := t.view(320, 10)
	assert late.rows[0].stale, 'sysnode is past the timeout'
	assert !late.rows[1].stale
	assert late.keepers == ['domain']
}

fn test_an_older_frame_does_not_rewind_a_node() {
	mut t := new_tracker(cfg_declaring())
	t.note(0x511, false, frame(0x11, cbv_ready_to_sleep), 1000)
	t.note(0x511, false, frame(0x11, 0), 500)
	n := t.nodes[0]
	assert n.count == 2
	assert n.last_ms == 1000
	assert n.ready_to_sleep(), "the newer frame's state stands"
	assert n.segs.len == 1 && n.segs[0].last_ms == 1000
	assert t.state(1100) == .releasing
}

fn test_a_29_bit_reporter_is_its_own_node() {
	mut t := new_tracker(Config{
		lo:       0x500
		hi:       0x53F
		ext:      true
		declared: [Declared{
			name: 'X'
			nid:  0x11
			id:   0x511
			ext:  true
		}]
	})
	t.note(0x511, true, frame(0x11, 0), 0)
	assert t.nodes[0].ext && t.name_of(0) == 'X'
	assert !t.note(0x511, false, frame(0x11, 0), 0)
}
