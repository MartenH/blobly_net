module lin

import blobly.transport

@[heap]
struct FakeClock {
mut:
	ns i64
}

fn (c &FakeClock) now_ns() i64 {
	return c.ns
}

fn open_or_panic(address string, cfg Config) Bus {
	return open(address, cfg) or { panic(err) }
}

// take is the one frame queued on a handle.
fn take(mut b Bus) Frame {
	f := b.recv(0) or { panic('nothing queued: ${err}') }
	if g := b.recv(0) {
		panic('a second frame queued: ${reading(g)}')
	}
	return f
}

fn test_open_refuses_other_schemes() {
	open('tty:/dev/ttyUSB0', Config{}) or {
		assert err.msg().contains('scheme `tty`')
		return
	}
	assert false
}

fn test_no_publisher_is_no_response() {
	clk := &FakeClock{
		ns: 1234
	}
	mut m := open_or_panic('inproc:none', Config{ role: .master, src: .tester, clock: clk })
	mut s := open_or_panic('inproc:none', Config{ role: .slave, src: .sim })
	mut mon := open_or_panic('inproc:none', Config{ role: .monitor })
	defer {
		m.close()
		s.close()
		mon.close()
	}
	m.header(0x21)!
	fm := take(mut m)
	fs := take(mut s)
	fo := take(mut mon)
	for f in [fm, fs, fo] {
		assert f.errs == Errs.no_response
		assert f.id == 0x21 && f.pid == 0x61
		assert f.src == .tester
		assert f.t_ns == 1234
		assert !f.ours
		assert !is_bus_traffic(f)
	}
	assert fm.header && !fs.header && !fo.header
	st := m.status()
	assert st.last_id == 0x21 && st.state == .active
}

fn test_one_publisher() {
	mut m := open_or_panic('inproc:one', Config{ role: .master, src: .tester })
	mut s := open_or_panic('inproc:one', Config{ role: .slave, src: .sim })
	mut mon := open_or_panic('inproc:one', Config{ role: .monitor })
	defer {
		m.close()
		s.close()
		mon.close()
	}
	s.set_entry(id: 0x21, dir: .publish, len: 4, data: [u8(1), 2, 3, 4])!
	m.header(0x21)!
	fm := take(mut m)
	fs := take(mut s)
	fo := take(mut mon)
	for f in [fm, fs, fo] {
		assert f.data == [u8(1), 2, 3, 4]
		assert f.checksum == 0x94
		assert f.model == .enhanced
		assert f.errs == Errs.zero()
		assert f.src == .sim
		assert reading(f) == '0x21 [4] 01 02 03 04 cs 0x94 enhanced'
	}
	assert fm.header && !fm.ours
	assert fs.ours && !fs.header
	assert !fo.ours && !fo.header
	// The entry stays: a second header answers again, with the data updated.
	s.update(0x21, [u8(9), 9, 9, 9])!
	m.header(0x21)!
	assert take(mut mon).data == [u8(9), 9, 9, 9]
	// A classic entry carries a classic checksum.
	s.set_entry(id: 0x22, dir: .publish, len: 2, model: .classic, data: [u8(5), 6])!
	m.header(0x22)!
	f := take(mut mon)
	assert f.model == .classic && f.errs == Errs.zero()
	assert f.checksum == checksum(.classic, pid(0x22), [u8(5), 6])
}

fn test_remote_publisher_is_bus_traffic() {
	mut m := open_or_panic('inproc:remote', Config{ role: .master, src: .tester })
	mut ecu := open_or_panic('inproc:remote', Config{ role: .slave, src: .remote })
	defer {
		m.close()
		ecu.close()
	}
	ecu.set_entry(id: 0x10, dir: .publish, len: 1, data: [u8(7)])!
	m.header(0x10)!
	fm := take(mut m)
	assert is_bus_traffic(fm)
	assert origin_of(fm) == 'RX'
	// The publisher's own copy is ours, not evidence of another node.
	assert !is_bus_traffic(take(mut ecu))
}

fn test_collision_is_bitwise_arbitration() {
	mut m := open_or_panic('inproc:coll', Config{ role: .master, src: .tester })
	mut a := open_or_panic('inproc:coll', Config{ role: .slave, src: .sim })
	mut b := open_or_panic('inproc:coll', Config{ role: .slave, src: .remote })
	mut mon := open_or_panic('inproc:coll', Config{ role: .monitor })
	defer {
		m.close()
		a.close()
		b.close()
		mon.close()
	}
	// 0x10 and 0x11 differ in bit 0, the first sent: B's recessive 1 loses to A's dominant 0, and
	// the wire carries A's whole frame.
	a.set_entry(id: 0x21, dir: .publish, len: 2, data: [u8(0x10), 0xAA])!
	b.set_entry(id: 0x21, dir: .publish, len: 2, data: [u8(0x11), 0x55])!
	m.header(0x21)!
	want := [u8(0x10), 0xAA, checksum(.enhanced, pid(0x21), [u8(0x10), 0xAA])]
	for f in [take(mut m), take(mut mon)] {
		assert f.raw == want
		assert f.errs == Errs.zero()
		assert f.src == .sim
		assert !f.ours
	}
	fa := take(mut a)
	assert fa.ours && fa.errs == Errs.zero()
	fb := take(mut b)
	assert fb.ours && fb.raw == want
	assert fb.errs == Errs.bit | Errs.collision
	assert key_suffix(fb) == '/collision+bit'
}

