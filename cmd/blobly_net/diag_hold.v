module main

import time
import isotp
import transport
import doip
import uds
import vgui
import diaghold
import sysview

// ---- The Diagnostics panel's held connection ----
//
// ONE holder thread per run owns the panel's connection: it opens it on the first press, serves
// every later press on it one at a time, keeps a non-default session alive, and lets it go by
// the rules in ./diaghold (which also says what "held" means on each carrier, why the holder is a
// RUN worker, and how another tool gets the entity). Nothing but that thread touches the channel
// or the client; what the panel shows of it is DiagHoldStatus, written under app.mu.

// DiagReq is one press of a panel button, addressed by the target key captured at click time.
struct DiagReq {
	kind string // 'session' | 'vin' | 'tp' | 'did' | the DTC tab's (diag_dtc.v): 'dtcs' |
	// 'dtc_detail' | 'dtc_clear' | 'dtc_setting' | the DIDs tab's (diag_did.v): 'did_read' |
	// 'did_read_all' | 'did_write'
	did  u16
	key  string
	epoch    u64 // app.diag_epoch when sent: a press of an earlier project's writes nothing
	// the DTC tab's
	mask     u8   // 0x19 02's status mask
	code     u32  // the DTC a 'dtc_detail' reads
	on       bool // 'dtc_setting': 0x85 01 (true) or 02
	auto     bool // the auto-refresh's, not a press: refused in silence, logged only on a change
	did_lens map[u16]int // snapshot DID sizes from the target's description
	// the DIDs tab's
	dids     []u16           // 'did_read_all': in order
	data     []u8            // 'did_write': the value
	sessions []u8            // 'did_write': the sessions the DID is written in (none = any)
	level    u8              // 'did_write': the security level it needs (0 = none)
	ref_key  bool            // the node's key is blobly_net's reference key: the panel can unlock
	follow   []u16           // 'did_write': read back after the DID itself (a parameter's status)
	writable bool            // 'did_write': the description declares a write gate (diaghold.write_plan)
	ident    string          // the description's identity the press was made under (DiagDesc.ident)
	desc     sysview.EcuDesc // the target's description, for naming and decoding the lines
}

// DiagHoldStatus is the strip at the top of the panel. Guarded by app.mu.
struct DiagHoldStatus {
mut:
	key        string // ... and its identity, for what is asked of this connection's state
	label      string // the target the connection is (or was) to
	doip       bool
	conn       diaghold.Conn
	why        string // failed: the error; closed: why it was let go
	session    u8 // what the last 0x10 answer on this connection established; 0 = none yet
	p2_ms      int // from that answer; -1 = none yet
	p2_star_ms int
	keepalives int // 3E 80 sent on this connection
	security   u8  // the level a 0x27 unlocked on this connection, since its last session change
	dtc_off    bool // a 0x85 02 was answered on this connection and no 0x85 01 since
}

// HoldCtx is what this holder generation's token reads: whose it is, which commands it has
// handled and what it is working on. Written by the holder thread only; read by its token, which
// only the holder thread calls (from inside the carriers' waits).
@[heap]
struct HoldCtx {
	gen u64
mut:
	handled  u64
	work_key string
}

// diag_idle_drain_max bounds one look's drain of a held CAN tap: the shared hub's ring.
const diag_idle_drain_max = 4096

// HeldConn is the holder thread's own: never shared.
struct HeldConn {
mut:
	open     bool
	target   DiagTarget
	where    string // what was opened, for the log
	ch       isotp.Channel // DoIP: the held connection; CAN: the held ISO-TP channel
	dc       &doip.DoipClient = unsafe { nil } // DoIP: the same connection, for its idle service
	sc       &isotp.SoftChannel = unsafe { nil } // CAN: the same channel, for its idle drain
	attached bool // CAN only: the channel and its tap are open
	cli      uds.Client
	session  u8
	security u8 // the level unlocked since the last session change (0x27); 0 = locked
	// how many requests the press in progress put on the carrier (diag_request): what the
	// unsent-request retry asks, since `cli.last` is the last exchange of a press of several
	press_sent int
	last_ms  i64 // the last thing sent to the ECU (time.ticks), which is what S3 runs from
	// the P2* the target announced on an earlier connection (app.diag_timing), loosened into the
	// client at the open
	p2_star_ms int
	// this holder generation's ONE cancellation token (diaghold.Commands.cancels), installed on
	// every wait it blocks in: the DoIP open and recv, the ISO-TP channel, the uds client
	stop fn() bool = unsafe { nil }
}

