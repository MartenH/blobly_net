module headless

import time
import sync
import blobly.candb
import blobly.cyclic
import blobly.project
import blobly.sim
import blobly.transport

// generators.v — the run's generators (`senders:`), each an entry of the run's wire to its target
// (cyclic.Wire): one loop and one send-only handle per wire send every generator and background
// sender on it, each on its own cycle while it runs and a generator on every fire asked for. A
// cyclic generator joins its wire with the run; any other at its first fire or start. The control
// a script has over them is sim.GenControl, which Run answers here.

// run_stopped is what a fire still queued when its wire stops is answered with.
const run_stopped = 'the run stopped'

@[heap]
struct Gen {
mut:
	mu      sync.Mutex
	s       project.Sender // as edited
	channel string         // the channel it is written under
	open    string         // the interface its wire opens; '' when it has nothing to send on
	row     string         // the row it sends as (transport.row_framed): the one owning its target, '' none
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
	// the signals it lists that carry no number (sim.sender_signal_refusals): said at the start
	signal_notes []string
	sent    i64
	// edits of what it sends (a signal's value or source, a signal unset, its payload), and how
	// many of them the last frame the bus took was built after
	edits      i64
	sent_edits i64
	spawned bool // it joined its wire
	ended   bool // its wire let it go: a fire is not queued for it
	// the fires waiting for the wire's loop, oldest first
	queue  []&Fire
	wire   &cyclic.Wire = unsafe { nil }
	ctl    &Ctl
	run_t0 u64
	// the wire's loop's alone: whether it was cyclic at the last pass, whether its cycle sends at
	// once (started, or started again), why the cycle's last send failed (said once while it
	// repeats), the note to go back to when it sends again, the grid slot the cycle last sent in
	// and when that send returned, and the wire's handle as its row
	was       bool
	fresh     bool = true
	failed    string
	base_note string
	slot      u64
	done      u64
	framed    ?transport.Bus
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
		ctl:     r.ctl
		run_t0:  r.run_t0
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
	g.row = sb.chan
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
				g.signal_notes = sim.sender_signal_refusals(s, g.dbs)
				return
			}
		}
		g.note = 'message "${s.message}" is not in the channel databases'
		g.open = ''
	}
}

// spawn_gen puts g on its wire, starting the wire's loop unless it runs, unless g is on it or the
// run is stopping; false when it is stopping.
fn (mut r Run) spawn_gen(mut g Gen) bool {
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
	if first {
		g.base_note = g.note
	}
	g.mu.unlock()
	if first {
		mut w := r.wire_for(g.open)
		g.mu.lock()
		g.wire = w
		g.mu.unlock()
		w.add(g) or { g.let_go(err.msg()) }
	}
	return true
}

// wire_for is the run's wire to `iface`, its loop started if it is new; the caller holds r.mu and
// has checked the run is not stopping.
fn (mut r Run) wire_for(iface string) &cyclic.Wire {
	key := transport.destination_key(iface)
	if w := r.wires[key] {
		return w
	}
	mut w := cyclic.new_wire(iface, fn [r] (s string) {
		mut rr := unsafe { r }
		rr.say(s)
	})
	r.wires[key] = w
	r.counted()
	spawn r.wire_loop(mut w)
	return w
}

// wire_loop runs wire w until the run's stop: one of the run's loops, counted out on every way.
fn (mut r Run) wire_loop(mut w cyclic.Wire) {
	defer {
		r.done()
	}
	d := w.run(r.gen_opener) or {
		r.say('${err}: its generators and background senders send nothing')
		return
	}
	// after the close: see sim_loop
	r.report_diag('${w.iface} (generators and background senders)', d)
}

// leaving is false: a generator stays on its wire until the run stops.
fn (mut g Gen) leaving() bool {
	return false
}

// due is when g sends next: at once for a fire waiting or a cycle (re)started, else on its grid
// by the cycle as it is now, so a shorter one applies at once; on its grid from the time the send
// returned, so a slow write is not followed by a catch-up frame. The send index counts DELIVERED
// frames only, as the GUI's does, so a counter source never skips a value a refused send did not
// put on the wire.
fn (mut g Gen) due(now u64) ?u64 {
	g.mu.lock()
	cyc := g.cyclic
	period := u64(g.s.cycle_ms)
	if g.restart {
		g.restart = false
		g.fresh = true
	}
	fire := g.queue.len > 0
	g.mu.unlock()
	if cyc && !g.was {
		g.fresh = true
	}
	g.was = cyc
	if fire || (cyc && g.fresh) {
		return now
	}
	if !cyc {
		return none
	}
	return sim.next_due(g.slot, period, g.done)
}

