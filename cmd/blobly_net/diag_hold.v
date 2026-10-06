module main

import time
import isotp
import doip
import uds
import vgui
import diaghold

// ---- The Diagnostics panel's held connection ----
//
// ONE holder thread per run owns the panel's connection: it opens it on the first press, serves
// every later press on it one at a time, keeps a non-default session alive, and lets it go by
// the rules in ./diaghold (which also says what "held" means on each carrier, why the holder is a
// RUN worker, and how another tool gets the entity). Nothing but that thread touches the channel
// or the client; what the panel shows of it is DiagHoldStatus, written under app.mu.

// DiagReq is one press of a panel button, addressed by the target key captured at click time.
struct DiagReq {
	kind string // 'session' | 'vin' | 'tp' | 'did'
	did  u16
	key  string
}

// DiagHoldStatus is the strip at the top of the panel. Guarded by app.mu.
struct DiagHoldStatus {
mut:
	label      string // the target the connection is (or was) to
	doip       bool
	conn       diaghold.Conn
	why        string // failed: the error; closed: why it was let go
	session    u8 // what the last 0x10 answer on this connection established; 0 = none yet
	p2_ms      int // from that answer; -1 = none yet
	p2_star_ms int
	keepalives int // 3E 80 sent on this connection
}

// HeldConn is the holder thread's own: never shared (a held DoIP client is also published as
// App.diag_doip_live, for Stop to interrupt — see diag_interrupt_locked).
struct HeldConn {
mut:
	open     bool
	target   DiagTarget
	where    string // what was opened, for the log
	ch       isotp.Channel // DoIP: the held connection; CAN: the exchange's, while attached
	attached bool // CAN only: a channel is open for the exchange in progress
	cli      uds.Client
	session  u8
	last_ms  i64 // the last thing sent to the ECU (time.ticks), which is what S3 runs from
	// CAN: the client's timing, carried from one exchange's client to the next
	timeout_ms int
	p2_star_ms int
}

// diag_press is one press of a Diagnostics panel button: handed to this run's holder, spawned
// on the first press. Marked busy HERE, under the lock that publishes the request, so a second
// click cannot slip in before the holder has taken the first.
fn (mut app App) diag_press(kind string, did u16) {
	app.mu.lock()
	if !app.running || app.diag_busy {
		app.mu.unlock()
		return
	}
	if app.diag_hold_gen != app.run_gen {
		app.diag_q = chan DiagReq{ cap: 4 }
		app.diag_hold_gen = app.run_gen
		app.reserve_run_worker_locked() // released by the holder's own defer
		spawn diag_holder(app, app.run_gen, app.diag_q)
	}
	app.diag_busy = true
	app.diag_q.try_push(DiagReq{
		kind: kind
		did: did
		key: app.diag_sel_key
	})
	app.mu.unlock()
}

// diag_disconnect is the strip's Disconnect: the holder lets go at its next look.
fn (mut app App) diag_disconnect() {
	app.mu.lock()
	app.diag_disconnect_req = true
	app.mu.unlock()
}

// diag_interrupt_locked is Stop's part: a press blocked on a DoIP answer returns now rather than
// at its deadline, so the holder — a run worker — is gone before a rebuild has to wait for it.
// Under app.mu, which the holder takes to unpublish the client BEFORE closing it, so the socket
// this shuts down is still the holder's. A CAN press has no such handle and ends at its timeout.
fn (mut app App) diag_interrupt_locked() {
	if !isnil(app.diag_doip_live) {
		mut c := app.diag_doip_live
		c.interrupt()
	}
}

// diag_publish_view tells the holder what the panel shows: open or closed, which target. Called
// every frame from the GUI thread, it takes the lock only when something changed.
fn (mut app App) diag_publish_view() {
	if app.diag_pub_open == app.show_diag && app.diag_pub_key == app.diag_sel_key {
		return
	}
	app.diag_pub_open = app.show_diag
	app.diag_pub_key = app.diag_sel_key
	app.mu.lock()
	app.diag_view_open = app.show_diag
	app.diag_view_key = app.diag_sel_key
	app.mu.unlock()
}

