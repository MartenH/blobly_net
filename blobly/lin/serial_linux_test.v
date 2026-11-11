module lin

// The serial backend over pseudo-terminals.

import os
import time
import blobly.lindb
import blobly.transport

const serial_ldf = @VMODROOT + '/dbc/lin_demo.ldf'

// raw_open opens a pty end as another program would: raw, no handle.
fn raw_open(path string) i32 {
	mut got := u32(0)
	fd := C.bl_ser_open(&char(path.str), 19200, 0, &got)
	assert fd >= 0
	return fd
}

// raw_pty is a pty with no link: its master end is the fd, read (or not) by the test.
fn raw_pty() (i32, string) {
	mut name := []u8{len: 64}
	fd := C.bl_pty_new(name.data, 64)
	assert fd >= 0
	return fd, unsafe { cstring_to_vstring(&char(name.data)) }
}

// fill writes into fd until the pty has had no room in that direction for 20 ms (the kernel
// moves what was written on in the background, so a full pty takes more in a moment).
fn fill(fd i32) {
	junk := []u8{len: 4096, init: 0x13}
	for _ in 0 .. 1000 {
		if C.bl_ser_write(fd, junk.data, i32(junk.len), 20) < 0 {
			return
		}
	}
	panic('the pty never filled')
}

// empty reads fd until nothing is left.
fn empty(fd i32) {
	mut buf := []u8{len: 4096}
	for C.bl_ser_read(fd, buf.data, i32(buf.len), 20) > 0 {
	}
}

// serial is a handle's backend, to reach its lock.
fn serial(b Bus) &SerialBus {
	return b as &SerialBus
}

// got is the next frame on a handle, within a generous bound.
fn got(mut b Bus) Frame {
	return b.recv(1000) or { panic('no frame: ${err}') }
}

fn test_a_master_and_a_slave_on_a_pty_link() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master, src: .tester })!
	mut s := open('pty:${link.b}', Config{ role: .slave, src: .sim, nad: 0x0A })!
	defer {
		m.close()
		s.close()
	}
	s.set_entry(Entry{ id: 0x21, dir: .publish, len: 4, data: [u8(1), 0xFF, 0, 0xFF] })!
	s.set_entry(Entry{ id: 0x10, dir: .subscribe, len: 2 })!
	s.set_entry(Entry{
		id:     0x22
		dir:    .publish
		len:    2
		data:   [u8(5), 6]
		inject: .bad_checksum
	})!
	s.set_entry(Entry{ id: slave_resp, dir: .publish, len: 8, data: []u8{len: 8, init: 0x55} })!
	m.set_entry(Entry{ id: 0x21, dir: .subscribe, len: 4 })!
	m.set_entry(Entry{ id: 0x22, dir: .subscribe, len: 2 })!
	m.set_entry(Entry{ id: 0x10, dir: .publish, len: 2, data: [u8(0xFF), 0x12] })!

	// a header the slave answers, its 0xFF bytes through the escaping
	m.header(0x21)!
	mut fm := got(mut m)
	mut fs := got(mut s)
	for f in [fm, fs] {
		assert f.errs == Errs.zero(), reading(f)
		assert f.id == 0x21 && f.data == [u8(1), 0xFF, 0, 0xFF]
	}
	assert fm.header && !fm.ours && fm.src == .remote
	assert !fs.header && fs.ours && fs.src == .sim

	// the master's own response
	m.header(0x10)!
	fm = got(mut m)
	fs = got(mut s)
	assert fm.errs == Errs.zero() && fs.errs == Errs.zero()
	assert fm.data == [u8(0xFF), 0x12] && fs.data == fm.data
	assert fm.header && fm.ours && fm.src == .tester
	assert !fs.header && !fs.ours && fs.src == .remote

	// nobody answers
	m.header(0x30)!
	fm = got(mut m)
	fs = got(mut s)
	assert fm.errs == Errs.no_response && fm.id == 0x30 && fm.src == .tester && fm.header
	assert fs.errs == Errs.no_response && fs.src == .remote && !fs.header

	// an injected checksum fault, seen at both ends
	m.header(0x22)!
	fm = got(mut m)
	fs = got(mut s)
	assert fm.errs == Errs.checksum && fs.errs == Errs.checksum && fs.ours

	// a SlaveResp only after a MasterReq naming the slave's NAD
	m.header(slave_resp)!
	assert got(mut m).errs == Errs.no_response
	got(mut s)
	mut req := []u8{len: 8, init: 0xFF}
	req[0] = 0x0A
	m.set_entry(Entry{ id: master_req, dir: .publish, len: 8, model: .classic, data: req })!
	m.header(master_req)!
	got(mut m)
	assert got(mut s).data == req
	m.header(slave_resp)!
	fm = got(mut m)
	assert fm.errs == Errs.zero() && fm.data == []u8{len: 8, init: 0x55}
	assert got(mut s).ours

	// a wakeup from the slave, the go-to-sleep from the master
	s.wakeup()!
	fm = got(mut m)
	fs = got(mut s)
	assert fm.event == .wakeup && !fm.ours && fm.src == .remote
	assert fs.event == .wakeup && fs.ours && fs.src == .sim
	m.sleep()!
	fm = got(mut m)
	fs = got(mut s)
	assert fm.event == .sleep && fm.ours && fm.header
	assert fs.event == .sleep && !fs.ours && fs.src == .remote
	assert m.status().state == .sleep && s.status().state == .sleep
	assert m.status().last_id == int(master_req)
	if f := m.recv(100) {
		assert false, 'a frame too many: ${reading(f)}'
	}
	assert m.diagnostics().decode_errors == 0 && s.diagnostics().decode_errors == 0
}

