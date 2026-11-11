module transport

import time

fn newest_wait(mut v NewestView, id u32, ext ?bool, data []u8) ?NewestFrame {
	deadline := time.sys_mono_now() + 2 * time.second
	for time.sys_mono_now() < deadline {
		if f := v.get(id, ext) {
			if f.frame.data == data {
				return f
			}
		}
		time.sleep(time.millisecond)
	}
	return none
}

fn test_the_reader_keeps_the_newest_frame_per_id_and_kind_while_nobody_reads() {
	mut script := metered(open('inproc:NEWEST_A') or { panic(err) }, 'inproc:NEWEST_A', 500000, 0)
	mut v := watch_newest(open('inproc:NEWEST_A') or { panic(err) }, 'inproc:NEWEST_A')
	script.view = v
	mut other := open('inproc:NEWEST_A') or { panic(err) }
	defer {
		v.close()
		script.close()
		other.close()
	}
	assert v.get(0x123, none) == none
	other.send(CanFrame{ id: 0x123, data: [u8(1)] })!
	other.send(CanFrame{ id: 0x123, data: [u8(2)] })!
	newest_wait(mut v, 0x123, false, [u8(2)]) or { panic('the newest 11-bit frame never came') }
	other.send(CanFrame{ id: 0x123, extended: true, data: [u8(3)] })!
	newest_wait(mut v, 0x123, none, [u8(3)]) or { panic('either kind: the newer') }
	f := v.get(0x123, false) or { panic('kept') }
	assert f.frame.data == [u8(2)]
	assert f.t_ns > 0 && f.t_ns <= i64(time.sys_mono_now())
	// a remote frame asks for the data and carries none
	v.keep(CanFrame{ id: 0x123, rtr: true }, i64(time.sys_mono_now()), i64(time.sys_mono_now()))
	g := v.get(0x123, false) or { panic('kept') }
	assert g.frame.data == [u8(2)] && !g.frame.rtr
	other.send(CanFrame{ id: 0x124, data: [u8(9)] })!
	newest_wait(mut v, 0x124, false, [u8(9)]) or { panic('later frame') }
	v.clear()
	assert v.get(0x124, none) == none
	assert v.failure() == ''
}

fn test_what_the_script_sends_is_not_kept_but_a_peer_frame_after_it_is() {
	mut script := metered(open('inproc:NEWEST_B') or { panic(err) }, 'inproc:NEWEST_B', 500000, 0)
	mut v := watch_newest(open('inproc:NEWEST_B') or { panic(err) }, 'inproc:NEWEST_B')
	script.view = v
	mut other := open('inproc:NEWEST_B') or { panic(err) }
	defer {
		v.close()
		script.close()
		other.close()
	}
	script.send(CanFrame{ id: 0x200, data: [u8(7)] })!
	other.send(CanFrame{ id: 0x201, data: [u8(1)] })!
	newest_wait(mut v, 0x201, false, [u8(1)]) or { panic('peer frame') }
	assert v.get(0x200, none) == none, 'the script heard its own send'
	other.send(CanFrame{ id: 0x200, data: [u8(7)] })!
	newest_wait(mut v, 0x200, false, [u8(7)]) or { panic('an identical frame of a peer') }
}

fn test_an_echo_takes_its_note_once_and_notes_expire() {
	mut v := new_newest()
	f := CanFrame{
		id:   0x10
		data: [u8(1), 2]
	}
	v.sending(f, 0)
	v.keep(f, 5, 5)
	assert v.get(0x10, none) == none
	v.keep(f, 6, 6)
	assert (v.get(0x10, none) or { panic('kept') }).t_ns == 6
	v.clear()
	v.sending(f, 10)
	v.keep(f, 11 + newest_echo_ns, 11 + newest_echo_ns)
	assert v.get(0x10, none) != none, 'an expired note claims nothing'
	v.clear()
	tok := v.sending(f, 20)
	v.unsent(tok)
	v.keep(f, 21, 21)
	assert v.get(0x10, none) != none, 'a send that failed has no echo'
}

fn test_a_failed_send_takes_back_its_note() {
	mut script := metered(open('inproc:NEWEST_C') or { panic(err) }, 'inproc:NEWEST_C', 500000, 0)
	mut v := new_newest()
	script.view = v
	defer {
		script.close()
	}
	// a classic frame past 8 bytes: refused before it reaches the wire
	f := CanFrame{
		id:   0x300
		data: []u8{len: 9}
	}
	if _ := script.send(f) {
		assert false, 'a software bus refuses it'
	}
	v.keep(f, 1, 1)
	assert v.get(0x300, false) != none
}

