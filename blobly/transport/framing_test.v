module transport

// ---- what format a wire carries (#185) --------------------------------------------------------
//
// The table is process-wide, so each test publishes the set it needs rather than adding to one.

fn test_an_undeclared_wire_frames_classic() {
	clear_wire_framing()
	f := framed_for_wire('inproc:CAN1', CanFrame{ id: 0x100, data: []u8{len: 8} })
	assert !f.fd && !f.brs, 'nothing was declared, so nothing is stamped'
}

fn test_a_declared_wire_stamps_what_it_declared() {
	replace_wire_policy([], {'inproc:CAN1': Framing{ fd: true, brs: true }})
	f := framed_for_wire('inproc:CAN1', CanFrame{ id: 0x100, data: []u8{len: 64} })
	assert f.fd && f.brs
	assert f.data.len == 64, 'everything else survives the stamp'
	assert f.id == 0x100
	// And a wire nobody declared is untouched by another wire's mark.
	other := framed_for_wire('inproc:CAN2', CanFrame{ id: 0x100 })
	assert !other.fd
}

fn test_fd_without_the_bit_rate_switch_is_carried_as_declared() {
	replace_wire_policy([], {'inproc:CAN1': Framing{ fd: true, brs: false }})
	f := framed_for_wire('inproc:CAN1', CanFrame{ id: 0x100, data: []u8{len: 64} })
	assert f.fd, '64-byte payloads are still FD'
	assert !f.brs, 'equal phases have no faster phase to switch into'
}

// UPWARD ONLY. Replay carries recorded flags through this same path, and demoting an FD frame to
// classic silently would be the truncation the change exists to stop.
fn test_a_frame_that_already_says_fd_is_never_demoted() {
	clear_wire_framing()
	f := framed_for_wire('inproc:CAN1', CanFrame{ id: 0x100, fd: true, brs: true, data: []u8{len: 64} })
	assert f.fd && f.brs, 'an undeclared wire must not strip a format the caller stated'
}

// TWO SPELLINGS, ONE WIRE — keyed exactly as listen-only is, so one transceiver cannot be declared
// two different formats by two rows that name it differently.
//
// WINDOWS ONLY, and the guard is the point rather than a convenience. `vector:` resolves to a
// vendor wire only where that vendor exists; on Linux the same string is an ordinary SocketCAN
// interface name, so `vector:1` and `vector:ch1` are genuinely two different wires and must not be
// folded together — which is exactly what test_destination_key_keeps_its_platform_guard pins for
// the key this one is built on. Asserting the Windows answer everywhere passed here and failed CI.
fn test_spellings_of_one_wire_share_a_declaration() {
	$if windows {
		replace_wire_policy([], {'vector:1@500000/2000000': Framing{ fd: true, brs: true }})
		for spelling in ['vector:1', 'vector:ch1', 'vector:app01@500000/2000000'] {
			f := framed_for_wire(spelling, CanFrame{ id: 0x100 })
			assert f.fd, '${spelling} names the same wire and must carry its format'
		}
		clear_wire_framing()
	}
	// EVERYWHERE: a software bus is keyed by its canonical address, so the two spellings of one hub
	// share a declaration on any platform. This half is what the rule rests on for the buses the
	// tests actually run over.
	replace_wire_policy([], {'inproc:framing_spell': Framing{ fd: true, brs: true }})
	for spelling in ['inproc:framing_spell', ' inproc:framing_spell'.trim_space()] {
		f := framed_for_wire(spelling, CanFrame{ id: 0x100 })
		assert f.fd, '${spelling} names the same hub and must carry its format'
	}
	clear_wire_framing()
}

