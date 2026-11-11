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

// target is `iface` as a sender's target of no row
fn target(iface string) cyclic.Target {
	return cyclic.Target{
		iface: iface
		open:  fn [iface] () !transport.Bus {
			return transport.open(iface)
		}
	}
}

fn test_a_background_sender_is_sent_by_the_runs_wire() {
	dir := os.join_path(os.vtmp_dir(), 'headless_cyc_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'cyc.blobnet')
	os.write_file(path, cyclic_project)!
	mut r := start(load(path, Options{})!, path, Options{})!
	mut rx := transport.open('inproc:HCYC')!
	defer {
		rx.close()
	}
	mut s := r.start_cyclic(target('inproc:HCYC'), cyclic.Spec{
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
	// a stopped run starts nothing
	r.start_cyclic(target('inproc:HCYC'), cyclic.Spec{
		period_ms: 10
	}) or {
		assert err.msg().contains('stopped')
		return
	}
	assert false, 'a stopped run started a sender'
}

@[heap]
struct Device {
mut:
	up bool
}

// a wire whose open failed is opened again by the next source on it: a sender refused while the
// device was absent starts once it is there
fn test_a_sender_after_a_failed_open_opens_the_wire_again() {
	dir := os.join_path(os.vtmp_dir(), 'headless_cyc_retry_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'cyc.blobnet')
	os.write_file(path, cyclic_project)!
	mut r := start(load(path, Options{})!, path, Options{})!
	defer {
		r.stop()
	}
	mut dev := &Device{}
	r.gen_opener = fn [dev] (iface string) !transport.Bus {
		if !dev.up {
			return error('no such device')
		}
		return transport.open(iface)
	}
	spec := cyclic.Spec{
		id:        0x78
		data:      [u8(1)]
		period_ms: 10
	}
	mut why := ''
	r.start_cyclic(target('inproc:HCYC'), spec) or { why = err.msg() }
	assert why.contains('no such device'), why
	dev.up = true
	mut rx := transport.open('inproc:HCYC')!
	defer {
		rx.close()
	}
	mut s := r.start_cyclic(target('inproc:HCYC'), spec)!
	assert s.info().running
	mut heard := false
	until := time.ticks() + 500
	for time.ticks() < until && !heard {
		f := rx.recv(10) or { continue }
		heard = f.id == 0x78
	}
	assert heard
	// the stopped run's refusal is typed, the state's and not the wire's
	r.stop()
	r.start_cyclic(target('inproc:HCYC'), spec) or {
		assert err is RunStopped
		return
	}
	assert false, 'a stopped run started a sender'
}

// senders on two addresses that open two hubs are sent on two wires: `inproc:HSP ` is its own hub
fn test_senders_on_two_hubs_spelled_alike_are_sent_on_their_own() {
	dir := os.join_path(os.vtmp_dir(), 'headless_cyc_space_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'cyc.blobnet')
	os.write_file(path, cyclic_project)!
	mut r := start(load(path, Options{})!, path, Options{})!
	defer {
		r.stop()
	}
	mut rx := transport.open('inproc:HSP ')!
	defer {
		rx.close()
	}
	r.start_cyclic(target('inproc:HSP'), cyclic.Spec{
		id:        0x1
		period_ms: 10
	})!
	r.start_cyclic(target('inproc:HSP '), cyclic.Spec{
		id:        0x2
		period_ms: 10
	})!
	mut heard := map[u32]int{}
	until := time.ticks() + 100
	for time.ticks() < until {
		f := rx.recv(10) or { continue }
		heard[f.id]++
	}
	assert heard[u32(0x2)] >= 5, '${heard}'
	assert heard[u32(0x1)] == 0, '${heard}'
}
