module headless

import os
import net
import sync
import time
import blobly.transport

// Lines is what a run said, kept for the assertions. HEAP, and locked: the sinks are called from
// the run's worker threads (Options says so), and the test reads while they are still starting.
@[heap]
struct Lines {
mut:
	mu  sync.Mutex
	out []string
	err []string
}

fn (mut l Lines) options() Options {
	return Options{
		out: fn [mut l] (s string) {
			l.mu.lock()
			l.out << s
			l.mu.unlock()
		}
		err: fn [mut l] (s string) {
			l.mu.lock()
			l.err << s
			l.mu.unlock()
		}
	}
}

fn (mut l Lines) said(what string) bool {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.out.any(it.contains(what)) || l.err.any(it.contains(what))
}

// A started project is observable from a bus handle of its own: sim-demo's simulated ECUs
// transmit on inproc:CAN1, and a stop ends every loop it spawned.
fn test_start_runs_the_simulation_and_stop_ends_it() {
	path := os.join_path(@VMODROOT, 'projects', 'sim-demo.blobnet')
	mut lines := &Lines{}
	o := lines.options()
	proj := load(path, o)!
	mut r := start(proj, path, o)!
	assert r.chans.map(it.cfg.name).contains('CAN1')
	assert lines.said('simulating')
	mut bus := transport.open('inproc:CAN1')!
	frame := bus.recv(1000)!
	assert frame.data.len > 0
	bus.close()
	assert r.spawned > 0
	r.stop()
	assert r.loops_done == r.spawned, 'every loop counted out: ${r.loops_done} of ${r.spawned}'
	assert !lines.said('still busy')
	// and the DoIP entity's port is free when stop returns: the same project starts again on
	// the ports the first run bound (its entity was moved onto one this process could bind)
	mut again := start(r.proj, path, Options{
		...o
		project_ports: true
	})!
	// one run per process: a second start is refused until this one is stopped
	if _ := start(proj, path, o) {
		assert false, 'two runs in one process'
	} else {
		assert err.msg().contains('already active'), err.msg()
	}
	again.stop()
	assert !lines.said('refusing')
}

// A tester still connected to the entity does not keep it serving past stop: the entity is
// closed from stop, and the port is free when it returns.
fn test_stop_closes_a_connected_entity() {
	path := os.join_path(@VMODROOT, 'projects', 'sim-demo.blobnet')
	mut lines := &Lines{}
	o := lines.options()
	proj := load(path, o)!
	mut r := start(proj, path, o)!
	row := r.proj.channels.filter(it.enabled && it.is_doip())[0]
	host, port := row.doip_endpoint()
	mut tester := net.dial_tcp('${host}:${port}')!
	time.sleep(50 * time.millisecond) // accepted: the serve loop is inside the connection
	t := time.ticks()
	r.stop()
	assert time.ticks() - t < 1500, 'stop waited out its bound: ${time.ticks() - t} ms'
	assert !lines.said('still busy')
	tester.close() or {}
	mut again := start(r.proj, path, Options{
		...o
		project_ports: true
	})!
	again.stop()
}

// A refusal reached AFTER loops were spawned stops them: the CAN row's simulation is running
// by the time the DoIP entity fails to bind, and nothing of it is left transmitting.
fn test_refusal_leaves_nothing_running() {
	// the entity's port is held, so its bind fails
	mut held := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := held.addr()!.port()!
	dir := os.join_path(os.temp_dir(), 'blobly_headless_test_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
		held.close() or {}
	}
	path := os.join_path(dir, 'refused.blobnet')
	os.write_file(path, '
project:
  name: refused
  version: 8
channels:
  - name: CAN1
    type: can
    interface: inproc:RUNTIME_REFUSED
    databases:
      - ${os.join_path(@VMODROOT, 'dbc', 'blobly_net.dbc')}
    simulation:
      - name: SUT
        signals:
          - { name: EngineSpeed, type: const, value: 1000 }
  - name: DoIP1
    type: doip
    interface: doip:127.0.0.1:${port}
    tester_address: "0x0E80"
    ecu_address: "0x1000"
    simulation:
      - name: SUT
        uds:
          dids:
            - { id: "0xF190", text: "VIN" }
')!
	mut lines := &Lines{}
	o := Options{
		...lines.options()
		project_ports: true
	}
	proj := load(path, o)!
	if _ := start(proj, path, o) {
		assert false, 'a held port must refuse the run'
	} else {
		assert err.msg().contains('refusing to run'), err.msg()
	}
	assert lines.said('simulating 1 node(s)')
	// the simulation was spawned and is stopped: a fresh handle on its wire hears nothing
	mut bus := transport.open('inproc:RUNTIME_REFUSED')!
	if f := bus.recv(300) {
		assert false, 'the refused run is still transmitting: 0x${f.id:X}'
	}
	bus.close()
}

// A project that cannot be read is load's error, not start's, so a caller can tell the two
// apart.
fn test_load_names_an_unreadable_project() {
	mut lines := &Lines{}
	if _ := load('/nonexistent/x.blobnet', lines.options()) {
		assert false
	} else {
		assert err.msg().starts_with('cannot load project')
	}
}

fn test_stop_twice_is_harmless() {
	path := os.join_path(@VMODROOT, 'projects', 'demo.blobnet')
	mut lines := &Lines{}
	o := lines.options()
	proj := load(path, o)!
	// demo.blobnet's one enabled row is vcan0: absent on CI, the loop counts itself out on the
	// failed open and the run is still a run
	mut r := start(proj, path, o) or {
		eprintln('demo.blobnet refused here (${err}); skipping')
		return
	}
	r.stop()
	t := time.ticks()
	r.stop()
	assert time.ticks() - t < 500
}
