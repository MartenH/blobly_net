// replay — a recording played onto live buses, and live buses recorded to a file, for a script:
// the Lua prelude's `replay` and `record` and the C ABI's bb_replay_* / bb_record_* (Python) call
// these, so both languages drive one implementation.
//
// A replay is blobly/player's: one Player over one plan (player.build_multi_log, the rest-bus
// subtraction by DBC sender), driven by its command protocol (player.Commands, control.v) from a
// worker thread of its own, as the GUI's Replay panel drives its replay group. Several targets
// share one clock, as the GUI's group does, because the timing across buses is what a gateway
// under test polices.
module replay

import os
import sync
import time
import blobly.candb
import blobly.canlog
import blobly.mf4
import blobly.player
import blobly.project
import blobly.transport

// the longest the worker waits between looks at its commands and its stop flag
const tick_ms = 20.0

// how long a command waits for the worker to take it, and stop for the worker to end
const settle_ms = 2000

// Target is one live bus a replay plays onto: a row of the project, its databases and what its
// `replay:` block says. `bus` is the recorded bus it plays ('' when the recording holds one);
// `exclude` the nodes subtracted, by DBC sender (the ECU under test).
pub struct Target {
pub:
	name    string
	iface   string // what is opened: the row's interface with its bitrate
	bus     string
	db      candb.Database
	exclude []string
}

// Opener opens a target's bus (`iface`, for the row `name`): transport.open by default; the GUI's
// Script panel supplies its reproducing tap, so a replay's frames are filed as ours. The bus must
// send frames as handed (open's, marked here by transport.verbatim, or a tap that reproduces): a
// wrapper of its own around open's would frame them for the wire.
pub type Opener = fn (iface string, name string) !transport.Bus

fn default_open(iface string, _ string) !transport.Bus {
	return transport.open(iface)
}

// Options is how a replay starts.
@[params]
pub struct Options {
pub:
	speed  f64 = 1.0 // player.speed_ok refuses the rest
	repeat bool
	paused bool // start paused at the beginning
	open   Opener = default_open
	// true ends the replay as a stop does, before anything goes out: a script's deadline
	give_up fn () bool = unsafe { nil }
}

// Status is what a replay is doing.
pub struct Status {
pub:
	state  player.State // playing, paused or finished; `ended` says it was stopped
	pos_s  f64 // seconds into the recording
	dur_s  f64
	speed  f64
	repeat bool
	passes int // complete passes, the last of a non-looping replay included
	sent   u64 // frames the drivers took this run (since the last restart)
	failed u64 // frames a driver refused
	error  string // the first refusal, with its bus
	ended  bool   // stopped: the worker has let go of its buses
}

// Session is a replay running; `stop` ends it.
@[heap]
pub struct Session {
mut:
	mu       sync.Mutex
	ctl_mu   sync.Mutex // held through one control, applied and acknowledged
	cmds     player.Commands
	asked    u64 // commands queued
	taken    u64 // commands the worker has applied and published
	st       Status
	stopping bool
	ended    bool
pub mut:
	// asked while a control waits for the worker: true gives the wait up (a script's deadline)
	give_up fn () bool = unsafe { nil }
pub:
	source string
	// what the plan said: frames kept and withheld per bus, an exclusion a bus cannot subtract
	notes []string
}

