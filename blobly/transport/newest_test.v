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
	mut v := watch_newest(open('inproc:NEWEST_A') or { panic(err) })
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
	mut v := watch_newest(open('inproc:NEWEST_B') or { panic(err) })
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
	// padded by the bus it went out on: still its echo
	v.keep(CanFrame{ ...f, data: [u8(1), 2, 0], fd: true }, 5, 5)
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
	mut v := watch_newest(inner)
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
	mut v := watch_newest(open('inproc:NEWEST_E') or { panic(err) })
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
