module main

import sync
import sync.stdatomic
import time
import blobly.candb
import blobly.cyclic
import blobly.project
import blobly.sim
import blobly.transport
import genrule
import taprule

// gen_wire.v — the GUI's generators (#691), each an entry of a cyclic.Wire per destination as a
// headless run's are (blobly/headless/generators.v): one sending thread per wire that has
// generators, each generator on its own sim.next_due grid, a long J1939 message a transfer the
// wire's loop steps (cyclic.Tp), and the frame built last sent again until something it is built
// from changes. Every frame goes out through the generator's row's transmit tap (tap_send), so
// the trace's TX origin, the bus load, the fault ladder (#142) and the verify notice (#95) see it
// as they see any tapped emitter's. What the GUI decides on its own is genrule.

// GenEntry is one generator on its wire's loop, made for one target and row of one run: a
// generator retargeted or removed leaves, and its successor is another entry (sync_gen_entries).
@[heap]
struct GenEntry {
	uid       u64    // its generator (SenderRT.uid)
	row       int    // the row it sends as (SenderRT.chan_idx), -1 none
	chan      string // that row's name, '' none
	tgt       string // its target (SenderRT.tgt)
	named     string // its row's tap's key (tx_bus_key), and the wire's shared tap's
	shared    string
	gen       u64   // the run it belongs to
	epoch     u64   // gen_state_epoch when it was made: its counts are written only while it holds
	wave_t0   u64   // the run's epoch, which its value sources are evaluated from
	dest_rows []int // the rows on its destination (indices into app.chans), fixed for the run
mut:
	wire &cyclic.Wire // the wire it is on, which a fire wakes
	app  &App
	mu   sync.Mutex
	// the GUI's side, under mu: a fire waiting for the loop, a transfer of its going out (the
	// loop's, mirrored so a fire is not taken over it), and whether it was asked to leave
	fire  bool
	busy  bool
	leave bool
	// the loop's alone from here: its tap framed as its row on its wire, the transfer in progress
	bus transport.Bus
	tp  cyclic.Tp
	// what it read of the GUI last (look_locked), at which revision and when, and where its
	// generator sat in app.senders then
	lk     GenLook
	looked bool
	seen   u64
	at     u64
	hint   int
	// its grid: armed at the last look, whether its cycle sends at once, the slot the cycle last
	// sent in and when that send ended
	was   bool
	fresh bool = true
	slot  u64
	done  u64
	// the send in progress: a fire's (else the cycle's), the send index its frame was built at;
	// whether a fire waiting goes before the cycle next; the cycle's last outcome ('' sent)
	job_fire  bool
	job_n     int
	fire_turn bool
	failed    string
	// the frame it built last and what it was built after (genrule.stale); its message, found
	// again only after an edit; the values a message's frame is built from, their storage kept
	built        transport.CanFrame
	built_ok     bool
	built_edits  u64
	built_varies bool
	msg          candb.Message
	msg_ok       bool
	msg_edits    u64
	declared     bool // its message is declared J1939: past 8 bytes on a classic row a transfer
	vals         []sim.SetValue
}

// GenLook is what an entry reads of the GUI before it sends, under app.mu.
struct GenLook {
	gone   bool // its generator was removed or retargeted, or its run is over: it leaves
	cyclic bool
	period u64
	armed  bool // genrule.armed
	name   string
}

// GenTap is the bus a generator's entry sends on: each send is its row's tap send (tap_send),
// over keys made once. It reads nothing and closes nothing, since the taps are the run's — opened
// for it at Start, closed by Stop.
struct GenTap {
	named  string
	shared string
	row    int
	chan   string
	iface  string
mut:
	app &App
}

fn (mut t GenTap) send(f transport.CanFrame) ! {
	t.app.tap_send(t.named, t.shared, t.row, t.chan, t.iface, f)!
}

fn (mut t GenTap) recv(_ int) !transport.CanFrame {
	return error("a generator's tap only sends")
}

fn (mut t GenTap) close() {}

fn (mut t GenTap) health() transport.BusHealth {
	return .unknown
}

fn (mut t GenTap) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut t GenTap) error_counters() transport.ErrorCounters {
	return transport.ErrorCounters{}
}

fn (mut t GenTap) reconcile_silence(_ bool) ! {}

// NoBus is a generators' wire's own handle, which nothing is sent on: every entry sends through
// its row's tap (GenTap), so the wire's loop opens this, never a bus of its own.
struct NoBus {}

fn (mut n NoBus) send(_ transport.CanFrame) ! {
	return error("a generator sends through its row's transmit tap")
}

