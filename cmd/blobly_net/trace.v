module main

import os
import time
import transport
import wiretap
import telem
import canlog
import project
import vgui

struct TraceRow {
	t_ms f64
	ch   string
	// TX | TX-S | REP | RX. The old `dir` answered "did I press send", never "whose frame is
	// this" — and our own sends come back to the monitor, so they landed in the same RX pile as
	// the device under test's. TX-S is still a TX: the simulation is us. REP is the one that is
	// not a direction, because a recording does not say who transmitted its lines.
	origin string
	id     u32
	ext    bool
	rtr    bool
	// CAN-FD, as a KIND rather than a decoration: a 64-byte payload is visible from `data`, but
	// an FD frame carrying 8 bytes or fewer is otherwise indistinguishable from a classic one,
	// and BRS is invisible either way. The trace is the record people read back, so a row that
	// drops these describes a frame that was never on the bus.
	fd  bool
	brs bool
	// ESI is on the ROW but deliberately NOT in the group key or the echo identity: it is a
	// received status, so keying on it would split one message into two rows the moment its
	// transmitter went error-passive. Shown from the latest frame, which is where a reader
	// looking for a degrading bus would look.
	esi  bool
	name string
	data []u8
	// End-to-end violation on a RECEIVED frame ('' = none, or not a protected message).
	// Carried on the row rather than computed at draw time because it depends on the PREVIOUS
	// frame's counter — a verdict the trace cannot reconstruct once the frames are just rows.
	e2e string
	// From a loaded recording: stamped on the FILE's clock, not the app's. A live row appended
	// behind imported ones (Resume, no Start) is on another clock, and the cycle window has
	// to know where one clock ends and the other begins (cyclerule; codex on #266).
	imported bool
mut:
	// An outbound row is written at emit, so it states intent; `missed` says its echo window
	// closed with the frame never coming back off the wire. Those disagree in every bench
	// failure worth catching — CAN needs an ACK from at least one other node, so a lone node's
	// frames never reach the wire at all, and the same goes for a wrong bitrate, swapped
	// CANH/CANL or a down link.
	//
	// No `confirmed`: nothing displays "arrived as expected", and a field written but never read
	// is a claim nobody checks. `seq` DOES earn its place now: it is the row's global frame
	// index, written once by push_row_locked and read by the IDX column — the views filter and
	// regroup their row slices, so "position in the slice" stops being the identity the moment
	// a filter runs. Row LOOKUP (echo confirmation) still goes by position against trace_base.
	missed bool
	// The driver REFUSED this emission: nothing went on the line, and the row must say so —
	// a row that reads as an ordinary TX for a frame that never left the host is the trace
	// claiming a send that did not happen (maintainer, 2026-08-21). Distinct from `missed`:
	// refused never reached the driver's queue; missed left it and nobody answered.
	refused bool
	seq     u64
	// The DISPLAYED frame number, frozen at push as seq - trace_run_base. Computing it at draw
	// time required threading the base through every view (and pairing it with the row snapshot,
	// or a mid-frame Clear wrapped every idx to ~1.8e19 — codex #127 r1), and a base reset
	// still renumbered history: after Start, the file rows of a trimmed import would have
	// wrapped. Frozen, a row's number is a fact about the row; later resets only affect later
	// rows. Start/Clear/Load all reset the base, so a new measurement numbers from 0 — a
	// trimmed import pre-advances seq, so its rows freeze to the file's own frame numbers.
	idx u64
	// The measurement this row was pushed into: trace_run_base at push, which Start, Clear and
	// Load each move. Frozen on the row like idx, because the base itself remembers only the
	// NEWEST boundary — a group silent across two Starts still has rows from three
	// measurements in the ring, and the cycle window must restart at each (codex on #266).
	run u64
}

// has_payload gates every SIGNAL-DECODING consumer of a row's data. An RTR frame's data is a
// zero-filled placeholder that carries only the requested DLC — live SocketCAN delivers it that
// way (the shim returns can_dlc bytes with no RTR check) and the canlog import now mirrors it —
// so decoding those bytes fabricates all-zero signal values from a frame that has NO payload.
// One predicate rather than a `!r.rtr` at each site, so the next decoder greps into the rule
// instead of rediscovering it (codex #127 r2).
fn (r TraceRow) has_payload() bool {
	return !r.rtr && r.data.len > 0
}

