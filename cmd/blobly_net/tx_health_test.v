module main

import transport
import time

// Exercise the actual send boundary, without starting a GUI or touching hardware.
// A bus attached before readiness must see no frame, and the trace must not claim one.
fn test_transmit_waits_for_health_receive_readiness() {
	iface := 'inproc:tx-health-readiness'
	mut app := &App{
		running: true
		run_gen: 1
	}
	mut peer := transport.open(iface) or { panic(err) }
	defer { peer.close() }
	mut tap := app.open_tap_phys(iface, iface, org_tx, '', 1, false) or { panic(err) }
	defer { tap.close() }
	wire := transport.wire_key(iface)
	app.tx_health.claim(wire, 1)
	frame := transport.CanFrame{ id: 0x123, data: [u8(0x42)] }
	if _ := tap.send(frame) {
		assert false, 'a claimed worker has not opened a receive queue yet'
	} else {
		assert err.msg().contains('waiting for the bus-health reader')
	}
	assert app.tx_count == 0
	assert app.trace.len == 0
	if _ := peer.recv(0) {
		assert false, 'the driver must not receive an early send'
	}
	app.tx_health.opened(wire, 1)
	tap.send(frame) or { panic(err) }
	got := peer.recv(1000) or { panic(err) }
	assert got.id == frame.id && got.data == frame.data
	assert app.tx_count == 1
	assert app.trace.len == 1
}

fn test_filed_tap_gets_a_reader_that_leaves_when_the_tap_does() {
	iface := 'inproc:tx-health-lifecycle'
	mut app := &App{
		running: true
		run_gen: 1
	}
	mut tap := app.open_tap_phys(iface, iface, org_tx, '', 1, false) or { panic(err) }
	app.file_tap(tx_bus_key('', iface), mut tap, 1)
	// A generous hang-breaker, not a claim about how quickly the scheduler runs.
	deadline := time.ticks() + 5000
	mut ready := false
	for time.ticks() < deadline {
		app.mu.lock()
		ready = app.tx_health.send_ready(transport.wire_key(iface), 1)
		app.mu.unlock()
		if ready {
			break
		}
		time.sleep(time.millisecond)
	}
	assert ready, 'the real receive worker must publish its open handle'
	app.drop_unwanted_taps('', iface)
	mut drained := false
	drain_deadline := time.ticks() + 5000
	for time.ticks() < drain_deadline {
		app.mu.lock()
		drained = app.run_workers == 0
		app.mu.unlock()
		if drained {
			break
		}
		time.sleep(time.millisecond)
	}
	assert drained, 'removing the last tap must close its reader and release the worker'
	app.mu.lock()
	assert app.tx_health.may_claim(transport.wire_key(iface), 1)
	app.running = false
	app.mu.unlock()
}
