module headless

import os
import net
import sync
import time
import blobly.project
import blobly.transport
import blobly.isotp

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
	assert !released(), 'a running run holds the process'
	r.stop()
	assert r.loops_done == r.spawned, 'every loop counted out: ${r.loops_done} of ${r.spawned}'
	assert !lines.said('still busy')
	assert released() && wait_released(0), 'a clean stop frees the process at once'
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
	row := r.proj.channels.filter(it.enabled && it.kind() == .doip)[0]
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

// A database reference that resolves only from the working directory is said on the error sink
// at load, with the spelling that names it from the project (#494).
fn test_load_says_a_reference_resolving_only_from_the_working_directory() {
	root := os.join_path(os.vtmp_dir(), 'headless_cwd_${os.getpid()}')
	os.mkdir_all(os.join_path(root, 'proj'))!
	os.mkdir_all(os.join_path(root, 'dbc'))!
	was := os.getwd()
	defer {
		os.chdir(was) or {}
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(root, 'dbc', 'x.dbc'), '')!
	path := os.join_path(root, 'proj', 'p.blobnet')
	os.write_file(path, 'project:\n  name: t\nchannels:\n  - name: CAN1\n    interface: inproc:CAN1\n    databases: [dbc/x.dbc]\n')!
	os.chdir(root)!
	mut lines := &Lines{}
	load(path, lines.options())!
	lines.mu.lock()
	err_lines := lines.err.clone()
	lines.mu.unlock()
	assert err_lines.len == 1
	assert err_lines[0] == '${path}: CAN1: `dbc/x.dbc` resolves only from the folder the program was started in (${os.getwd()}); write it relative to the project file (`../dbc/x.dbc`)'
}

// A second stop of an older run does nothing: it cannot free the slot a newer run holds.
fn test_stop_twice_is_harmless() {
	path := os.join_path(@VMODROOT, 'projects', 'sim-demo.blobnet')
	mut lines := &Lines{}
	o := lines.options()
	proj := load(path, o)!
	mut first := start(proj, path, o)!
	// two stops at once: the second returns when the first has finished, not before
	other := spawn first.stop()
	first.stop()
	assert first.stop_done
	other.wait()
	mut second := start(first.proj, path, Options{
		...o
		project_ports: true
	})!
	t := time.ticks()
	first.stop()
	assert time.ticks() - t < 500
	if _ := start(proj, path, o) {
		assert false, "the older run's second stop freed the slot the newer one holds"
	} else {
		assert err.msg().contains('already active'), err.msg()
	}
	second.stop()
}

// A process held past stop (a loop that outlived its bound keeps the slot) is not released until
// the run that holds it lets go, and wait_released says so within its timeout.
fn test_wait_released_waits_for_the_holder() {
	headless_mu.lock()
	held := headless_owner == 0
	if held {
		headless_next++
		headless_owner = headless_next
	}
	gen := headless_owner
	headless_mu.unlock()
	assert held, 'another test left the process held'
	assert !released()
	t0 := time.ticks()
	assert !wait_released(30)
	assert time.ticks() - t0 >= 30
	release_process(gen)
	assert released() && wait_released(0)
}

// `builtin_uds: false` on any enabled row of a wire keeps the built-in 0x7E0/0x7E8 server off it,
// and the start line says so.
fn test_builtin_uds_false_starts_no_default_server() {
	path := os.join_path(os.temp_dir(), 'builtin_uds_${os.getpid()}.blobnet')
	os.write_file(path, 'project:
  name: t
buses:
  - name: CAN1
    interface: inproc:BUILTIN613
    simulate: [BodyECU]
  - name: CAN1b
    interface: inproc:BUILTIN613
    builtin_uds: false
')!
	defer {
		os.rm(path) or {}
	}
	mut lines := &Lines{}
	o := lines.options()
	proj := load(path, o)!
	mut r := start(proj, path, o)!
	assert lines.said('simulating 1 node(s), no UDS server')
	mut ch := isotp.open_software('inproc:BUILTIN613', 0x7E0, 0x7E8, false)!
	ch.send([u8(0x22), 0xF1, 0x90])!
	if resp := ch.recv(300) {
		assert false, 'answered: ${resp}'
	}
	ch.close()
	r.stop()
}

// A row's interface overridden at load is where the run opens it: sim-demo's CAN1 moved onto
// another in-process bus carries its simulated ECUs there, at the row's own rate.
fn test_an_interface_override_moves_the_row_for_the_run() {
	path := os.join_path(@VMODROOT, 'projects', 'sim-demo.blobnet')
	mut lines := &Lines{}
	o := Options{
		...lines.options()
		interfaces: [project.IfaceOverride{'CAN1', 'inproc:CAN1_moved'}]
	}
	proj := load(path, o)!
	assert lines.said('CAN1: inproc:CAN1_moved (overridden)')
	mut bus := transport.open('inproc:CAN1_moved')!
	mut r := start(proj, path, o)!
	can1 := r.chans.filter(it.cfg.name == 'CAN1')[0]
	assert can1.cfg.iface == 'inproc:CAN1_moved'
	frame := bus.recv(1000)!
	assert frame.data.len > 0
	bus.close()
	r.stop()
}

// An override naming no row refuses the load, naming the rows.
fn test_an_interface_override_naming_no_row_refuses_the_load() {
	path := os.join_path(@VMODROOT, 'projects', 'sim-demo.blobnet')
	mut lines := &Lines{}
	if _ := load(path, Options{
		...lines.options()
		interfaces: [project.IfaceOverride{'CAN9', 'inproc:x'}]
	})
	{
		assert false
	} else {
		assert err.msg().contains('no row named "CAN9"'), err.msg()
		assert err.msg().contains('"CAN1"'), err.msg()
	}
}

// recv_id is the next frame of `id` on `bus` within `ms`, none when none came.
fn recv_id(mut bus transport.Bus, id u32, ms int) ?transport.CanFrame {
	deadline := time.ticks() + ms
	for time.ticks() < deadline {
		f := bus.recv(10) or { continue }
		if f.id == id {
			return f
		}
	}
	return none
}

// A simulated node announces its NM PDU on the row's cycle while the run is up, falls silent when
// a script releases the network for the row, and announces again on a request.
fn test_a_simulated_node_announces_nm_until_released() {
	dir := os.join_path(os.temp_dir(), 'blobly_headless_nm_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'nm.blobnet')
	os.write_file(path, 'project:
  name: nm
channels:
  - name: CAN1
    interface: inproc:NMHL
    nm: { lo: 0x500, hi: 0x53F, timeout_ms: 300, cycle_ms: 20 }
    simulation:
      - name: Body
        nm: { id: 0x511, nid: 0x11 }
')!
	mut lines := &Lines{}
	o := lines.options()
	proj := load(path, o)!
	mut bus := transport.open('inproc:NMHL')!
	mut r := start(proj, path, o)!
	defer {
		r.stop()
		bus.close()
	}
	assert lines.said('Body announces NM on 0x511 (NID 0x11) every 20 ms')
	f := recv_id(mut bus, 0x511, 1000) or { panic('no NM frame') }
	assert f.data == [u8(0x11), 0, 0, 0, 0, 0, 0, 0]
	assert r.chans[0].fault_target().nm_request(false)! == 1
	time.sleep(60 * time.millisecond)
	for _ in 0 .. 1000 {
		bus.recv(0) or { break }
	}
	assert recv_id(mut bus, 0x511, 150) == none, 'a released node falls silent'
	assert r.chans[0].fault_target().nm_request(true)! == 1
	assert recv_id(mut bus, 0x511, 500) != none, 'a request announces again'
}