// diag_tool_begin is called by an operator tool that speaks UDS (a script, a flash) as it starts:
// the panel holds nothing while one runs (./diaghold), and the tool waits here, bounded, for a
// held connection to close and for a press already queued to finish — a DoIP entity serves one
// tester, and would otherwise keep the tool waiting behind the panel until its idle timeout.
// Paired with diag_tool_end. Returns a note when the wait ran out, for the tool to show.
fn (mut app App) diag_tool_begin() string {
	app.mu.lock()
	app.diag_tools++
	app.mu.unlock()
	t0 := time.ticks()
	for {
		app.mu.lock()
		st := app.diag_status.conn
		live := app.diag_hold_gen != 0
		busy := app.diag_busy
		app.mu.unlock()
		if !live || (!busy && st != .held && st != .opening) {
			return ''
		}
		if time.ticks() - t0 > diag_tool_wait_ms {
			return 'the Diagnostics panel was still using its connection after ${diag_tool_wait_ms} ms; going ahead'
		}
		time.sleep(10 * time.millisecond)
	}
	return ''
}

fn (mut app App) diag_tool_end() {
	app.mu.lock()
	app.diag_tools--
	app.mu.unlock()
}

// diag_tool_wait_ms bounds how long a tool waits for the panel to let go: an idle connection
// closes within one holder look (50 ms); this covers a press in flight on a slow ECU.
const diag_tool_wait_ms = 3000