struct TRec {
	ch     int
	core   int // the block's core (from its header) — authoritative for lane grouping (esp. idle)
	abs_us u64 // start_us folded across epoch re-anchors (µs; u64 so a long capture can't wrap)
	rec    telem.Record
}

// reset_trace_locked empties the trace and everything keyed to it. Caller holds app.mu.
fn (mut app App) reset_trace_locked() {
	app.trace = []
	app.gcount = map[string]u64{}
	app.viewing_rec = '' // whatever replaces the rows, the view is no longer that recording
	app.trace_run_base = app.trace_seq // idx restarts at 0 for the new measurement's rows
	// The pending records STAY. An echo already in flight is still ours, and dropping the record
	// would turn the next few of our own frames into RX rows, recording entries and verifier
	// input. Row identities are monotonic and trace_base makes the old ones unresolvable, so a
	// surviving record suppresses its echo without confirming a row that came later.
	app.trace_base = app.trace_seq
}

// since_ms is the one clock every row and record is stamped from: f64 milliseconds since the
// app started, carried at the ns-resolution of the monotonic clock underneath. All stamp sites
// go through here — the previous arrangement had five copies of `f64(time.ticks() - t0)`, so a
// clock change meant five edits, and the chart's "now" (a sixth) could drift from the rows'.
fn (app &App) since_ms() f64 {
	return f64(time.sys_mono_now() - app.t0_ns) / 1_000_000.0
}

// since_s: the same instant in seconds — what canlog.LogEntry.t_s and the chart's x-axis speak.
// A sibling rather than four copies of `/ 1000.0`, for the same reason since_ms exists at all.
fn (app &App) since_s() f64 {
	return app.since_ms() / 1000.0
}

// push_row_locked appends a row, stamps its identity and trims the ring. Caller holds app.mu.
fn (mut app App) push_row_locked(row TraceRow) u64 {
	seq := app.trace_seq
	app.trace_seq++
	mut r := row
	r.seq = seq
	r.idx = seq - app.trace_run_base // frozen here — see the field
	r.run = app.trace_run_base
	app.trace << r
	// Trimmed in CHUNKS. Reslicing to the cap on every append copies the whole ring each time —
	// unnoticeable at a few frames a second, and the dominant cost when a recording is imported,
	// which is exactly where the row count is largest. Letting it run to 1.5x and cutting back
	// to the cap makes the copying amortised O(1) per row; the visible window is unchanged.
	if app.trace.len > trace_cap + trace_cap / 2 {
		drop := app.trace.len - trace_cap
		app.trace = app.trace[drop..].clone()
		app.trace_base += u64(drop)
	}
	return seq
}

// row_index_locked maps a row identity to its current position, or -1 once the ring has trimmed
// it away. Caller holds app.mu.
fn (app &App) row_index_locked(seq u64) int {
	// Every comparison in u64, and the ghost range rejected BEFORE any narrowing: V's int is
	// 32 bits, so int(ghost_base - 0) wraps to a small number — the first paused emissions were
	// resolving to rows 0, 1, 2 and marking healthy pre-pause traffic as never sent.
	if seq >= ghost_base || seq < app.trace_base {
		return -1
	}
	off := seq - app.trace_base
	return if off < u64(app.trace.len) { int(off) } else { -1 }
}

// expire_pending_locked marks the rows whose frame never came back off the wire.
fn (mut app App) expire_pending_locked(now_ms f64) {
	for seq in app.taps.expire(now_ms) {
		i := app.row_index_locked(seq)
		if i >= 0 {
			app.trace[i].missed = true
		}
	}
}

