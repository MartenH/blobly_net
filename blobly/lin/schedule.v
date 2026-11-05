module lin

import sync
import sync.stdatomic
import time
import blobly.transport

// Slot is one entry of a schedule table: a header, then delay_ms until the next slot starts.
pub struct Slot {
pub:
	id       u8
	delay_ms f64
}

// HeaderSender is what a scheduler drives: every master Bus is one.
pub interface HeaderSender {
mut:
	header(id u8) !
}

// Sleeper waits; a test injects one that moves a synthetic clock instead.
pub interface Sleeper {
	sleep_ns(ns i64)
}

// RealSleep sleeps on the host.
pub struct RealSleep {}

pub fn (s RealSleep) sleep_ns(ns i64) {
	time.sleep(ns * time.nanosecond)
}

pub struct SchedOpts {
pub:
	name    string
	clock   Clock   = MonoClock{}
	sleeper Sleeper = RealSleep{}
	// poll_ms is the longest single wait, so a stop is seen within it.
	poll_ms int = 20
	// stop_wait_ms bounds stop(): how long it waits for the thread to end.
	stop_wait_ms int = 100
}

pub struct SchedStats {
pub:
	sent u64
	// failed is headers the bus refused.
	failed u64
	// late is slots that started after their time, from which the grid was taken up again.
	late       u64
	last_error string
	schedule   string
	running    bool
}

// HostScheduler runs a schedule table on its own thread, sending each slot's header at its
// start on an absolute grid: a slot starts where the previous one's delay ends, however late
// the wait woke, so lateness does not accumulate. A slot that starts after its time (a header
// call that ran long) is sent at once and the grid is taken up again from it, so the slots
// after it are not sent in a burst. The bus going away (transport.CarrierGone) ends the run.
@[heap]
pub struct HostScheduler {
mut:
	bus     HeaderSender
	clock   Clock
	sleeper Sleeper
	poll_ns i64
	wait_ms int
	// slots and name are the running table, the thread's own.
	slots []Slot
	name  string
	// guarded by mu
	mu           sync.Mutex
	pending      []Slot
	pending_name string
	has_pending  bool
	sent         u64
	failed       u64
	late         u64
	last_error   string
	cur_name     string
	started      bool
	ended        bool
	stopping     u64
	done         chan bool
}

pub fn new_scheduler(bus HeaderSender, slots []Slot, opts SchedOpts) !&HostScheduler {
	check_slots(slots)!
	if opts.poll_ms < 1 {
		return error('lin: poll_ms ${opts.poll_ms} must be at least 1')
	}
	return &HostScheduler{
		bus:      bus
		clock:    opts.clock
		sleeper:  opts.sleeper
		poll_ns:  i64(opts.poll_ms) * 1_000_000
		wait_ms:  opts.stop_wait_ms
		slots:    slots.clone()
		name:     opts.name
		cur_name: opts.name
		done:     chan bool{}
	}
}

fn check_slots(slots []Slot) ! {
	if slots.len == 0 {
		return error('lin: a schedule needs at least one slot')
	}
	for i, s in slots {
		check_id(s.id)!
		if !(s.delay_ms > 0) {
			return error('lin: slot ${i} (0x${s.id:02X}) has delay ${s.delay_ms} ms; it must be above 0')
		}
	}
}

fn slot_ns(s Slot) i64 {
	return i64(s.delay_ms * 1_000_000.0 + 0.5)
}

// start runs the schedule on a thread of its own.
pub fn (mut s HostScheduler) start() ! {
	s.mu.lock()
	if s.started {
		s.mu.unlock()
		return error('lin: scheduler already started')
	}
	s.started = true
	s.mu.unlock()
	spawn s.run()
}

// switch_to replaces the table at the end of the current slot; the new one starts at its first.
pub fn (mut s HostScheduler) switch_to(slots []Slot, name string) ! {
	check_slots(slots)!
	s.mu.lock()
	s.pending = slots.clone()
	s.pending_name = name
	s.has_pending = true
	s.mu.unlock()
}

// stop ends the run: no header is sent after it returns true. It waits at most stop_wait_ms;
// false means the thread is still inside a header call, and it ends, sending nothing more, when
// that call returns.
pub fn (mut s HostScheduler) stop() bool {
	stdatomic.store_u64(&s.stopping, 1)
	s.mu.lock()
	started := s.started
	s.mu.unlock()
	if !started {
		return true
	}
	// The select is an expression: false is the closed channel, which is the thread ended.
	timed_out := select {
		_ := <-s.done {
		}
		(i64(s.wait_ms) * time.millisecond) {
		}
	}
	return !timed_out
}

pub fn (mut s HostScheduler) stats() SchedStats {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return SchedStats{
		sent:       s.sent
		failed:     s.failed
		late:       s.late
		last_error: s.last_error
		schedule:   s.cur_name
		running:    s.started && !s.ended
	}
}

fn (mut s HostScheduler) stopped() bool {
	return stdatomic.load_u64(&s.stopping) != 0
}

// take_pending moves a switched-to table into place.
fn (mut s HostScheduler) take_pending() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.has_pending {
		return false
	}
	s.slots = s.pending
	s.name = s.pending_name
	s.cur_name = s.pending_name
	s.has_pending = false
	return true
}

fn (mut s HostScheduler) run() {
	defer {
		s.mu.lock()
		s.ended = true
		s.mu.unlock()
		s.done.close()
	}
	s.take_pending()
	mut k := 0
	mut start := s.clock.now_ns()
	mut first := true
	for !s.stopped() {
		mut now := s.clock.now_ns()
		if !first && now > start {
			// The slot's time passed before it was waited for: send now, take the grid up from here.
			start = now
			s.mu.lock()
			s.late++
			s.mu.unlock()
		}
		for now < start {
			if s.stopped() {
				return
			}
			left := start - now
			s.sleeper.sleep_ns(if left < s.poll_ns { left } else { s.poll_ns })
			now = s.clock.now_ns()
		}
		if s.stopped() {
			return
		}
		first = false
		slot := s.slots[k]
		mut ok := true
		mut gone := false
		s.bus.header(slot.id) or {
			ok = false
			gone = err is transport.CarrierGone
			s.mu.lock()
			s.failed++
			s.last_error = err.msg()
			s.mu.unlock()
		}
		if gone {
			return
		}
		if ok {
			s.mu.lock()
			s.sent++
			s.mu.unlock()
		}
		start += slot_ns(slot)
		k = (k + 1) % s.slots.len
		if s.take_pending() {
			k = 0
		}
	}
}