fn test_a_monitor_reads_what_another_program_writes() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut mon := open('pty:${link.a}', Config{ role: .monitor })!
	defer {
		mon.close()
	}
	mut refused := false
	mon.header(0x21) or { refused = err is RoleRefused }
	assert refused
	fd := raw_open(link.b)
	defer {
		C.bl_ser_close(fd)
	}
	p21 := pid(0x21)
	p22 := pid(0x22)
	cs21 := checksum(.enhanced, p21, [u8(1), 2])
	cs22 := checksum(.enhanced, p22, [u8(1), 2])
	mut bytes := pty_bytes(true, [u8(0x55), p21, 1, 2, cs21])
	// byte 0x02 received with a framing error
	bytes << pty_bytes(true, [u8(0x55), p22, 1])
	bytes << [u8(0xFF), 0x00, 0x02]
	bytes << pty_bytes(false, [cs22])
	// a PID whose parity is wrong
	bytes << pty_bytes(true, [u8(0x55), 0x21])
	// a break with nothing after it is a wakeup
	bytes << pty_bytes(true, [])
	assert C.bl_ser_write(fd, bytes.data, i32(bytes.len), 100) == 0
	frames := [got(mut mon), got(mut mon), got(mut mon), got(mut mon)]
	assert frames.map(reading(it)) == ['0x21 [2] 01 02 cs 0x${cs21:02X} enhanced',
		'0x22 [2] 01 02 cs 0x${cs22:02X} enhanced !framing', 'pid 0x21 !parity', 'wakeup']
	assert frames.all(it.src == .remote && !it.ours && !it.header)
}

fn test_a_device_opens_once_in_a_process() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut a := open('pty:${link.a}@10417', Config{ role: .master })!
	mut why := ''
	open('pty:${link.a}', Config{ role: .monitor }) or { why = err.msg() }
	assert why.contains('already open in this process as `pty:${link.a}@10417`'), why
	a.close()
	mut b := open('pty:${link.a}', Config{ role: .monitor })!
	b.close()
	// a closed handle is gone
	mut gone := false
	b.recv(0) or { gone = err is transport.CarrierGone }
	assert gone
	open('pty:${link.a}@9600', Config{ baud: 10417 }) or { why = err.msg() }
	assert why.contains('states 9600 baud'), why
}