// diag_press is one press of a Diagnostics panel button: handed to this run's holder, spawned
// on the first press. Marked busy HERE, under the lock that publishes the request, so a second
// click cannot slip in before the holder has taken the first. Refused while a tool has the target.
fn (mut app App) diag_press(kind string, did u16) {
	app.diag_send(DiagReq{
		kind: kind
		did:  did
	})
}

// diag_send is diag_press for any request; the key is filled in here.
fn (mut app App) diag_send(r DiagReq) {
	app.mu.lock()
	why := diaghold.press_refusal(app.running, app.diag_busy, app.diag_tools)
	if why != '' {
		app.mu.unlock()
		// a click while a press is in flight is the panel's own busy state; an auto-refresh
		// refused is not a press at all
		if why != 'busy' && !r.auto {
			app.diag_push('${r.kind}: ${why}')
		}
		return
	}
	if app.diag_hold_gen != app.run_gen {
		app.diag_q = chan DiagReq{cap: 4}
		app.diag_hold_gen = app.run_gen
		app.diag_holders_alive++
		app.reserve_run_worker_locked() // released by the holder's own defer
		spawn diag_holder(app, app.run_gen, app.diag_q)
	}
	app.diag_busy = true
	app.diag_q.try_push(DiagReq{
		...r
		key:   app.diag_sel_key
		epoch: app.diag_epoch
	})
	app.mu.unlock()
}

// diag_command issues a release to THIS run's holder (diaghold.Commands): it cancels the work
// that holder is blocked in, at its next stop poll, and the holder lets go at its next look.
fn (mut app App) diag_command_locked(why diaghold.Release, keep_key string) diaghold.Ticket {
	return app.diag_cmds.issue(app.diag_hold_gen, why, keep_key)
}

// diag_disconnect is the strip's Disconnect.
fn (mut app App) diag_disconnect() {
	app.mu.lock()
	app.diag_command_locked(.disconnect, '')
	app.mu.unlock()
}

// diag_publish_view tells the holder what the panel shows — open or closed, which target — and
// issues the release each change means. Called every frame from the GUI thread, it takes the
// lock only when something changed.
fn (mut app App) diag_publish_view() {
	if app.diag_pub_open == app.show_diag && app.diag_pub_key == app.diag_sel_key {
		return
	}
	closed := app.diag_pub_open && !app.show_diag
	moved := app.diag_pub_key != app.diag_sel_key && app.diag_pub_key != ''
	app.diag_pub_open = app.show_diag
	app.diag_pub_key = app.diag_sel_key
	app.mu.lock()
	app.diag_view_open = app.show_diag
	app.diag_view_key = app.diag_sel_key
	if closed {
		app.diag_command_locked(.panel_closed, '')
	} else if moved {
		app.diag_command_locked(.deselected, app.diag_sel_key)
	}
	app.mu.unlock()
}

// diag_tool_begin is called by an operator tool that speaks UDS (a script, a flash) as it starts.
// The panel holds nothing while one runs (./diaghold): the tool is counted — so no press is taken
// — and commands this run's holder to release, which cancels whatever it is blocked in; then it
// waits for that RELEASE (diaghold.tool_may_start), which is a stop poll and a holder look away.
// The safety bound is for a defect, and says so loudly. Paired with diag_tool_end; returns a note
// for the tool to show when the bound was hit.
fn (mut app App) diag_tool_begin() string {
	app.mu.lock()
	app.diag_tools++
	t := app.diag_command_locked(.tool, '')
	app.mu.unlock()
	t0 := time.ticks()
	for {
		app.mu.lock()
		may := diaghold.tool_may_start(app.diag_holders_alive, app.diag_hold_gen, app.diag_released,
			t)
		app.mu.unlock()
		if may {
			return ''
		}
		if time.ticks() - t0 > diaghold.tool_safety_ms {
			note := 'DEFECT: the Diagnostics panel did not release the target within ${diaghold.tool_safety_ms} ms of being told to; going ahead'
			app.elog(note)
			return note
		}
		time.sleep(5 * time.millisecond)
	}
	return ''
}

