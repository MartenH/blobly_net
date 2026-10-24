module headless

import os
import time
import blobly.cyclic
import blobly.transport

const cyclic_project = 'project:
  name: cyclic
  version: 8
channels:
  - name: C1
    type: can
    interface: inproc:HCYC
'

fn test_a_background_sender_is_one_of_the_runs_loops() {
	dir := os.join_path(os.vtmp_dir(), 'headless_cyc_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'cyc.blobnet')
	os.write_file(path, cyclic_project)!
	mut r := start(load(path, Options{})!, path, Options{})!
	mut rx := transport.open('inproc:HCYC')!
	defer {
		rx.close()
	}
	mut s := r.start_cyclic(transport.open('inproc:HCYC')!, cyclic.Spec{
		id:        0x77
		data:      [u8(1)]
		period_ms: 10
	})!
	mut heard := 0
	until := time.ticks() + 100
	for time.ticks() < until {
		f := rx.recv(10) or { continue }
		if f.id == 0x77 {
			heard++
		}
	}
	assert heard >= 5
	// the run's stop ends it, and waits for it: no loop is left out
	t0 := time.ticks()
	r.stop()
	assert time.ticks() - t0 < 1000
	assert !s.info().running
	assert released()
	// a stopped run starts nothing, and closes the bus it was handed
	r.start_cyclic(transport.open('inproc:HCYC')!, cyclic.Spec{
		period_ms: 10
	}) or {
		assert err.msg().contains('stopped')
		return
	}
	assert false, 'a stopped run started a sender'
}