fn test_rows_over_a_pty_link_run_a_cluster() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut slave := start_row(RowSpec{
		name:     'S'
		address:  'pty:${link.b}'
		ldf:      serial_ldf
		role:     .slave
		simulate: ['LSM']
	}, RowOpts{})!
	mut master := start_row(RowSpec{
		name:     'M'
		address:  'pty:${link.a}'
		ldf:      serial_ldf
		role:     .master
		simulate: ['CEM']
		schedule: 'NormalTable'
	}, RowOpts{})!
	mut t := master.tap()!
	l := lindb.load_ldf(serial_ldf)!
	lsm2 := l.frame('LSM_Frm2') or { panic('no LSM_Frm2') }
	mut lsm := 0
	for lsm < 3 {
		f := t.recv(1000)!
		if f.id == lsm2.id {
			assert f.errs == Errs.zero(), reading(f)
			assert f.data == l.template(lsm2) && f.src == .remote && f.header
			lsm++
		}
	}
	master.stop()
	slave.stop()
	mv := master.view()
	sv := slave.view()
	cem1 := mv.frames.filter(it.id == 0x01)[0]
	assert cem1.errors == 0 && cem1.last.ours && origin_of(cem1.last) == 'TX-S'
	s12 := sv.frames.filter(it.id == lsm2.id)[0]
	assert s12.errors == 0 && s12.last.ours && origin_of(s12.last) == 'TX-S'
	// RSM is simulated by nobody: its frame goes unanswered at both ends
	assert mv.frames.filter(it.id == 0x22)[0].last.errs == Errs.no_response
}

fn test_a_header_that_did_not_go_out_leaves_nothing_behind() {
	mfd, path := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	mut m := open('pty:${path}', Config{ role: .master, src: .tester })!
	defer {
		m.close()
	}
	m.set_entry(Entry{ id: 0x10, dir: .publish, len: 2, data: [u8(1), 2] })!
	m.set_entry(Entry{ id: 0x12, dir: .publish, len: 2, data: [u8(5), 6], one_shot: true })!
	other := raw_open(path)
	defer {
		C.bl_ser_close(other)
	}
	fill(other)
	mut failed := false
	m.header(0x12) or { failed = true }
	assert failed
	empty(mfd)
	// the next header is matched to itself, not to the one that failed
	m.header(0x10)!
	f := got(mut m)
	assert f.id == 0x10 && f.ours && f.src == .tester && f.errs == Errs.zero(), reading(f)
	// and the one-shot entry is still there to answer
	m.header(0x12)!
	g := got(mut m)
	assert g.id == 0x12 && g.ours && g.data == [u8(5), 6], reading(g)
}

fn test_a_slave_that_could_not_answer_does_not_claim_the_frame() {
	mfd, path := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	mut s := open('pty:${path}', Config{ role: .slave, src: .sim })!
	defer {
		s.close()
	}
	s.set_entry(Entry{ id: 0x21, dir: .publish, len: 2, data: [u8(1), 2] })!
	other := raw_open(path)
	defer {
		C.bl_ser_close(other)
	}
	fill(other)
	hdr := pty_bytes(true, [u8(0x55), pid(0x21)])
	assert C.bl_ser_write(mfd, hdr.data, i32(hdr.len), 100) == 0
	f := got(mut s)
	assert f.errs == Errs.no_response && !f.ours && f.src == .remote, reading(f)
	mut failed := false
	s.wakeup() or { failed = true }
	assert failed
	empty(mfd)
	// another node's wakeup pulse is not this handle's
	assert C.bl_ser_write(mfd, [u8(0x00)].data, 1, 100) == 0
	w := got(mut s)
	assert w.event == .wakeup && !w.ours && w.src == .remote
}