fn (mut app App) diag_tool_end() {
	app.mu.lock()
	app.diag_tools--
	app.mu.unlock()
}

// diag_holder is the run's holder thread. A RUN WORKER: reserved by diag_press, ended by Stop,
// waited for by a rebuild (see ./diaghold for why that bucket).
fn diag_holder(app &App, gen u64, q chan DiagReq) {
	defer {
		release_run_worker(app)
	}
	mut a := unsafe { app }
	mut ctx := &HoldCtx{
		gen: gen
	}
	stop := fn [app, ctx] () bool {
		mut ap := unsafe { app }
		ap.mu.lock()
		live := ap.running && ap.run_gen == ctx.gen
		cmds := ap.diag_cmds
		ap.mu.unlock()
		return cmds.cancels(ctx.gen, ctx.handled, live, ctx.work_key)
	}
	mut h := HeldConn{
		stop: stop
	}
	for {
		v, handled := a.diag_hold_view(gen, ctx.handled, if h.open { h.target.key } else { '' })
		r := diaghold.release(v)
		if r != .keep {
			a.diag_let_go(gen, mut h, .closed, r.words())
		}
		// released only once let go: a tool waiting on this mark then finds the target free
		ctx.handled = handled
		ctx.work_key = ''
		a.mu.lock()
		a.diag_released = diaghold.Mark{gen, handled}
		a.mu.unlock()
		if !v.run_live {
			break
		}
		if diaghold.keepalive_due(h.open, h.session, h.last_ms, time.ticks()) {
			ctx.work_key = h.target.key
			a.diag_keepalive(gen, mut h)
		}
		if h.open {
			ctx.work_key = h.target.key
			a.diag_idle(gen, mut h)
		}
		select {
			req := <-q {
				ctx.work_key = req.key
				a.diag_serve(gen, mut h, req)
			}
			50 * time.millisecond {
			}
		}
	}
	// No more presses for this holder: the next one spawns the next run's. Then answer what was
	// already queued — published under the same lock diag_press pushes under, so nothing can
	// arrive after this drain.
	a.mu.lock()
	if a.diag_hold_gen == gen {
		a.diag_hold_gen = 0
	}
	a.diag_holders_alive--
	a.mu.unlock()
	mut req := DiagReq{}
	for q.try_pop(mut req) == .success {
		a.diag_push_for(req, '${req.kind}: not sent — the measurement stopped')
		a.diag_done()
	}
}

// diag_hold_view reads what the release rule needs, under one take of the lock: the commands of
// THIS generation not yet handled (another generation's are never this holder's), and the number
// it has handled once this look is acted on.
fn (mut app App) diag_hold_view(gen u64, handled u64, held_key string) (diaghold.View, u64) {
	app.mu.lock()
	mut command := diaghold.Release.keep
	mut now := handled
	if app.diag_cmds.pending(gen, handled) {
		command = app.diag_cmds.releases(handled, held_key)
		now = app.diag_cmds.seq
	}
	v := diaghold.View{
		held_key:     held_key
		selected_key: app.diag_view_key
		panel_open:   app.diag_view_open
		run_live:     app.running && app.run_gen == gen
		command:      command
		tool_running: app.diag_tools > 0
	}
	app.mu.unlock()
	return v, now
}

// diag_set_status writes the strip, only while this holder is the run's: a holder still finishing
// after Stop must not describe the next run's connection.
fn (mut app App) diag_set_status(gen u64, s DiagHoldStatus) {
	app.mu.lock()
	if app.diag_hold_gen == gen {
		app.diag_status = s
	}
	app.mu.unlock()
	vgui.wake()
}

