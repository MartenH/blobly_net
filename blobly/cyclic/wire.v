// wire.v — one sending loop and one send-only handle for every periodic source on a wire: a
// run's generators and background senders, each an Entry on the grid it has alone (sim.next_due),
// the loop waiting for the earliest one due or a wake-up. The handle is never read, so on a
// shared-hub wire it is no subscriber. A long J1939 message is a transfer the loop steps (tp.v),
// each of its frames one more thing due, so it holds no other entry back.
module cyclic

import sync
import time
import blobly.sim
import blobly.transport

// idle_wait_ms is the longest a loop waits with nothing due: every change that makes something
// due wakes it, so this only bounds a wake-up lost to nobody.
const idle_wait_ms = u64(1000)

// Entry is one source of frames a Wire sends, its methods called by the wire's loop alone.
pub interface Entry {
	// leaving is true once it asked to go: the wire lets it go before sending anything more
mut:
	leaving() bool
	// due is when it sends next (ms on the monotonic clock), none while nothing is due
	due(now u64) ?u64
	// serve sends what is due at `now` on the wire's handle; what to say ('' nothing)
	serve(mut bus transport.Bus, now u64) string
	// quit ends what it has in progress on the wire's handle (a transfer, tp.v), the handle still
	// open: called before let_go when the wire, open, lets it go
	quit(mut bus transport.Bus)
	// let_go is called once, when the wire lets it go: `failure` why the wire cannot send ('' it
	// was asked to go, or the wire stopped)
	let_go(failure string)
}

enum WireState {
	opening
	open
	failed
	ended
}

struct Slot {
	id int
mut:
	e Entry
}

// Wire is one wire's loop and its entries; `run` is the loop.
@[heap]
pub struct Wire {
pub:
	iface string // what the loop opens
mut:
	mu      sync.Mutex
	entries []Slot
	version int // moves whenever entries does, so the loop copies it only then
	next_id int
	state   WireState
	why     string // why it failed
	asked   bool
	solo    bool // it ends once its last entry left (a sender started alone)
	life    Life
	say     fn (string) = unsafe { nil }
	wake    chan bool   = chan bool{cap: 1}
}

// new_wire is a wire to `iface`, its loop not yet started; `say` is told what an entry says.
pub fn new_wire(iface string, say fn (string)) &Wire {
	return &Wire{
		iface: iface
		say:   say
	}
}

// add puts `e` on the wire from its next pass; refused once the wire failed or ended.
pub fn (mut w Wire) add(e Entry) ! {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	match w.state {
		.failed { return error(w.why) }
		.ended { return error('the wire is stopped: nothing is sent') }
		else {}
	}
	if w.asked {
		return error('the wire is stopped: nothing is sent')
	}
	w.entries << Slot{
		id: w.next_id
		e:  e
	}
	w.next_id++
	w.version++
	w.wake.try_push(true)
}

// failed is whether the wire's open failed: it takes no entries, and a new wire may be opened.
pub fn (mut w Wire) failed() bool {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	return w.state == .failed
}

// poke wakes the loop: something became due sooner than it waits for.
pub fn (mut w Wire) poke() {
	w.wake.try_push(true)
}

// ask_stop asks the loop to end, without waiting.
pub fn (mut w Wire) ask_stop() {
	w.mu.lock()
	w.asked = true
	w.mu.unlock()
	w.wake.try_push(true)
}

// wait_opened waits until the loop has opened its handle, or failed to, or was asked to stop;
// the open's refusal, or that it stopped.
pub fn (mut w Wire) wait_opened() ! {
	for {
		w.mu.lock()
		st, why, asked := w.state, w.why, w.asked
		w.mu.unlock()
		match st {
			.open { return }
			.failed { return error(why) }
			.ended { return error('the wire is stopped: nothing is sent') }
			.opening {}
		}
		if asked {
			return error('the wire is stopped: nothing is sent')
		}
		time.sleep(2 * time.millisecond)
	}
}

// stopping is whether the loop is to end: asked to, or its owner no longer runs.
fn (mut w Wire) stopping() bool {
	if w.life.running != unsafe { nil } && !w.life.running() {
		return true
	}
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	return w.asked
}

fn now_ms() u64 {
	return time.sys_mono_now() / 1_000_000
}

// run opens the wire's handle with `open` and serves its entries until asked to stop (or, solo,
// until its last entry left): every entry let go, the handle closed, its diagnostics returned. An
// open that fails lets every entry go with the reason, which it returns.
pub fn (mut w Wire) run(open fn (string) !transport.Bus) !transport.BusDiagnostics {
	defer {
		if w.life.ended != unsafe { nil } {
			w.life.ended()
		}
	}
	mut bus := open(w.iface) or {
		why := 'cannot open ${w.iface}: ${err}'
		w.mu.lock()
		w.state = .failed
		w.why = why
		mut gone := w.entries.clone()
		w.entries = []
		w.version++
		w.mu.unlock()
		for mut sl in gone {
			sl.e.let_go(why)
		}
		return error(why)
	}
	w.mu.lock()
	w.state = .open
	w.mu.unlock()
	mut mine := []Slot{}
	mut seen := -1
	mut last := []Slot{} // a solo wire's last entries, let go once the handle is closed
	outer: for {
		if w.stopping() {
			break
		}
		w.mu.lock()
		if w.version != seen {
			mine = w.entries.clone()
			seen = w.version
		}
		w.mu.unlock()
		mut earliest := max_u64
		mut leaving := []int{}
		for mut sl in mine {
			if sl.e.leaving() {
				leaving << sl.id
				continue
			}
			now := now_ms()
			mut next := sl.e.due(now) or { continue }
			if next <= now {
				// a stop asked while an earlier entry's send was blocked starts no further send
				if w.stopping() {
					break outer
				}
				said := sl.e.serve(mut bus, now)
				if said != '' && w.say != unsafe { nil } {
					w.say(said)
				}
				next = sl.e.due(now_ms()) or { continue }
			}
			if next < earliest {
				earliest = next
			}
		}
		if leaving.len > 0 {
			mut gone := mine.filter(it.id in leaving)
			w.mu.lock()
			w.entries = w.entries.filter(it.id !in leaving)
			w.version++
			done := w.solo && w.entries.len == 0
			if done {
				w.state = .ended
			}
			w.mu.unlock()
			for mut sl in gone {
				sl.e.quit(mut bus)
			}
			if done {
				last = gone.clone()
				break
			}
			for mut sl in gone {
				sl.e.let_go('')
			}
		}
		after := now_ms()
		// an owner asked at every poll is asked at least that often
		cap := if w.life.running != unsafe { nil } { u64(poll_ms) } else { idle_wait_ms }
		wait := sim.wait_until(earliest, after, cap)
		select {
			_ := <-w.wake {
			}
			i64(wait) * time.millisecond {
			}
		}
	}
	w.mu.lock()
	mut held := w.entries.clone()
	w.mu.unlock()
	for mut sl in held {
		sl.e.quit(mut bus)
	}
	bus.close()
	w.mu.lock()
	w.state = .ended
	mut rest := w.entries.clone()
	w.entries = []
	w.version++
	w.mu.unlock()
	for mut sl in last {
		sl.e.let_go('')
	}
	for mut sl in rest {
		sl.e.let_go('')
	}
	return bus.diagnostics()
}
