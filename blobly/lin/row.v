// row — one LIN bus as a project describes it: the single owner of its handles, its simulated
// nodes publishing their LDF frames, the master's schedule, a live view per frame id, and taps
// that read every frame. Every front end (the headless run, a script, a later GUI panel) goes
// through a Row, so none of them opens the bus twice or keeps a rule of its own.
module lin

import sync
import sync.stdatomic
import time
import blobly.lindb
import blobly.transport

// RowSpec is one LIN bus of a project.
pub struct RowSpec {
pub:
	name    string
	address string
	// baud is the bus's rate; 0 takes the rate a serial address states, else the LDF's LIN_speed,
	// else 19200. A rate the address contradicts is refused.
	baud int
	// ldf is the description file's path; '' for none, which allows no simulate or schedule.
	ldf  string
	role Role
	// simulate is the LDF nodes this process plays: each publishes its frames at their init
	// values. The LDF's master node only in the master role.
	simulate []string
	// schedule is the table the master runs from the start; '' for none.
	schedule string
}

pub struct RowOpts {
pub:
	clock   Clock   = MonoClock{}
	sleeper Sleeper = RealSleep{}
	// tap_cap is each tap's queue; a full tap drops and counts.
	tap_cap int = 1024
}

// IdView is what the row has seen of one frame id.
pub struct IdView {
pub:
	id   u8
	name string // the LDF's name for it, '' when the LDF has none
	// count is frames seen, errors those with an error flag.
	count  u64
	errors u64
	last   Frame
	// cadence_ms is the time between the last two error-free frames, 0 before two.
	cadence_ms f64
	signals    []lindb.SignalValue // the last frame decoded through the LDF
}

// RowView is the row as a panel or a script reads it.
pub struct RowView {
pub:
	name     string
	address  string
	role     Role
	state    State
	schedule string
	frames   []IdView // by id
	// load_percent is the bus time frames took in the last whole second.
	load_percent f64
	// dropped is frames a full tap lost.
	dropped u64
	sched   SchedStats
	notes   []string
}

// Tap is one reader of every frame the row sees, from the moment it was taken.
@[heap]
pub struct Tap {
mut:
	q       chan Frame
	dropped u64
}

// recv is the tap's next frame within timeout_ms (0 a look): Timeout when none came,
// transport.CarrierGone once the row has stopped and the tap is drained.
pub fn (mut t Tap) recv(timeout_ms int) !Frame {
	if timeout_ms == 0 {
		mut f := Frame{}
		return match t.q.try_pop(mut f) {
			.success { f }
			.closed { row_stopped() }
			.not_ready { Timeout{} }
		}
	}
	mut got := false
	mut frame := Frame{}
	chan_open := select {
		f := <-t.q {
			got = true
			frame = f
		}
		(i64(if timeout_ms < 0 { 1 << 30 } else { timeout_ms }) * time.millisecond) {
		}
	}
	if got {
		return frame
	}
	if !chan_open {
		return row_stopped()
	}
	return Timeout{}
}

fn row_stopped() IError {
	return transport.CarrierGone{
		msg: 'the LIN row has stopped'
	}
}

// dropped is frames this tap lost to a full queue.
pub fn (t &Tap) dropped() u64 {
	return stdatomic.load_u64(&t.dropped)
}

struct IdState {
mut:
	count  u64
	errors u64
	last   Frame
	// last_ok_ns is the last error-free frame's time, when has_ok.
	last_ok_ns i64
	has_ok     bool
	cadence_ns i64
}

// Simulated is a node this row plays: its handle and the values its frames carry now.
struct Simulated {
	node string
	// shared: the node answers through the row's own handle, which the row reads and closes.
	shared bool
mut:
	bus    Bus
	values map[string]map[string]lindb.Value // frame name -> signal -> value set by set_signal
}