fn (mut app App) diag_status_copy() DiagHoldStatus {
	app.mu.lock()
	s := app.diag_status
	app.mu.unlock()
	return s
}

// diag_let_go lets the connection go for the holder's own reasons (a release, the keep-alive, the
// idle service) and says so; a request's let-go says it through diag_push_for(req, diag_drop(…)).
fn (mut app App) diag_let_go(gen u64, mut h HeldConn, conn diaghold.Conn, why string) {
	line := app.diag_drop(gen, mut h, conn, why)
	if line != '' {
		app.diag_push(line)
	}
}

// diag_drop closes the connection and updates the strip; the line to say about it, '' for none.
fn (mut app App) diag_drop(gen u64, mut h HeldConn, conn diaghold.Conn, why string) string {
	if !h.open {
		return ''
	}
	if h.target.carrier.doip {
		h.ch.close()
	} else {
		app.diag_detach(mut h)
	}
	h.open = false
	mut s := app.diag_status_copy()
	s.conn = conn
	s.why = why
	app.diag_set_status(gen, s)
	return if conn == .closed { 'closed ${h.where}: ${why}' } else { '' }
}

// diag_attach opens a CAN target's ISO-TP channel on a tap, held with the connection until it is
// let go: diag_open's CAN half. The client is new; the P2* the target announced before is
// loosened into it.
fn (mut app App) diag_attach(gen u64, mut h HeldConn) ! {
	t := h.target
	// the physical interface resolved under the lock: bitrate_iface walks app.chans
	app.mu.lock()
	iface := if t.iface != '' { t.iface } else { app.diag_iface() }
	phys := app.bitrate_iface(iface)
	app.mu.unlock()
	if iface == '' {
		return error('no running CAN channel')
	}
	// on its own thread, so the token ends a slow open (a CANsub open, or waiting on the wire's
	// first opener) as it ends every other wait; an open that lands after that is closed
	//
	// `ap := app` is THIS App by reference; `&app` would be a copy (scripts/check_mut_refs.sh)
	ap := app
	bus := transport.open_stoppable(fn [ap, iface, phys, t, gen] () !transport.Bus {
		return ap.open_tap_phys(iface, phys, org_tx, t.chan, gen, false)
	}, h.stop)!
	mut sc := isotp.on_bus(bus, phys, t.rx, t.tx, t.ext) or {
		mut b := bus
		b.close()
		return err
	}
	// a send or a wait in flight when the run ends is abandoned rather than finished (#347)
	sc.stop_requested = h.stop
	h.ch = isotp.Channel(sc)
	h.sc = sc
	h.cli = uds.new_client(sc)
	h.cli.stop_requested = h.stop
	h.cli.loosen_p2_star(h.p2_star_ms)
	h.where = 'ISO-TP on ${iface} (0x${t.rx:X}/0x${t.tx:X})'
	h.attached = true
}

// diag_detach closes a CAN connection's channel and its tap.
fn (mut app App) diag_detach(mut h HeldConn) {
	if h.target.carrier.doip || !h.attached {
		return
	}
	h.ch.close()
	h.sc = unsafe { nil }
	h.attached = false
}

// diag_open opens the connection a target needs into `h`, timed: a DoIP open as its connect and
// its routing activation; a CAN target's first channel as its total.
fn (mut app App) diag_open(gen u64, mut h HeldConn, t DiagTarget) !diaghold.Open {
	t0 := time.sys_mono_now()
	h = HeldConn{
		target: t
		stop: h.stop
	}
	app.mu.lock()
	h.p2_star_ms = app.diag_timing[t.key] or { 0 }
	app.mu.unlock()
	if t.carrier.doip {
		mut c := doip.open_doip_stoppable(t.carrier.host, t.carrier.port, t.carrier.tester,
			t.carrier.ecu, h.stop)!
		total := i64(time.sys_mono_now() - t0) / 1000
		h.ch = isotp.Channel(c)
		h.dc = c
		h.cli = uds.new_client(c)
		h.cli.stop_requested = h.stop
		h.cli.loosen_p2_star(h.p2_star_ms)
		h.where = 'doip ${c.iface}'
		h.open = true
		return diaghold.Open{
			doip: true
			total_us: total
			connect_us: c.connect_us
			activate_us: c.activate_us
		}
	}
	app.diag_attach(gen, mut h)!
	h.open = true
	return diaghold.Open{
		total_us: i64(time.sys_mono_now() - t0) / 1000
	}
}