fn test_bytes_waiting_in_the_port_are_decoded_before_a_header() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master, src: .tester })!
	defer {
		m.close()
	}
	peer := raw_open(link.b)
	defer {
		C.bl_ser_close(peer)
	}
	mut sb := serial(m)
	// another node's wakeup pulse reaches the port while this handle holds its lock
	sb.mu.lock()
	assert C.bl_ser_write(peer, [u8(0x00)].data, 1, 100) == 0
	time.sleep(30 * time.millisecond)
	sb.send_header(Wrote{ id: 0x10, src: .tester }, [u8(0x55), pid(0x10)]) or {
		sb.mu.unlock()
		panic(err)
	}
	sb.mu.unlock()
	w := got(mut m)
	assert w.event == .wakeup && !w.ours, reading(w)
	f := got(mut m)
	assert f.id == 0x10 && f.errs == Errs.no_response, reading(f)
}

fn test_a_stray_byte_does_not_hide_the_wakeup_after_it() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut mon := open('pty:${link.a}', Config{ role: .monitor })!
	defer {
		mon.close()
	}
	peer := raw_open(link.b)
	defer {
		C.bl_ser_close(peer)
	}
	assert C.bl_ser_write(peer, [u8(0x13)].data, 1, 100) == 0
	time.sleep(100 * time.millisecond)
	assert C.bl_ser_write(peer, [u8(0x00)].data, 1, 100) == 0
	w := mon.recv(500) or { panic('no wakeup: ${err}') }
	assert w.event == .wakeup
}

fn test_a_serial_rows_tester_frames_are_the_testers() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut r := start_row(RowSpec{
		name:     'M'
		address:  'pty:${link.a}'
		ldf:      serial_ldf
		role:     .master
		simulate: ['LSM']
	}, RowOpts{})!
	defer {
		r.stop()
	}
	mut t := r.tap()!
	r.header(0x22)!
	r.header(0x12)!
	r.wakeup()!
	mut seen := []string{}
	for seen.len < 3 {
		f := t.recv(1000)!
		seen << '${reading(f).all_before(' ')} ${origin_of(f)}'
	}
	// RSM's header nobody answers and the wakeup are the tester's; LSM's answer the simulation's
	assert seen == ['0x22 TX', '0x12 TX-S', 'wakeup TX']
}

fn test_a_closed_handle_lets_go_of_its_port() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master })!
	mut sb := serial(m)
	m.close()
	assert sb.fd == -1
	assert m.diagnostics().bus_errors == 0
}

fn test_a_header_waits_for_the_slot_before_it() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master, src: .tester })!
	mut s := open('pty:${link.b}', Config{ role: .slave, src: .sim })!
	defer {
		m.close()
		s.close()
	}
	s.set_entry(Entry{ id: 0x21, dir: .publish, len: 2, data: [u8(1), 2] })!
	s.set_entry(Entry{ id: 0x31, dir: .publish, len: 1, data: [u8(0xAA)], one_shot: true })!
	m.header(0x30)!
	m.wakeup()!
	m.header(0x21)!
	m.header(0x21)!
	m.header(0x31)!
	m.header(0x31)!
	mut seen := []string{}
	for seen.len < 6 {
		f := got(mut m)
		seen << reading(f).all_before(' cs')
	}
	assert seen == ['0x30 no response', 'wakeup', '0x21 [2] 01 02', '0x21 [2] 01 02', '0x31 [1] AA',
		'0x31 no response']
}

fn test_a_lost_port_ends_the_schedule() {
	mut link := pty_link()!
	mut r := start_row(RowSpec{
		name:     'M'
		address:  'pty:${link.a}'
		ldf:      serial_ldf
		role:     .master
		simulate: ['CEM']
		schedule: 'NormalTable'
	}, RowOpts{})!
	defer {
		r.stop()
	}
	time.sleep(50 * time.millisecond)
	link.close()
	for _ in 0 .. 100 {
		if !r.view().sched.running {
			break
		}
		time.sleep(30 * time.millisecond)
	}
	assert !r.view().sched.running
	mut gone := false
	r.header(0x01) or { gone = err is transport.CarrierGone }
	assert gone
}

