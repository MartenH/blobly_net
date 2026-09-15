module main

import transport
import time
import candb
import project

// Models a backend whose health needs a live handle and whose subscriber loss
// is finalized only at close, as on the shared PCAN/CANsub transport.
struct FinalHealthBus {
	closing_app  &App = unsafe { nil }
	closing_wire string
mut:
	closed           bool
	hstate           transport.BusHealth = .bus_off
	health_reads     int
	diagnostic_reads int
}

fn (mut b FinalHealthBus) send(frame transport.CanFrame) ! {}

fn (mut b FinalHealthBus) recv(timeout_ms int) !transport.CanFrame {
	return error('timeout')
}

fn (mut b FinalHealthBus) close() {
	b.assert_readiness_revoked()
	b.closed = true
}

fn (mut b FinalHealthBus) health() transport.BusHealth {
	b.health_reads++
	b.assert_readiness_revoked()
	return if b.closed { .unknown } else { b.hstate }
}

fn (mut b FinalHealthBus) diagnostics() transport.BusDiagnostics {
	b.diagnostic_reads++
	b.assert_readiness_revoked()
	return transport.BusDiagnostics{ dropped: if b.closed { u64(7) } else { 0 } }
}

fn test_a_failed_monitor_immediately_stops_covering_the_send_gate() {
	iface := 'inproc:failed-monitor'
	mut app := &App{
		running: true
		run_gen: 1
		chans: [Chan{ iface: iface, mode: 'normal', enabled: true, running: true }]
	}
	app.tx_health.expect(transport.wire_key(iface), 1)
	assert app.transmit_ready_locked(transport.wire_key(iface))
	app.retire_failed_monitor(0, iface, 1)
	assert !app.transmit_ready_locked(transport.wire_key(iface))
	app.run_gen = 2
	app.chans[0].enabled = true
	app.chans[0].running = true
	app.retire_failed_monitor(0, iface, 1)
	assert app.chans[0].receive_ready(), 'an old monitor cannot retire its replacement'
}

fn test_reader_retirement_waits_for_an_already_admitted_send() {
	for monitor in [false, true] {
		iface := 'inproc:admitted-send-${monitor}'
		wire := transport.wire_key(iface)
		mut app := &App{ running: true, run_gen: 1 }
		if monitor {
			app.chans = [
				Chan{ iface: iface, mode: 'normal', enabled: true, running: true },
			]
			app.tx_health.expect(wire, 1)
		} else {
			app.tx_health.claim(wire, 1)
			app.tx_health.opened(wire, 1)
		}
		m := app.tx_mutex(iface)
		m.lock() // a TapBus send between its readiness check and physical completion
		done := chan bool{ cap: 1 }
		spawn fn (app &App, iface string, monitor bool, done chan bool) {
			mut a := unsafe { app }
			if monitor {
				a.retire_failed_monitor(0, iface, 1)
			} else {
				a.begin_tx_health_close(iface, 1)
			}
			done <- true
		}(app, iface, monitor, done)
		deadline := time.ticks() + 5000
		mut revoked := false
		for time.ticks() < deadline {
			app.mu.lock()
			revoked = !app.transmit_ready_locked(wire)
			app.mu.unlock()
			if revoked {
				break
			}
			time.sleep(time.millisecond)
		}
		mut early := false
		select {
			_ := <-done {
				early = true
			}
			50 * time.millisecond {
			}
		}
		m.unlock()
		if !early {
			_ := <-done
		}
		assert revoked, 'new sends must be refused while the admitted send finishes'
		assert !early, 'the receive handle must remain open until the admitted send finishes'
	}
}

fn test_monitor_restores_the_diagnostic_chip_without_repeating_the_log() {
	iface := 'inproc:retained-diagnostics'
	seven := transport.BusDiagnostics{ dropped: 7 }
	mut app := &App{
		running: true
		run_gen: 2
		chans: [Chan{ iface: iface }]
		diag_reported: {
			u64(1): seven
		}
	}
	assert app.report_monitor_diagnostics(0, iface, 2, 1, seven, seven)
	assert app.chans[0].diag == seven
	assert app.chans[0].diag_at > 0
	assert app.logs.len == 0
	assert !app.report_monitor_diagnostics(0, iface, 2, 1, seven, seven)
	assert !app.report_monitor_diagnostics(0, iface, 1, 1, seven, transport.BusDiagnostics{})
	assert app.chans[0].diag == seven, 'an older run cannot overwrite the new chip'
}