// diag_target resolves a press's key against the current list. By the identity captured at click
// time: the combo stays live while a request is in flight, so reading the live selection here
// could address whichever ECU was selected after the click.
fn (app &App) diag_target(key string) ?DiagTarget {
	targets := app.diag_targets()
	for cand in targets {
		if cand.key == key {
			return cand
		}
	}
	if key == '' && targets.len > 0 {
		return targets[0]
	}
	return none
}

// diag_serve answers one press on the held connection, opening it first when it is not open.
fn (mut app App) diag_serve(gen u64, mut h HeldConn, req DiagReq) {
	defer {
		app.diag_done()
	}
	// a press taken just as Stop lands is not sent: the entity may be going away under it
	if !app.run_live(gen) {
		app.diag_push_for(req, '${req.kind}: not sent — the measurement stopped')
		return
	}
	app.mu.lock()
	refused := diaghold.press_refusal(true, false, app.diag_tools)
	app.mu.unlock()
	if refused != '' {
		app.diag_push_for(req, '${req.kind}: ${refused}')
		return
	}
	t := app.diag_target(req.key) or {
		app.diag_push_for(req, 'target "${req.key}" is no longer available')
		return
	}
	if h.open && h.target.key != t.key {
		app.diag_push_for(req, app.diag_drop(gen, mut h, .closed, diaghold.Release.deselected.words()))
	}
	held_before := h.open
	if !h.open {
		if !app.diag_connect(gen, mut h, t, req) {
			return
		}
	}
	mut out := DiagOut{}
	mut negative := false
	out, negative = app.diag_request(gen, mut h, req)
	// (a press its token cancelled is not a stale connection: it is not repeated)
	if out.err && !h.stop()
		&& diaghold.retry_on_reopen(t.carrier.doip, held_before, h.press_sent, negative) {
		// the entity had closed the idle connection: the request never went out, so it is asked
		// once more on a fresh one
		app.diag_push_for(req, '[not sent] ${out.line} — reopening')
		app.diag_push_for(req, app.diag_drop(gen, mut h, .closed, 'found closed before the request went out'))
		if !app.diag_connect(gen, mut h, t, req) {
			return
		}
		out, negative = app.diag_request(gen, mut h, req)
	}
	timing := if out.timed { out.t } else { h.timing() }
	if out.line != '' { // a multi-request press said its earlier lines itself
		app.diag_push_for(req, '${timing.prefix()} ${out.line}')
	}
	// a press its token cancelled is let go by the holder's next look, with the command's reason
	if out.err && !negative && !h.stop() {
		app.diag_push_for(req, app.diag_drop(gen, mut h, .failed, out.line))
	}
	// what this target announced, kept for a later connection BEFORE this press is done: the next
	// may start the moment diag_busy clears — and not into a project loaded meanwhile
	app.mu.lock()
	if diaghold.view_writable(req.epoch, app.diag_epoch) {
		app.diag_timing[t.key] = h.cli.p2_star_ms
	}
	app.mu.unlock()
}