// note_emit records a frame we are about to put on the wire: one row stating intent, and one
// pending echo. Called BEFORE the send — the RX thread can see the frame the instant the driver
// takes it, and a pending entry added afterwards would arrive too late to claim its own echo.
// Returns the row identity and the RECORDING identity of the entry this call wrote, or rec_none
// when it wrote none. The retract path must not guess that from the backend (a bus that normally
// echoes also records at emit whenever no monitor is running) and must not search for it either:
// a scan can be outrun by traffic on a busy bus.
fn (mut app App) note_emit(iface string, chan_name string, origin string, f transport.CanFrame) (u64, u64, u64) {
	app.mu.lock()
	// Sampled AFTER the lock. Another operation can hold app.mu for longer than the echo window
	// — opening a large recording during a measurement, say — and a time taken before blocking
	// would make the emission look two seconds old the instant it is registered, expiring it
	// before the frame has even been sent.
	t_ms := app.since_ms()
	// Under the lock, not before it. The dbc_readers drain covers the RX loops, which register
	// as lock-free readers; a tapped emitter — a simulated ECU, a diagnostic or flash worker
	// still draining after Stop — is not in that lifecycle, so resolving a name outside the
	// mutex could read app.dbs while a configuration edit replaces it.
	chn := if chan_name != '' { chan_name } else { app.chan_name_for(iface) }
	name := app.lookup_name(f.id, f.extended)
	app.expire_pending_locked(t_ms)
	// Paused: the emission is STILL tracked so its echo is recognised as ours — otherwise a
	// paused trace would feed our own frames to the E2E verifier as the ECU's and log them to
	// the recording twice — it simply has no row to confirm.
	mut seq := ghost_base + app.ghost_seq
	app.ghost_seq++
	if !app.paused {
		seq = app.push_row_locked(TraceRow{
			t_ms:   t_ms
			ch:     chn
			origin: origin
			id:     f.id
			ext:    f.extended
			fd:     f.fd
			brs:    f.brs
			esi:    f.esi
			rtr:    f.rtr
			name:   name
			data:   f.data.clone()
		})
		app.gcount[gkey_frame(origin, chn, f)]++
	}
	// Counted whether or not the trace is paused, and whether or not a row was written: pausing
	// freezes the table, it does not stop the bus.
	match origin {
		org_tx { app.tx_count++ }
		org_tx_sim { app.tx_sim_count++ }
		else {} // REP never reaches a bus; RX is not ours to count here
	}

	epoch := app.tx_epoch
	// ALWAYS record what we sent, on any backend that could echo — the emission is ours whether
	// or not a monitor happens to be open at this instant, and the sim emits its first frames
	// while the rx loops are still opening. Attributing those to the device under test breaks
	// the one promise this column makes.
	//
	// The monitor list rides along instead of gating: it says who could have seen this frame,
	// which decides who may claim it and whether "never came back" is evidence of anything. Asked
	// NOW rather than when the bus was opened, since a channel disabled mid-run takes its monitor
	// with it.
	// Recording at EMIT only where nothing will observe the frame FOR us: PCAN and Kvaser never
	// hand our own transmissions back, and a bus with no monitor running has nobody to write it
	// — a generator aimed at an off channel, or the simulation's first frames before the rx
	// loop opens, would otherwise vanish from the file while genuinely reaching the bus.
	// Everywhere else the echo records it, in observation order (see rx_loop); doing both would
	// duplicate the frame and put a fast responder's answer ahead of its request.
	//
	// Not gated on `paused`: pausing freezes the TABLE, not the recording.
	watching := transport.echoes_own_sends(iface) && app.monitors_locked(iface).len > 0
	mut recorded_here := false
	mut rec_id := u64(0)
	if app.recording && !watching {
		// Stamped INSIDE the lock, like the rx path: a time taken before acquiring it can be
		// older than a line already written, and the file would then disagree with itself.
		rec_id = app.rec_append_locked(canlog.LogEntry{
			t_s:   app.since_s()
			iface: chn
			frame: f
		})
		recorded_here = true
	}
	if transport.echoes_own_sends(iface) {
		watchers := app.monitors_locked(iface)
		// `recorded_here` travels with the emission: a monitor whose bus is OPEN but which has
		// not published readiness yet is invisible to the check above, so we record at emit and
		// its echo would then record the same frame again.
		for missed in app.taps.note(seq, iface, f, t_ms, watchers, chn, recorded_here) {
			i := app.row_index_locked(missed)
			if i >= 0 {
				app.trace[i].missed = true
			}
		}
	}
	// Rate-limited exactly like the rx path: a simulation emitting hundreds of frames a second
	// would otherwise post an event per frame and hold the UI at the traffic rate.
	now := time.ticks()
	if now - app.last_wake >= app.wake_ms {
		app.last_wake = now
		app.mu.unlock()
		vgui.wake()
	} else {
		app.mu.unlock()
	}
	return seq, if recorded_here {
		rec_id
	} else {
		rec_none
	}, epoch
}