// A PROJECT REPLACED MUST NOT LEAVE ITS MARKS BEHIND, the hazard clear_listen_only exists for.
fn test_replacing_the_set_drops_what_is_no_longer_declared() {
	replace_wire_policy([], {'inproc:CAN1': Framing{ fd: true, brs: true }, 'inproc:CAN2': Framing{ fd: true, brs: false }})
	assert framed_for_wire('inproc:CAN2', CanFrame{}).fd
	replace_wire_policy([], {'inproc:CAN1': Framing{ fd: true, brs: true }})
	assert framed_for_wire('inproc:CAN1', CanFrame{}).fd, 'still declared'
	assert !framed_for_wire('inproc:CAN2', CanFrame{}).fd, 'no longer declared, so no longer stamped'
	clear_wire_framing()
	assert !framed_for_wire('inproc:CAN1', CanFrame{}).fd, 'cleared'
}

// A CLASSIC DECLARATION IS THE ABSENCE OF A MARK, not a stored false — one way to say one thing.
fn test_declaring_classic_removes_the_mark() {
	replace_wire_policy([], {'inproc:CAN1': Framing{ fd: true, brs: true }})
	set_wire_framing('inproc:CAN1', Framing{})
	assert !framed_for_wire('inproc:CAN1', CanFrame{}).fd
	clear_wire_framing()
}

// SILENCE STILL WINS. The format is decided only for a frame that is actually going out; a wire
// the operator ticked listen-only refuses regardless of what it carries.
fn test_a_listen_only_fd_wire_still_refuses_to_transmit() {
	// BOTH IN ONE PUBLISH, which is the whole point of the merged table — `replace_listen_only`
	// replaces the entire set, so publishing them one after the other would wipe the first.
	replace_wire_policy(['inproc:framing_quiet'], {
		'inproc:framing_quiet': Framing{ fd: true, brs: true }
	})
	assert wire_policy('inproc:framing_quiet').silent
	assert wire_policy('inproc:framing_quiet').framing.fd, 'one entry carries both'
	mut b := open('inproc:framing_quiet') or {
		assert false, 'open: ${err}'
		return
	}
	defer {
		b.close()
		clear_listen_only()
		clear_wire_framing()
	}
	if _ := b.send(CanFrame{ id: 0x100, data: []u8{len: 64} }) {
		assert false, 'a listen-only wire must refuse whatever format it carries'
	}
}

// AND THE WHOLE PATH, through the bus every emitter is handed: a frame built classic by a caller
// that asks nothing about framing comes out FD, with no cooperation from the caller at all.
fn test_a_bus_from_open_frames_what_a_raw_emitter_sends() {
	clear_listen_only()
	replace_wire_policy([], {'inproc:framing_e2e': Framing{ fd: true, brs: true }})
	mut tx := open('inproc:framing_e2e') or {
		assert false, 'tx: ${err}'
		return
	}
	mut rx := open('inproc:framing_e2e') or {
		assert false, 'rx: ${err}'
		return
	}
	defer {
		tx.close()
		rx.close()
		clear_wire_framing()
	}
	tx.send(CanFrame{ id: 0x201, data: []u8{len: 64} }) or {
		assert false, 'send: ${err}'
		return
	}
	got := rx.recv(500) or {
		assert false, 'nothing arrived: ${err}'
		return
	}
	assert got.id == 0x201
	assert got.fd, 'the seam must frame a caller that never asked'
	assert got.brs
	assert got.data.len == 64
}

// A BUS WHOSE CALLER OWNS THE FORMAT IS NOT FRAMED (#202 r3).
//
// Replay reproduces a recording: its classic frames are classic because they were CAPTURED that
// way, and `fd == false` cannot tell that apart from an emitter that simply did not say. Framing
// them on an FD wire silently rewrites the recording replay exists to reproduce — which is the same
// not-specified-vs-specified-as-classic conflation that has cost this repo several review rounds.
fn test_a_verbatim_bus_leaves_a_recorded_classic_frame_classic() {
	clear_listen_only()
	replace_wire_policy([], {'inproc:framing_verbatim': Framing{ fd: true, brs: true }})
	mut raw := open('inproc:framing_verbatim') or {
		assert false, 'tx: ${err}'
		return
	}
	mut tx := verbatim(mut raw)
	mut rx := open('inproc:framing_verbatim') or {
		assert false, 'rx: ${err}'
		return
	}
	defer {
		tx.close()
		rx.close()
		clear_wire_framing()
	}
	// Exactly what a recording holds for an ordinary classic frame.
	tx.send(CanFrame{ id: 0x301, data: []u8{len: 8} }) or {
		assert false, 'send: ${err}'
		return
	}
	got := rx.recv(500) or {
		assert false, 'nothing arrived: ${err}'
		return
	}
	assert got.id == 0x301
	assert !got.fd, 'a recorded classic frame must stay classic on an FD wire'
	assert !got.brs
}