// diag_connect opens the target's connection into `h` and says so in the log and the strip.
// Its lines are the request's (`req`) that made it open.
fn (mut app App) diag_connect(gen u64, mut h HeldConn, t DiagTarget, req DiagReq) bool {
	app.diag_set_status(gen, DiagHoldStatus{
		key: t.key
		label: t.label
		doip: t.carrier.doip
		conn: .opening
		p2_ms: -1
	})
	t0 := time.sys_mono_now()
	opened := app.diag_open(gen, mut h, t) or {
		if h.open {
			app.diag_push_for(req, app.diag_drop(gen, mut h, .failed, err.msg()))
		}
		ms := diaghold.ms_text(i64(time.sys_mono_now() - t0) / 1000)
		where := if t.carrier.doip { 'doip ${t.carrier.host}:${t.carrier.port}' } else { t.iface }
		// an open the token ended did not fail: it was abandoned, and nothing is held for the
		// holder's next look to let go with the command's reason
		cancelled := h.stop()
		why := if cancelled { 'opening abandoned' } else { err.msg() }
		app.diag_push_for(req, '[${ms:6} ms] open ${where}: ${why}')
		app.diag_set_status(gen, DiagHoldStatus{
			key: t.key
			label: t.label
			doip: t.carrier.doip
			conn: if cancelled { diaghold.Conn.closed } else { diaghold.Conn.failed }
			why: why
			p2_ms: -1
		})
		return false
	}
	app.diag_push_for(req, opened.line(h.where))
	app.diag_set_status(gen, DiagHoldStatus{
		key: t.key
		label: t.label
		doip: t.carrier.doip
		conn: .held
		p2_ms: -1
	})
	return true
}

struct DiagOut {
	line  string // '' = nothing more to say
	err   bool
	timed bool // `t` is the line's timing, not the last exchange's (a press of several requests)
	t     diaghold.Timing
}

// diag_request sends one press's request on the held connection; the second value is whether
// an error was a negative response (the ECU answering, which keeps the connection).
fn (mut app App) diag_request(gen u64, mut h HeldConn, req DiagReq) (DiagOut, bool) {
	h.cli.last = uds.ExchangeTiming{}
	h.press_sent = 0
	// counted on the connection's client (diag_serve opened the connection: on CAN, its channel)
	base := h.cli.sent_count
	defer {
		h.press_sent = int(h.cli.sent_count - base)
		h.last_ms = time.ticks()
	}
	match req.kind {
		'session' {
			return app.diag_session_change(gen, mut h, 0x03)
		}
		'dtcs', 'dtc_detail', 'dtc_clear', 'dtc_setting' {
			return app.diag_dtc_request(gen, mut h, req)
		}
		'did_read', 'did_read_all', 'did_write' {
			return app.diag_did_request(gen, mut h, req)
		}
		'vin' {
			r := h.cli.read_data_by_identifier(0xF190) or {
				return DiagOut{line: 'VIN: ${err}', err: true}, err is uds.NegativeResponse
			}
			return DiagOut{line: 'VIN = ${r.bytestr()}', err: false}, false
		}
		'tp' {
			h.cli.tester_present() or {
				return DiagOut{line: 'tester present: ${err}', err: true}, err is uds.NegativeResponse
			}
			return DiagOut{line: 'tester present OK', err: false}, false
		}
		else {
			r := h.cli.read_data_by_identifier(req.did) or {
				return DiagOut{line: 'DID ${req.did:04X}: ${err}', err: true}, err is uds.NegativeResponse
			}
			return DiagOut{line: 'DID ${req.did:04X} = ${hex(r)}  "${printable(r)}"', err: false}, false
		}
	}
}

// diag_session_change sends 0x10 `session` on the held connection and records what the answer
// established, on the connection and on the strip.
fn (mut app App) diag_session_change(gen u64, mut h HeldConn, session u8) (DiagOut, bool) {
	resp := h.cli.raw([u8(0x10), session]) or {
		return DiagOut{
			line: 'session 0x${session:02X}: ${err}'
			err:  true
		}, err is uds.NegativeResponse
	}
	h.session = if resp.len > 1 { resp[1] } else { u8(0) }
	h.security = 0 // ISO 14229-1: a session transition locks the server again
	mut s := app.diag_status_copy()
	s.session = h.session
	s.security = 0
	if h.session == diaghold.default_session {
		s.dtc_off = false // ISO 14229-1: entering the default session turns DTC setting back on
	}
	mut timing := ''
	if st := uds.session_timing(resp) {
		s.p2_ms = st.p2_ms
		s.p2_star_ms = st.p2_star_ms
		timing = ' · P2 ${st.p2_ms} ms, P2* ${st.p2_star_ms} ms'
	}
	app.diag_set_status(gen, s)
	return DiagOut{
		line: 'session 0x${h.session:02X} (${diaghold.session_name(h.session)}) OK${timing}'
	}, false
}