fn test_a_late_health_open_closes_without_sampling_the_ended_run() {
	for restarted in [false, true] {
		mut app := &App{ running: restarted, run_gen: if restarted { u64(2) } else { 1 } }
		mut raw := &FinalHealthBus{}
		mut bus := transport.Bus(raw)
		assert !app.admit_tx_health_reader(mut bus, 'inproc:late-open', 1)
		assert raw.closed
		assert raw.health_reads == 0 && raw.diagnostic_reads == 0
		assert app.logs.len == 0
	}
}

fn test_shared_diagnostics_do_not_repeat_across_readers_runs_or_stale_samples() {
	mut app := &App{}
	zero := transport.BusDiagnostics{}
	seven := transport.BusDiagnostics{ dropped: 7 }
	nine := transport.BusDiagnostics{ dropped: 9 }
	assert app.append_diagnostics_locked('pcan:test', 1, zero, seven, '')
	assert !app.append_diagnostics_locked('pcan:test', 1, zero, seven, '')
	app.run_gen++
	assert !app.append_diagnostics_locked('pcan:test', 1, zero, seven, '')
	assert app.append_diagnostics_locked('pcan:test', 1, zero, nine, '')
	assert app.logs.last().contains('+2 dropped')
	assert !app.append_diagnostics_locked('pcan:test', 1, zero, seven, 'old run: ')
	assert app.append_diagnostics_locked('pcan:test', 2, zero, seven, '')
	assert app.logs.last().contains('+7 dropped'), 'a new physical open has independent counts'
	assert app.logs.len == 3
}

fn test_simulation_keeps_its_first_long_period_cycle_while_receive_is_pending() {
	iface := 'inproc:sim-readiness'
	mut app := &App{
		running: true
		run_gen: 1
		chans: [
			Chan{ name: 'BUS', iface: iface, mode: 'normal', enabled: true, spawning: true },
		]
	}
	app.tx_health.expect(transport.wire_key(iface), 1)
	mut peer := transport.open(iface) or { panic(err) }
	defer { peer.close() }
	sc := SimCfg{
		iface: iface
		pch: project.Channel{ name: 'BUS', iface: iface }
		db: candb.Database{
			messages: [candb.Message{
				name: 'Cycle'
				id: 0x123
				dlc: 1
				sender: 'ECU'
				cycle_ms: 1000000
				signals: [candb.Signal{ name: 'Count', length: 8 }]
			}]
		}
		nodes: [project.NodeCfg{
			name: 'ECU'
			signals: [
				project.GenCfg{ signal: 'Count', typ: 'counter', start: 42, step: 1 },
			]
		}]
	}
	app.reserve_run_worker()
	spawn sim_loop(app, sc, 1)
	deadline := time.ticks() + 5000
	mut attached := false
	for time.ticks() < deadline {
		app.mu.lock()
		attached = app.consumers_ready[transport.destination_key(iface)] == 1
		app.mu.unlock()
		if attached {
			break
		}
		time.sleep(time.millisecond)
	}
	assert attached
	if _ := peer.recv(100) {
		assert false, 'no simulated frame may precede receive readiness'
	}
	app.mu.lock()
	app.chans[0].running = true
	app.chans[0].spawning = false
	app.mu.unlock()
	got := peer.recv(2000) or { panic(err) }
	app.mu.lock()
	app.running = false
	app.mu.unlock()
	app.wait_for_run_workers()
	assert got.id == 0x123 && got.data == [u8(42)], 'the first cycle and send index must survive the wait'
}

fn (mut b FinalHealthBus) reconcile_silence(want bool) ! {}

fn (b &FinalHealthBus) assert_readiness_revoked() {
	if b.closing_wire == '' {
		return
	}
	mut a := unsafe { b.closing_app }
	a.mu.lock()
	assert !a.tx_health.send_ready(b.closing_wire, 1)
	assert !a.tx_health.may_claim(b.closing_wire, 1), 'a replacement cannot overlap finalization'
	a.mu.unlock()
}

fn test_readiness_is_revoked_throughout_finalization_without_releasing_ownership() {
	iface := 'inproc:tx-health-closing'
	wire := transport.wire_key(iface)
	mut app := &App{ running: true, run_gen: 1 }
	app.tx_health.claim(wire, 1)
	app.tx_health.opened(wire, 1)
	mut bus := transport.Bus(&FinalHealthBus{ closing_app: app, closing_wire: wire })
	app.finish_tx_health(mut bus, iface, 1, TxHealthSample{})
	assert !app.tx_health.send_ready(wire, 1)
	assert !app.tx_health.may_claim(wire, 1)
	app.tx_health.release(wire, 1, true)
	assert app.tx_health.may_claim(wire, 1)
	assert app.tx_health.wires[wire].failures == 1
}

