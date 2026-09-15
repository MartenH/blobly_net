module main

import transport
import time

fn test_health_observation_never_gates_transmission_and_workers_stop() {
	iface := 'inproc:health-observer'
	mut app := &App{ running: true, run_gen: 1 }
	mut tap := app.open_tap_phys(iface, iface, org_tx, '', 1, false) or { panic(err) }
	defer { tap.close() }
	mut peer := transport.open(iface) or { panic(err) }
	defer { peer.close() }
	app.tx_buses[tx_bus_key('', iface)] = tap
	// No health worker exists yet: the ordinary transmit path must still work.
	tap.send(transport.CanFrame{ id: 0x123, data: [u8(42)] }) or { panic(err) }
	got := peer.recv(200) or { panic(err) }
	assert got.data == [u8(42)]
	app.reserve_run_worker()
	spawn tx_health_loop(app, 1)
	deadline := time.ticks() + 2000
	mut watching := false
	for time.ticks() < deadline {
		app.mu.lock()
		watching = app.tx_health_watches[transport.wire_key(iface)].busy
		app.mu.unlock()
		if watching {
			break
		}
		time.sleep(time.millisecond)
	}
	app.mu.lock()
	app.running = false
	app.mu.unlock()
	app.wait_for_run_workers()
	assert watching
	assert !app.tx_health_watches[transport.wire_key(iface)].busy
}

fn test_health_reports_only_for_the_current_unmonitored_wire() {
	iface := 'inproc:health-report'
	mut app := &App{ running: true, run_gen: 1 }
	mut tap := app.open_tap_phys(iface, iface, org_tx, '', 1, false) or { panic(err) }
	defer { tap.close() }
	app.tx_buses[tx_bus_key('', iface)] = tap
	app.tx_buses[tx_bus_key('BUS', iface)] = tap
	assert app.tx_health_targets_locked().len == 1
	app.report_tx_health(iface, 1, .unknown, .bus_off)
	assert app.logs.len == 1 && app.logs[0].contains('BUS-OFF')
	app.report_tx_health(iface, 1, .bus_off, .bus_off)
	app.report_tx_health(iface, 0, .unknown, .bus_off)
	app.chans = [Chan{ iface: iface, enabled: true, running: true, mode: 'normal' }]
	assert app.tx_health_targets_locked().len == 0
	app.report_tx_health(iface, 1, .bus_off, .ok)
	assert app.logs.len == 1
}