fn (mut n NoBus) recv(_ int) !transport.CanFrame {
	return error("a generators' wire reads nothing")
}

fn (mut n NoBus) close() {}

fn (mut n NoBus) health() transport.BusHealth {
	return .unknown
}

fn (mut n NoBus) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut n NoBus) error_counters() transport.ErrorCounters {
	return transport.ErrorCounters{}
}

fn (mut n NoBus) reconcile_silence(_ bool) ! {}

// tap_of_locked is the tap a send from row `row` (named `chan_name`) on `iface` goes through: its
// named tap `named`, else the wire's `shared` one where taprule.fallback lets it stand in — or
// why there is none, as the Log says it. Caller holds app.mu.
fn (app &App) tap_of_locked(named string, shared string, row int, chan_name string, iface string) !transport.Bus {
	if b := app.tx_buses[named] {
		return b
	}
	match taprule.fallback_of(named in app.tap_failed, shared in app.tx_buses, row >= 0) {
		.wait {
			return error('TX not sent: the transmit tap of ${chan_name} on ${iface} is still opening')
		}
		.none_open {
			return error('TX failed: no open bus for ${iface}')
		}
		.via_wire {
			return app.tx_buses[shared] or { error('TX failed: no open bus for ${iface}') }
		}
	}
}

// tap_send sends `f` as row `row`'s (named `chan_name`; -1 and '' for none) on `iface` through
// tap_of_locked's tap, keyed `named` and `shared` by the caller (tx_bus_key) — tx_on_chan's send
// for a caller that makes its keys once. The lookup is under app.mu, the send is not: the tap
// takes its wire's send lock and then app.mu inside note_emit.
fn (mut app App) tap_send(named string, shared string, row int, chan_name string, iface string, f transport.CanFrame) ! {
	app.mu.lock()
	mut b := app.tap_of_locked(named, shared, row, chan_name, iface) or {
		app.mu.unlock()
		return err
	}
	app.mu.unlock()
	// a channel's frames in its own format, which on a wire two rows dispute the wire has not
	// (#384): the tap frames it for its row and its wire in one policy read
	sent := if row < 0 || chan_name == '' || f.format_stated {
		f
	} else {
		transport.CanFrame{
			...f
			row: chan_name
		}
	}
	// The row, the recording, the pending echo and the count are the tap's job (open_tap), so
	// they happen for every emitter rather than only for the ones that remember to log.
	b.send(sent) or { return error('TX failed: ${err}') }
}

// sender_index_locked is where generator `uid` sits in app.senders, -1 when it is gone; `hint`
// is where it sat last, asked first. Caller holds app.mu.
fn (app &App) sender_index_locked(uid u64, hint int) int {
	if hint >= 0 && hint < app.senders.len && app.senders[hint].uid == uid {
		return hint
	}
	for i, sr in app.senders {
		if sr.uid == uid {
			return i
		}
	}
	return -1
}

// dest_rows_locked is the rows on `iface`'s destination, by index into app.chans. Caller holds
// app.mu.
fn (app &App) dest_rows_locked(iface string) []int {
	want := transport.destination_key(iface)
	mut out := []int{}
	for i, c in app.chans {
		if transport.destination_key(c.iface) == want {
			out << i
		}
	}
	return out
}

// gen_bump_locked says something an entry reads before it sends has changed (GenEntry.refresh),
// and wakes every generators' wire so the change applies now. Caller holds app.mu.
fn (mut app App) gen_bump_locked() {
	stdatomic.add_u64(&app.gen_rev, 1)
	for _, mut w in app.gen_wires {
		w.poke()
	}
}

// new_gen_entry is generator `sr`'s entry on wire `w` for the run on now. Caller holds app.mu.
fn (mut app App) new_gen_entry(sr SenderRT, w &cyclic.Wire) &GenEntry {
	gen := app.run_gen
	named := tx_bus_key(sr.chan_idx, sr.tgt)
	shared := tx_bus_key(-1, sr.tgt)
	tap := &GenTap{
		named:  named
		shared: shared
		row:    sr.chan_idx
		chan:   sr.chan
		iface:  sr.tgt
		app:    app
	}
	mut e := &GenEntry{
		uid:       sr.uid
		row:       sr.chan_idx
		chan:      sr.chan
		tgt:       sr.tgt
		named:     named
		shared:    shared
		gen:       gen
		epoch:     app.gen_state_epoch
		wave_t0:   app.wave_t0_ns
		dest_rows: app.dest_rows_locked(sr.tgt)
		wire:      w
		app:       app
		// on the PHYSICAL interface, the one the tap opened: what a J1939 transfer's lane and its
		// connection's reader are on, at the wire's rate
		bus:       transport.emitter_on(tap, app.phys_for_locked(sr.tgt), sr.chan)
	}
	// a connection between its packets ends once the run it belongs to does
	e.tp.stop_by(fn [app, gen] () bool {
		mut a := unsafe { app }
		a.mu.lock()
		over := !a.running || a.run_gen != gen
		a.mu.unlock()
		return over
	})
	return e
}

