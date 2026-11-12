module transport

import time

// alloc_test.v — what a send and a receive on an in-process wire ALLOCATE, in bytes, through the
// wrappers a script's handle and a generator's wire have (open's SilentBus, a MeteredBus): the
// policy read, the meter, the fan-out and the wait for a frame (the method of
// blobly/wiretap/bench_test.v). A policy read built an empty map per send on a wire with no
// policy, a `select` per receive allocated its case arrays, a timeout built its error per answer,
// and a meter cast its bus between interfaces per send (#689).

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
	// a receive that finds nothing in time, as a reader on a quiet wire does every slice
	for _ in 0 .. 100 {
		if _ := recv_sliced(mut rx, 1, 1, never) {
			assert false, 'nothing was sent'
		}
	}
	b3 := total_allocated()
	send := f64(b1 - b0) / f64(n)
	recv := f64(b2 - b1) / f64(n)
	quiet := f64(b3 - b2) / 100.0
	println('inproc cost: ${send:.0f} bytes per metered send, ${recv:.0f} per metered receive of a queued frame, ${quiet:.0f} per receive that timed out')
	assert send < 32, 'a metered send allocates ${send:.0f} bytes'
	assert recv < 32, 'a metered receive of a queued frame allocates ${recv:.0f} bytes'
	assert quiet < 32, 'a receive that timed out allocates ${quiet:.0f} bytes'
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

// a handle whose newest frames a view keeps, as every Python handle's are (newest.v): its send
// notes the frame for the view to know its echo by, a copy of the payload and no more, and the
// view's reader keeps every frame it hears without allocating
fn test_a_watched_handle_allocates_its_echo_note_per_send() {
	$if !gcboehm ? {
		println('watched send cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut tx := metered(open('inproc:ALLOCV')!, 'inproc:ALLOCV', 500000, 0)
	tx.view = watch_newest(open('inproc:ALLOCV')!, 'inproc:ALLOCV')
	mut rx := open('inproc:ALLOCV')!
	defer {
		tx.view.close()
		tx.close()
		rx.close()
	}
	rx.recv(0) or {}
	f := alloc_frame()
	for _ in 0 .. 10 {
		tx.send(f)!
	}
	n := 200
	before := total_allocated()
	for _ in 0 .. n {
		tx.send(f)!
		time.sleep(500 * time.microsecond)
	}
	tx.view.settle()
	after := total_allocated()
	per := f64(after - before) / f64(n)
	println('watched send cost: ${per:.0f} bytes per send')
	assert per < 96, 'a send on a watched handle allocates ${per:.0f} bytes'
}
