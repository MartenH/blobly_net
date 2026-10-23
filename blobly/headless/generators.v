module headless

import time
import sync
import blobly.candb
import blobly.project
import blobly.sim
import blobly.transport

// generators.v — the run's generators (`senders:`), each sent by a loop of its own that holds its
// bus: its cycle while it runs, and a fire whenever one is asked for, so one thread uses the
// handle. A cyclic generator's loop starts with the run; any other's at its first fire or start.
// The control a script has over them is sim.GenControl, which Run answers here.

// run_stopped is what a fire still queued when its loop ends is answered with.
const run_stopped = 'the run stopped'

@[heap]
struct Gen {
mut:
	mu      sync.Mutex
	s       project.Sender // as edited
	channel string         // the channel it is written under
	open    string         // the interface its loop opens; '' when it has nothing to send on
	note    string         // why it cannot send, '' when it can
	dbs     []candb.Database
	id      u32 // its frame's id: its message's, for one with a message
	ext     bool
	cyclic  bool // sending on its cycle
	restart bool // its cycle starts again from now (gen_start)
	left    bool // every row on its target has left the run: it is not said at the start
	// a cycle the project gives that a generator cannot have: said at the start, the generator
	// left with none (a fire still sends it, and gen_start gives it one)
	cycle_note string
	sent    i64
	spawned bool // its loop was started
	ended   bool // its loop is out: a fire is not queued for it
	// the fires waiting for the loop, oldest first, and its wake-up when one is queued
	queue []&Fire
	wake  chan bool = chan bool{cap: 1}
}

// fires_waiting is how many fires may wait for one generator's loop at once.
const fires_waiting = 4

// Fire is one fire request: sent by the loop only when it takes it before `until` (the
// monotonic clock, ns) and before the caller gave up on it.
@[heap]
struct Fire {
	until u64
mut:
	mu      sync.Mutex
	taken   bool // the loop took it: its frame is being sent
	dropped bool // given up before the loop took it: it is never sent
	reply   chan Answer = chan Answer{cap: 1}
}

// Answer is the loop's answer to a fire: why it was not sent ('' when the bus took it), and when
// the loop answered (the monotonic clock, ns).
struct Answer {
	why string
	at  u64
}

// answered is the loop's answer of `why`, now.
fn answered(why string) Answer {
	return Answer{
		why: why
		at:  time.sys_mono_now()
	}
}

// take is true when the loop may send it now: not given up on, and not past its time — which a
// caller held off the processor past its wait cannot have checked yet.
fn (mut f Fire) take(now u64) bool {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	if f.dropped || now >= f.until {
		f.dropped = true
		return false
	}
	f.taken = true
	return true
}

// is_dropped says it was given up on.
fn (mut f Fire) is_dropped() bool {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	return f.dropped
}

// given is the loop's answer if it has given one, without waiting.
fn (f &Fire) given() ?Answer {
	select {
		a := <-f.reply {
			return a
		}
		else {
			return none
		}
	}
	return none
}

// drop gives it up: false when the loop has taken it already.
fn (mut f Fire) drop() bool {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	if f.taken {
		return false
	}
	f.dropped = true
	return true
}

// add_gen adds generator `s` of row `ci`, as bring_up resolves it: where it sends, and with which
// databases; `note` when it can send nowhere.
fn (mut r Run) add_gen(ci int, s project.Sender, mut row_dbs map[int]candb.Database, proj_dir string, files &DbFiles) {
	proj := r.proj
	ch := proj.channels[ci]
	mut g := &Gen{
		// the run's own copy: an edit lasts for the run, never reaching the loaded project
		s:       project.Sender{
			...s
			signals: s.signals.clone()
			data:    s.data.clone()
		}
		channel: ch.name
		id:      s.id
		ext:     s.ext
	}
	r.gens << g
	// what it is, from its own channel's databases, even where it can send nowhere; what it sends
	// is resolved below from its target's
	if s.message != '' {
		own := row_db(mut row_dbs, proj.channels, ci, proj_dir, files)
		if m := own.message_named(s.message) {
			g.id, g.ext = m.id, m.ext
		}
	}
	if s.cycle_ms > sim.gen_cycle_max_ms {
		g.cycle_note = 'its cycle of ${s.cycle_ms} ms is past ${sim.gen_cycle_max_ms}'
		g.s.cycle_ms = 0
	}
	sb := project.resolve_sender_bus(s.bus, ch, proj.channels)
	if sb.iface == '' {
		g.note = sb.note
		return
	}
	rows := project.sender_target_rows(sb, ci, proj.channels)
	enabled := rows.filter(proj.channels[it].enabled)
	if rows.len > 0 && enabled.len == 0 {
		g.note = 'every channel on ${sb.iface} has left the run'
		g.left = true
		return
	}
	g.open = if enabled.len > 0 {
		proj.channels[enabled[0]].iface_with_bitrate()
	} else {
		sb.iface
	}
	if s.message != '' {
		for row in rows {
			g.dbs << row_db(mut row_dbs, proj.channels, row, proj_dir, files)
		}
		for db in g.dbs {
			if m := db.message_named(s.message) {
				g.id, g.ext = m.id, m.ext
				return
			}
		}
		g.note = 'message "${s.message}" is not in the channel databases'
		g.open = ''
	}
}