fn test_stopped_generator_edits_do_not_wait_on_a_tools_send_mutex() {
	iface := 'inproc:tx-health-stopped-edit'
	mut app := &App{
		chans: [Chan{ name: 'FIRST', iface: iface }]
		senders: [SenderRT{ uid: 1, iface: iface, tgt: iface }]
	}
	m := app.tx_mutex(iface)
	m.lock() // stand in for a tool whose driver send is stalled
	done := chan bool{ cap: 1 }
	spawn fn (app &App, iface string, done chan bool) {
		mut a := unsafe { app }
		a.plan_sender_bus(0, iface, '') or {}
		a.plan_add_generator()
		done <- true
	}(app, iface, done)
	deadline := time.ticks() + 5000
	mut finished := false
	for time.ticks() < deadline {
		select {
			_ := <-done {
				finished = true
			}
			else {
			}
		}
		if finished {
			break
		}
		time.sleep(time.millisecond)
	}
	m.unlock()
	if !finished {
		_ := <-done
	} // drain a failing implementation before the assertion
	assert finished, 'stopped edits must finish while the send mutex remains held'
	assert app.senders.len == 2
	assert app.tx_health.wires.len == 0
}

fn test_retarget_and_removal_release_wires_before_pending_opens_complete() {
	b := 'inproc:tx-health-pending-b'
	c := 'inproc:tx-health-pending-c'
	mut app := &App{
		running: true
		run_gen: 1
		senders: [SenderRT{ uid: 1, tgt: 'inproc:old' }]
	}
	mut tool := app.open_tap_phys(b, b, org_tx, '', 0, false) or { panic(err) }
	defer { tool.close() }
	mut peer := transport.open(b) or { panic(err) }
	defer { peer.close() }
	app.plan_sender_bus(0, b, '') or { panic('expected B open') }
	assert !app.tx_health.send_ready(transport.wire_key(b), 1)
	app.plan_sender_bus(0, c, '') or { panic('expected C open') }
	assert app.tx_buses.len == 0, 'neither pending opener has returned'
	tool.send(transport.CanFrame{ id: 0x123 }) or { panic(err) }
	got := peer.recv(1000) or { panic(err) }
	assert got.id == 0x123
	assert !app.tx_health.send_ready(transport.wire_key(c), 1)
	app.remove_generator(0)
	assert app.tx_health.send_ready(transport.wire_key(c), 1)
}

fn test_final_samples_survive_restart_without_changing_the_new_run() {
	mut app := &App{
		running: true
		run_gen: 2
		chans: [Chan{ iface: 'inproc:final', health: .ok }]
	}
	app.tx_health.expect('inproc:final', 2)
	mut bus := transport.Bus(&FinalHealthBus{})
	app.finish_tx_health(mut bus, 'inproc:final', 1, TxHealthSample{})
	assert app.logs.len == 2
	assert app.logs[0].contains('run 1 final:') && app.logs[0].contains('BUS-OFF')
	assert app.logs[1].contains('run 1 final:') && app.logs[1].contains('+7 drop')
	assert app.chans[0].health == .ok
	assert app.chans[0].diag == transport.BusDiagnostics{}
	assert !app.tx_health.send_ready('inproc:final', 2)
}

fn test_late_observation_is_retained_even_if_the_old_backend_recovers_before_close() {
	mut app := &App{ running: true, run_gen: 2 }
	mut last := TxHealthSample{}
	assert app.report_tx_health_sample('inproc:late', 1, TxHealthSample{
		health: .bus_off
	}, mut last)
	mut bus := transport.Bus(&FinalHealthBus{ hstate: .ok })
	app.finish_tx_health(mut bus, 'inproc:late', 1, last)
	assert app.logs.len == 3
	assert app.logs[0].contains('run 1 final:') && app.logs[0].contains('BUS-OFF')
	assert app.logs[1].contains('run 1 final:') && app.logs[1].contains('recovered')
	assert app.logs[2].contains('run 1 final:') && app.logs[2].contains('+7 drop')
}