// …and a verbatim bus still refuses on a wire the operator ticked silent. Owning the FORMAT is not
// permission to transmit.
fn test_a_verbatim_bus_still_obeys_listen_only() {
	replace_wire_policy(['inproc:framing_vquiet'], {
		'inproc:framing_vquiet': Framing{ fd: true, brs: true }
	})
	mut raw := open('inproc:framing_vquiet') or {
		assert false, 'open: ${err}'
		return
	}
	mut b := verbatim(mut raw)
	defer {
		b.close()
		clear_listen_only()
		clear_wire_framing()
	}
	if _ := b.send(CanFrame{ id: 0x100 }) {
		assert false, 'listen-only outranks whoever owns the format'
	}
}

// ---- a format STATED per frame (#203) ---------------------------------------------------------

// The case the wire table could not reach: a classic frame, on purpose, on a CAN-FD wire — through
// an ordinary bus, so the stamping every other emitter relies on is what it has to survive.
fn test_a_stated_classic_frame_survives_an_fd_wire() {
	clear_listen_only()
	replace_wire_policy([], {'inproc:framing_stated': Framing{ fd: true, brs: true }})
	mut tx := open('inproc:framing_stated') or {
		assert false, 'tx: ${err}'
		return
	}
	mut rx := open('inproc:framing_stated') or {
		assert false, 'rx: ${err}'
		return
	}
	defer {
		tx.close()
		rx.close()
		clear_wire_framing()
	}
	classic := FrameFormat.classic.stamp(CanFrame{ id: 0x123, data: []u8{len: 8} }) or {
		assert false, 'stamp: ${err}'
		return
	}
	tx.send(classic) or {
		assert false, 'send: ${err}'
		return
	}
	got := rx.recv(500) or {
		assert false, 'nothing arrived: ${err}'
		return
	}
	assert !got.fd && !got.brs, 'stated classic must not be promoted by the wire'
	assert !got.format_stated, 'the statement is consumed before the frame reaches a receiver'
	// The NEXT frame states nothing, and the wire's declaration still applies to it.
	tx.send(CanFrame{ id: 0x124, data: []u8{len: 8} }) or {
		assert false, 'send: ${err}'
		return
	}
	next := rx.recv(500) or {
		assert false, 'nothing arrived: ${err}'
		return
	}
	assert next.fd && next.brs, 'an unstated frame on the same wire is still stamped'
}

fn test_each_stated_format_is_what_goes_out() {
	replace_wire_policy([], {'inproc:framing_each': Framing{ fd: true, brs: true }})
	defer {
		clear_wire_framing()
	}
	base := CanFrame{
		id:   0x200
		data: []u8{len: 8}
	}
	cases := {
		FrameFormat.classic: [false, false]
		FrameFormat.fd:      [true, false]
		FrameFormat.fd_brs:  [true, true]
	}
	for ff, want in cases {
		stated := ff.stamp(base) or {
			assert false, '${ff}: ${err}'
			return
		}
		assert stated.format_stated
		out := framed_for_wire('inproc:framing_each', stated)
		assert out.fd == want[0] && out.brs == want[1], '${ff} on an FD+BRS wire'
		assert !out.format_stated
		// And on a wire that declared nothing — the FD row of a disputed wire is this case.
		bare := framed_for_wire('inproc:framing_undeclared', stated)
		assert bare.fd == want[0] && bare.brs == want[1], '${ff} on an undeclared wire'
	}
	// `wire` states nothing: the wire decides.
	w := FrameFormat.wire.stamp(base) or { panic(err) }
	assert !w.format_stated
	assert framed_for_wire('inproc:framing_each', w).fd
}