// spawn_gen starts g's loop unless it runs or the run is stopping; false when it is stopping.
fn (mut r Run) spawn_gen(mut g Gen, run_t0 u64) bool {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if r.stopping {
		return false
	}
	g.mu.lock()
	first := !g.spawned
	g.spawned = true
	g.mu.unlock()
	if first {
		r.counted()
		spawn r.gen_loop(mut g, run_t0)
	}
	return true
}

// gen_loop sends g's frame on its cycle while it runs and on every fire, until the run stops —
// the headless counterpart of the GUI's gen_loop, the frame built by sim.sender_message_frame.
// The send index counts DELIVERED frames only, as the GUI's does, so a counter source never skips
// a value a refused send did not put on the wire.
fn (mut r Run) gen_loop(mut g Gen, run_t0 u64) {
	defer {
		r.done()
	}
	mut bus := r.gen_opener(g.open) or {
		why := 'cannot open ${g.open}: ${err}'
		// one step: a start or a fire sees the loop running or gone, never between
		g.mu.lock()
		g.note = why
		g.cyclic = false
		g.ended = true
		g.mu.unlock()
		r.say('generator "${g.s.name}": ${why}')
		g.end(why)
		return
	}
	mut was := false
	mut fresh := true // the cycle sends at once: started, or started again
	mut last := u64(0) // when the cycle last sent
	for r.ctl.running {
		g.mu.lock()
		cyc := g.cyclic
		period := u64(g.s.cycle_ms)
		if g.restart {
			g.restart = false
			fresh = true
		}
		g.mu.unlock()
		if cyc && !was {
			fresh = true
		}
		was = cyc
		// the handle is never read: on a shared-hub wire it is then no subscriber, and has no
		// cursor to fall behind the ring and book as the wire's loss
		now := time.sys_mono_now() / 1_000_000
		// due by the cycle as it is now, so a shorter one applies at once
		if cyc && (fresh || now >= last + period) {
			// on its grid, unless a stall put it a cycle behind: no burst of catch-up frames
			last = if fresh || now >= last + 2 * period { now } else { last + period }
			fresh = false
			g.send(mut bus, run_t0)
		}
		// a fire is served between cyclic frames, however far behind the cycle is
		after := time.sys_mono_now() / 1_000_000
		mut wait := u64(20)
		if cyc {
			due := last + period
			wait = if due <= after { 0 } else if due - after < wait { due - after } else { wait }
		}
		select {
			_ := <-g.wake {}
			i64(wait) * time.millisecond {}
		}
		// every fire waiting, in order; one taken after a stop began is not sent
		for {
			mut fire := g.next_fire() or { break }
			if fire.take(time.sys_mono_now()) {
				fire.reply <- answered(if r.ctl.running { g.send(mut bus, run_t0) } else { run_stopped })
			}
		}
	}
	bus.close()
	g.end(run_stopped)
	r.report_diag('${g.open} (generator ${g.s.name})', bus.diagnostics())
}

// send puts g's frame on the bus once: '' when the bus took it, else why not.
fn (mut g Gen) send(mut bus transport.Bus, run_t0 u64) string {
	g.mu.lock()
	s := project.Sender{
		...g.s
		signals: g.s.signals.clone()
	}
	n := int(g.sent)
	g.mu.unlock()
	el := f64(time.sys_mono_now() - run_t0) / 1_000_000_000.0
	frame := if s.message != '' {
		sim.sender_message_frame(s, g.dbs, n, el) or {
			return 'message "${s.message}" is not in the channel databases'
		}
	} else {
		transport.CanFrame{
			id:       s.id
			extended: s.ext
			data:     s.data.clone()
		}
	}
	bus.send(frame) or { return 'not sent: ${err}' }
	g.mu.lock()
	g.sent++
	g.mu.unlock()
	return ''
}