@[heap]
pub struct Row {
pub:
	spec RowSpec
	baud int
mut:
	ldf ?lindb.Ldf
	// expects is every LDF frame's length and model: what the row reads a response by, whatever
	// the backend made of it, so a monitor holds the bus to its LDF too.
	expects map[u8]Expect
	bus     Bus // the row's own handle: master, slave or monitor
	sims    []Simulated
	// smu guards sched and sched_name, and is held across a start, a switch or a stop, so two
	// front ends never run two schedulers and none starts after the row stops. Taken before mu
	// where both are held; never held while waiting for the reader.
	smu        sync.Mutex
	sched      ?&HostScheduler
	opts       RowOpts
	reader     thread
	mu         sync.Mutex
	ids        map[u8]IdState
	taps       []&Tap
	notes      []string
	noted      map[string]bool // schedule tables whose notes are in `notes`
	sched_name string
	// dropped is every frame a tap lost, untapped or not.
	dropped u64
	// master_vals is the values the master's frames carry now, as a slave's are on its Simulated.
	master_vals map[string]map[string]lindb.Value
	// the load window: bits seen in the second that began at sec_start_ns, and the last whole
	// second's.
	sec_start_ns i64
	sec_started  bool
	sec_bits     i64
	last_bits    i64
	stopping     u64
	stopped      bool
}

// start_row opens a row's bus and brings it up: the simulated nodes publishing, the schedule
// running, a reader feeding the view and the taps. Everything that can be refused is refused
// before anything is opened.
pub fn start_row(spec RowSpec, opts RowOpts) !&Row {
	mut ldf := ?lindb.Ldf(none)
	if spec.ldf != '' {
		l := lindb.load_ldf(spec.ldf) or { return error('lin ${spec.name}: ${err.msg()}') }
		ldf = l
	}
	check_row(spec, ldf)!
	mut baud := spec.baud
	if baud == 0 {
		baud = address_baud(spec.address) or {
			mut speed := default_baud
			if l := ldf {
				speed = l.speed_bps or { default_baud }
			}
			speed
		}
	}
	mut notes := []string{}
	mut master_sim := false
	mut slaves := []string{}
	if l := ldf {
		notes << l.notes.map('lin ${spec.name}: ${it}')
		for n in spec.simulate {
			if n == l.master.name {
				master_sim = true
			} else {
				slaves << n
			}
		}
	}
	// What the schedule sends, worked out before the bus is opened.
	mut sched := LdfSchedule{}
	if spec.schedule != '' {
		if l := ldf {
			sched = schedule_of(&l, spec.schedule) or { return error('lin ${spec.name}: ${err.msg()}') }
			notes << sched.notes.map('lin ${spec.name}: ${it}')
		}
	}
	// Every node's entries, worked out before any handle opens, so a refused one opens nothing.
	mut master_entries := []Entry{}
	mut slave_entries := [][]Entry{}
	if l := ldf {
		if master_sim {
			master_entries = publish_entries(&l, l.master.name) or {
				return error('lin ${spec.name}: ${err.msg()}')
			}
		}
		for n in slaves {
			slave_entries << publish_entries(&l, n) or {
				return error('lin ${spec.name}: ${err.msg()}')
			}
		}
	}
	// On a bus that takes one handle per device the row's own handle answers for every node it
	// simulates: their entries say their responses are the simulation's, and a single simulated
	// slave's NAD is the handle's.
	shared_handle := one_handle_per_device(spec.address)
	src := if spec.role == .monitor {
		Src.remote
	} else if master_sim {
		Src.sim
	} else {
		Src.tester
	}
	mut nad := u8(0)
	if shared_handle && slaves.len == 1 {
		if l := ldf {
			if node := l.node(slaves[0]) {
				nad = node.configured_nad or { u8(0) }
			}
		}
	}
	bus := open(spec.address, Config{
		role:  spec.role
		baud:  baud
		src:   src
		nad:   nad
		clock: opts.clock
	}) or { return error('lin ${spec.name}: ${err.msg()}') }
	mut r := &Row{
		spec:  spec
		baud:  baud
		ldf:   ldf
		opts:  opts
		bus:   bus
		notes: notes
	}
	if l := ldf {
		r.expects = expects_of(&l)
	}
	r.bring_up(master_entries, slaves, slave_entries) or {
		r.close_handles()
		return error('lin ${spec.name}: ${err.msg()}')
	}
	r.reader = spawn r.read_loop()
	if sched.slots.len > 0 {
		r.noted[spec.schedule] = true
		r.smu.lock()
		r.run_sched(sched.slots, spec.schedule) or {
			r.smu.unlock()
			r.stop()
			return error('lin ${spec.name}: ${err.msg()}')
		}
		r.smu.unlock()
	}
	return r
}