fn test_a_response_longer_than_expected_reads_long() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master })!
	mut s := open('pty:${link.b}', Config{ role: .slave })!
	defer {
		m.close()
		s.close()
	}
	s.set_entry(Entry{ id: 0x21, dir: .publish, len: 4, data: [u8(1), 2, 3, 0xEF] })!
	m.set_entry(Entry{ id: 0x21, dir: .subscribe, len: 2 })!
	m.header(0x21)!
	f := got(mut m)
	assert f.errs.has(.long) && f.data == [u8(1), 2], reading(f)
	if g := m.recv(100) {
		assert false, 'a frame too many: ${reading(g)}'
	}
}

fn test_a_break_read_while_a_header_goes_out_does_not_take_it() {
	mfd, path := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	mut m := open('pty:${path}', Config{ role: .master, src: .tester })!
	defer {
		m.close()
	}
	e := Entry{
		id:   0x10
		dir:  .publish
		len:  2
		data: [u8(1), 2]
	}
	m.set_entry(e)!
	mut sb := serial(m)
	// another node's break reaches the port while this handle holds its lock to send a header
	sb.mu.lock()
	brk := [u8(0xFF), 0x00, 0x00]
	assert C.bl_ser_write(mfd, brk.data, 3, 100) == 0
	time.sleep(30 * time.millisecond)
	resp := response_bytes(0x10, e)
	mut bytes := [u8(0x55), pid(0x10)]
	bytes << resp
	sb.send_header(Wrote{ id: 0x10, bytes: resp, src: .tester, header: true }, bytes) or {
		sb.mu.unlock()
		panic(err)
	}
	sb.mu.unlock()
	w := got(mut m)
	assert w.event == .wakeup && !w.ours, reading(w)
	f := got(mut m)
	assert f.id == 0x10 && f.ours && f.header && f.src == .tester, reading(f)
}

fn test_a_one_shot_entry_is_read_by_its_own_length_after_it_is_used() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master })!
	defer {
		m.close()
	}
	// D7's enhanced checksum inverted is D7's classic checksum
	m.set_entry(Entry{
		id:       0x10
		dir:      .publish
		len:      1
		data:     [u8(0xD7)]
		one_shot: true
		inject:   .bad_checksum
	})!
	m.header(0x10)!
	f := got(mut m)
	assert f.errs == Errs.checksum && f.model == .enhanced, reading(f)
}

fn test_a_response_of_unknown_length_ends_with_its_slot() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut mon := open('pty:${link.a}', Config{ role: .monitor })!
	defer {
		mon.close()
	}
	peer := raw_open(link.b)
	defer {
		C.bl_ser_close(peer)
	}
	p := pid(0x22)
	frame := pty_bytes(true, [u8(0x55), p, 1, 2, checksum(.enhanced, p, [u8(1), 2])])
	assert C.bl_ser_write(peer, frame.data, i32(frame.len), 100) == 0
	time.sleep(20 * time.millisecond)
	assert C.bl_ser_write(peer, [u8(0x00)].data, 1, 100) == 0
	f := got(mut mon)
	assert f.id == 0x22 && f.data == [u8(1), 2] && f.errs == Errs.zero(), reading(f)
	assert got(mut mon).event == .wakeup
}

fn test_a_masterreq_with_a_bad_checksum_arms_nothing() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master, nad: 0x0A })!
	defer {
		m.close()
	}
	mut req := []u8{len: 8, init: 0xFF}
	req[0] = 0x0A
	m.set_entry(Entry{
		id:     master_req
		dir:    .publish
		len:    8
		model:  .classic
		data:   req
		inject: .bad_checksum
	})!
	m.set_entry(Entry{ id: slave_resp, dir: .publish, len: 8, data: []u8{len: 8, init: 0x55} })!
	m.header(master_req)!
	assert got(mut m).errs == Errs.checksum
	m.header(slave_resp)!
	f := got(mut m)
	assert f.errs == Errs.no_response, reading(f)
}

fn test_a_look_does_not_wait_for_the_lock() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master })!
	defer {
		m.close()
	}
	mut sb := serial(m)
	done := chan bool{cap: 1}
	sb.mu.lock()
	spawn fn [mut m, done] () {
		m.recv(0) or {}
		done <- true
	}()
	mut quick := false
	select {
		_ := <-done {
			quick = true
		}
		100 * time.millisecond {
		}
	}
	sb.mu.unlock()
	if !quick {
		_ := <-done
	}
	assert quick
}