fn test_collision_lost_mid_frame() {
	mut m := open_or_panic('inproc:coll2', Config{ role: .master })
	mut a := open_or_panic('inproc:coll2', Config{ role: .slave, src: .sim })
	mut b := open_or_panic('inproc:coll2', Config{ role: .slave, src: .sim })
	defer {
		m.close()
		a.close()
		b.close()
	}
	// Equal first bytes; the second differs at bit 3 (0xF7 against 0xFF): A wins there.
	a.set_entry(id: 0x05, dir: .publish, len: 2, data: [u8(0x42), 0xF7])!
	b.set_entry(id: 0x05, dir: .publish, len: 2, data: [u8(0x42), 0xFF])!
	m.header(0x05)!
	fm := take(mut m)
	assert fm.data == [u8(0x42), 0xF7] && fm.errs == Errs.zero()
	assert take(mut a).errs == Errs.zero()
	assert take(mut b).errs == Errs.bit | Errs.collision
}

fn test_collision_of_identical_responses_reads_back_clean() {
	mut m := open_or_panic('inproc:same', Config{ role: .master })
	mut a := open_or_panic('inproc:same', Config{ role: .slave, src: .sim })
	mut b := open_or_panic('inproc:same', Config{ role: .slave, src: .tester })
	defer {
		m.close()
		a.close()
		b.close()
	}
	a.set_entry(id: 0x05, dir: .publish, len: 1, data: [u8(0x11)])!
	b.set_entry(id: 0x05, dir: .publish, len: 1, data: [u8(0x11)])!
	m.header(0x05)!
	fm := take(mut m)
	assert fm.errs == Errs.zero()
	assert fm.src == .remote // survivors of mixed sources
	assert take(mut a).errs == Errs.zero()
	assert take(mut b).errs == Errs.zero()
}

fn test_injected_faults() {
	mut m := open_or_panic('inproc:inject', Config{ role: .master })
	mut s := open_or_panic('inproc:inject', Config{ role: .slave })
	defer {
		m.close()
		s.close()
	}
	data := [u8(1), 2, 3, 4]
	s.set_entry(id: 0x21, dir: .publish, len: 4, data: data, inject: .bad_checksum)!
	m.header(0x21)!
	f := take(mut m)
	assert f.errs == Errs.checksum
	assert f.checksum == 0x94 ^ 0xFF
	take(mut s)

	s.set_entry(id: 0x21, dir: .publish, len: 4, data: data, inject: .silent)!
	m.header(0x21)!
	assert take(mut m).errs == Errs.no_response
	assert !take(mut s).ours

	s.set_entry(id: 0x21, dir: .publish, len: 4, data: data, inject: .short)!
	m.header(0x21)!
	g := take(mut m)
	assert g.errs == Errs.short
	assert g.raw == [u8(1)]
	assert reading(g) == '0x21 [1] 01 !short'
	assert take(mut s).ours
}

fn test_one_shot_is_consumed() {
	mut m := open_or_panic('inproc:oneshot', Config{ role: .master })
	mut s := open_or_panic('inproc:oneshot', Config{ role: .slave })
	defer {
		m.close()
		s.close()
	}
	s.set_entry(id: 0x30, dir: .publish, len: 1, data: [u8(0xAA)], one_shot: true)!
	m.header(0x30)!
	assert take(mut m).data == [u8(0xAA)]
	m.header(0x30)!
	assert take(mut m).errs == Errs.no_response
	// A consumed entry cannot be updated.
	s.update(0x30, [u8(1)]) or { return }
	assert false
}