// load decodes a `.mf4` or candump `.log` recording, with its buses: an .mf4's own table, a .log's
// synthesized from the interface names its lines carry. The GUI's replay and Scan read it too.
pub fn load(source string) !(canlog.Log, []mf4.BusInfo) {
	if source.to_lower().ends_with('.mf4') {
		rec := mf4.load_recording(source)!
		if rec.log.len() == 0 {
			return error('${os.base(source)} holds no frames')
		}
		return rec.log, rec.buses.clone()
	}
	mut log := canlog.load_log(source)!
	if log.len() == 0 {
		return error('${os.base(source)} holds no frames')
	}
	// a plan keeps file order, and the player's schedule needs it in time: a hand-edited or merged
	// file whose times fall back is put in time order, equal times as the file has them
	if !in_time_order(&log) {
		rows := log.rows
		mut order := []int{len: rows.len, init: index}
		order.sort_with_compare(fn [rows] (a &int, b &int) int {
			ta, tb := rows[*a].t_s, rows[*b].t_s
			if ta != tb {
				return if ta < tb { -1 } else { 1 }
			}
			return *a - *b
		})
		// the rows themselves, permuted: a row carries its payload, so nothing else is copied
		log = canlog.Log{
			rows:   order.map(rows[it])
			labels: log.labels
		}
	}
	mut counts := map[string]int{}
	for i in 0 .. log.len() {
		counts[log.iface(i)]++
	}
	mut ifs := counts.keys()
	ifs.sort()
	mut buses := []mf4.BusInfo{}
	for name in ifs {
		buses << mf4.BusInfo{
			iface:  name
			frames: counts[name]
		}
	}
	return log, buses
}

fn in_time_order(log &canlog.Log) bool {
	for i in 1 .. log.len() {
		if log.t_s(i) < log.t_s(i - 1) {
			return false
		}
	}
	return true
}

// resolve_bus is the label of the recorded bus `want` names (player.resolve_bus over `buses`).
pub fn resolve_bus(buses []mf4.BusInfo, want string) !string {
	mut names := []player.BusName{}
	mut labels := []string{}
	for b in buses {
		names << player.BusName{
			iface: b.iface
			name:  b.name
		}
		labels << b.iface
	}
	return player.resolve_bus(names, labels, want)
}

// Plan is a recording made ready for targets: what start plays. A streamed one holds a reader
// (Prepared.close).
pub struct Plan {
pub:
	notes []string
pub mut:
	prep Prepared
}

// plan_for subtracts what the targets' `exclude` names from `source`, refusing what would play
// something other than asked: a recorded bus that does not resolve, an exclusion no target's
// database declares, two targets on one recorded or live bus, and nothing left to play.
pub fn plan_for(source string, targets []Target) !Plan {
	return plan_until(source, targets, unsafe { nil })
}

// plan_until is plan_for, a streamed recording's reads given up once `stop` answers true.
pub fn plan_until(source string, targets []Target, stop fn () bool) !Plan {
	if targets.len == 0 {
		return error('replay: no channel to play onto')
	}
	rec := open_recording_until(source, stop)!
	buses := rec.buses
	mut specs := []player.BusSpec{}
	mut dbs := []candb.Database{}
	mut excluded := []string{}
	for t in targets {
		src := resolve_bus(buses, t.bus) or {
			return error('replay ${t.name}: ${err} (${os.base(source)})')
		}
		specs << player.BusSpec{
			src:     src
			dst:     t.iface
			db:      t.db
			exclude: t.exclude.clone()
		}
		dbs << t.db
		excluded << t.exclude
	}
	for c in player.conflicts(specs) {
		return error('replay: ${c}')
	}
	// one wire is one target, whatever rate each spelling asks for
	mut wires := map[string]string{}
	for t in targets {
		k := transport.wire_key(t.iface)
		if prev := wires[k] {
			return error('replay: ${prev} and ${t.name} are one wire (${k})')
		}
		wires[k] = t.name
	}
	nowhere := player.unknown_everywhere(dbs, excluded)
	if nowhere.len > 0 {
		return error('replay: no database of these channels declares ${nowhere.join(', ')}')
	}
	mut notes := []string{}
	for i, sp in specs {
		silent := player.check_nodes(sp.db, sp.exclude)
		if silent.len > 0 {
			notes << '${targets[i].name}: ${silent.join(', ')} not declared by its database — nothing is subtracted there'
		}
	}
	if rec.note != '' {
		notes << rec.note
	}
	mut prep := rec.prepare(specs)!
	mut total := 0
	for i, b in prep.buses {
		r := b.report
		total += r.kept
		gone := r.withheld_excluded + r.withheld_unattributed + r.remote
		notes << '${targets[i].name}: ${r.kept} frames, ${gone} withheld${if r.remote > 0 { ' (${r.remote} remote request(s), never replayed)' } else { '' }}'
	}
	if total == 0 {
		prep.close()
		return error('replay: nothing to play from ${os.base(source)} — ${notes.join('; ')}')
	}
	return Plan{
		prep:  prep
		notes: notes
	}
}