fn test_a_lost_port_is_gone_before_what_it_queued() {
	mut link := pty_link()!
	mut mon := open('pty:${link.a}', Config{ role: .monitor })!
	defer {
		mon.close()
	}
	peer := raw_open(link.b)
	hdrs := pty_bytes(true, [u8(0x55), pid(0x10)])
	mut bytes := hdrs.clone()
	bytes << hdrs
	bytes << hdrs
	assert C.bl_ser_write(peer, bytes.data, i32(bytes.len), 100) == 0
	time.sleep(30 * time.millisecond)
	C.bl_ser_close(peer)
	link.close()
	time.sleep(100 * time.millisecond)
	mut gone := false
	mon.recv(0) or { gone = err is transport.CarrierGone }
	assert gone
}

fn test_a_flooded_port_still_closes() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut mon := open('pty:${link.a}', Config{ role: .monitor })!
	peer := raw_open(link.b)
	defer {
		C.bl_ser_close(peer)
	}
	stop := chan bool{cap: 1}
	// the writer is joined before peer closes: a write after that lands on whatever fd reuses
	// peer's number, a later test's pty
	writer := spawn fn [peer, stop] () {
		p := pid(0x21)
		one := pty_bytes(true, [u8(0x55), p, 1, 2, checksum(.enhanced, p, [u8(1), 2])])
		mut block := []u8{}
		for block.len < 4000 {
			block << one
		}
		for {
			select {
				_ := <-stop {
					return
				}
				else {
				}
			}
			C.bl_ser_write(peer, block.data, i32(block.len), 10)
		}
	}()
	time.sleep(100 * time.millisecond)
	t0 := time.now()
	mon.close()
	took := time.since(t0)
	stop <- true
	writer.wait()
	assert took < 100 * time.millisecond, '${took}'
}

fn test_two_wakeups_are_two_events() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master })!
	mut s := open('pty:${link.b}', Config{ role: .slave })!
	defer {
		m.close()
		s.close()
	}
	m.wakeup()!
	time.sleep(20 * time.millisecond)
	m.wakeup()!
	for _ in 0 .. 2 {
		f := got(mut m)
		assert f.event == .wakeup, reading(f)
		assert got(mut s).event == .wakeup
	}
}

fn test_a_header_from_elsewhere_is_not_a_masters_own() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master, src: .tester })!
	defer {
		m.close()
	}
	peer := raw_open(link.b)
	defer {
		C.bl_ser_close(peer)
	}
	hdr := pty_bytes(true, [u8(0x55), pid(0x30)])
	assert C.bl_ser_write(peer, hdr.data, i32(hdr.len), 100) == 0
	f := got(mut m)
	assert f.errs == Errs.no_response && !f.header && f.src == .remote, reading(f)
}

fn test_a_wakeup_is_not_written_over_one_unconfirmed() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut m := open('pty:${link.a}', Config{ role: .master })!
	mut s := open('pty:${link.b}', Config{ role: .slave })!
	defer {
		m.close()
		s.close()
	}
	m.wakeup()!
	m.wakeup()!
	for _ in 0 .. 2 {
		assert got(mut m).event == .wakeup
		assert got(mut s).event == .wakeup
	}
}