// check_row is every refusal a spec can earn from its LDF alone.
fn check_row(spec RowSpec, ldf ?lindb.Ldf) ! {
	if spec.role == .monitor && spec.simulate.len > 0 {
		return error('lin ${spec.name}: a monitor publishes nothing, so it cannot simulate ${spec.simulate.join(', ')}')
	}
	if spec.schedule != '' && spec.role != .master {
		return error('lin ${spec.name}: only the master runs a schedule; this row is a ${spec.role}')
	}
	l := ldf or {
		if spec.simulate.len > 0 || spec.schedule != '' {
			return error('lin ${spec.name}: simulate and schedule need an LDF')
		}
		return
	}
	for i, n in spec.simulate {
		if n in spec.simulate[..i] {
			return error('lin ${spec.name}: ${n} is listed twice in simulate')
		}
		if n == l.master.name {
			if spec.role != .master {
				return error('lin ${spec.name}: ${n} is the LDF master, which only the master role can simulate')
			}
		} else if n !in l.slaves {
			return error('lin ${spec.name}: the LDF has no node `${n}` (master ${l.master.name}, slaves ${l.slaves.join(', ')})')
		}
	}
}

fn (mut r Row) bring_up(master_entries []Entry, slaves []string, slave_entries [][]Entry) ! {
	l := r.ldf or { return }
	for e in master_entries {
		r.bus.set_entry(e)!
	}
	// The frames the row does not publish, by their LDF length and model, so a backend that
	// times a response window by length (serial) does not wait out eight bytes for each.
	if r.spec.role != .monitor {
		mut published := master_entries.map(it.id)
		for es in slave_entries {
			published << es.map(it.id)
		}
		for id, exp in r.expects {
			if id !in published {
				r.bus.set_entry(Entry{
					id:    id
					dir:   .subscribe
					len:   exp.len
					model: exp.model
				})!
			}
		}
	}
	if one_handle_per_device(r.spec.address) {
		for k, n in slaves {
			for e in slave_entries[k] {
				r.bus.set_entry(Entry{ ...e, sim: true })!
			}
			r.sims << Simulated{
				node:   n
				shared: true
				bus:    r.bus
			}
		}
		return
	}
	for k, n in slaves {
		node := l.node(n) or { lindb.Node{} }
		mut b := open(r.spec.address, Config{
			role:  .slave
			baud:  r.baud
			src:   .sim
			nad:   node.configured_nad or { u8(0) }
			clock: r.opts.clock
		})!
		r.sims << Simulated{
			node: n
			bus:  b
		}
		for e in slave_entries[k] {
			b.set_entry(e)!
		}
	}
}

// read_loop reads the row's handle until it closes, feeding the view and the taps; a simulated
// node's handle hears every frame too, and is drained so its queue never fills.
fn (mut r Row) read_loop() {
	for stdatomic.load_u64(&r.stopping) == 0 {
		f := r.bus.recv(20) or {
			if err is transport.CarrierGone {
				break
			}
			r.drain_sims()
			continue
		}
		r.drain_sims()
		r.saw(f)
	}
	r.mu.lock()
	for mut t in r.taps {
		t.q.close()
	}
	r.taps.clear()
	r.mu.unlock()
}

fn (mut r Row) drain_sims() {
	for mut s in r.sims {
		if s.shared {
			continue
		}
		for {
			s.bus.recv(0) or { break }
		}
	}
}

// saw folds one frame into the view and hands it to every tap, read against the LDF.
fn (mut r Row) saw(read Frame) {
	mut f := read
	if exp := r.expects[f.id] {
		if has_id(f) && f.raw.len > 0 {
			f = reread(f, exp)
		}
	}
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	// a go-to-sleep is a whole MasterReq on the wire; a wakeup pulse is not a frame, and a header
	// that went wrong before its id was read is bus time under no id
	if f.event != .wakeup && !has_id(f) {
		r.count_bits(f.t_ns, frame_bits(-1))
	} else if f.event != .wakeup {
		mut st := r.ids[f.id] or { IdState{} }
		st.count++
		if f.errs != Errs.zero() {
			st.errors++
		} else {
			if st.has_ok {
				st.cadence_ns = f.t_ns - st.last_ok_ns
			}
			st.last_ok_ns = f.t_ns
			st.has_ok = true
		}
		st.last = f
		r.ids[f.id] = st
		bits := if f.raw.len > 0 { frame_bits(f.raw.len - 1) } else { frame_bits(-1) }
		r.count_bits(f.t_ns, bits)
	}
	for mut t in r.taps {
		if t.q.try_push(f.clone()) != .success {
			stdatomic.add_u64(&t.dropped, 1)
			r.dropped++
		}
	}
}