// diag_holder is the run's holder thread. A RUN WORKER: reserved by diag_press, ended by Stop,
// waited for by a rebuild (see ./diaghold for why that bucket).
fn diag_holder(app &App, gen u64, q chan DiagReq) {
	defer {
		release_run_worker(app)
	}
	mut a := unsafe { app }
	mut h := HeldConn{}
	for {
		v := a.diag_hold_view(gen, if h.open { h.target.key } else { '' })
		r := diaghold.release(v)
		if r != .keep {
			a.diag_let_go(gen, mut h, .closed, r.words())
		}
		if !v.run_live {
			break
		}
		if diaghold.keepalive_due(h.open, h.session, h.last_ms, time.ticks()) {
			a.diag_keepalive(gen, mut h)
		}
		select {
			req := <-q {
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
	a.mu.unlock()
	mut req := DiagReq{}
	for q.try_pop(mut req) == .success {
		a.diag_push('${req.kind}: not sent — the measurement stopped')
		a.diag_done()
	}
}

// diag_hold_view reads what the release rule needs, under one take of the lock. A Disconnect is
// CONSUMED by the look that sees it, so it lets go of the connection it was pressed for and not
// of the next one.
fn (mut app App) diag_hold_view(gen u64, held_key string) diaghold.View {
	app.mu.lock()
	v := diaghold.View{
		held_key: held_key
		selected_key: app.diag_view_key
		panel_open: app.diag_view_open
		run_live: app.running && app.run_gen == gen
		disconnect: app.diag_disconnect_req
		tool_running: app.diag_tools > 0
	}
	app.diag_disconnect_req = false
	app.mu.unlock()
	return v
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

fn (mut app App) diag_let_go(gen u64, mut h HeldConn, conn diaghold.Conn, why string) {
	if !h.open {
		return
	}
	if h.target.carrier.doip {
		// unpublished BEFORE the close, under the lock Stop interrupts under
		app.mu.lock()
		app.diag_doip_live = unsafe { nil }
		app.mu.unlock()
		h.ch.close()
	} else {
		app.diag_detach(mut h)
	}
	h.open = false
	mut s := app.diag_status_copy()
	s.conn = conn
	s.why = why
	app.diag_set_status(gen, s)
	if conn == .closed {
		app.diag_push('closed ${h.where}: ${why}')
	}
}

// diag_attach opens a CAN target's ISO-TP channel on a tap for one exchange (DoIP: nothing to do
// — the connection is held). The client is new; the timing the last one learned is carried in.
fn (mut app App) diag_attach(gen u64, mut h HeldConn) ! {
	if h.target.carrier.doip || h.attached {
		return
	}
	t := h.target
	// the physical interface resolved under the lock: bitrate_iface walks app.chans
	app.mu.lock()
	iface := if t.iface != '' { t.iface } else { app.diag_iface() }
	phys := app.bitrate_iface(iface)
	app.mu.unlock()
	if iface == '' {
		return error('no running CAN channel')
	}
	bus := app.open_tap_phys(iface, phys, org_tx, t.chan, gen, false)!
	mut sc := isotp.on_bus(bus, phys, t.rx, t.tx, t.ext) or {
		mut b := bus
		b.close()
		return err
	}
	// a segmented send in flight when the run ends is abandoned rather than finished (#347)
	sc.stop_requested = fn [app, gen] () bool {
		mut ap := unsafe { app }
		return !ap.run_live(gen)
	}
	h.ch = isotp.Channel(sc)
	h.cli = uds.new_client(sc)
	if h.timeout_ms > 0 {
		h.cli.timeout_ms = h.timeout_ms
	}
	h.cli.loosen_p2_star(h.p2_star_ms)
	h.where = 'ISO-TP on ${iface} (0x${t.rx:X}/0x${t.tx:X})'
	h.attached = true
}

// diag_detach closes a CAN exchange's channel, keeping what its client learned of the timing.
fn (mut app App) diag_detach(mut h HeldConn) {
	if h.target.carrier.doip || !h.attached {
		return
	}
	h.timeout_ms = h.cli.timeout_ms
	h.p2_star_ms = h.cli.p2_star_ms
	h.ch.close()
	h.attached = false
}

// diag_open opens the connection a target needs into `h`, timed: a DoIP open as its connect and
// its routing activation; a CAN target's first channel as its total.
fn (mut app App) diag_open(gen u64, mut h HeldConn, t DiagTarget) !diaghold.Open {
	t0 := time.sys_mono_now()
	h = HeldConn{
		target: t
	}
	app.mu.lock()
	h.p2_star_ms = app.diag_timing[t.key] or { 0 }
	app.mu.unlock()
	if t.carrier.doip {
		mut c := doip.open_doip(t.carrier.host, t.carrier.port, t.carrier.tester, t.carrier.ecu)!
		total := i64(time.sys_mono_now() - t0) / 1000
		h.ch = isotp.Channel(c)
		h.cli = uds.new_client(c)
		h.cli.loosen_p2_star(h.p2_star_ms)
		h.where = 'doip ${c.iface}'
		app.mu.lock()
		app.diag_doip_live = c
		live := app.running && app.run_gen == gen
		app.mu.unlock()
		h.open = true
		if !live {
			// Stop landed during the open: its interrupt could not reach a client not yet published
			return error('the measurement stopped')
		}
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
		app.diag_push('${req.kind}: not sent — the measurement stopped')
		return
	}
	app.mu.lock()
	epoch := app.diag_timing_epoch
	app.mu.unlock()
	t := app.diag_target(req.key) or {
		app.diag_push('target "${req.key}" is no longer available')
		return
	}
	if h.open && h.target.key != t.key {
		app.diag_let_go(gen, mut h, .closed, diaghold.Release.deselected.words())
	}
	held_before := h.open
	if !h.open {
		if !app.diag_connect(gen, mut h, t) {
			return
		}
	}
	mut out := DiagOut{}
	mut negative := false
	out, negative = app.diag_request(gen, mut h, req)
	if out.err && diaghold.retry_on_reopen(t.carrier.doip, held_before, h.cli.last.sent, negative) {
		// the entity had closed the idle connection: the request never went out, so it is asked
		// once more on a fresh one
		app.diag_push('[not sent] ${out.line} — reopening')
		app.diag_let_go(gen, mut h, .closed, 'found closed before the request went out')
		if !app.diag_connect(gen, mut h, t) {
			return
		}
		out, negative = app.diag_request(gen, mut h, req)
	}
	timing := diaghold.Timing{
		sent: h.cli.last.sent
		rtt_us: h.cli.last.rtt_us
		pending: h.cli.last.pending
		pending_us: h.cli.last.pending_us
	}
	app.diag_push('${timing.prefix()} ${out.line}')
	if out.err && !negative {
		app.diag_let_go(gen, mut h, .failed, out.line)
	}
	// what this target announced, kept for a later connection BEFORE this press is done: the next
	// may start the moment diag_busy clears — and not into a project loaded meanwhile
	app.mu.lock()
	if app.diag_timing_epoch == epoch {
		app.diag_timing[t.key] = h.cli.p2_star_ms
	}
	app.mu.unlock()
}

// diag_connect opens the target's connection into `h` and says so in the log and the strip.
fn (mut app App) diag_connect(gen u64, mut h HeldConn, t DiagTarget) bool {
	app.diag_set_status(gen, DiagHoldStatus{
		label: t.label
		doip: t.carrier.doip
		conn: .opening
		p2_ms: -1
	})
	t0 := time.sys_mono_now()
	opened := app.diag_open(gen, mut h, t) or {
		if h.open {
			app.diag_let_go(gen, mut h, .failed, err.msg())
		}
		ms := diaghold.ms_text(i64(time.sys_mono_now() - t0) / 1000)
		where := if t.carrier.doip { 'doip ${t.carrier.host}:${t.carrier.port}' } else { t.iface }
		app.diag_push('[${ms:6} ms] open ${where}: ${err}')
		app.diag_set_status(gen, DiagHoldStatus{
			label: t.label
			doip: t.carrier.doip
			conn: .failed
			why: err.msg()
			p2_ms: -1
		})
		return false
	}
	app.diag_push(opened.line(h.where))
	app.diag_set_status(gen, DiagHoldStatus{
		label: t.label
		doip: t.carrier.doip
		conn: .held
		p2_ms: -1
	})
	return true
}

struct DiagOut {
	line string
	err  bool
}

// diag_request sends one press's request on the held connection; the second value is whether
// an error was a negative response (the ECU answering, which keeps the connection).
fn (mut app App) diag_request(gen u64, mut h HeldConn, req DiagReq) (DiagOut, bool) {
	h.cli.last = uds.ExchangeTiming{}
	app.diag_attach(gen, mut h) or { return DiagOut{'${req.kind}: ${err}', true}, false }
	defer {
		app.diag_detach(mut h)
		h.last_ms = time.ticks()
	}
	match req.kind {
		'session' {
			resp := h.cli.raw([u8(0x10), 0x03]) or {
				return DiagOut{'session 0x03: ${err}', true}, err is uds.NegativeResponse
			}
			h.session = if resp.len > 1 { resp[1] } else { u8(0) }
			mut s := app.diag_status_copy()
			s.session = h.session
			mut timing := ''
			if st := uds.session_timing(resp) {
				s.p2_ms = st.p2_ms
				s.p2_star_ms = st.p2_star_ms
				timing = ' · P2 ${st.p2_ms} ms, P2* ${st.p2_star_ms} ms'
			}
			app.diag_set_status(gen, s)
			return DiagOut{'session 0x${h.session:02X} (${diaghold.session_name(h.session)}) OK${timing}', false}, false
		}
		'vin' {
			r := h.cli.read_data_by_identifier(0xF190) or {
				return DiagOut{'VIN: ${err}', true}, err is uds.NegativeResponse
			}
			return DiagOut{'VIN = ${r.bytestr()}', false}, false
		}
		'tp' {
			h.cli.tester_present() or {
				return DiagOut{'tester present: ${err}', true}, err is uds.NegativeResponse
			}
			return DiagOut{'tester present OK', false}, false
		}
		else {
			r := h.cli.read_data_by_identifier(req.did) or {
				return DiagOut{'DID ${req.did:04X}: ${err}', true}, err is uds.NegativeResponse
			}
			return DiagOut{'DID ${req.did:04X} = ${hex(r)}  "${printable(r)}"', false}, false
		}
	}
}

// diag_keepalive sends tester-present with the positive response suppressed (3E 80), on the
// holder's thread, so it never lands inside a press's exchange. Not logged when it succeeds —
// one line every two seconds would bury the presses — but counted on the strip.
fn (mut app App) diag_keepalive(gen u64, mut h HeldConn) {
	app.diag_attach(gen, mut h) or {
		h.last_ms = time.ticks()
		app.diag_push('keep-alive 3E 80: ${err}')
		app.diag_let_go(gen, mut h, .failed, 'keep-alive: ${err}')
		return
	}
	saved := h.cli.timeout_ms
	h.cli.timeout_ms = diaghold.keepalive_wait_ms
	_ := h.cli.raw_suppressed([u8(0x3E), 0x00]) or {
		h.cli.timeout_ms = saved
		app.diag_detach(mut h)
		h.last_ms = time.ticks()
		if err is uds.NegativeResponse {
			// the ECU refused it: the session is no longer ours to know, and asking every two
			// seconds would only repeat the refusal
			h.session = 0
			mut s := app.diag_status_copy()
			s.session = 0
			app.diag_set_status(gen, s)
			app.diag_push('keep-alive 3E 80 refused (${err}); stopped until the next session change')
			return
		}
		app.diag_push('keep-alive 3E 80: ${err}')
		app.diag_let_go(gen, mut h, .failed, 'keep-alive: ${err}')
		return
	}
	h.cli.timeout_ms = saved
	app.diag_detach(mut h)
	h.last_ms = time.ticks()
	mut s := app.diag_status_copy()
	s.keepalives++
	app.diag_set_status(gen, s)
}