// serve sends g's cyclic frame if it is due, then one fire: however far behind the cycle is, a
// fire is served, and however full the queue is kept, the cycle is; one taken after a stop began
// is not sent. What it says is a cyclic send's failure, once while it repeats.
fn (mut g Gen) serve(mut bus transport.Bus, now u64) string {
	mut b := g.framed or {
		f := transport.row_framed(bus, g.open, g.row)
		g.framed = f
		f
	}
	g.mu.lock()
	cyc := g.cyclic
	period := u64(g.s.cycle_ms)
	g.mu.unlock()
	mut said := ''
	if cyc && (g.fresh || now >= sim.next_due(g.slot, period, g.done)) {
		g.slot = if g.fresh { now } else { sim.next_due(g.slot, period, g.done) }
		g.fresh = false
		why := g.send(mut b)
		g.done = time.sys_mono_now() / 1_000_000
		if why != g.failed {
			g.failed = why
			g.mu.lock()
			g.note = if why != '' { why } else { g.base_note }
			g.mu.unlock()
			if why != '' {
				said = 'generator "${g.s.name}": ${why}'
			}
		}
	}
	if mut fire := g.next_fire() {
		if fire.take(time.sys_mono_now()) {
			fire.reply <- answered(if g.ctl.running { g.send(mut b) } else { run_stopped })
			// a slot the fire's write covered is skipped too
			g.done = time.sys_mono_now() / 1_000_000
		}
	}
	return said
}

// let_go is g's wire letting it go: `failure` its note (the wire could not open), every fire still
// queued answered with it, or with run_stopped when the run stopped.
fn (mut g Gen) let_go(failure string) {
	if failure != '' {
		g.mu.lock()
		g.note = failure
		g.mu.unlock()
	}
	g.end(if failure != '' { failure } else { run_stopped })
}

// poke wakes g's wire: a fire queued, a start or a cycle changed.
fn (mut g Gen) poke() {
	g.mu.lock()
	mut w := g.wire
	g.mu.unlock()
	if !isnil(w) {
		w.poke()
	}
}

// send puts g's frame on the bus once: '' when the bus took it, else why not.
fn (mut g Gen) send(mut bus transport.Bus) string {
	g.mu.lock()
	s := project.Sender{
		...g.s
		signals: g.s.signals.clone()
		data:    g.s.data.clone()
	}
	n := int(g.sent)
	edits := g.edits
	g.mu.unlock()
	el := f64(time.sys_mono_now() - g.run_t0) / 1_000_000_000.0
	frame := if s.message != '' {
		sim.sender_message_frame(s, g.dbs, n, el) or { return err.msg() }
	} else {
		sim.sender_raw_frame(s, s.id, s.ext, s.data.clone()) or { return err.msg() }
	}
	bus.send(frame) or { return 'not sent: ${err}' }
	g.mu.lock()
	g.sent++
	g.sent_edits = edits
	g.mu.unlock()
	return ''
}

// end marks g let go and answers every fire still queued with `why`.
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

// payload_cap is the most a frame row `row` sends on `iface` carries of a payload: a classic frame
// on a wire SocketCAN clamps takes 8 bytes, any other frame 64 (a vendor backend refuses what its
// wire cannot carry, a software bus carries it).
fn payload_cap(iface string, row string) int {
	fd := transport.row_framing(iface, row).fd || transport.wire_framing(iface).fd
	return if transport.clamps_to_classic(iface) && !fd { 8 } else { 64 }
}

// data_cap is the most a raw frame row `row` sends on `iface` carries: 64 bytes where the row or
// the wire is CAN-FD, else 8 (a classic frame past 8 bytes is refused or clamped by every bus).
fn data_cap(iface string, row string) int {
	fd := transport.row_framing(iface, row).fd || transport.wire_framing(iface).fd
	return if fd { 64 } else { 8 }
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
		applied:  g.sent_edits == g.edits
		data:     if g.s.message == '' { g.s.data.clone() } else { []u8{} }
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
	if !r.spawn_gen(mut g) {
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
	g.poke()
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
		why := if g.cycle_note != '' { ' (${g.cycle_note})' } else { '' }
		g.mu.unlock()
		return sim.gen_error(.refused, 'generator "${g.s.name}" has no cycle${why}: give it one')
	}
	if g.open == '' || g.ended {
		g.mu.unlock()
		return g.sendable()
	}
	g.s.cycle_ms = ms
	g.cyclic = true
	g.restart = true
	g.mu.unlock()
	g.poke()
	if !r.spawn_gen(mut g) {
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
	g.poke()
}

// gen_value sends `signal` of generator g at the static `value` from its next frame.
pub fn (mut r Run) gen_value(i int, signal string, value f64) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	sim.gen_set_value(mut g.s, g.dbs, payload_cap(g.open, g.row), signal, value)!
	g.edits++
}

// gen_source gives `signal` of generator g the value source `w` from its next frame.
pub fn (mut r Run) gen_source(i int, signal string, w project.GenCfg) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	sim.gen_set_source(mut g.s, g.dbs, payload_cap(g.open, g.row), signal, w)!
	g.edits++
}

// gen_signals is generator g's signals as its next frame takes them, each once.
pub fn (mut r Run) gen_signals(i int) ![]project.SenderSig {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	return sim.gen_signals(g.s)
}

// gen_unset takes `signal` off generator g's list from its next frame.
pub fn (mut r Run) gen_unset(i int, signal string) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	sim.gen_unset(mut g.s, signal)!
	g.edits++
}

// gen_data sends raw generator g's frame with the payload `data` from its next frame.
pub fn (mut r Run) gen_data(i int, data []u8) ! {
	mut g := r.gen(i)!
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	sim.gen_set_data(mut g.s, data_cap(g.open, g.row), data)!
	g.edits++
}