// sync_gen_entries puts every generator with a CAN target on its destination's wire, starting a
// wire (a run worker) for a destination that has none, and asks each entry whose generator was
// removed or retargeted to leave — its successor, on its new target's wire, made here. Called on
// the GUI thread at Start and after an edit that adds, removes or retargets a generator; nothing
// while stopped.
fn (mut app App) sync_gen_entries() {
	mut spawns := []&cyclic.Wire{}
	app.mu.lock()
	if !app.running {
		app.mu.unlock()
		return
	}
	mut gone := []u64{}
	for uid, e in app.gen_entries {
		i := app.sender_index_locked(uid, -1)
		if i < 0 || app.senders[i].tgt != e.tgt || app.senders[i].chan_idx != e.row {
			gone << uid
		}
	}
	for uid in gone {
		if mut e := app.gen_entries[uid] {
			e.ask_leave()
		}
		app.gen_entries.delete(uid)
	}
	gen := app.run_gen
	for sr in app.senders {
		// NOT AN ETHERNET TARGET: no tap is opened for one (tap_plan_locked), so nothing could
		// send; a fire says so (fire_index)
		if sr.uid in app.gen_entries || sr.tgt == '' || project.kind_of_iface(sr.tgt) != .can {
			continue
		}
		key := transport.destination_key(sr.tgt)
		mut w := app.gen_wires[key] or {
			nw := cyclic.new_wire(key, fn [app, gen] (s string) {
				notify_gen(app, gen, s)
			})
			app.gen_wires[key] = nw
			app.reserve_run_worker_locked() // released by gen_wire_loop's defer
			spawns << nw
			nw
		}
		mut e := app.new_gen_entry(sr, w)
		w.add(e) or { continue } // asked to stop: Stop, which empties the map
		app.gen_entries[sr.uid] = e
	}
	app.mu.unlock()
	for mut w in spawns {
		spawn gen_wire_loop(app, mut w)
	}
}

// stop_gen_wires asks every generators' wire to end, and forgets them and their entries: Stop.
// The loops are run workers, which the next rebuild waits for.
fn (mut app App) stop_gen_wires() {
	app.mu.lock()
	mut wires := []&cyclic.Wire{cap: app.gen_wires.len}
	for _, w in app.gen_wires {
		wires << w
	}
	app.gen_wires = map[string]&cyclic.Wire{}
	app.gen_entries = map[u64]&GenEntry{}
	app.mu.unlock()
	for mut w in wires {
		w.ask_stop()
	}
}

// gen_wire_loop runs generators' wire `w` until Stop: a run worker, its slot reserved by
// sync_gen_entries. The wire's own handle is a NoBus: every entry sends through its row's tap.
fn gen_wire_loop(app &App, mut w cyclic.Wire) {
	defer {
		release_run_worker(app)
	}
	w.run(fn (_ string) !transport.Bus {
		return NoBus{}
	}) or {}
}

// gen_counts is generator `uid`'s frames sent and slots skipped this run.
fn (mut app App) gen_counts(uid u64) (int, u64) {
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	return app.gen_send_n[uid] or { 0 }, app.gen_skipped[uid] or { 0 }
}

// ask_leave asks the entry's wire to let it go before it sends anything more.
fn (mut e GenEntry) ask_leave() {
	e.mu.lock()
	e.leave = true
	e.mu.unlock()
}

// ask_fire asks for one fire, which its wire's loop sends next: false where genrule.fire_taken
// refuses it. Pokes nothing: the caller does, once its locks are let go.
fn (mut e GenEntry) ask_fire() bool {
	e.mu.lock()
	defer {
		e.mu.unlock()
	}
	if !genrule.fire_taken(e.fire, e.busy) {
		return false
	}
	e.fire = true
	return true
}

// take_fire takes the fire waiting, if there is one.
fn (mut e GenEntry) take_fire() bool {
	e.mu.lock()
	defer {
		e.mu.unlock()
	}
	f := e.fire
	e.fire = false
	return f
}

