module headless

import os
import time
import blobly.transport

// send_alloc_test.v — what a running generator's send ALLOCATES, in bytes, because allocation is
// deterministic where time is not (the method of blobly/wiretap/bench_test.v). With a few hundred
// generators every byte per frame is collector work, and a collection stops the world: their
// sending loops all stop at once and leave out the slots it covered (#689). A generator whose
// frame cannot differ between sends sends the frame it built; one on a value source builds one
// payload per send, which a receiver keeps.

const send_alloc_dbc = 'VERSION ""

NS_ :

BS_:

BU_: Node Receiver

BO_ 256 Msg000: 8 Node
 SG_ S000_0 : 0|16@1+ (1,0) [0|65535] "" Receiver
 SG_ S000_1 : 16|16@1+ (1,0) [0|65535] "" Receiver
 SG_ S000_2 : 32|16@1+ (1,0) [0|65535] "" Receiver
 SG_ S000_3 : 48|16@1+ (1,0) [0|65535] "" Receiver
'

// send_alloc_dir is where send_alloc_run writes its project, removed by the test.
fn send_alloc_dir() string {
	return os.join_path(os.vtmp_dir(), 'headless_send_alloc_${os.getpid()}')
}

// send_alloc_run starts a project with three generators on inproc:HALLOC, none on its cycle: a
// message of static values (Static), the same message with a sine on one signal (Sourced), and a
// raw frame (Raw).
fn send_alloc_run() !&Run {
	dir := send_alloc_dir()
	os.mkdir_all(dir)!
	dbc := os.join_path(dir, 'alloc.dbc')
	os.write_file(dbc, send_alloc_dbc)!
	path := os.join_path(dir, 'alloc.blobnet')
	os.write_file(path, 'project:
  name: send_alloc
  version: 8
channels:
  - name: A
    type: can
    interface: inproc:HALLOC
    databases:
      - ${dbc}
    senders:
      - name: Static
        message: Msg000
        signals:
          - { name: S000_0, value: 0 }
          - { name: S000_1, value: 1 }
          - { name: S000_2, value: 2 }
          - { name: S000_3, value: 3 }
      - name: Sourced
        message: Msg000
        signals:
          - { name: S000_0, type: sine, offset: 1000, amplitude: 500, freq: 1 }
          - { name: S000_1, value: 1 }
      - name: Raw
        id: "0x321"
        data: 01 02 03 04 05 06 07 08
')!
	return start(load(path, Options{})!, path, Options{})!
}

// bytes_per_send is what generator `g`'s cyclic sends allocate, each, once it is running: its
// serve driven as its wire's loop drives it, every slot due, on a handle opened as the loop opens
// its own, with a subscriber on the wire so the fan-out runs.
fn bytes_per_send(mut r Run, gi int, mut sub transport.Bus) !f64 {
	mut g := r.gens[gi]
	mut bus := r.gen_opener(g.open)!
	defer {
		bus.close()
	}
	g.cyclic = true
	g.s.cycle_ms = 1
	g.told = true
	for _ in 0 .. 50 {
		g.grid.restart()
		g.serve(mut bus, time.sys_mono_now() / 1_000_000)
	}
	for {
		sub.recv(0) or { break }
	}
	n := 1000
	sent0 := g.sent
	before := u64(gc_heap_usage().total_bytes)
	for _ in 0 .. n {
		g.grid.restart()
		g.serve(mut bus, time.sys_mono_now() / 1_000_000)
	}
	after := u64(gc_heap_usage().total_bytes)
	assert g.sent - sent0 == n, 'generator ${g.s.name}: ${g.sent - sent0} of ${n} sends went out'
	for {
		sub.recv(0) or { break }
	}
	return f64(after - before) / f64(n)
}

fn test_a_running_generator_sends_without_garbage() {
	$if !gcboehm ? {
		println('send cost: skipped, no Boehm allocation counter in this build')
		return
	}
	defer {
		os.rmdir_all(send_alloc_dir()) or {}
	}
	mut r := send_alloc_run()!
	mut sub := transport.open('inproc:HALLOC')!
	defer {
		sub.close()
		r.stop()
	}
	sub.recv(0) or {}
	fixed := bytes_per_send(mut r, 0, mut sub)!
	sourced := bytes_per_send(mut r, 1, mut sub)!
	raw := bytes_per_send(mut r, 2, mut sub)!
	println('generator send cost: static message ${fixed:.0f}, sourced ${sourced:.0f}, raw ${raw:.0f} bytes allocated per send')
	assert fixed < 64, 'a static message generator allocates ${fixed:.0f} bytes per send'
	assert raw < 64, 'a raw generator allocates ${raw:.0f} bytes per send'
	// one payload, which a receiver of the frame keeps
	assert sourced < 128, 'a generator on a value source allocates ${sourced:.0f} bytes per send'
}
