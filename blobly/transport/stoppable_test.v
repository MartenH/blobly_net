module transport

import sync.stdatomic
import time

@[heap]
struct SlowOpenCount {
mut:
	closes i64
}

struct SlowOpenBus {
	ctl &SlowOpenCount
}

fn (mut b SlowOpenBus) send(frame CanFrame) ! {}

fn (mut b SlowOpenBus) recv(timeout_ms int) !CanFrame {
	return error('timeout')
}

fn (mut b SlowOpenBus) close() {
	stdatomic.add_i64(&b.ctl.closes, 1)
}

fn (mut b SlowOpenBus) health() BusHealth {
	return .unknown
}

fn (mut b SlowOpenBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b SlowOpenBus) reconcile_silence(want bool) ! {}

fn slow_opener(ms int, ctl &SlowOpenCount) fn () !Bus {
	return fn [ms, ctl] () !Bus {
		time.sleep(ms * time.millisecond)
		return Bus(&SlowOpenBus{
			ctl: ctl
		})
	}
}

// a stop ends the wait for a slow open within a poll, and the open that lands later is closed
fn test_a_stop_ends_a_slow_open_and_the_late_bus_is_closed() {
	ctl := &SlowOpenCount{}
	at := time.ticks() + 50
	sw := time.new_stopwatch()
	mut why := 'opened'
	open_stoppable(slow_opener(400, ctl), fn [at] () bool {
		return time.ticks() >= at
	}) or { why = err.msg() }
	assert why == open_stopped_note, why
	assert sw.elapsed().milliseconds() < 200, 'the stop waited for the open'
	for _ in 0 .. 100 {
		if stdatomic.load_i64(&ctl.closes) > 0 {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert stdatomic.load_i64(&ctl.closes) == 1, 'the late bus was leaked'
}

// unstopped, the open's bus and its error both come back as they were
fn test_an_unstopped_open_returns_its_bus_or_its_error() {
	ctl := &SlowOpenCount{}
	never := fn () bool {
		return false
	}
	mut b := open_stoppable(slow_opener(30, ctl), never) or {
		assert false, 'open: ${err}'
		return
	}
	b.close()
	assert stdatomic.load_i64(&ctl.closes) == 1
	failing := fn () !Bus {
		return error('no such device')
	}
	mut why := ''
	open_stoppable(failing, never) or { why = err.msg() }
	assert why == 'no such device'
	open_stoppable(failing, unsafe { nil }) or { why = 'nil: ' + err.msg() }
	assert why == 'nil: no such device'
}
