module transport

import time

// alloc_test.v — what a send and a receive on an in-process wire ALLOCATE, in bytes, through the
// wrappers a script's handle and a generator's wire have (open's SilentBus, a MeteredBus): the
// policy read, the meter, the fan-out and the wait for a frame (the method of
// blobly/wiretap/bench_test.v). A policy read built an empty map per send on a wire with no
// policy, a `select` per receive allocated its case arrays, and a meter cast its bus between
// interfaces per send (#689).

fn alloc_frame() CanFrame {
	return CanFrame{
		id:   0x123
		data: [u8(1), 2, 3, 4, 5, 6, 7, 8]
	}
}

fn total_allocated() u64 {
	return u64(gc_heap_usage().total_bytes)
}

fn test_a_send_and_a_receive_allocate_nothing_per_frame() {
	$if !gcboehm ? {
		println('send and receive cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut rx := Bus(metered(open('inproc:ALLOC')!, 'inproc:ALLOC', 500000, 0))
	mut tx := metered(open('inproc:ALLOC')!, 'inproc:ALLOC', 500000, 0)
	defer {
		rx.close()
		tx.close()
	}
	rx.recv(0) or {}
	f := alloc_frame()
	n := 2000
	never := fn () bool {
		return false
	}
	for _ in 0 .. 10 {
		tx.send(f)!
		rx.recv(50)!
	}
	b0 := total_allocated()
	for _ in 0 .. n {
		tx.send(f)!
	}
	b1 := total_allocated()
	for _ in 0 .. n {
		recv_sliced(mut rx, 50, 20, never)!
	}
	b2 := total_allocated()
	send := f64(b1 - b0) / f64(n)
	recv := f64(b2 - b1) / f64(n)
	println('inproc cost: ${send:.0f} bytes per metered send, ${recv:.0f} per metered receive of a queued frame')
	assert send < 32, 'a metered send allocates ${send:.0f} bytes'
	assert recv < 32, 'a metered receive of a queued frame allocates ${recv:.0f} bytes'
}

// a receive that waits for its frame: the sender a thread of its own, sending every 2 ms, so most
// receives find the queue empty and wait
fn test_a_receive_that_waits_allocates_nothing_per_frame() {
	$if !gcboehm ? {
		println('waiting receive cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut rx := Bus(metered(open('inproc:ALLOCW')!, 'inproc:ALLOCW', 500000, 0))
	mut tx := open('inproc:ALLOCW')!
	defer {
		rx.close()
		tx.close()
	}
	rx.recv(0) or {}
	n := 200
	f := alloc_frame()
	t := spawn fn [mut tx, f, n] () {
		time.sleep(20 * time.millisecond)
		for _ in 0 .. n {
			tx.send(f) or {}
			time.sleep(2 * time.millisecond)
		}
	}()
	never := fn () bool {
		return false
	}
	before := total_allocated()
	mut got := 0
	for got < n {
		recv_sliced(mut rx, 1000, 20, never) or { break }
		got++
	}
	after := total_allocated()
	t.wait()
	assert got == n
	per := f64(after - before) / f64(got)
	println('waiting receive cost: ${per:.0f} bytes per frame')
	assert per < 32, 'a receive that waits for its frame allocates ${per:.0f} bytes'
}