// Job is the worker's input in one struct: spawn passes it whole.
struct Job {
	prep   Prepared
	buses  map[string]transport.Bus
	speed  f64
	repeat bool
	paused bool
}

// start plays `source` onto `targets` on one clock, from its first frame (or paused there), and
// returns once the buses are open and the worker runs. Refused with the first problem, nothing
// left open.
pub fn start(source string, targets []Target, o Options) !&Session {
	if !player.speed_ok(o.speed) {
		return error('replay: speed ${o.speed} — a rate of at least ${player.min_speed}, finite')
	}
	mut pl := plan_until(source, targets, o.give_up)!
	mut buses := map[string]transport.Bus{}
	for t in targets { // plan_for refused two targets on one wire
		mut b := o.open(t.iface, t.name) or {
			for _, mut ob in buses {
				ob.close()
			}
			pl.prep.close()
			return error('replay ${t.name}: cannot open ${t.iface}: ${err}')
		}
		// it reproduces the recording's framing rather than originating any
		buses[t.iface] = transport.verbatim(mut b)
	}
	mut s := &Session{
		source:  source
		give_up: o.give_up
		notes:   pl.notes
		st:     Status{
			state:  if o.paused { player.State.paused } else { player.State.playing }
			dur_s:  pl.prep.end_s - pl.prep.t0_s
			speed:  o.speed
			repeat: o.repeat
		}
	}
	spawn s.run(Job{
		prep:   pl.prep
		buses:  buses
		speed:  o.speed
		repeat: o.repeat
		paused: o.paused
	})
	return s
}

fn ms_of(sw time.StopWatch) f64 {
	return f64(i64(sw.elapsed())) / 1e6
}

// run is the worker: the commands taken once a tick, the due frames sent, then a wait for the
// next one, at most a tick.
fn (mut s Session) run(j Job) {
	mut buses := j.buses.clone()
	mut prep := j.prep
	defer {
		prep.close()
		for _, mut b in buses {
			b.close()
		}
		s.mu.lock()
		s.st = Status{
			...s.st
			ended: true
		}
		s.ended = true
		s.mu.unlock()
	}
	mut p := prep.player(j.speed, j.repeat)
	mut sw := time.new_stopwatch()
	p.play(0)
	if j.paused {
		p.pause(0)
	}
	cancel := fn [mut s] () bool {
		return s.is_stopping()
	}
	mut batch := []canlog.LogEntry{cap: 256}
	mut sent := u64(0)
	mut failed := u64(0)
	mut first_err := ''
	mut read_err := ''
	for {
		s.mu.lock()
		stop := s.stopping || (!isnil(s.give_up) && s.give_up())
		cmd := s.cmds.take()
		asked := s.asked
		s.mu.unlock()
		if stop {
			break
		}
		now := ms_of(sw)
		p.apply_latched(cmd)
		if p.apply_timed(cmd, now).restarted {
			sent = 0
			failed = 0
			first_err = ''
		}
		p.due_into(now, mut batch)
		if read_err == '' && prep.read_error() != '' {
			read_err = '${os.base(s.source)}: ${prep.read_error()}'
		}
		mut cut := false
		for e in batch {
			if s.is_stopping() {
				cut = true
				break
			}
			mut b := buses[e.iface] or { continue }
			transport.send_waiting_for_room(mut b, e.frame, 500, cancel) or {
				failed++
				if first_err == '' {
					first_err = '${e.iface}: ${err.msg()}'
				}
				continue
			}
			sent++
		}
		if cut {
			// the player has passed frames that were never sent: its position is not the replay's
			s.mu.lock()
			s.st = Status{
				...s.st
				sent:   sent
				failed: failed
				error:  joined(first_err, read_err)
			}
			s.mu.unlock()
			break
		}
		st := p.status(ms_of(sw))
		s.mu.lock()
		s.st = Status{
			state:  st.state
			pos_s:  st.pos_s
			dur_s:  p.duration_s()
			speed:  st.speed
			repeat: st.repeat
			passes: st.loops
			sent:   sent
			failed: failed
			error:  joined(first_err, read_err)
		}
		s.taken = asked
		s.mu.unlock()
		mut until := ms_of(sw) + tick_ms
		if p.state() == .playing {
			if nd := p.next_due_ms() {
				if nd < until {
					until = nd
				}
			}
		}
		player.wait_until_ms(mut sw, until)
	}
}