fn test_a_closed_view_handle_says_why() {
	mut inner := open('inproc:NEWEST_D') or { panic(err) }
	mut v := watch_newest(inner, 'inproc:NEWEST_D')
	inner.close()
	deadline := time.sys_mono_now() + 2 * time.second
	for v.failure() == '' && time.sys_mono_now() < deadline {
		time.sleep(time.millisecond)
	}
	assert v.failure() != ''
	v.close()
	v.close()
}

fn test_a_settle_answers_as_of_the_call() {
	mut v := watch_newest(open('inproc:NEWEST_E') or { panic(err) }, 'inproc:NEWEST_E')
	mut other := open('inproc:NEWEST_E') or { panic(err) }
	defer {
		v.close()
		other.close()
	}
	for i in 0 .. 200 {
		other.send(CanFrame{ id: 0x400, data: [u8(i)] })!
		v.settle()
		f := v.get(0x400, false) or { panic('a frame sent before the settle was not kept') }
		assert f.frame.data == [u8(i)]
	}
	// a quiet wire: one slice at most
	t0 := time.sys_mono_now()
	v.settle()
	assert time.sys_mono_now() - t0 < u64(newest_settle_ms) * u64(time.millisecond)
	new_newest().settle() // no reader: nothing to wait for
}

fn test_an_echo_is_the_payload_sent_or_its_fd_padding_and_nothing_longer() {
	mut v := new_newest()
	empty := CanFrame{
		id: 0x20
	}
	v.sending(empty, 0)
	v.keep(CanFrame{ ...empty, data: [u8(1), 2, 3] }, 1, 1)
	assert v.get(0x20, none) != none, 'a send of nothing claimed a longer peer frame'
	v.clear()
	f := CanFrame{
		id:   0x21
		data: [u8(1), 2]
	}
	v.sending(f, 2)
	v.keep(CanFrame{ ...f, data: [u8(1), 2, 3] }, 3, 3)
	assert v.get(0x21, none) != none, 'a classic frame that starts with the payload sent is a peer frame'
	v.clear()
	nine := CanFrame{
		id:   0x22
		data: []u8{len: 9, init: 7}
	}
	v.sending(nine, 4)
	mut padded := nine.data.clone()
	padded << [u8(0), 0, 5]
	v.keep(CanFrame{ ...nine, fd: true, data: padded }, 5, 5)
	assert v.get(0x22, none) != none, 'padding that is not zero is not padding'
	v.keep(CanFrame{ ...nine, fd: true, data: fd_pad(nine.data) }, 6, 6)
	assert (v.get(0x22, none) or { panic('kept') }).t_ns == 5, 'the padded echo was kept'
}

fn test_a_send_the_view_handle_will_not_hear_is_not_noted() {
	mut v := &NewestView{}
	f := CanFrame{
		id:   0x30
		data: [u8(4)]
	}
	assert v.sending(f, 0) == 0
	v.keep(f, 1, 1)
	assert v.get(0x30, none) != none, 'a peer frame was taken for the echo of a send nobody hears'
	assert echoes_own_sends('inproc:X') && new_newest().hears_sends
}

// TimeoutBus answers its first receive with a timeout after a settle was asked behind its back,
// and its second with the frame queued meanwhile, noting how far settles were answered by then.
struct TimeoutBus {
mut:
	view     &NewestView = unsafe { nil }
	calls    int
	asked    u64
	answered u64
	seen     bool
}

fn (mut b TimeoutBus) send(_ CanFrame) ! {}

fn (mut b TimeoutBus) recv(_ int) !CanFrame {
	b.calls++
	if b.calls == 1 {
		b.view.mu.lock()
		b.view.asked++
		b.asked = b.view.asked
		b.view.mu.unlock()
		return error('timeout')
	}
	if b.calls == 2 {
		b.answered = b.view.answered_now()
		b.seen = true
		return CanFrame{
			id:   0x40
			data: [u8(1)]
		}
	}
	time.sleep(time.millisecond)
	return error('timeout')
}

fn (mut b TimeoutBus) close() {}

fn (mut b TimeoutBus) health() BusHealth {
	return .unknown
}

fn (mut b TimeoutBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b TimeoutBus) error_counters() ErrorCounters {
	return ErrorCounters{}
}

fn (mut b TimeoutBus) reconcile_silence(_ bool) ! {}

fn test_a_timeout_answers_only_the_settles_asked_before_its_receive() {
	mut tb := &TimeoutBus{}
	bus := Bus(tb)
	mut v := &NewestView{
		bus: bus
	}
	tb.view = v
	v.reader = spawn v.read()
	defer {
		v.close()
	}
	deadline := time.sys_mono_now() + 2 * time.second
	for !tb.seen && time.sys_mono_now() < deadline {
		time.sleep(time.millisecond)
	}
	assert tb.seen
	assert tb.answered < tb.asked, 'a settle asked after the receive looked was answered by its timeout'
}
