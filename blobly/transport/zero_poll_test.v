module transport

import net
import time

// The one rule every backend applies after it skips a filtered record — and the only test that
// reaches it for the drivers no CI runner loads (Kvaser, Vector, PCAN).
fn test_look_again_is_the_callers_wait_and_a_bounded_look_at_zero() {
	// forever is forever
	assert look_again(-1, 1_000_000, 1_000_000_000_000)
	// a positive wait lasts exactly as long as it was asked to
	assert look_again(200, 1, 199_999_999)
	assert !look_again(200, 1, 200_000_000)
	// a zero-timeout look skips what is queued, within the count and the time bound
	assert look_again(0, 1, 0)
	assert look_again(0, zero_poll_skip_limit - 1, zero_poll_budget_ns - 1)
	assert !look_again(0, zero_poll_skip_limit, 0)
	assert !look_again(0, 1, zero_poll_budget_ns)
}

// recv(0) on an empty in-process bus answers at once, and returns what is queued.
fn test_inproc_zero_receive_is_a_look() {
	mut rx := open_inproc('zero_poll_inproc')!
	mut tx := open_inproc('zero_poll_inproc')!
	defer {
		rx.close()
		tx.close()
	}
	t0 := time.ticks()
	for _ in 0 .. 100 {
		if _ := rx.recv(0) {
			assert false, 'a frame from nowhere'
		}
	}
	assert time.ticks() - t0 < 80, '100 looks at an empty bus took ${time.ticks() - t0} ms'
	tx.send(CanFrame{ id: 0x42 })!
	assert rx.recv(0)!.id == 0x42
}

// What a re-reading backend (Kvaser) waits on its next read.
fn test_read_wait_is_what_is_left_and_nothing_once_spent() {
	assert read_wait_ms(-1, 3, 999_000_000, 200)? == 200 // forever, in slices
	assert read_wait_ms(0, 7, 999_000_000, 200)? == 0 // a look stays a look
	assert read_wait_ms(50, 0, 999_000_000, 200)? == 50 // the first read gets the whole wait
	assert read_wait_ms(50, 1, 20_000_000, 200)? == 30 // a retry gets what is left
	if w := read_wait_ms(50, 1, 50_000_000, 200) {
		assert false, 'a spent wait read again for ${w} ms'
	}
}

// A caller's timeout arms the wait as given; 0 is a look at what is queued — here a listener with
// nothing to accept, then one with a connection waiting.
fn test_socket_wait_is_the_timeout_and_a_look_at_zero() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { l.close() or {} }
	assert socket_wait(l.sock.handle, 250) or { 0 } == 250 * time.millisecond
	assert socket_wait(l.sock.handle, 0) == none, 'nothing to accept, yet the look armed a wait'
	addr := l.addr() or { panic(err) }
	mut c := net.dial_tcp(addr.str()) or { panic(err) }
	defer { c.close() or {} }
	time.sleep(20 * time.millisecond)
	assert socket_wait(l.sock.handle, 0) or { 0 } == time.millisecond, 'a queued connection was not seen'
}