// end marks g's loop out and answers every fire still queued with `why`.
fn (mut g Gen) end(why string) {
	g.mu.lock()
	g.ended = true
	g.cyclic = false
	g.mu.unlock()
	for {
		mut f := g.next_fire() or { break }
		if f.take(0) {
			f.reply <- answered(why)
		}
	}
}

// next_fire is the oldest fire waiting, taken off the queue; none when none waits.
fn (mut g Gen) next_fire() ?&Fire {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	if g.queue.len == 0 {
		return none
	}
	f := g.queue[0]
	g.queue.delete(0)
	return f
}

// gen is generator i, or the refusal for a run that has no such one or is stopping.
fn (mut r Run) gen(i int) !&Gen {
	r.mu.lock()
	stopping := r.stopping
	r.mu.unlock()
	if stopping {
		return sim.gen_error(.stopped, 'the run is stopped: its generators send nothing')
	}
	if i < 0 || i >= r.gens.len {
		return sim.gen_error(.refused, 'no generator ${i} (the run has ${r.gens.len})')
	}
	return r.gens[i]
}

// payload_cap is the most a frame on `iface` carries of a payload: a classic wire SocketCAN clamps
// takes 8 bytes, any other frame 64 (a vendor backend refuses what its wire cannot carry, a
// software bus carries it).
fn payload_cap(iface string) int {
	return if transport.clamps_to_classic(iface) && !transport.wire_framing(iface).fd { 8 } else { 64 }
}

// sendable is g's refusal when it has nothing to send on.
fn (mut g Gen) sendable() ! {
	g.mu.lock()
	note := g.note
	ok := g.open != '' && !g.ended
	g.mu.unlock()
	if !ok {
		return sim.gen_error(.refused, 'generator "${g.s.name}" cannot send: ${if note != '' {
			note
		} else {
			'the run stopped'
		}}')
	}
}

pub fn (mut r Run) generators() []sim.GenInfo {
	stopping := r.is_stopping()
	mut out := []sim.GenInfo{}
	for mut g in r.gens {
		out << g.info(stopping)
	}
	return out
}

// gen_info is generator i as it is now; refused once the run is stopping.
pub fn (mut r Run) gen_info(i int) !sim.GenInfo {
	mut g := r.gen(i)!
	return g.info(false)
}

// info is g as it is now; nothing of a run that is stopping runs, whatever a loop still out says.
fn (mut g Gen) info(stopping bool) sim.GenInfo {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	return sim.GenInfo{
		name:     g.s.name
		channel:  g.channel
		message:  g.s.message
		id:       g.id
		ext:      g.ext
		trigger:  g.s.trigger
		cycle_ms: if g.s.cycle_ms > 0 { g.s.cycle_ms } else { 0 }
		running:  g.cyclic && !stopping
		sent:     g.sent
		target:   g.open
		note:     g.note
	}
}