// diag_idle serves the held connection between presses, once per holder look.
//
// DoIP (well inside an entity's 500 ms alive check timeout): an Alive Check Request is answered
// there (doip.DoipClient.idle), since an entity that asks and hears nothing closes the connection
// and the session with it; an entity that closed it anyway is let go now, said, rather than found
// at the next press.
//
// CAN: what arrived on the held tap since the last look is read away (isotp.SoftChannel.
// drain_idle), so on a shared-hub wire (PCAN, CANsub) its cursor never falls behind the ring —
// a tap nobody reads is booked as the WIRE's loss. At a look per 50 ms the ring's 4096 frames
// are about four times what a 1 Mbit/s wire saturated with empty classic frames (~20k/s) carries
// meanwhile; the next request's pre-send drain would discard the same frames. A bus that fails
// here is let go, said.
fn (mut app App) diag_idle(gen u64, mut h HeldConn) {
	if !h.target.carrier.doip {
		if isnil(h.sc) {
			return
		}
		h.sc.drain_idle(diag_idle_drain_max) or {
			app.diag_push('${h.where}: ${err.msg()} (while idle)')
			app.diag_let_go(gen, mut h, .failed, '${err.msg()} (while idle)')
		}
		return
	}
	h.dc.idle() or {
		if h.stop() {
			return // cancelled: the holder's next look lets go, with the command's reason
		}
		app.diag_let_go(gen, mut h, .closed, '${err.msg()} (while idle)')
	}
}

// diag_keepalive sends tester-present with the positive response suppressed (3E 80), on the
// holder's thread, so it never lands inside a press's exchange. BOUNDED: its first-answer wait
// and its pending budget are both `keepalive_wait_ms`, so a server answering 0x78 cannot hold the
// holder — and every press queued behind it — for the client's two-minute budget; a 0x78 is the
// keep-alive failing (diaghold.keepalive_verdict), said on the strip. Not logged when it succeeds
// — one line every two seconds would bury the presses — but counted on the strip.
fn (mut app App) diag_keepalive(gen u64, mut h HeldConn) {
	saved_wait, saved_budget := h.cli.timeout_ms, h.cli.pending_budget_ms
	h.cli.timeout_ms = diaghold.keepalive_wait_ms
	h.cli.pending_budget_ms = diaghold.keepalive_wait_ms
	mut errored := false
	mut negative := false
	mut expired := false
	mut why := ''
	h.cli.raw_suppressed([u8(0x3E), 0x00]) or {
		errored = true
		negative = err is uds.NegativeResponse
		expired = err is uds.PendingExpired
		why = err.msg()
	}
	h.cli.timeout_ms = saved_wait
	h.cli.pending_budget_ms = saved_budget
	h.last_ms = time.ticks()
	if errored && h.stop() {
		return // cancelled: the holder's next look lets go, with the command's reason
	}
	match diaghold.keepalive_verdict(errored, negative, expired) {
		.ok {
			mut s := app.diag_status_copy()
			s.keepalives++
			app.diag_set_status(gen, s)
		}
		.refused {
			// the session is no longer ours to know, and asking every two seconds would only
			// repeat the refusal
			h.session = 0
			h.security = 0
			mut s := app.diag_status_copy()
			s.session = 0
			s.security = 0
			s.dtc_off = false // no longer ours to know either
			app.diag_set_status(gen, s)
			app.diag_push('keep-alive 3E 80 refused (${why}); stopped until the next session change')
		}
		.pending {
			app.diag_push('keep-alive 3E 80 answered 0x78 (responsePending): a keep-alive does not wait; let go')
			app.diag_let_go(gen, mut h, .failed, 'keep-alive answered 0x78 (responsePending)')
		}
		.failed {
			app.diag_push('keep-alive 3E 80: ${why}')
			app.diag_let_go(gen, mut h, .failed, 'keep-alive: ${why}')
		}
	}
}