fn test_slave_response_armed_by_nad() {
	mut m := open_or_panic('inproc:diag', Config{ role: .master, src: .tester })
	mut a := open_or_panic('inproc:diag', Config{ role: .slave, src: .sim, nad: 0x01 })
	mut b := open_or_panic('inproc:diag', Config{ role: .slave, src: .sim, nad: 0x02 })
	mut mon := open_or_panic('inproc:diag', Config{ role: .monitor })
	defer {
		m.close()
		a.close()
		b.close()
		mon.close()
	}
	resp_a := [u8(0x01), 0x06, 0x62, 0xF1, 0x90, 0x41, 0x42, 0x43]
	resp_b := [u8(0x02), 0x06, 0x62, 0xF1, 0x90, 0x51, 0x52, 0x53]
	req := fn (nad u8) Entry {
		return Entry{
			id:   0x3C
			dir:  .publish
			len:  8
			data: [nad, 0x03, 0x22, 0xF1, 0x90, 0xFF, 0xFF, 0xFF]
		}
	}
	slave_entry := fn (data []u8) Entry {
		return Entry{
			id:   0x3D
			dir:  .publish
			len:  8
			data: data
		}
	}
	a.set_entry(slave_entry(resp_a))!
	b.set_entry(slave_entry(resp_b))!
	// Unarmed: neither answers a SlaveResp header.
	m.header(0x3D)!
	assert take(mut mon).errs == Errs.no_response
	// A request to NAD 2 arms b alone.
	m.set_entry(req(0x02))!
	m.header(0x3C)!
	r := take(mut mon)
	assert r.model == .classic && r.errs == Errs.zero() && r.src == .tester
	m.header(0x3D)!
	f := take(mut mon)
	assert f.data == resp_b
	assert f.model == .classic && f.errs == Errs.zero()
	// The entry was one-shot: the next SlaveResp is unanswered, even after a new request.
	m.header(0x3D)!
	assert take(mut mon).errs == Errs.no_response
	m.header(0x3C)!
	take(mut mon)
	m.header(0x3D)!
	assert take(mut mon).errs == Errs.no_response
	// A request to NAD 1 arms a.
	m.set_entry(req(0x01))!
	m.header(0x3C)!
	take(mut mon)
	m.header(0x3D)!
	assert take(mut mon).data == resp_a
	// Broadcast arms every node with a response ready.
	a.set_entry(slave_entry(resp_a))!
	b.set_entry(slave_entry(resp_b))!
	m.set_entry(req(broadcast_nad))!
	m.header(0x3C)!
	take(mut mon)
	m.header(0x3D)!
	// Both answer and arbitrate: 0x01 and 0x02 differ at bit 0, where b's 0 wins.
	assert take(mut mon).data == resp_b
	mut last := Frame{}
	for {
		last = a.recv(0) or { break }
	}
	assert last.ours && last.errs == Errs.bit | Errs.collision
	// A request to another node disarms.
	a.set_entry(slave_entry(resp_a))!
	m.set_entry(req(0x01))!
	m.header(0x3C)!
	m.set_entry(req(0x05))!
	m.header(0x3C)!
	m.header(0x3D)!
	mon.recv(0)!
	mon.recv(0)!
	assert take(mut mon).errs == Errs.no_response
}

fn test_second_master_and_baud_refused() {
	mut m := open_or_panic('inproc:masters', Config{ role: .master })
	open('inproc:masters', Config{ role: .master }) or {
		assert err.msg().contains('already has a master')
		open('inproc:masters', Config{ role: .slave, baud: 9600 }) or {
			assert err.msg().contains('19200 baud, not 9600')
			// The master slot is free once the master closes.
			m.close()
			mut m2 := open_or_panic('inproc:masters', Config{ role: .master })
			m2.close()
			return
		}
	}
	assert false
}

fn refusal(err IError, role Role, call string) bool {
	if err is RoleRefused {
		return err.role == role && err.call == call
			&& err.msg() == 'lin: ${call} refused: this handle is a ${role}'
	}
	return false
}

fn test_roles_refuse_control_calls() {
	mut m := open_or_panic('inproc:roles', Config{ role: .master })
	mut s := open_or_panic('inproc:roles', Config{ role: .slave })
	mut mon := open_or_panic('inproc:roles', Config{ role: .monitor })
	defer {
		m.close()
		s.close()
		mon.close()
	}
	e := Entry{
		id:   1
		dir:  .publish
		len:  1
		data: [u8(1)]
	}
	mut n := 0
	mon.set_entry(e) or { n += int(refusal(err, .monitor, 'set_entry')) }
	mon.update(1, [u8(1)]) or { n += int(refusal(err, .monitor, 'update')) }
	mon.header(1) or { n += int(refusal(err, .monitor, 'header')) }
	mon.wakeup() or { n += int(refusal(err, .monitor, 'wakeup')) }
	mon.sleep() or { n += int(refusal(err, .monitor, 'sleep')) }
	s.header(1) or { n += int(refusal(err, .slave, 'header')) }
	s.sleep() or { n += int(refusal(err, .slave, 'sleep')) }
	assert n == 7
	// Nothing reached the bus.
	assert mon.recv(0) or { Frame{ id: 0xFF } }.id == 0xFF
}

