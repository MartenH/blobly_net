module main

import transport
import time

fn test_start_and_restart_prepare_the_real_transmit_plan() {
	iface := 'inproc:tx-health-start'
	wire := transport.wire_key(iface)
	mut app := &App{
		// A generator can target a wire with no channel row or monitor.
		senders: [SenderRT{ iface: iface, tgt: iface }]
	}
	mut tool := app.open_tap_phys(iface, iface, org_tx, '', 0, false) or { panic(err) }
	defer { tool.close() }
	for gen in [u64(1), 2] {
		app.start()
		app.mu.lock()
		started := app.running && app.run_gen == gen
		expected := app.tx_health.wires[wire] or { panic('Start did not prepare its wire') }
		app.mu.unlock()
		assert started
		assert expected.gen == gen
		deadline := time.ticks() + 5000
		mut ready := false
		for time.ticks() < deadline {
			app.mu.lock()
			ready = app.transmit_ready_locked(wire)
			app.mu.unlock()
			if ready {
				break
			}
			time.sleep(time.millisecond)
		}
		assert ready
		tool.send(transport.CanFrame{ id: 0x123, data: [u8(1)] }) or { panic(err) }
		app.stop()
		app.wait_for_run_workers()
		assert app.runtime_census().readers == 0
	}
}

fn test_spawning_monitor_needs_a_health_claim_until_a_receiver_opens() {
	iface := 'inproc:tx-health-spawning'
	wire := transport.wire_key(iface)
	mut app := &App{
		running: true
		run_gen: 1
		chans: [Chan{ iface: iface, mode: 'normal', enabled: true, spawning: true }]
	}
	app.expect_tx_health_locked(1)
	assert !app.transmit_ready_locked(wire)
	mut tap := app.open_tap_phys(iface, iface, org_tx, '', 1, false) or { panic(err) }
	app.file_tap(tx_bus_key('', iface), mut tap, 1)
	app.mu.lock()
	claimed := !app.tx_health.may_claim_now(wire, 1)
	app.chans[0].enabled = false
	app.running = false
	app.mu.unlock()
	app.drop_unwanted_taps('', iface)
	assert claimed, 'spawning must not suppress the first health-reader claim'
	app.wait_for_run_workers()
}

fn test_surviving_tool_waits_before_new_run_taps_are_filed() {
	iface := 'inproc:tx-health-surviving-tool'
	wire := transport.wire_key(iface)
	mut app := &App{
		run_gen: 1
		chans: [Chan{ iface: iface, mode: 'off', enabled: true }]
	}
	mut peer := transport.open(iface) or { panic(err) }
	defer { peer.close() }
	mut tool := app.open_tap_phys(iface, iface, org_tx, '', 0, false) or { panic(err) }
	defer { tool.close() }
	app.tx_health.claim(wire, 1)
	app.tx_health.opened(wire, 1)
	app.run_gen = 2
	app.expect_tx_health_locked(2)
	app.running = true
	assert app.tx_buses.len == 0, 'the new run has not filed its taps yet'
	frame := transport.CanFrame{ id: 0x321, data: [u8(0x24)] }
	if _ := tool.send(frame) {
		assert false, "a guardless tool must not reuse its previous run's readiness"
	}
	assert app.tx_count == 0
	if _ := peer.recv(0) {
		assert false, 'no early frame may reach the driver'
	}
	app.tx_health.claim(wire, 2)
	app.tx_health.opened(wire, 2)
	tool.send(frame) or { panic(err) }
	got := peer.recv(1000) or { panic(err) }
	assert got.id == frame.id
}

fn test_an_open_monitor_covers_a_pending_health_claim() {
	iface := 'inproc:tx-health-monitored'
	wire := transport.wire_key(iface)
	mut app := &App{
		running: true
		run_gen: 1
		chans: [Chan{ iface: iface, mode: 'normal', enabled: true, spawning: true }]
	}
	app.expect_tx_health_locked(1)
	assert !app.transmit_ready_locked(wire)
	app.chans[0].running = true
	assert app.transmit_ready_locked(wire)
	app.chans[0].running = false
	assert !app.transmit_ready_locked(wire)
}

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
