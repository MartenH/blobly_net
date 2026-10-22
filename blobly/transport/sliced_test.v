module transport

import time

// Answers is a bus whose every receive returns at once: a frame after `frames_after` calls, else
// the error it is given (a 'timeout' that did not wait, or a failure).
struct Answers {
mut:
	calls        int
	frames_after int    = -1
	fail         string = 'timeout'
}

fn (mut b Answers) send(frame CanFrame) ! {}

fn (mut b Answers) recv(timeout_ms int) !CanFrame {
	b.calls++
	if b.frames_after >= 0 && b.calls > b.frames_after {
		return CanFrame{
			id: 0x42
		}
	}
	return error(b.fail)
}

fn (mut b Answers) close() {}

fn (mut b Answers) health() BusHealth {
	return .unknown
}

fn (mut b Answers) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b Answers) reconcile_silence(_ bool) ! {}

fn never() bool {
	return false
}

// A bus answering 'timeout' without waiting costs one call per slice, not a core (#401).
fn test_a_timeout_that_did_not_wait_is_waited_out() {
	mut a := &Answers{}
	mut bus := Bus(a)
	t0 := time.ticks()
	if _ := recv_sliced(mut bus, 100, 20, never) {
		assert false, 'a frame from nowhere'
	} else {
		assert err.msg() == 'timeout'
	}
	el := time.ticks() - t0
	assert el >= 100 && el < 1000, 'returned after ${el} ms'
	assert a.calls <= 7, '${a.calls} calls in 100 ms of 20 ms slices: a spin'
}

// Any other error ends the receive with that error, at once.
fn test_a_failing_bus_ends_the_receive() {
	mut a := &Answers{
		fail: 'bus is closed'
	}
	mut bus := Bus(a)
	t0 := time.ticks()
	if _ := recv_sliced(mut bus, -1, 20, never) {
		assert false
	} else {
		assert err.msg() == 'bus is closed'
	}
	assert a.calls == 1 && time.ticks() - t0 < 500
}

// A stop ends it with the stop code, so each caller says it in its own words; a frame is
// returned as it comes.
fn test_stop_and_frame() {
	mut a := &Answers{}
	mut bus := Bus(a)
	if _ := recv_sliced(mut bus, -1, 20, fn () bool {
		return true
	})
	{
		assert false
	} else {
		assert err.code() == sliced_stop_code
	}
	mut b := &Answers{
		frames_after: 2
	}
	mut bus2 := Bus(b)
	f := recv_sliced(mut bus2, 1000, 5, never)!
	assert f.id == 0x42 && b.calls == 3
}

// Zero is one look, as Bus.recv(0) is: one call, at once, and a stop is not asked.
fn test_zero_is_one_look() {
	mut a := &Answers{}
	mut bus := Bus(a)
	t0 := time.ticks()
	if _ := recv_sliced(mut bus, 0, 20, fn () bool {
		return true
	})
	{
		assert false
	} else {
		assert err.msg() == 'timeout'
	}
	assert a.calls == 1 && time.ticks() - t0 < 50
}