fn test_entries_dropped_on_close() {
	mut m := open_or_panic('inproc:drop', Config{ role: .master })
	mut s := open_or_panic('inproc:drop', Config{ role: .slave })
	defer {
		m.close()
	}
	s.set_entry(id: 0x21, dir: .publish, len: 1, data: [u8(1)])!
	m.header(0x21)!
	take(mut m)
	// s has the frame queued when it closes.
	s.close()
	m.header(0x21)!
	assert take(mut m).errs == Errs.no_response
	// A closed handle is gone, not quiet, whatever was queued on it.
	if f := s.recv(0) {
		assert false, 'a closed handle read ${reading(f)}'
	} else {
		assert err is transport.CarrierGone
	}
	s.wakeup() or { assert err is transport.CarrierGone }
	s.set_entry(id: 0x21, dir: .publish, len: 1, data: [u8(1)]) or {
		assert err is transport.CarrierGone
		return
	}
	assert false
}

fn test_entry_checks() {
	mut s := open_or_panic('inproc:checks', Config{ role: .slave })
	defer {
		s.close()
	}
	s.set_entry(id: 0x40, dir: .publish, len: 1, data: [u8(1)]) or {
		assert err.msg().contains('above 0x3F')
		s.set_entry(id: 1, dir: .publish, len: 2, data: [u8(1)]) or {
			assert err.msg().contains('1 data bytes for length 2')
			s.set_entry(id: 1, dir: .subscribe, len: 9) or {
				assert err.msg().contains('outside 1..8')
				return
			}
		}
	}
	assert false
}

fn test_sleep_and_wakeup_events() {
	mut clk := &FakeClock{
		ns: 5
	}
	mut m := open_or_panic('inproc:sleep', Config{ role: .master, src: .tester, clock: clk })
	mut s := open_or_panic('inproc:sleep', Config{ role: .slave, src: .sim })
	defer {
		m.close()
		s.close()
	}
	m.sleep()!
	fs := take(mut s)
	assert fs.event == .sleep
	assert fs.id == 0x3C && fs.data == sleep_data() && fs.model == .classic
	assert fs.errs == Errs.zero()
	assert fs.src == .tester && !fs.ours
	assert key_suffix(fs) == '/sleep'
	fm := take(mut m)
	assert fm.ours && fm.header
	assert s.status().state == .sleep
	assert s.status().last_id == 0x3C
	clk.ns = 9
	s.wakeup()!
	w := take(mut m)
	assert w.event == .wakeup && w.src == .sim && !w.ours && w.t_ns == 9
	assert take(mut s).ours
	assert reading(w) == 'wakeup'
	assert m.status().state == .active
}

fn test_recv_timeout_is_typed() {
	mut s := open_or_panic('inproc:timeout', Config{ role: .slave })
	mut other := open_or_panic('inproc:timeout', Config{ role: .slave })
	defer {
		other.close()
	}
	s.recv(0) or { assert err is Timeout }
	s.recv(1) or { assert err is Timeout }
	// Three frames queued on s, then s closes: every timeout form answers gone.
	for _ in 0 .. 3 {
		other.wakeup()!
	}
	s.close()
	for t in [0, 1, -1] {
		if f := s.recv(t) {
			assert false, 'recv(${t}) on a closed handle read ${reading(f)}'
		} else {
			assert err is transport.CarrierGone
		}
	}
}

fn test_closed_master_sends_nothing() {
	mut old := open_or_panic('inproc:closedmaster', Config{ role: .master })
	mut mon := open_or_panic('inproc:closedmaster', Config{ role: .monitor })
	old.close()
	mut m := open_or_panic('inproc:closedmaster', Config{ role: .master })
	defer {
		m.close()
		mon.close()
	}
	mut n := 0
	old.header(0x01) or { n += int(err is transport.CarrierGone) }
	old.sleep() or { n += int(err is transport.CarrierGone) }
	old.wakeup() or { n += int(err is transport.CarrierGone) }
	old.update(0x01, [u8(1)]) or { n += int(err is transport.CarrierGone) }
	assert n == 4
	if f := mon.recv(0) {
		assert false, 'a closed master put ${reading(f)} on the bus'
	}
	assert mon.status().last_id == -1
}

fn test_reserved_nads_refused() {
	open('inproc:nads', Config{ nad: broadcast_nad }) or {
		assert err.msg().contains('0x7F is the broadcast address')
		open('inproc:nads', Config{ nad: functional_nad }) or {
			assert err.msg().contains('0x7E is the functional address')
			return
		}
	}
	assert false
}

fn test_queue_drops_counted() {
	mut m := open_or_panic('inproc:full', Config{ role: .master })
	mut mon := open_or_panic('inproc:full', Config{ role: .monitor })
	defer {
		m.close()
		mon.close()
	}
	for _ in 0 .. inproc_queue_cap + 7 {
		m.header(0x01)!
		m.recv(0)!
	}
	assert mon.diagnostics().dropped == 7
	assert m.diagnostics().dropped == 0
}
