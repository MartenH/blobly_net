module sim

import time
import blobly.candb
import blobly.player
import blobly.transport

fn ten_ms_engine() Engine {
	return Engine{
		ecus: [
			SimEcu{
				name:     'Node'
				messages: [
					SimMessage{
						msg:       candb.Message{
							id:   0x123
							name: 'Fast'
							dlc:  8
						}
						period_ms: 10
					},
				]
			},
		]
	}
}

fn test_recv_wait_is_bounded_by_the_next_due_message() {
	mut e := ten_ms_engine()
	assert e.next_due_ms()? == 0
	assert e.recv_wait_ms(0) == 0, 'a message already due is not waited for'
	e.due_frames(0)
	assert e.next_due_ms()? == 10
	assert e.recv_wait_ms(7.5) == 3, 'rounded up, so the next pass finds it due'
	assert e.recv_wait_ms(1) == loop_wait_ms
	assert Engine{}.recv_wait_ms(0) == loop_wait_ms, 'nothing cyclic: the loop bound alone'
}

fn test_wait_until() {
	assert wait_until(10, 12, 8) == 0
	assert wait_until(10, 7, 8) == 3
	assert wait_until(30, 7, 8) == 8
}

struct LoopRun {
mut:
	engine Engine
	bus    transport.Bus
}

fn (mut l LoopRun) run(ms int) {
	t0 := time.sys_mono_now()
	for since_ms(t0) < f64(ms) {
		serve_pass(mut l.engine, mut l.bus, t0, 'inproc:sim_loop_cadence', 'Loop')
	}
}

fn test_a_10_ms_message_is_sent_about_100_times_a_second() {
	// the 1 ms timer period every front end asks for at startup (Windows; nothing elsewhere)
	player.raise_timer_resolution()
	mut mon := transport.open('inproc:sim_loop_cadence')!
	mut l := &LoopRun{
		engine: ten_ms_engine()
		bus:    transport.open('inproc:sim_loop_cadence')!
	}
	th := spawn l.run(1000)
	mut n := 0
	until := time.sys_mono_now() + 1_300_000_000
	for time.sys_mono_now() < until {
		f := mon.recv(20) or { continue }
		if f.id == 0x123 {
			n++
		}
	}
	th.wait()
	l.bus.close()
	mon.close()
	// slots 0, 10 .. 990 (1000 at most); on Windows the 15.6 ms tick as the clock sends about 64
	assert n >= 80 && n <= 101, '${n} frames of a 10 ms message in 1 s'
}