// joined is a send failure and a read failure, either or both.
fn joined(send string, read string) string {
	return if send == '' || read == '' { send + read } else { '${send}; ${read}' }
}

fn (mut s Session) is_stopping() bool {
	s.mu.lock()
	v := s.stopping
	s.mu.unlock()
	return v || (!isnil(s.give_up) && s.give_up())
}

// ask queues `c` and waits until the worker has applied it and published the status it leads to,
// so the next status() says what it did; refused once the replay is stopped.
fn (mut s Session) ask(c player.Commands) ! {
	// one control at a time, so two from two threads are applied in turn, never merged
	s.ctl_mu.lock()
	defer {
		s.ctl_mu.unlock()
	}
	s.mu.lock()
	if s.stopping || s.ended {
		s.mu.unlock()
		return error('replay: stopped')
	}
	merged := player.Commands{
		state:  if c.state != .stopped { c.state } else { s.cmds.state }
		speed:  if c.speed > 0 { c.speed } else { s.cmds.speed }
		seek:   if c.seek >= 0 { c.seek } else { s.cmds.seek }
		repeat: if c.repeat >= 0 { c.repeat } else { s.cmds.repeat }
	}
	s.cmds = merged
	s.asked++
	want := s.asked
	s.mu.unlock()
	until := time.sys_mono_now() + u64(settle_ms) * 1_000_000
	for time.sys_mono_now() < until {
		s.mu.lock()
		taken := s.taken >= want
		ended := s.ended
		s.mu.unlock()
		if taken {
			return
		}
		if ended {
			return error('replay: stopped before the command was applied')
		}
		if !isnil(s.give_up) && s.give_up() {
			return error('replay: the wait for the command was given up; it applies when the worker next can')
		}
		time.sleep(time.millisecond)
	}
	return error('replay: the worker did not take the command within ${settle_ms} ms (a send held up by its driver); it applies when the worker next can')
}

// pause holds the replay where it is.
pub fn (mut s Session) pause() ! {
	s.ask(player.Commands{ state: .paused })!
}

// resume plays on from where it is; from the end of a non-looping replay, again from the start.
pub fn (mut s Session) resume() ! {
	s.ask(player.Commands{ state: .playing })!
}

// seek moves to `pos_s` seconds into the recording (clamped to it), playing or paused as it was;
// a finished replay is left paused there.
pub fn (mut s Session) seek(pos_s f64) ! {
	if pos_s < 0 || pos_s != pos_s {
		return error('replay: seek to ${pos_s} s — a position is 0 or more')
	}
	s.ask(player.Commands{ seek: pos_s })!
}

// set_speed changes the rate, the position kept.
pub fn (mut s Session) set_speed(rate f64) ! {
	if !player.speed_ok(rate) {
		return error('replay: speed ${rate} — a rate of at least ${player.min_speed}, finite')
	}
	s.ask(player.Commands{ speed: rate })!
}

// set_loop says whether the end of the recording starts it again; decided at the end of a pass.
pub fn (mut s Session) set_loop(on bool) ! {
	s.ask(player.Commands{ repeat: if on { i8(1) } else { i8(0) } })!
}

// status is what the replay is doing, as of the worker's last tick.
pub fn (mut s Session) status() Status {
	s.mu.lock()
	st := s.st
	s.mu.unlock()
	return st
}