// gen_fire sends generator g's current frame once, and returns once the bus took it, or did not
// by `until` (the monotonic clock, ns; 0, or past sim.gen_fire_wait_ms from now: that long). A
// fire its loop reaches past `until` is not sent.
pub fn (mut r Run) gen_fire(i int, until u64) ! {
	latest := time.sys_mono_now() + u64(sim.gen_fire_wait_ms) * 1_000_000
	due := if until == 0 || until > latest { latest } else { until }
	mut g := r.gen(i)!
	g.sendable()!
	if !r.spawn_gen(mut g, r.run_t0) {
		return sim.gen_error(.stopped, 'the run is stopped: its generators send nothing')
	}
	mut f := &Fire{
		until: due
	}
	g.mu.lock()
	if g.ended {
		note := g.note
		g.mu.unlock()
		return fire_outcome(g.s.name, answered(if note != '' { note } else { run_stopped }), due,
			r.is_stopping())
	}
	// a fire its caller gave up on holds no place
	mut live := []&Fire{}
	for mut q in g.queue {
		if !q.is_dropped() {
			live << q
		}
	}
	g.queue = live
	if g.queue.len >= fires_waiting {
		g.mu.unlock()
		return sim.gen_error(.refused, 'generator "${g.s.name}": ${fires_waiting} fires are already waiting for its bus')
	}
	g.queue << f
	g.mu.unlock()
	g.wake.try_push(true)
	// in slices, so a stop is seen while the loop is held up (an open stalled in its driver)
	for {
		now := time.sys_mono_now()
		stopping := r.is_stopping()
		if now >= f.until || stopping {
			// an answer already given is the answer, though this caller was late to read it
			if a := f.given() {
				return fire_outcome(g.s.name, a, f.until, stopping)
			}
			// given up on here unless the loop has it, in which case its bus may yet send it
			fate := if f.drop() { 'nothing was sent' } else { 'it may still go out' }
			if stopping {
				return sim.gen_error(.stopped, 'generator "${g.s.name}": the run stopped before its bus took the frame; ${fate}')
			}
			return sim.gen_error(.timeout, 'generator "${g.s.name}": its bus did not take the frame in time; ${fate}')
		}
		left := i64((f.until - now) / 1_000_000) + 1
		select {
			a := <-f.reply {
				return fire_outcome(g.s.name, a, f.until, r.is_stopping())
			}
			i64(if left < 20 { left } else { 20 }) * time.millisecond {}
		}
	}
}

// fire_outcome is what a fire's caller is told of the loop's answer `a`, its deadline `until`,
// and whether a stop has begun: a stop that overtook the fire is the answer whatever became of
// the frame; then a refusal; then an answer past the deadline, which is a timeout though the frame
// went out.
fn fire_outcome(name string, a Answer, until u64, stopping bool) ! {
	if stopping || a.why == run_stopped {
		fate := if a.why == '' { 'its frame was sent' } else { a.why }
		return sim.gen_error(.stopped, 'generator "${name}": the run stopped; ${fate}')
	}
	if a.why != '' {
		return sim.gen_error(.refused, 'generator "${name}": ${a.why}')
	}
	if a.at > until {
		return sim.gen_error(.timeout, 'generator "${name}": its bus took the frame ${(a.at - until) / 1_000_000} ms past the wait; it went out')
	}
}

fn (mut r Run) is_stopping() bool {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	return r.stopping
}

// gen_start sends generator g on its cycle — `cycle_ms`, or its own when 0 — from now.
pub fn (mut r Run) gen_start(i int, cycle_ms int) ! {
	mut g := r.gen(i)!
	if cycle_ms != 0 {
		sim.gen_cycle_check(cycle_ms)!
	}
	// read, checked and set in one step: a cycle changed meanwhile is kept, and a loop that
	// failed to open is never started again
	g.mu.lock()
	ms := if cycle_ms != 0 { cycle_ms } else { g.s.cycle_ms }
	if ms <= 0 {
		g.mu.unlock()
		return sim.gen_error(.refused, 'generator "${g.s.name}" has no cycle: give it one')
	}
	if g.open == '' || g.ended {
		g.mu.unlock()
		return g.sendable()
	}
	g.s.cycle_ms = ms
	g.cyclic = true
	g.restart = true
	g.mu.unlock()
	if !r.spawn_gen(mut g, r.run_t0) {
		g.mu.lock()
		g.cyclic = false
		g.mu.unlock()
		return sim.gen_error(.stopped, 'the run is stopped: its generators send nothing')
	}
}

// gen_stop ends generator g's cycle; a fire still sends it.
pub fn (mut r Run) gen_stop(i int) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	g.cyclic = false
	g.mu.unlock()
}

// gen_cycle sets generator g's cycle; a running one keeps it from its next frame.
pub fn (mut r Run) gen_cycle(i int, ms int) ! {
	mut g := r.gen(i)!
	sim.gen_cycle_check(ms)!
	g.mu.lock()
	g.s.cycle_ms = ms
	g.mu.unlock()
}

// gen_value sends `signal` of generator g at the static `value` from its next frame.
pub fn (mut r Run) gen_value(i int, signal string, value f64) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	sim.gen_set_value(mut g.s, g.dbs, payload_cap(g.open), signal, value)!
}

// gen_source gives `signal` of generator g the value source `w` from its next frame.
pub fn (mut r Run) gen_source(i int, signal string, w project.GenCfg) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	sim.gen_set_source(mut g.s, g.dbs, payload_cap(g.open), signal, w)!
}
