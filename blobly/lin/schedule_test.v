module lin

import sync
import sync.stdatomic
import blobly.transport

// SimClock is synthetic time: the scheduler's sleeper moves it, a slow header moves it too.
@[heap]
struct SimClock {
mut:
	ns i64
	// overshoot is how late every sleep wakes.
	overshoot i64
}

fn (c &SimClock) now_ns() i64 {
	return stdatomic.load_i64(&c.ns)
}

fn (c &SimClock) sleep_ns(ns i64) {
	stdatomic.add_i64(&c.ns, int(ns + c.overshoot))
}

fn (c &SimClock) advance(ns i64) {
	stdatomic.add_i64(&c.ns, int(ns))
}

struct Sent {
	id   u8
	t_ns i64
}

// FakeBus records the first `limit` headers and signals when it has them.
@[heap]
struct FakeBus {
mut:
	clock &SimClock
	mu    sync.Mutex
	sent  []Sent
	limit int
	full  chan bool
	// slow[n] is how long the n-th header takes, in synthetic ns.
	slow map[int]i64
	// hook runs inside the n-th header.
	hook fn (n int) = unsafe { nil }
	// gone: every header answers that the bus is closed.
	gone bool
	// blocking: the second header waits on block.
	blocking bool
	block    chan bool
}

fn (mut b FakeBus) header(id u8) ! {
	if b.gone {
		return transport.carrier_gone('closed')
	}
	b.mu.lock()
	n := b.sent.len
	if n < b.limit {
		b.sent << Sent{id, b.clock.now_ns()}
		if b.sent.len == b.limit {
			b.full <- true
		}
	}
	b.mu.unlock()
	if b.hook != unsafe { nil } {
		b.hook(n)
	}
	if d := b.slow[n] {
		b.clock.advance(d)
	}
	if n == 1 && b.blocking {
		_ := <-b.block
	}
}

const ms = i64(1_000_000)

fn fake(limit int) (&SimClock, &FakeBus) {
	clk := &SimClock{
		ns: 1000 * ms
	}
	bus := &FakeBus{
		clock: clk
		limit: limit
		full:  chan bool{cap: 1}
	}
	return clk, bus
}

fn run_to_limit(mut bus FakeBus, mut s HostScheduler) []Sent {
	s.start() or { panic(err) }
	_ := <-bus.full
	assert s.stop()
	bus.mu.lock()
	defer {
		bus.mu.unlock()
	}
	return bus.sent.clone()
}

fn rel(sent []Sent) []i64 {
	return sent.map((it.t_ns - sent[0].t_ns) / 100_000) // in tenths of a millisecond
}

fn test_grid_does_not_drift() {
	mut clk, mut bus := fake(30)
	clk.overshoot = 3 * ms / 10 // every sleep wakes 0.3 ms late
	slots := [Slot{0x10, 10}, Slot{0x11, 5}, Slot{0x12, 5.5}]
	mut s := new_scheduler(bus, slots, clock: clk, sleeper: clk)!
	sent := run_to_limit(mut bus, mut s)
	mut grid := i64(0)
	for k, x in sent {
		assert x.id == slots[k % 3].id
		want := if k == 0 { i64(0) } else { grid + 3 * ms / 10 }
		assert x.t_ns - sent[0].t_ns == want, 'slot ${k}'
		grid += slot_ns(slots[k % 3])
	}
	assert s.stats().late == 0
	assert s.stats().sent >= 30
}

fn test_late_slot_does_not_burst() {
	mut clk, mut bus := fake(6)
	bus.slow[2] = 25 * ms
	slots := [Slot{0x01, 10}]
	mut s := new_scheduler(bus, slots, clock: clk, sleeper: clk)!
	sent := run_to_limit(mut bus, mut s)
	// The third header ran to 45 ms: the fourth goes then, and the grid follows from it.
	assert rel(sent) == [i64(0), 100, 200, 450, 550, 650]
	assert s.stats().late == 1
}

fn test_switch_at_end_of_slot() {
	mut clk, mut bus := fake(7)
	mut s := new_scheduler(bus, [Slot{0x01, 10}, Slot{0x02, 10}],
		name:    'A'
		clock:   clk
		sleeper: clk
	)!
	sp := s
	bus.hook = fn [sp] (n int) {
		if n == 2 {
			mut t := sp
			t.switch_to([Slot{0x20, 5}], 'B') or { panic(err) }
		}
	}
	assert s.stats().schedule == 'A'
	sent := run_to_limit(mut bus, mut s)
	assert sent.map(it.id) == [u8(0x01), 0x02, 0x01, 0x20, 0x20, 0x20, 0x20]
	// Switched during 0x01's slot at 20 ms: B starts when that slot ends, at 30 ms.
	assert rel(sent) == [i64(0), 100, 200, 300, 350, 400, 450]
	assert s.stats().schedule == 'B'
}

fn test_stop_is_bounded_while_a_header_hangs() {
	mut clk, mut bus := fake(10)
	bus.blocking = true
	mut s := new_scheduler(bus, [Slot{0x01, 10}], clock: clk, sleeper: clk, stop_wait_ms: 5)!
	s.start()!
	for {
		bus.mu.lock()
		n := bus.sent.len
		bus.mu.unlock()
		if n == 2 {
			break
		}
	}
	assert !s.stop() // still inside the header
	assert s.stats().running
	bus.block <- true
	mut ended := false
	for _ in 0 .. 200 {
		if s.stop() {
			ended = true
			break
		}
	}
	assert ended
	assert !s.stats().running
	bus.mu.lock()
	assert bus.sent.len == 2 // nothing sent after the stop
	bus.mu.unlock()
}

fn test_stop_during_a_long_wait() {
	_, mut bus := fake(1)
	mut s := new_scheduler(bus, [Slot{0x01, 60_000}], poll_ms: 2)!
	s.start()!
	_ := <-bus.full
	assert s.stop() // within one 2 ms poll, not the minute
}

fn test_bus_gone_ends_the_run() {
	mut clk, mut bus := fake(1)
	bus.gone = true
	mut s := new_scheduler(bus, [Slot{0x01, 10}], clock: clk, sleeper: clk)!
	s.start()!
	for s.stats().running {
	}
	st := s.stats()
	assert st.failed == 1 && st.sent == 0
	assert st.last_error == 'closed'
	assert s.stop()
}

fn test_slots_checked() {
	_, bus := fake(1)
	new_scheduler(bus, [], SchedOpts{}) or {
		assert err.msg().contains('at least one slot')
		new_scheduler(bus, [Slot{0x01, 0}], SchedOpts{}) or {
			assert err.msg().contains('must be above 0')
			new_scheduler(bus, [Slot{0x40, 10}], SchedOpts{}) or {
				assert err.msg().contains('above 0x3F')
				return
			}
		}
	}
	assert false
}