fn test_a_stated_classic_frame_longer_than_eight_bytes_is_refused() {
	if _ := FrameFormat.classic.stamp(CanFrame{ id: 0x1, data: []u8{len: 12} }) {
		assert false, 'a classic frame cannot carry 12 bytes'
	}
	fd := FrameFormat.fd.stamp(CanFrame{ id: 0x1, data: []u8{len: 12} }) or { panic(err) }
	assert fd.fd
	if _ := FrameFormat.fd_brs.stamp(CanFrame{ id: 0x1, data: []u8{len: 65} }) {
		assert false, 'an FD frame cannot carry 65 bytes'
	}
}

fn test_a_verbatim_bus_drops_the_statement_too() {
	clear_listen_only()
	clear_wire_framing()
	mut raw := open('inproc:framing_vstated') or { panic(err) }
	mut tx := verbatim(mut raw)
	mut rx := open('inproc:framing_vstated') or { panic(err) }
	defer {
		tx.close()
		rx.close()
	}
	tx.send(FrameFormat.fd.stamp(CanFrame{ id: 0x5 }) or { panic(err) }) or { panic(err) }
	got := rx.recv(500) or { panic(err) }
	assert got.fd
	assert !got.format_stated
}

fn test_parse_frame_format() {
	assert frame_format_names.len == frame_formats.len
	for i, name in frame_format_names {
		got := parse_frame_format(name) or {
			assert false, name
			continue
		}
		assert got == frame_formats[i], 'the names and the picker order agree'
	}
	assert parse_frame_format('') or { FrameFormat.classic } == .wire
	assert parse_frame_format('FD+BRS') or { FrameFormat.wire } == .fd_brs
	if _ := parse_frame_format('fdx') {
		assert false, 'an unknown name is refused, not read as the wire default'
	}
}

// The choice is offered only where it changes something.
fn test_the_choice_is_offered_only_where_it_can_change_the_frame() {
	classic := Framing{}
	fd := Framing{
		fd: true
	}
	assert !format_choice_offered(classic, true, classic), 'every frame is classic either way'
	assert format_choice_offered(classic, true, fd), 'an FD wire: how a classic frame gets out'
	assert format_choice_offered(classic, false, fd), 'an FD wire, whichever row names it'
	assert format_choice_offered(fd, true, classic), 'an FD row on a disputed wire sends FD: how a classic frame gets out'
	// A disabled FD alias of an enabled classic row: the wire table ignores it, so must this.
	assert !format_choice_offered(fd, false, classic), 'a disabled row declares nothing about the run'
}

// ---- a row's own emitters (#384) --------------------------------------------------------------

fn test_a_row_declares_over_an_undeclared_wire_only_while_enabled() {
	classic := Framing{}
	fd_brs := Framing{
		fd:  true
		brs: true
	}
	assert row_declared(fd_brs, true, classic) == fd_brs, 'the FD row of a disputed wire keeps its format'
	assert row_declared(fd_brs, false, classic) == classic, 'a disabled row declares nothing'
	assert row_declared(classic, true, fd_brs) == fd_brs, 'a classic row never lowers the wire'
	assert row_declared(classic, true, classic) == classic
}

