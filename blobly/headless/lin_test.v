module headless

import os
import blobly.lin
import blobly.project
import blobly.transport
import sync

// LinSaid is what a run said (this file is also tested on its own, without headless_test.v).
@[heap]
struct LinSaid {
mut:
	mu    sync.Mutex
	lines []string
}

fn (mut l LinSaid) options() Options {
	sink := fn [mut l] (s string) {
		l.mu.lock()
		l.lines << s
		l.mu.unlock()
	}
	return Options{
		out: sink
		err: sink
	}
}

fn (mut l LinSaid) said(what string) bool {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.lines.any(it.contains(what))
}

fn lin_project(dir string, bus string, schedule string) !string {
	ldf := os.join_path(@VMODROOT, 'dbc', 'lin_demo.ldf')
	path := os.join_path(dir, '${bus}.blobnet')
	os.write_file(path, 'project:
  name: lin
buses:
  - name: CAN1
    interface: inproc:lin_${bus}
lin:
  - name: BODY
    address: inproc:${bus}
    ldf: ${ldf}
    role: master
    simulate: [CEM, LSM, RSM]
    schedule: ${schedule}
')!
	return path
}

// A LIN bus of the project runs with the run, its frames on the wire, and stop ends it.
fn test_lin_rows_run_with_the_run() {
	dir := os.join_path(os.vtmp_dir(), 'headless_lin_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := lin_project(dir, 'hl_body', 'NormalTable')!
	mut lines := &LinSaid{}
	o := lines.options()
	proj := load(path, o)!
	assert proj.channels.len == 1, 'the LIN bus is not a channel'
	mut r := start(proj, path, o)!
	rows := r.lin_rows()
	assert rows.len == 1 && rows[0].spec.name == 'BODY'
	assert lines.said('lin BODY (inproc:hl_body @ 19200): master, simulating CEM, LSM, RSM, schedule NormalTable')
	mut mon := lin.open('inproc:hl_body', lin.Config{ role: .monitor })!
	mut ids := map[u8]bool{}
	for _ in 0 .. 20 {
		f := mon.recv(200)!
		ids[f.id] = true
	}
	assert 0x01 in ids && 0x12 in ids, ids.str()
	mut row := rows[0]
	mut tap := row.tap()!
	r.stop()
	assert r.loops_done == r.spawned
	assert released()
	for {
		tap.recv(100) or {
			assert err is transport.CarrierGone, err.msg()
			break
		}
	}
	mon.close()
}

// A LIN bus the row refuses refuses the run, and nothing is left holding the bus.
fn test_a_refused_lin_bus_refuses_the_run() {
	dir := os.join_path(os.vtmp_dir(), 'headless_lin_bad_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	mut proj := project.load(lin_project(dir, 'hl_bad', 'NoSuchTable')!)!
	proj.lin << project.LinBus{
		...proj.lin[0]
		name:     'FIRST'
		address:  'inproc:hl_first'
		schedule: 'NormalTable'
	}
	proj.lin = [proj.lin[1], proj.lin[0]]
	mut lines := &LinSaid{}
	if _ := start(proj, os.join_path(dir, 'x.blobnet'), lines.options()) {
		assert false, 'started with a schedule the LDF does not have'
	} else {
		assert err.msg().contains('NoSuchTable'), err.msg()
	}
	assert released()
	// the first row was stopped: its bus takes a master again
	mut m := lin.open('inproc:hl_first', lin.Config{ role: .master })!
	m.close()
}