// wait_done waits at most timeout_ms (negative: for ever) for the recording to run out (a
// non-looping replay finishes) or the replay to be stopped; true when it did.
pub fn (mut s Session) wait_done(timeout_ms int) bool {
	until := time.sys_mono_now() + u64(if timeout_ms > 0 { timeout_ms } else { 0 }) * 1_000_000
	for {
		st := s.status()
		if st.state == .finished || st.ended {
			return true
		}
		now := time.sys_mono_now()
		if timeout_ms >= 0 && now >= until {
			return false
		}
		mut step := u64(2_000_000)
		if timeout_ms >= 0 && until - now < step {
			step = until - now
		}
		time.sleep(i64(step) * time.nanosecond)
	}
	return false
}

// ended is whether the worker has let go of its buses: a stop that ran out of time leaves it
// letting go.
pub fn (mut s Session) ended() bool {
	s.mu.lock()
	e := s.ended
	s.mu.unlock()
	return e
}

// stop ends the replay and lets its buses go, waiting at most 2 s for the worker (a driver
// call that will not return keeps its bus until it does), and answers the last status.
pub fn (mut s Session) stop() Status {
	s.mu.lock()
	s.stopping = true
	s.mu.unlock()
	until := time.sys_mono_now() + u64(settle_ms) * 1_000_000
	for time.sys_mono_now() < until {
		s.mu.lock()
		ended := s.ended
		s.mu.unlock()
		if ended || (!isnil(s.give_up) && s.give_up()) {
			break
		}
		time.sleep(time.millisecond)
	}
	return s.status()
}

// Row is a project row a replay may play onto, as a script names it: its name, the interface it
// opens, its databases, and its `replay:` block with the source resolved (none without one).
pub struct Row {
pub:
	name  string
	iface string
	db    candb.Database
	cfg   ?project.Replay
}

// Ask is what a script asks of a replay over rows; what it leaves unsaid the rows' `replay:`
// blocks say: the source, the speed, loop, and the nodes subtracted.
@[params]
pub struct Ask {
pub:
	source  string // '' : the rows'
	speed   f64    // 0: the rows' (1 for a row without a replay: block)
	repeat  i8 = -1 // -1: the rows'
	paused  bool
	exclude ?[]string // none: each row's own
	bus     string    // the recorded bus, for one row; '': the row's
	open    Opener = default_open
	give_up fn () bool = unsafe { nil } // Options.give_up
}

// start_rows is start over project rows, by the one rule both bindings ask: refused where the rows
// disagree about what only the script could settle (their source, speed or loop).
pub fn start_rows(rows []Row, a Ask) !&Session {
	if rows.len == 0 {
		return error('replay: no channel to play onto')
	}
	if a.bus != '' && rows.len > 1 {
		return error('replay: a bus names the recorded bus of one channel, and ${rows.len} are given')
	}
	mut source := a.source
	mut speed := a.speed
	mut repeat := a.repeat
	mut targets := []Target{}
	for i, r in rows {
		cfg := r.cfg or { project.Replay{} }
		if a.source == '' {
			if cfg.source == '' {
				return error('replay ${r.name}: the row has no replay source; name one')
			}
			if i > 0 && os.real_path(cfg.source) != os.real_path(source) {
				return error('replay: ${rows[0].name} and ${r.name} replay different recordings; name the source')
			}
			source = cfg.source
		}
		row_speed := player.usable_speed(cfg.speed)
		row_repeat := i8(if cfg.repeat { 1 } else { 0 })
		if i > 0 && ((a.speed == 0 && row_speed != speed) || (a.repeat < 0 && row_repeat != repeat)) {
			return error('replay: ${rows[0].name} and ${r.name} disagree on speed or loop, and share one clock; say which')
		}
		if a.speed == 0 {
			speed = row_speed
		}
		if a.repeat < 0 {
			repeat = row_repeat
		}
		targets << Target{
			name:    r.name
			iface:   r.iface
			bus:     if a.bus != '' { a.bus } else { cfg.bus }
			db:      r.db
			exclude: a.exclude or { cfg.exclude }
		}
	}
	return start(source, targets,
		speed:  speed
		repeat: repeat == 1
		paused:  a.paused
		open:    a.open
		give_up: a.give_up
	)
}