fn (mut e GenEntry) fire_waiting() bool {
	e.mu.lock()
	defer {
		e.mu.unlock()
	}
	return e.fire
}

fn (mut e GenEntry) set_busy(b bool) {
	e.mu.lock()
	e.busy = b
	e.mu.unlock()
}

// say puts `msg` in the Log while its run is on.
fn (e &GenEntry) say(msg string) {
	notify_gen(e.app, e.gen, msg)
}

// look_locked is what the entry reads of the GUI: whether its generator is still the one it was
// made for, in the run it was made for, and whether its cycle may send (genrule.armed). Caller
// holds app.mu.
fn (mut e GenEntry) look_locked() GenLook {
	a := e.app
	if !a.running || a.run_gen != e.gen {
		return GenLook{
			gone: true
		}
	}
	i := a.sender_index_locked(e.uid, e.hint)
	if i < 0 || a.senders[i].tgt != e.tgt || a.senders[i].chan_idx != e.row {
		return GenLook{
			gone: true
		}
	}
	e.hint = i
	s := unsafe { &a.senders[i].sender }
	cyc := s.trigger == 'cyclic' && s.cycle_ms > 0
	ready := taprule.ready_of(e.named in a.tx_buses, e.named in a.tap_failed, e.shared in a.tx_buses,
		e.row >= 0)
	mut enabled := 0
	for r in e.dest_rows {
		if r < a.chans.len && a.chans[r].enabled {
			enabled++
		}
	}
	return GenLook{
		cyclic: cyc
		period: u64(if cyc { s.cycle_ms } else { 0 })
		armed:  genrule.armed(cyc, ready, genrule.departed(e.dest_rows.len, enabled))
		name:   s.name
	}
}

// refresh reads the GUI again where genrule.relook says, else keeps what it read last.
fn (mut e GenEntry) refresh(now u64) {
	rev := stdatomic.load_u64(&e.app.gen_rev)
	if !genrule.relook(e.looked, e.seen, rev, now, e.at) {
		return
	}
	mut a := e.app
	a.mu.lock()
	e.lk = e.look_locked()
	a.mu.unlock()
	e.looked = true
	e.seen = rev
	e.at = now
	if e.lk.gone {
		e.ask_leave()
	}
}

fn (mut e GenEntry) leaving() bool {
	e.mu.lock()
	defer {
		e.mu.unlock()
	}
	return e.leave
}

// due is when it sends next: at once for a fire waiting or a cycle (re)armed, else on its grid
// by the cycle as it is now, from the time its last send returned (sim.next_due); none while its
// cycle is not armed and no fire waits.
fn (mut e GenEntry) due(now u64) ?u64 {
	if e.tp.busy() {
		return e.tp.due(now)
	}
	e.refresh(now)
	if e.lk.gone {
		return none
	}
	if genrule.restarts(e.was, e.lk.armed) {
		e.fresh = true
	}
	e.was = e.lk.armed
	if e.fire_waiting() || (e.lk.armed && e.fresh) {
		return now
	}
	if !e.lk.armed {
		return none
	}
	return sim.next_due(e.slot, e.lk.period, e.done)
}

// serve drives its transfer in progress, else sends its cyclic frame if it is due, then a fire
// waiting: however far behind the cycle is a fire is served, and a cycle's transfer that ended
// lets a fire waiting go first. A send that begins a transfer ends the pass for it.
fn (mut e GenEntry) serve(mut _ transport.Bus, now u64) string {
	pa := probe_alloc_mark()
	defer {
		probe_alloc_note(.gen, pa)
	}
	if e.tp.busy() {
		of_cycle := !e.job_fire
		e.progress(e.tp.pump(mut e.bus, now))
		e.fire_turn = of_cycle && !e.tp.busy()
		return ''
	}
	e.refresh(now)
	if e.lk.gone {
		return ''
	}
	turn := e.fire_turn && e.fire_waiting()
	e.fire_turn = false
	if !turn && e.lk.armed
		&& (e.fresh || now >= sim.next_due(e.slot, e.lk.period, e.done)) {
		if e.fresh {
			e.slot = now
		} else {
			next := sim.next_due(e.slot, e.lk.period, e.done)
			left := sim.slots_skipped(e.slot, e.lk.period, next)
			e.slot = next
			if left > 0 {
				e.note_skipped(left)
			}
		}
		e.fresh = false
		e.job_fire = false
		e.progress(e.send(now))
		if e.tp.busy() {
			return ''
		}
	}
	if e.take_fire() {
		e.job_fire = true
		e.progress(e.send(now))
	}
	return ''
}

