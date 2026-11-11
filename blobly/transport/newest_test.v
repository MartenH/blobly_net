module transport

import sync
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
	mut v := new_newest('inproc:T')
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
	mut v := new_newest('inproc:T')
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
	new_newest('inproc:T').settle() // no reader: nothing to wait for
}

fn test_an_echo_is_the_payload_sent_or_its_fd_padding_and_nothing_longer() {
	mut v := new_newest('inproc:T')
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
	assert echoes_own_sends('inproc:X') && new_newest('inproc:T').hears_sends
}

// QueuedBus spends every waiting receive's budget and answers it with a timeout, as a backend
// skipping error records does with a data frame still queued; a zero look takes the frame.
struct QueuedBus {
mut:
	mu     sync.Mutex
	queued []CanFrame
}

fn (mut b QueuedBus) send(f CanFrame) ! {
	b.mu.lock()
	b.queued << f
	b.mu.unlock()
}

fn (mut b QueuedBus) recv(timeout_ms int) !CanFrame {
	if timeout_ms > 0 {
		time.sleep(timeout_ms * time.millisecond)
		return error('timeout')
	}
	b.mu.lock()
	defer {
		b.mu.unlock()
	}
	if b.queued.len == 0 {
		return error('timeout')
	}
	f := b.queued[0]
	b.queued.delete(0)
	return f
}

fn (mut b QueuedBus) close() {}

fn (mut b QueuedBus) health() BusHealth {
	return .unknown
}

fn (mut b QueuedBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b QueuedBus) error_counters() ErrorCounters {
	return ErrorCounters{}
}

fn (mut b QueuedBus) reconcile_silence(_ bool) ! {}

fn test_a_settle_looks_at_the_queue_after_a_receive_that_timed_out() {
	mut qb := &QueuedBus{}
	mut v := watch_newest(Bus(qb), 'inproc:T')
	defer {
		v.close()
	}
	for i in 0 .. 20 {
		qb.send(CanFrame{ id: 0x40, data: [u8(i)] })!
		v.settle()
		f := v.get(0x40, false) or { panic('a queued frame was not kept before the settle answered') }
		assert f.frame.data == [u8(i)]
	}
}

fn test_an_echo_is_also_the_frame_as_the_backend_clamps_it() {
	mut v := new_newest('vcan0')
	twelve := CanFrame{
		id:   0x810
		data: []u8{len: 12, init: u8(index)}
	}
	v.sending(twelve, 0)
	v.keep(CanFrame{ id: 0x010, data: twelve.data[..8].clone() }, 1, 1)
	assert v.get(0x010, false) == none, 'the clamped echo of a send was kept'
	v.keep(CanFrame{ id: 0x010, data: twelve.data[..8].clone() }, 2, 2)
	assert v.get(0x010, false) != none, 'a peer frame after the echo was not kept'
	mut sw := new_newest('inproc:T')
	sw.sending(twelve, 0)
	sw.keep(CanFrame{ id: 0x010, data: twelve.data[..8].clone() }, 1, 1)
	assert sw.get(0x010, false) != none, 'a software bus carries the frame as given'
}