// count_bits adds a frame's bits to the load window.
fn (mut r Row) count_bits(t_ns i64, bits int) {
	if !r.sec_started {
		r.sec_start_ns = t_ns
		r.sec_started = true
	}
	r.roll(t_ns)
	r.sec_bits += bits
}

// roll moves the load window on to `now_ns`: a second that has ended becomes the last whole
// second, and a second with no frame in it is a second at 0. Frames are stamped by the clock
// the row gave its bus, so a frame's time and the view's now are one clock.
fn (mut r Row) roll(now_ns i64) {
	if !r.sec_started {
		return
	}
	gap := now_ns - r.sec_start_ns
	if gap >= 1_000_000_000 {
		r.last_bits = if gap < 2_000_000_000 { r.sec_bits } else { 0 }
		r.sec_bits = 0
		r.sec_start_ns += gap / 1_000_000_000 * 1_000_000_000
	}
}

// tap is a new reader of every frame from now on.
pub fn (mut r Row) tap() !&Tap {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if r.stopped {
		return row_stopped()
	}
	t := &Tap{
		q: chan Frame{cap: r.opts.tap_cap}
	}
	r.taps << t
	return t
}

// untap ends a tap; its queue closes.
pub fn (mut r Row) untap(t &Tap) {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	for i, x in r.taps {
		if voidptr(x) == voidptr(t) {
			mut y := r.taps[i]
			y.q.close()
			r.taps.delete(i)
			return
		}
	}
}

// view is the row as it stands.
pub fn (mut r Row) view() RowView {
	r.mu.lock()
	mut ids := r.ids.keys()
	ids.sort()
	mut states := []IdState{cap: ids.len}
	for id in ids {
		states << r.ids[id]
	}
	r.roll(r.opts.clock.now_ns())
	dropped := r.dropped
	bits := r.last_bits
	notes := r.notes.clone()
	r.mu.unlock()
	r.smu.lock()
	sched_name := r.sched_name
	mut sstats := SchedStats{}
	if mut s := r.sched {
		sstats = s.stats()
	}
	r.smu.unlock()
	mut frames := []IdView{cap: ids.len}
	for i, id in ids {
		st := states[i]
		mut name := ''
		mut sigs := []lindb.SignalValue{}
		if l := r.ldf {
			if resp := l.response_for(id, st.last.data) {
				name = resp.name
				if lf := resp.frame {
					sigs = l.decode(lf, st.last.data)
				}
			}
		}
		frames << IdView{
			id:         id
			name:       name
			count:      st.count
			errors:     st.errors
			last:       st.last.clone()
			cadence_ms: f64(st.cadence_ns) / 1e6
			signals:    sigs
		}
	}
	return RowView{
		name:         r.spec.name
		address:      r.spec.address
		role:         r.spec.role
		state:        r.bus.status().state
		schedule:     sched_name
		frames:       frames
		load_percent: f64(bits) * 100.0 / f64(r.baud)
		dropped:      dropped
		sched:        sstats
		notes:        notes
	}
}