fn test_a_serial_master_times_external_frames_by_the_ldf() {
	mut link := pty_link()!
	defer {
		link.close()
	}
	mut slave := start_row(RowSpec{
		name:     'S'
		address:  'pty:${link.b}'
		ldf:      serial_ldf
		role:     .slave
		simulate: ['LSM', 'RSM']
	}, RowOpts{})!
	// FastTable gives the 2-byte LSM_Frm1 and RSM_Frm1 5 ms slots: an 8-byte window would
	// make each of them late
	mut master := start_row(RowSpec{
		name:     'M'
		address:  'pty:${link.a}'
		ldf:      serial_ldf
		role:     .master
		simulate: ['CEM']
		schedule: 'FastTable'
	}, RowOpts{})!
	mut t := master.tap()!
	// the gap from each RSM_Frm1 header to the LSM_Frm1 header after it: the slot is 5 ms, an
	// eight-byte window at 19200 baud 9 ms
	mut gaps := []i64{}
	mut prev := i64(-1)
	for gaps.len < 15 {
		f := t.recv(1000)!
		if f.id == 0x21 {
			prev = f.t_ns
		} else if f.id == 0x11 && prev >= 0 {
			gaps << f.t_ns - prev
			prev = -1
		}
	}
	master.stop()
	slave.stop()
	gaps.sort()
	assert gaps[gaps.len / 2] < 7_000_000, 'median gap ${gaps[gaps.len / 2]} ns'
}


// raw_read reads what fd has within ms.
fn raw_read(fd i32, ms int) []u8 {
	mut out := []u8{}
	mut buf := []u8{len: 256}
	deadline := time.now().add(ms * time.millisecond)
	for time.now() < deadline {
		n := C.bl_ser_read(fd, buf.data, i32(buf.len), 5)
		if n > 0 {
			out << buf[..n]
		}
	}
	return out
}

fn test_a_plain_pty_reads_frames_with_no_break_between_them() {
	mfd, slave := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	// a slave that publishes nothing reads as a monitor does, and takes the LDF's lengths
	mut mon := open('pty:${slave},plain', Config{ role: .slave })!
	defer {
		mon.close()
	}
	mon.set_entry(Entry{ id: 0x21, dir: .subscribe, len: 4, model: .classic })!
	p21 := pid(0x21)
	data := [u8(0xAA), 0xFF, 0x55, 0xDD]
	mut frame := [u8(0x55), p21]
	frame << data
	frame << checksum(.classic, p21, data)
	// a header nobody answers, then a frame of an id with no expectation, then the 0x21 frame
	frames_out := [[u8(0x55), pid(0x30)], [u8(0x55), pid(0x10), 1, 2,
		checksum(.enhanced, pid(0x10), [u8(1), 2])], frame]
	for bytes in frames_out {
		assert C.bl_ser_write(mfd, bytes.data, i32(bytes.len), 100) == 0
		time.sleep(30 * time.millisecond)
	}
	got3 := [got(mut mon), got(mut mon), got(mut mon)]
	assert got3.map(reading(it)) == ['0x30 no response',
		'0x10 [2] 01 02 cs 0x${checksum(.enhanced, pid(0x10), [u8(1), 2]):02X} enhanced',
		'0x21 [4] AA FF 55 DD cs 0x${frame.last():02X} classic']
	assert got3.all(it.src == .remote && !it.ours && !it.header)
}

fn test_a_plain_pty_slave_answers_in_plain_bytes() {
	mfd, slave := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	mut s := open('pty:${slave},plain', Config{ role: .slave, src: .sim })!
	defer {
		s.close()
	}
	s.set_entry(Entry{ id: 0x20, dir: .publish, len: 2, data: [u8(0xFF), 0x01] })!
	hdr := [u8(0x55), pid(0x20)]
	assert C.bl_ser_write(mfd, hdr.data, 2, 100) == 0
	cs := checksum(.enhanced, pid(0x20), [u8(0xFF), 0x01])
	// the master reads its response as it reads a UART: data and checksum, no marks
	assert raw_read(mfd, 30) == [u8(0xFF), 0x01, cs]
	f := got(mut s)
	assert reading(f) == '0x20 [2] FF 01 cs 0x${cs:02X} enhanced' && f.ours && f.src == .sim
}

fn test_a_plain_pty_master_writes_plain_bytes() {
	mfd, slave := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	mut m := open('pty:${slave},plain', Config{ role: .master, src: .tester })!
	defer {
		m.close()
	}
	m.set_entry(Entry{ id: 0x10, dir: .publish, len: 2, data: [u8(0xFF), 0x12] })!
	m.header(0x10)!
	cs := checksum(.enhanced, pid(0x10), [u8(0xFF), 0x12])
	assert raw_read(mfd, 30) == [u8(0x55), pid(0x10), 0xFF, 0x12, cs]
	f := got(mut m)
	assert reading(f) == '0x10 [2] FF 12 cs 0x${cs:02X} enhanced' && f.ours && f.header
}