fn test_a_row_frame_is_raised_upward_only_and_a_statement_kept() {
	fd_brs := Framing{
		fd:  true
		brs: true
	}
	p := WirePolicy{
		rows: {
			'FD': fd_brs
		}
	}
	up := p.frame(CanFrame{ id: 1, data: []u8{len: 12}, row: 'FD' })
	assert up.fd && up.brs && up.data.len == 12 && up.row == '', 'raised, the row consumed'
	assert !p.frame(CanFrame{ id: 1, row: 'CL' }).fd, 'a row the wire has no FD entry for raises nothing'
	already := p.frame(CanFrame{ id: 1, fd: true, row: 'FD' })
	assert already.fd && !already.brs, 'a frame that says fd keeps its own brs'
	stated := FrameFormat.classic.stamp(CanFrame{ id: 1, data: []u8{len: 8}, row: 'FD' }) or {
		panic(err)
	}
	kept := p.frame(stated)
	assert !kept.fd && !kept.format_stated && kept.row == '', 'a stated classic frame stays classic'
	on_fd := WirePolicy{
		framing: fd_brs
	}
	assert on_fd.frame(CanFrame{ id: 1, row: 'CL' }).fd, 'a classic row never lowers the wire'
}

// two spellings of one wire are one wire: the rows each published merge
fn test_rows_published_under_two_spellings_of_a_wire_merge() {
	fd := Framing{
		fd: true
	}
	replace_wire_policy_rows([], map[string]Framing{}, {
		'inproc':     {
			'A': fd
		}
		'inproc:CAN': {
			'B': fd
		}
	})
	defer {
		clear_wire_framing()
	}
	assert row_framing('inproc:CAN', 'A').fd && row_framing('inproc', 'B').fd
}

// Two rows dispute the wire, so it is undeclared: each row's handle sends in its own row's format,
// a frame stated classic through the FD row's handle stays classic, and the format is asked per
// send, so a project published since is what the next frame follows.
fn test_each_row_handle_on_a_disputed_wire_sends_its_own_format() {
	clear_listen_only()
	fd_row := Framing{
		fd:  true
		brs: true
	}
	replace_wire_policy_rows([], map[string]Framing{}, {
		'inproc:framing_rows': {
			'FD': fd_row
		}
	})
	assert !wire_framing('inproc:framing_rows').fd, 'the wire itself declares nothing'
	assert row_framing('inproc:framing_rows', 'FD') == fd_row
	assert !row_framing('inproc:framing_other', 'FD').fd, 'a row is a row of its wire'
	mut fd_raw := open('inproc:framing_rows') or { panic(err) }
	mut fd_tx := row_framed(fd_raw, 'inproc:framing_rows', 'FD')
	mut cl_tx := row_framed(open('inproc:framing_rows') or { panic(err) }, 'inproc:framing_rows',
		'CL')
	mut rx := open('inproc:framing_rows') or { panic(err) }
	defer {
		fd_tx.close()
		cl_tx.close()
		rx.close()
		clear_wire_framing()
	}
	fd_tx.send(CanFrame{ id: 0x401, data: []u8{len: 12} }) or { panic(err) }
	a := rx.recv(500) or { panic(err) }
	assert a.id == 0x401 && a.fd && a.brs && a.data.len == 12, 'the FD row frames FD'
	cl_tx.send(CanFrame{ id: 0x402, data: []u8{len: 8} }) or { panic(err) }
	b := rx.recv(500) or { panic(err) }
	assert b.id == 0x402 && !b.fd && !b.brs, 'the classic row frames classic'
	stated := FrameFormat.classic.stamp(CanFrame{ id: 0x403, data: []u8{len: 8} }) or { panic(err) }
	fd_tx.send(stated) or { panic(err) }
	c := rx.recv(500) or { panic(err) }
	assert c.id == 0x403 && !c.fd && !c.format_stated, 'a stated classic frame is not raised'
	// a metered handle prices what the wrapper sent
	probe := fd_tx
	if probe is SentFrame {
		assert !probe.sent_frame().fd, 'the last send was the stated classic one'
	} else {
		assert false, 'a row-framed bus says what it sent'
	}
	clear_wire_framing()
	fd_tx.send(CanFrame{ id: 0x404, data: []u8{len: 8} }) or { panic(err) }
	d := rx.recv(500) or { panic(err) }
	assert d.id == 0x404 && !d.fd, 'the row was published away: asked per send, not at open'
}