// note_skipped counts `left` slots its cycle left out.
fn (mut e GenEntry) note_skipped(left u64) {
	mut a := e.app
	a.mu.lock()
	if a.gen_state_epoch == e.epoch {
		a.gen_skipped[e.uid] = (a.gen_skipped[e.uid] or { 0 }) + left
	}
	a.mu.unlock()
}

// send begins its frame as the generator is edited now on its tap — a J1939 message past eight
// bytes on a classic row as its BAM or its connection (cyclic.Tp), which serve drives from then.
fn (mut e GenEntry) send(now u64) cyclic.Step {
	mut a := e.app
	a.mu.lock()
	frame := e.frame_locked() or {
		a.mu.unlock()
		return cyclic.Step{
			why: err.msg()
		}
	}
	a.mu.unlock()
	return e.tp.begin(mut e.bus, frame, e.declared, now)
}

// frame_locked is its frame as the generator is now, its send index noted: the frame built last
// while genrule.stale says it still is, else one built afresh from what the generator is under
// app.mu, so an edit is never half seen. A frame kept is sent again as it is: a payload is never
// written once built. Caller holds app.mu.
fn (mut e GenEntry) frame_locked() !transport.CanFrame {
	a := e.app
	i := a.sender_index_locked(e.uid, e.hint)
	if i < 0 {
		return error('the generator was removed')
	}
	// read in place: a copy of the generator here would be put on the heap by the payload's clone
	// below, once per send
	s := unsafe { &a.senders[i].sender }
	edits := a.senders[i].edits
	e.job_n = a.gen_send_n[e.uid] or { 0 }
	varies := s.message != '' && sim.sender_varies(*s)
	if !genrule.stale(e.built_ok, e.built_edits, edits, varies) {
		return e.built
	}
	if s.message == '' {
		frame := sim.sender_raw_frame(*s, s.id, s.ext, s.data.clone())!
		e.declared = false
		e.keep(frame, edits, false)
		return frame
	}
	// its message as its target rows' databases send it, found again only after an edit (the
	// message is one), since the databases are the run's
	if !e.msg_ok || e.msg_edits != edits {
		e.msg = sim.sender_message_of(*s, a.gen_dbs(a.senders[i])) or {
			e.msg_ok = false
			return error('message "${s.message}" is not in the channel databases')
		}
		e.msg_ok = true
		e.msg_edits = edits
	}
	e.declared = e.msg.j1939
	// ONE clock sample for the whole frame, from the run's epoch, so a restarted measurement
	// begins at the same phase
	el := if e.wave_t0 > 0 { f64(time.sys_mono_now() - e.wave_t0) / 1_000_000_000.0 } else { 0.0 }
	sim.sender_values(mut e.vals, *s, e.job_n, el)
	frame := sim.sender_frame(e.msg, s.format, e.vals)!
	e.keep(frame, edits, varies)
	return frame
}

// keep notes `frame` as the one it built last, after `edits`, `varies` whether its next may differ.
fn (mut e GenEntry) keep(frame transport.CanFrame, edits u64, varies bool) {
	e.built = frame
	e.built_ok = true
	e.built_edits = edits
	e.built_varies = varies
}

// progress is what it makes of where its send stands: once it ended, the frame counted where the
// bus took it (the send index a counter source rides), the next slot gridded from then, a fire's
// failure said and a cycle's said once while it repeats (genrule.says).
fn (mut e GenEntry) progress(st cyclic.Step) {
	e.set_busy(st.going)
	if st.going {
		return
	}
	e.done = time.sys_mono_now() / 1_000_000
	mut a := e.app
	if st.why == '' {
		a.mu.lock()
		if a.gen_state_epoch == e.epoch {
			a.gen_send_n[e.uid] = e.job_n + 1
		}
		a.mu.unlock()
	}
	if e.job_fire {
		e.job_fire = false
		if st.why != '' {
			e.say('generator ${e.lk.name}: ${st.why}')
		}
		return
	}
	if genrule.says(e.failed, st.why) {
		e.say('generator ${e.lk.name}: ${st.why}')
	}
	e.failed = st.why
}

// quit ends its transfer in progress as its wire lets it go, a connection with its abort.
fn (mut e GenEntry) quit(mut _ transport.Bus) {
	if e.tp.busy() {
		e.tp.quit(mut e.bus)
		e.set_busy(false)
	}
}

fn (mut e GenEntry) let_go(_ string) {
	e.mu.lock()
	e.leave = true
	e.fire = false
	e.mu.unlock()
}