fn test_a_pty_path_is_read_from_the_file_a_program_writes_it_in() {
	mfd, slave := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	file := os.join_path(os.temp_dir(), 'lin_slave_${os.getpid()}')
	os.write_file(file, '${slave}\n')!
	defer {
		os.rm(file) or {}
	}
	mut mon := open('pty:${file},plain', Config{ role: .monitor })!
	defer {
		mon.close()
	}
	// the device, not the file, is what is open once in this process
	mut refused := ''
	open('pty:${slave}', Config{ role: .monitor }) or { refused = err.msg() }
	assert refused.contains('is already open'), refused
	bytes := [u8(0x55), pid(0x30)]
	assert C.bl_ser_write(mfd, bytes.data, 2, 100) == 0
	assert reading(got(mut mon)) == '0x30 no response'
	os.write_file(file, '\n')!
	mut empty_why := ''
	device_path(parse_serial('pty:${file}')!) or { empty_why = err.msg() }
	assert empty_why.contains('names no device'), empty_why
}

fn test_a_plain_pty_splits_frames_that_came_in_one_read_and_waits_for_a_late_response() {
	mfd, slave := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	mut s := open('pty:${slave},plain', Config{ role: .slave })!
	defer {
		s.close()
	}
	s.set_entry(Entry{ id: 0x10, dir: .subscribe, len: 2 })!
	s.set_entry(Entry{ id: 0x11, dir: .subscribe, len: 1 })!
	cs10 := checksum(.enhanced, pid(0x10), [u8(1), 2])
	cs11 := checksum(.enhanced, pid(0x11), [u8(7)])
	// two whole frames in one write: the first ends at its length
	two := [u8(0x55), pid(0x10), 1, 2, cs10, 0x55, pid(0x11), 7, cs11]
	assert C.bl_ser_write(mfd, two.data, i32(two.len), 100) == 0
	assert reading(got(mut s)) == '0x10 [2] 01 02 cs 0x${cs10:02X} enhanced'
	assert reading(got(mut s)) == '0x11 [1] 07 cs 0x${cs11:02X} enhanced'
	// a response 4 ms behind its header: past the quiet, within an 8-byte frame's 9 ms slot
	s.set_entry(Entry{ id: 0x20, dir: .subscribe, len: 8 })!
	data := []u8{len: 8, init: u8(index)}
	cs20 := checksum(.enhanced, pid(0x20), data)
	time.sleep(30 * time.millisecond)
	hdr := [u8(0x55), pid(0x20)]
	assert C.bl_ser_write(mfd, hdr.data, 2, 100) == 0
	time.sleep(4 * time.millisecond)
	mut resp := data.clone()
	resp << cs20
	assert C.bl_ser_write(mfd, resp.data, i32(resp.len), 100) == 0
	late := got(mut s)
	assert reading(late) == '0x20 [8] 00 01 02 03 04 05 06 07 cs 0x${cs20:02X} enhanced', reading(late)
}

fn test_a_pty_path_file_older_than_its_device_is_refused() {
	file := os.join_path(os.temp_dir(), 'lin_stale_${os.getpid()}')
	os.write_file(file, '/dev/pts/0\n')!
	defer {
		os.rm(file) or {}
	}
	// written long before any pty there was made
	os.utime(file, 1_000_000, 1_000_000)!
	mfd, slave := raw_pty()
	defer {
		C.bl_ser_close(mfd)
	}
	os.write_file(file, '${slave}\n')!
	os.utime(file, 1_000_000, 1_000_000)!
	mut why := ''
	device_path(parse_serial('pty:${file},plain')!) or { why = err.msg() }
	assert why.contains('was written before'), why
	// a tty address never reads a file
	assert device_path(parse_serial('tty:${file}')!)! == file
}