fn test_reported_samples_are_not_repeated_at_close() {
	mut app := &App{ running: true, run_gen: 1 }
	mut last := TxHealthSample{}
	assert app.report_tx_health_sample('inproc:reported', 1, TxHealthSample{
		health: .bus_off
		diagnostics: transport.BusDiagnostics{ dropped: 7 }
	}, mut last)
	assert app.logs.len == 2
	mut bus := transport.Bus(&FinalHealthBus{})
	app.finish_tx_health(mut bus, 'inproc:reported', 1, last)
	assert app.logs.len == 2
}

fn test_live_retarget_blocks_tools_before_the_tap_open_is_started() {
	for returning in [false, true] {
		iface := 'inproc:tx-health-retarget-${returning}'
		wire := transport.wire_key(iface)
		mut app := &App{
			running: true
			run_gen: 1
			senders: [SenderRT{ uid: 1, iface: 'inproc:old', tgt: 'inproc:old' }]
		}
		mut tool := app.open_tap_phys(iface, iface, org_tx, '', 0, false) or { panic(err) }
		mut peer := transport.open(iface) or { panic(err) }
		if returning {
			app.tx_health.claim(wire, 1)
			app.tx_health.release(wire, 1, false)
			app.tx_health.retain_needed([], 1)
		}
		// This is the real mutation used by set_sender_bus, before its opener
		// is spawned. Both a first target and a previously departed one wait.
		want := app.plan_sender_bus(0, iface, '') or { panic('expected a tap open') }
		assert want.iface == iface
		assert app.senders[0].target() == iface
		assert app.tx_buses.len == 0
		if _ := tool.send(transport.CanFrame{ id: 0x123 }) {
			assert false, 'a live retarget must gate a tool before its async open'
		}
		if _ := peer.recv(0) {
			assert false, 'the early frame must not reach the wire'
		}
		assert app.tx_count == 0
		tool.close()
		peer.close()
	}
}

fn test_live_generator_addition_gates_an_unmonitored_first_channel() {
	iface := 'inproc:tx-health-add'
	mut app := &App{
		running: true
		run_gen: 1
		chans: [Chan{ name: 'FIRST', iface: iface, mode: 'normal', enabled: false }]
	}
	mut tool := app.open_tap_phys(iface, iface, org_tx, '', 0, false) or { panic(err) }
	defer { tool.close() }
	mut peer := transport.open(iface) or { panic(err) }
	defer { peer.close() }
	want := app.plan_add_generator()
	assert want.iface == iface && want.chan_name == 'FIRST'
	assert app.senders.len == 1 && app.senders[0].target() == iface
	assert app.tx_buses.len == 0
	if _ := tool.send(transport.CanFrame{ id: 0x123 }) {
		assert false, 'adding a generator must gate the wire before its async open'
	}
	if _ := peer.recv(0) {
		assert false, 'the early frame must not reach the wire'
	}
}

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

fn test_spawning_monitor_blocks_sends_then_failed_open_gets_a_health_reader() {
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
	assert app.tx_health.may_claim_now(wire, 1), 'do not race a scheduled monitor with a second reader'
	assert !app.transmit_ready_locked(wire), 'scheduling a monitor must not permit sends'
	app.reserve_run_worker_locked()
	app.mu.unlock()

	// The monitor's open-failure path clears spawning. The existing tap must
	// get a fallback from the real supervisor without being filed again.
	spawn tx_health_loop(app, 1)
	app.mu.lock()
	app.chans[0].spawning = false
	app.mu.unlock()
	deadline := time.ticks() + 5000
	mut ready := false
	for time.ticks() < deadline {
		app.mu.lock()
		ready = app.tx_health.send_ready(wire, 1)
		app.mu.unlock()
		if ready {
			break
		}
		time.sleep(time.millisecond)
	}
	app.mu.lock()
	app.chans[0].enabled = false
	app.running = false
	app.mu.unlock()
	app.drop_unwanted_taps('', iface)
	app.wait_for_run_workers()
	assert ready, 'a failed monitor must get a health reader before sends resume'
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
	mut peer := transport.open(iface) or { panic(err) }
	defer { peer.close() }
	mut tool := app.open_tap_phys(iface, iface, org_tx, '', 0, false) or { panic(err) }
	defer { tool.close() }
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
	tool.send(transport.CanFrame{ id: 0x123, data: [u8(1)] }) or { panic(err) }
	got := peer.recv(1000) or { panic(err) }
	assert got.id == 0x123, 'the departed wire must not leave a tool permanently blocked'
	app.mu.lock()
	assert app.tx_health.may_claim(transport.wire_key(iface), 1)
	app.running = false
	app.mu.unlock()
}