// set_signal changes what a simulated node publishes: the signal's frame is encoded again with
// the value, and the node's handle updated, from its next response on.
pub fn (mut r Row) set_signal(signal string, value lindb.Value) ! {
	l := r.ldf or { return error('lin ${r.spec.name}: no LDF, so no signal `${signal}`') }
	mut idx := -1
	for i, lf in l.frames {
		if lf.kind == .unconditional && lf.signals.any(it.name == signal) {
			idx = i
			break
		}
	}
	if idx < 0 {
		return error('lin ${r.spec.name}: the LDF has no signal `${signal}` in an unconditional frame')
	}
	f := l.frames[idx]
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if f.publisher == l.master.name && l.master.name in r.spec.simulate {
		mut vals := (r.master_vals[f.name] or { map[string]lindb.Value{} }).clone()
		vals[signal] = value
		r.bus.update(f.id, l.encode(f, vals)!)!
		r.master_vals[f.name] = vals.clone()
		return
	}
	for mut s in r.sims {
		if s.node == f.publisher {
			mut vals := (s.values[f.name] or { map[string]lindb.Value{} }).clone()
			vals[signal] = value
			s.bus.update(f.id, l.encode(f, vals)!)!
			s.values[f.name] = vals.clone()
			return
		}
	}
	return error('lin ${r.spec.name}: ${signal} is in ${f.name}, which ${f.publisher} publishes, and this row does not simulate ${f.publisher}')
}

// schedule runs the named LDF schedule table: started, or switched to at the end of the slot
// running now.
pub fn (mut r Row) schedule(name string) ! {
	if r.spec.role != .master {
		return RoleRefused{
			role: r.spec.role
			call: 'schedule'
		}
	}
	l := r.ldf or { return error('lin ${r.spec.name}: no LDF, so no schedule table `${name}`') }
	sched := schedule_of(&l, name)!
	r.smu.lock()
	defer {
		r.smu.unlock()
	}
	r.mu.lock()
	if r.stopped {
		r.mu.unlock()
		return row_stopped()
	}
	if name !in r.noted {
		r.noted[name] = true
		r.notes << sched.notes.map('lin ${r.spec.name}: ${it}')
	}
	r.mu.unlock()
	r.run_sched(sched.slots, name)!
}

// run_sched switches the running scheduler to `slots`, or starts one. The caller holds smu.
fn (mut r Row) run_sched(slots []Slot, name string) ! {
	if mut s := r.sched {
		if s.stats().running {
			s.switch_to(slots, name)!
			r.sched_name = name
			return
		}
	}
	mut s := new_scheduler(r.bus, slots, SchedOpts{
		name:    name
		clock:   r.opts.clock
		sleeper: r.opts.sleeper
	})!
	s.start()!
	r.sched = s
	r.sched_name = name
}

// stop_schedule stops the running schedule: no header after it returns. False when the
// scheduler's thread was still inside a header call at its bound.
pub fn (mut r Row) stop_schedule() bool {
	r.smu.lock()
	defer {
		r.smu.unlock()
	}
	return r.stop_sched()
}

// stop_sched stops the scheduler; the caller holds smu.
fn (mut r Row) stop_sched() bool {
	mut ok := true
	if mut s := r.sched {
		ok = s.stop()
	}
	r.sched = none
	r.sched_name = ''
	return ok
}

// header sends one header from the row's master handle.
pub fn (mut r Row) header(id u8) ! {
	r.bus.header(id)!
}

// wakeup sends a wakeup pulse from the row's handle.
pub fn (mut r Row) wakeup() ! {
	r.bus.wakeup()!
}

// sleep sends the go-to-sleep command from the row's master handle.
pub fn (mut r Row) sleep() ! {
	r.bus.sleep()!
}

// ldf is the row's LDF, none when it has none.
pub fn (r &Row) ldf() ?lindb.Ldf {
	return r.ldf
}

// notes is everything the row did not take as written: the LDF's notes and what a schedule
// leaves unsent.
pub fn (mut r Row) notes() []string {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	return r.notes.clone()
}

// diagnostics is the row's handle's counts.
pub fn (mut r Row) diagnostics() transport.BusDiagnostics {
	return r.bus.diagnostics()
}

// stop ends the row: the schedule first, so no header follows, then every handle. The reader
// ends on its handle closing and closes every tap. Returns false when the schedule or the
// reader outlived its bound.
pub fn (mut r Row) stop() bool {
	r.smu.lock()
	r.mu.lock()
	if r.stopped {
		r.mu.unlock()
		r.smu.unlock()
		return true
	}
	r.stopped = true
	r.mu.unlock()
	ok := r.stop_sched()
	r.smu.unlock()
	stdatomic.store_u64(&r.stopping, 1)
	r.close_handles()
	r.reader.wait()
	return ok
}

fn (mut r Row) close_handles() {
	for mut s in r.sims {
		if !s.shared {
			s.bus.close()
		}
	}
	r.bus.close()
}