// rec_append_locked appends to the recording and returns that entry's stable identity.
//
// EVERY append goes through here, because `rec` and `rec_ids` must stay index-for-index: the
// received frames and the echoes append too, and one that skipped the id would put the two arrays
// out of step — after which `unrecord`, which finds an entry by searching rec_ids, would delete
// somebody else's frame. Caller holds app.mu.
fn (mut app App) rec_append_locked(e canlog.LogEntry) u64 {
	id := app.rec_seq
	app.rec_seq++
	app.rec << e
	app.rec_ids << id
	if app.rec.len > 200000 {
		drop := app.rec.len - 200000
		app.rec = app.rec[drop..].clone()
		app.rec_ids = app.rec_ids[drop..].clone()
	}
	return id
}

// unrecord drops a frame we recorded at emit but never managed to send, BY IDENTITY. The
// previous version searched backwards for a matching frame, which a busy bus outruns: a vendor
// driver can block long enough for the received traffic to push the entry out of any bounded
// window, leaving a frame in the file that was never transmitted.
//
// NOT gated on app.recording: the user may have stopped recording between the emit-append and
// the driver's refusal, and the entry is still in the buffer. (If Stop already WROTE the file,
// the frame is in it — nothing here can reach that, and a stopped recording is not rewritten.)
fn (mut app App) unrecord(rec_id u64) {
	if rec_id == rec_none {
		return
	}
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	// Located by its id, kept alongside each entry. Arithmetic on a base does not survive a
	// deletion in the MIDDLE — two emit-time sends on different interfaces can fail out of
	// order — after which every later id would point one entry off and a retraction would
	// delete an unrelated frame. The ids are ascending, so this is a binary search.
	mut lo := 0
	mut hi := app.rec_ids.len - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		if app.rec_ids[mid] == rec_id {
			app.rec.delete(mid)
			app.rec_ids.delete(mid)
			return
		}
		if app.rec_ids[mid] < rec_id {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
}

// tx_counts renders what we transmitted, split the way the trace's origin column splits it:
// the tester's own sends and the simulated rest-of-bus are different facts. TX-S appears only
// once the simulation has actually sent something, so a pure-tester session is not padded with
// a permanent zero.
//
// Rendered ONCE per frame under app.mu, next to rx and the row snapshot, and passed down as a
// string. The panels run on the UI thread while sim/generator/diagnostic workers are counting;
// reading the two fields there would be a data race, and reading them separately could print
// "TX-S" with a count that a concurrent Clear had already zeroed. Caller holds app.mu.
fn (app &App) tx_counts_locked() string {
	if app.tx_sim_count == 0 {
		return 'TX ${app.tx_count}'
	}
	return 'TX ${app.tx_count} · ${org_tx_sim} ${app.tx_sim_count}'
}

// count_tx_load adds a frame the driver ACCEPTED to its wire's load. After the send and not
// at note_emit, so a refused frame never needs refunding (codex #263 r1); and onto the row
// that is RUNNING for the wire rather than the row named by the tap — two enabled rows on one
// destination share one reader and one running flag, and the load is the wire's, so the
// alias's frames would otherwise land on a row the panel and the toolbar skip (r1).
fn (mut app App) count_tx_load(iface string, f transport.CanFrame) {
	key := transport.destination_key(iface)
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	i := app.load_owner_locked(key)
	if i < 0 {
		return
	}
	nominal, data := app.wire_rates_locked(i)
	app.chans[i].load_bits += transport.frame_bits(f, nominal, data)
}

// load_owner_locked is the row that holds a wire's load right now: the running reader; failing
// that, the row whose reader is on its way up — a tap can win the race against rx_loop at
// Start, and a handoff has a moment with no running row (codex #263 r3); failing THAT, the
// wire's first enabled row — between `app.running = true` and the spawn loop that follows it
// nothing is marked yet, and a script's guardless tap can send in that window (r4). The roll
// runs on the GUI thread, the same thread start() runs on, so it cannot reset that row's
// bits in between. -1 when no enabled row is on the wire.
fn (app &App) load_owner_locked(key string) int {
	mut spawning := -1
	mut enabled := -1
	for i, c in app.chans {
		if c.doip || transport.destination_key(c.iface) != key {
			continue
		}
		if c.running {
			return i
		}
		if c.spawning && spawning < 0 {
			spawning = i
		}
		if c.monitorable() && enabled < 0 {
			enabled = i
		}
	}
	if spawning >= 0 {
		return spawning
	}
	return enabled
}

// wire_rates_locked is the nominal and data rate a frame on row `i`'s WIRE is charged at —
// ONE answer per destination, whichever row asks: the nominal rate is the first enabled row's
// on that wire, and the data rate is the first enabled row's that declares one. On SocketCAN
// and the software buses two enabled rows may share a wire and disagree (the project warns
// rather than refuses, because those adapters do not configure timing), and the reader is
// whichever came first — so read from the reader's row, a BRS frame through a classic row
// had its whole payload charged at the nominal rate (codex #263 r4), and reordering two rows
// halved the load and a handoff reinterpreted an interval at another rate (r6). The first
// enabled row is still an order, but it is the same order for RX, TX and the handoff. And
// it is resolved ONCE per row per run and kept: enabling an alias that precedes the reader
// mid-run would otherwise change the answer under an interval whose bits were priced at the
// old one, and the roll would divide them by the new rate — a false spike or dip (r8).
//
// An UNSET nominal rate is the project's default, the one reading the open path and
// origination_framing already share (project.Channel.nominal_bitrate); the raw zero the row
// keeps would make load_percent answer 0 % for every interval on a live wire (r5).
fn (mut app App) wire_rates_locked(i int) (int, int) {
	if app.chans[i].load_nominal > 0 {
		return app.chans[i].load_nominal, app.chans[i].load_data
	}
	key := transport.destination_key(app.chans[i].iface)
	mut nominal := 0
	mut data := 0
	for c in app.chans {
		if c.doip || !c.monitorable() || transport.destination_key(c.iface) != key {
			continue
		}
		if nominal == 0 {
			// normalised HERE: an unset rate on the first row is 500 kbit/s, not "no answer
			// yet" for a later row to overwrite (codex #263 r9)
			nominal = if c.bitrate > 0 { c.bitrate } else { project.default_bitrate }
		}
		if data == 0 && c.data_bitrate > 0 {
			data = c.data_bitrate
		}
	}
	if nominal == 0 {
		nominal = if app.chans[i].bitrate > 0 { app.chans[i].bitrate } else { project.default_bitrate }
	}
	app.chans[i].load_nominal = nominal
	app.chans[i].load_data = data
	return nominal, data
}

// retract_emit takes back an emission the driver refused. The row stays and is marked: the frame
// did not reach the wire, which is exactly what the mark says — but the pending record goes, so
// expiry does not report it a second time.
fn (mut app App) retract_emit(seq u64, origin string, epoch u64) {
	app.mu.lock()
	app.taps.forget(seq)
	// note_emit counted it before the driver was asked, because the echo can arrive first. The
	// driver refused, so it never reached the wire and the count must come back — but only to
	// the session that paid for it. A driver on one interface can block across a Clear while a
	// send on another succeeds into the fresh counters, and an unconditional decrement would
	// take the refund out of THAT frame's count instead.
	if epoch == app.tx_epoch {
		match origin {
			org_tx {
				if app.tx_count > 0 { app.tx_count-- }
			}
			org_tx_sim {
				if app.tx_sim_count > 0 { app.tx_sim_count-- }
			}
			else {}
		}
	}
	i := app.row_index_locked(seq)
	if i >= 0 {
		app.trace[i].refused = true
		// the gcount refund, next to the TX-counter refund and under the same epoch guard:
		// note_emit counted this frame into the group total before the driver was asked, and
		// a sustained refusal (bus-off) otherwise grew count and held the cycle as if frames were
		// flowing while the header honestly said TX 0 (codex #143 r2). Only while the row is
		// still in the ring — the key is rebuilt from it; a retract lands ms after the emit,
		// so a trimmed row is a busy-bus corner where one count is the honest loss.
		if epoch == app.tx_epoch {
			k := app.trace[i].gkey()
			if app.gcount[k] > 0 {
				app.gcount[k]--
			}
		}
	}
	app.mu.unlock()
}

// claim_echo_locked confirms the emission this frame is the echo of, and reports whether it
// found one. The matching rules (one-shot, oldest first, width-exact) and why they are what they
// are live in modules/wiretap. Caller holds app.mu.
fn (mut app App) claim_echo_locked(monitor int, iface string, f transport.CanFrame, t_ms f64) ?wiretap.Claim {
	app.expire_pending_locked(t_ms)
	return app.taps.claim(monitor, iface, f, t_ms)
}

fn (mut app App) clear_trace() {
	app.mu.lock()
	app.reset_trace_locked()
	app.trecs = []
	app.rx = 0
	app.tx_count = 0
	app.tx_sim_count = 0
	app.tx_epoch++
	for i in 0 .. app.chans.len {
		app.chans[i].rx = 0
	}
	app.mu.unlock()
}

// toggle_record starts capturing frames, or stops and writes them to a candump .log.
// recordings_dir is where captures are written AND where File > Open Recording starts — one
// value, because the write side and the read side of the same feature disagreeing about where
// recordings live is exactly how a fresh capture became invisible to the picker. Beside the
// open project; for an unsaved project, projects/ (the picker's own fallback), then the CWD.
fn (app &App) recordings_dir() string {
	if app.proj_path != '' {
		return os.dir(app.proj_path)
	}
	if os.is_dir('projects') {
		return os.abs_path('projects')
	}
	return os.abs_path('.')
}

// fresh_rec_path picks a collision-proof destination — timestamped, -N suffix within the
// second — and RESERVES it by creating the file on the spot. Choosing without reserving left
// the whole capture interval as a race window: a second app instance recording beside the same
// project in the same second saw the name as free and truncated whichever capture finished
// first. Creation shrinks that window to the microseconds between the exists() probe and the
// create (vlib's open_file has no O_EXCL to close it entirely — its mode parser ignores
// unknown letters, verified, so 'wx' silently means 'w'). Reserving up front also means an
// unwritable destination fails AT THE RECORD PRESS, not after an hour of capturing.
// A crash mid-recording leaves the reserved file empty; it is timestamped and gitignored.
fn (app &App) fresh_rec_path() !string {
	dir := app.recordings_dir()
	stamp := time.now().custom_format('YYYYMMDD-HHmmss')
	mut path := os.join_path(dir, 'recording-${stamp}.log')
	mut n := 2
	for os.exists(path) {
		path = os.join_path(dir, 'recording-${stamp}-${n}.log')
		n++
	}
	mut f := os.create(path)!
	f.close()
	return path
}

// write_rec_locked=false snapshot writer: WRITE FIRST, DISCARD ON SUCCESS. The buffer used to
// be emptied before the write, so a full disk threw away up to 200k captured frames with only
// a toast to say so.
fn (mut app App) write_rec(entries []canlog.LogEntry, path string) bool {
	mut lines := []string{cap: entries.len}
	for e in entries {
		lines << canlog.format_line(e)
	}
	os.write_file(path, lines.join('\n') + '\n') or {
		app.notify('record write failed: ${err} — frames kept; press Record to retry the save')
		return false
	}
	app.mu.lock()
	app.rec = []
	app.rec_ids = [] // WITH the buffer: a stale id list makes the next retraction index past
	// the end of a shorter buffer, which panics rather than mislabels
	app.mu.unlock()
	app.notify('recorded ${entries.len} frames -> ${path}')
	return true
}

fn (mut app App) toggle_record() {
	if app.recording {
		app.mu.lock()
		entries := app.rec.clone()
		app.recording = false
		app.mu.unlock()
		app.write_rec(entries, app.rec_path)
	} else {
		app.mu.lock()
		frozen := app.rec.clone()
		app.mu.unlock()
		if frozen.len > 0 {
			// A non-empty buffer while not recording is a capture whose write FAILED. This
			// press retries the save — it does not arm a new capture, because rearming let
			// live frames append to (and, at the 200k cap, evict from) the very frames the
			// failure path had promised to preserve (codex #128 r1). And it retries to the
			// path ALREADY RESERVED for this capture: allocating a fresh name left the
			// reserved file behind empty, so the picker showed two files for one capture and
			// a later reader could open the wrong one and conclude frames were lost.
			app.write_rec(frozen, app.rec_path)
			return
		}
		path := app.fresh_rec_path() or {
			app.notify('cannot create a recording file here: ${err} — not recording')
			return
		}
		app.mu.lock()
		app.rec_ids = []
		app.recording = true
		app.rec_path = path
		app.mu.unlock()
		app.notify('recording -> ${path}')
	}
}
