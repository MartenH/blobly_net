module main

import os
import time
import uds
import vgui
import sysview
import diaghold

// ---- The Diagnostics panel's DTC tab ----
//
// The fault memory of the selected target, read with 0x19 02 and shown as a table — code, the
// name its description gives, the status bits by ISO abbreviation, and the occurrence and aging
// counters 0x19 06 holds — with a selected row's snapshot (0x19 04) and extended data below it.
// Every request goes through the panel's held connection (diag_hold.v) and is timed in the log
// like a General-tab press. Names come from the blobly_emb node the target addresses
// (sysview: the target's diagnostic addressing picks the node, its ecu.toml names the DTCs and
// sizes the DIDs); with no description everything still works with raw codes.

// answered: an error that is the ECU answering — refused, or answered with what cannot be read —
// rather than the connection failing; the held connection is kept through it.
fn answered(err IError) bool {
	return err is uds.NegativeResponse || err is uds.UndecodableAnswer
}

// dtc_ext_max bounds the 0x19 06 reads one refresh makes for the table's counters: past it the
// columns stay empty, and a row's own extended data is still read when it is selected.
const dtc_ext_max = 16

// DtcRow is one DTC as the last read found it.
struct DtcRow {
	rec    uds.DtcRecord
	ext_ok bool // its 0x19 06 counters were read
	cnt    uds.BloblyCounters
}

// DtcDetail is the selected DTC's records.
struct DtcDetail {
	code     u32
	loaded   bool
	snap     uds.DtcSnapshot
	snap_ok  bool
	snap_err string
	ext      uds.DtcExtended
	ext_ok   bool
	ext_err  string
	// the DTC's status as its own answer gave it (0x19 06's, else 0x19 04's), and when
	status_ok bool
	status    u8
	at_ms     i64
}

// DtcView is the tab's last read, written by the holder under app.mu and only ever replaced
// whole, so a frame's copy of it is consistent.
struct DtcView {
	key      string // the target it was read from
	read     bool
	mask     u8
	avail    u8
	rows     []DtcRow
	sig      string // what the read found, for the auto-refresh's "changed?" (diaghold)
	err      string
	ext_note string // why some counters are missing (a server refusing 0x19 06, the connection)
	times    diaghold.ReadTimes // time.ticks() of the last read, and of the last attempt
	detail   DtcDetail
}

// DtcUi is the tab's controls. GUI thread only.
struct DtcUi {
mut:
	mask_sel   int // 0 = all, else dtc_status_bits[mask_sel - 1]
	auto       bool
	sel_code   u32
	has_sel    bool
	want_sel   bool   // a row was clicked while a press was out: ask for its records when free
	want_key   string // ... of the target it was clicked on (diaghold.deferred_selection)
	select_tab bool // the autopress hook brings the tab forward
	// the last list press this tab sent, and for which target: the auto-refresh counts its
	// interval from it as well as from the last read, so a press that fails before it reads
	// anything (a connect refused, a target gone) is not asked again every frame
	asked_key string
	asked_ms  i64
}

fn (u &DtcUi) mask() u8 {
	if u.mask_sel <= 0 || u.mask_sel > uds.dtc_status_bits.len {
		return 0xFF
	}
	return uds.dtc_status_bits[u.mask_sel - 1].mask
}

// ---- the description: which system, which node ----

// diag_sys_refresh keeps the DTC tab's system model current and publishes its nodes as targets on
// the channels named after their buses. GUI thread.
//
// ONE identity decides both (`diag_sys_key`): the model's sysview.System.identity — every file it
// was read from, system.toml and each ecu.toml, as it was read. The model is reloaded when the
// path to use changes (the System panel's system.toml when one is loaded there, else the one
// sysview.find_system finds) or any of those files has changed since, looked at every few seconds;
// the targets are rebuilt from the model every frame and republished when anything a target shows
// differs, the identity included — never by key alone, which survives a node renamed behind
// unchanged ids.
fn (mut app App) diag_sys_refresh() {
	now := time.ticks()
	if app.diag_sys_key == '' || now - app.diag_sys_checked_ms >= diag_sys_check_ms {
		app.diag_sys_checked_ms = now
		path := if app.sys_loaded {
			app.sys.path
		} else {
			sysview.find_system(app.proj_path, app.proj_db_refs()) or { '' }
		}
		mut want := 'none'
		if path != '' {
			want = if app.diag_sys_ok && app.diag_sys.path == path && app.diag_sys.current() {
				app.diag_sys_key
			} else {
				// to be (re)loaded; a system.toml that will not parse is tried again when it changes
				'load|${path}@${sysview.stamp(path).stamp}'
			}
		}
		if want != app.diag_sys_key {
			app.diag_sys_ok = false
			app.diag_sys = sysview.System{}
			app.diag_sys_key = want
			if path != '' {
				if sy := sysview.load(path) {
					app.diag_sys = sy
					app.diag_sys_ok = true
					app.diag_sys_key = sy.identity()
				} else {
					app.elog('Diagnostics: ${path} could not be read (${err}); DTCs are shown by code')
				}
			}
		}
	}
	// the CAN channels a target may be on, under the lock their flags are written under: an
	// enabled monitored row, whichever row of its wire holds the reader
	mut rows := []sysview.ChanRef{}
	app.mu.lock()
	for c in app.chans {
		if c.monitorable() {
			rows << sysview.ChanRef{c.name, c.iface}
		}
	}
	app.mu.unlock()
	mut targets := []DiagTarget{}
	if app.diag_sys_ok {
		for nt in app.diag_sys.can_targets(rows) {
			node := app.diag_sys.nodes[nt.node].name
			on := if nt.shared_name { '${nt.bus} (${nt.iface})' } else { nt.bus }
			targets << DiagTarget{
				key:   diag_key_can(nt.iface, nt.req, nt.rsp)
				label: '${node} on ${on}  (0x${nt.req:X}/0x${nt.rsp:X})'
				iface: nt.iface
				chan:  nt.bus
				rx:    nt.req
				tx:    nt.rsp
				ext:   nt.ext
			}
		}
	}
	fp := '${app.diag_sys_key}#' + targets.map('${it.key}|${it.label}|${it.chan}').join('#')
	if fp != app.diag_sys_print {
		app.diag_sys_print = fp
		app.mu.lock()
		app.diag_sys_targets = targets
		app.mu.unlock()
	}
}

// diag_sys_check_ms is how often the DTC tab looks for its system.toml again.
const diag_sys_check_ms = 3000

// proj_db_refs is every channel's database references as the project writes them — what
// sysview.find_system looks beside.
fn (app &App) proj_db_refs() []string {
	mut refs := []string{}
	for c in app.proj.channels {
		refs << c.databases
	}
	return refs
}

// DiagDesc is what the panel knows about a target: the node it addresses and that node's
// description, or why there is none.
struct DiagDesc {
	ok   bool
	node string
	desc sysview.EcuDesc
	why  string
}

fn (app &App) diag_desc(t DiagTarget) DiagDesc {
	if !app.diag_sys_ok {
		return DiagDesc{
			why: 'no system.toml beside the project or its databases (load one in the System panel)'
		}
	}
	// the channel decides between two nodes with one address, on either carrier
	addr := if t.carrier.doip {
		sysview.TargetAddr{
			doip:    true
			logical: t.carrier.ecu
			bus:     t.chan
		}
	} else {
		sysview.TargetAddr{
			req: t.rx
			rsp: t.tx
			bus: t.chan
		}
	}
	link := app.diag_sys.node_for(addr)
	if link.node < 0 {
		return DiagDesc{
			why: link.why
		}
	}
	n := app.diag_sys.nodes[link.node]
	if n.ecu_err != '' {
		return DiagDesc{
			node: n.name
			why:  '${n.name}: ${n.ecu} could not be read'
		}
	}
	return DiagDesc{
		ok:   true
		node: n.name
		desc: n.desc
	}
}

// ---- the holder's side (diag_hold.v's diag_request hands these over) ----

fn (h &HeldConn) timing() diaghold.Timing {
	return timing_of(h.cli.last)
}

fn timing_of(t uds.ExchangeTiming) diaghold.Timing {
	return diaghold.Timing{
		sent:       t.sent
		rtt_us:     t.rtt_us
		pending:    t.pending
		pending_us: t.pending_us
	}
}

// diag_dtc_request serves one DTC-tab press on the held connection. Like diag_request, the second
// value says an error was the ECU answering negatively, which keeps the connection.
fn (mut app App) diag_dtc_request(gen u64, mut h HeldConn, req DiagReq) (DiagOut, bool) {
	match req.kind {
		'dtc_detail' {
			return app.dtc_detail(mut h, req)
		}
		'dtc_clear' {
			h.cli.clear_dtc(0xFFFFFF) or {
				return DiagOut{
					line: '0x14 FFFFFF (clear all): ${err}'
					err:  true
				}, answered(err)
			}
			app.diag_say(req, '${h.timing().prefix()} 0x14 FFFFFF: every DTC cleared')
			// what was read before the clear no longer describes the ECU: gone NOW, so a refresh
			// that fails cannot leave pre-clear records on screen under its error
			app.mu.lock()
			if diaghold.view_writable(req.epoch, app.diag_epoch) && app.dtc_view.key == req.key {
				app.dtc_view = DtcView{
					key:   req.key
					times: app.dtc_view.times.failed(time.ticks())
				}
			}
			app.mu.unlock()
			return app.dtc_read(mut h, DiagReq{
				...req
				kind: 'dtcs'
			})
		}
		'dtc_setting' {
			s := diaghold.dtc_setting_session(h.session, req.on)
			if s != 0 {
				out, negative := app.diag_session_change(gen, mut h, s)
				if out.err {
					return out, negative
				}
				app.diag_say(req, '${h.timing().prefix()} ${out.line} (0x85 is served outside the default session)')
			}
			sub := if req.on { u8(0x01) } else { u8(0x02) }
			h.cli.control_dtc_setting(req.on) or {
				return DiagOut{
					line: '0x85 ${sub:02X}: ${err}'
					err:  true
				}, answered(err)
			}
			mut st := app.diag_status_copy()
			st.dtc_off = !req.on
			app.diag_set_status(gen, st)
			return DiagOut{
				line: '0x85 ${sub:02X}: DTC setting ${if req.on { 'on' } else { 'off — the ECU records no faults' }}'
			}, false
		}
		else {
			return app.dtc_read(mut h, req)
		}
	}
}

// dtc_read reads the list (0x19 02) and each listed DTC's counters (0x19 06, up to dtc_ext_max),
// and publishes them to the tab. A list read is published even when a counter read then fails.
fn (mut app App) dtc_read(mut h HeldConn, req DiagReq) (DiagOut, bool) {
	what := '0x19 02 ${req.mask:02X}'
	rep := h.cli.dtcs(req.mask) or {
		app.dtc_failed(req, err.msg())
		return DiagOut{
			line: '${what}: ${err}'
			err:  true
		}, answered(err)
	}
	t02 := h.timing()
	mut rows := rep.records.map(DtcRow{
		rec: it
	})
	mut batch := diaghold.CounterBatch{}
	for i in 0 .. imin(rows.len, dtc_ext_max) {
		if !batch.going() {
			break
		}
		ext := h.cli.extended(rows[i].rec.code, 0xFF) or {
			if err is uds.NegativeResponse {
				// 0x31 is this DTC having none; any other refusal is the service's, for every DTC
				batch.refusal(h.timing(), '0x19 06 ${rows[i].rec.name()}: ${err.msg()}',
					diaghold.nrc_per_dtc(err.nrc))
			} else if err is uds.UndecodableAnswer {
				batch.refusal(h.timing(), '0x19 06 ${rows[i].rec.name()}: ${err.msg()}',
					true)
			} else {
				batch.failure(h.timing(), '0x19 06 ${rows[i].rec.name()} FF: ${err}')
			}
			continue
		}
		batch.answered(h.timing())
		rows[i] = DtcRow{
			// its status as this answer gives it: read after the list's
			rec:    if ext.dtc.code == rows[i].rec.code { ext.dtc } else { rows[i].rec }
			ext_ok: true
			cnt:    ext.blobly_counters()
		}
	}
	failed := batch.failed
	ext_note := batch.summary()
	sig := rows.map(diaghold.dtc_sig_entry(it.rec.code, it.rec.status, if it.ext_ok {
		it.cnt.shown()
	} else {
		''
	})).join(' ')
	app.mu.lock()
	if !diaghold.view_writable(req.epoch, app.diag_epoch) {
		// asked under the project before this one: nothing of it is shown or said, but a
		// connection that failed is still let go
		app.mu.unlock()
		return DiagOut{
			line: failed
			err:  failed != ''
		}, false
	}
	prev := if app.dtc_view.key == req.key && app.dtc_view.read && app.dtc_view.err == '' {
		app.dtc_view.sig
	} else {
		'\x00' // nothing read from this target yet: any first read is news
	}
	// the selected DTC's records stay while it is still listed
	keep := app.dtc_view.key == req.key && rows.any(it.rec.code == app.dtc_view.detail.code)
	app.dtc_view = DtcView{
		key:      req.key
		read:     true
		mask:     req.mask
		avail:    rep.availability
		rows:     rows
		sig:      sig
		ext_note: ext_note
		times:    diaghold.read_at(time.ticks())
		detail:   if keep { app.dtc_view.detail } else { DtcDetail{} }
	}
	app.mu.unlock()
	vgui.wake()
	if !diaghold.autorefresh_logged(req.auto, failed != '', prev, sig) {
		return DiagOut{}, false
	}
	confirmed := rows.filter(it.rec.has(uds.dtc_confirmed)).len
	auto := if req.auto { ' (auto-refresh: changed)' } else { '' }
	app.diag_say(req, '${t02.prefix()} ${what}: ${rows.len} DTC(s), ${confirmed} confirmed${auto}')
	if failed != '' {
		// the connection failed under the counters: said, and let go like any failed press
		return DiagOut{
			line: failed
			err:  true
		}, false
	}
	if batch.asked() == 0 {
		return DiagOut{}, false
	}
	note := if ext_note != '' { ' — ${ext_note}' } else { '' }
	return DiagOut{
		line:  '0x19 06 FF ×${batch.asked()}: occurrence / aging counters${note}'
		timed: true
		t:     batch.t
	}, false
}

// dtc_failed records a read that failed, so the tab says so and the auto-refresh waits its
// interval before asking again.
fn (mut app App) dtc_failed(req DiagReq, why string) {
	app.mu.lock()
	if !diaghold.view_writable(req.epoch, app.diag_epoch) {
		// asked of the project before this one
	} else if app.dtc_view.key == req.key {
		// the last good read stays, said to be the last good one, as old as it is
		app.dtc_view = DtcView{
			...app.dtc_view
			err:   why
			times: app.dtc_view.times.failed(time.ticks())
		}
	} else {
		// another target's read is never shown under this one's name
		app.dtc_view = DtcView{
			key:   req.key
			err:   why
			times: diaghold.ReadTimes{}.failed(time.ticks())
		}
	}
	app.mu.unlock()
	vgui.wake()
}

// dtc_detail reads one DTC's snapshot records (0x19 04, every record) and extended data
// (0x19 06, every record). Snapshot DIDs are sized from the description the press carried; one it
// does not size is read once with 0x22 to learn it (uds.Client.snapshot).
fn (mut app App) dtc_detail(mut h HeldConn, req DiagReq) (DiagOut, bool) {
	for id, n in req.did_lens {
		h.cli.set_did_size(id, n)
	}
	name := uds.dtc_name(req.code)
	mut snap := uds.DtcSnapshot{}
	mut snap_ok := false
	mut snap_err := ''
	if s, st := h.cli.snapshot_timed(req.code, 0xFF) {
		snap = s
		snap_ok = true
		dids := s.records.map(it.dids.len)
		mut n := 0
		for x in dids {
			n += x
		}
		// the 0x19 04 at its own time, and each DID it had to size by reading it, at theirs
		app.diag_say(req, '${timing_of(st.request).prefix()} 0x19 04 ${name} FF: ${s.records.len} snapshot record(s), ${n} DID(s)')
		for pr in st.probes {
			app.diag_say(req, '${timing_of(pr.timing).prefix()} 0x22 ${pr.did:04X}: sized a snapshot DID the description does not')
		}
	} else {
		// said and shown; the extended data is still asked for, and a connection that has gone
		// fails there and is let go as any failed press is
		snap_err = err.msg()
		app.diag_say(req, '${h.timing().prefix()} 0x19 04 ${name} FF: ${err}')
	}
	ext := h.cli.extended(req.code, 0xFF) or {
		app.dtc_set_detail(req, DtcDetail{
			code:      req.code
			loaded:    true
			snap:      snap
			snap_ok:   snap_ok
			snap_err:  snap_err
			ext_err:   err.msg()
			status_ok: snap_ok
			status:    snap.dtc.status
			at_ms:     time.ticks()
		})
		return DiagOut{
			line: '0x19 06 ${name} FF: ${err}'
			err:  true
		}, answered(err)
	}
	app.dtc_set_detail(req, DtcDetail{
		code:     req.code
		loaded:   true
		snap:     snap
		snap_ok:  snap_ok
		snap_err: snap_err
		ext:       ext
		ext_ok:    true
		status_ok: true
		status:    ext.dtc.status
		at_ms:     time.ticks()
	})
	return DiagOut{
		line: '0x19 06 ${name} FF: ${ext.records.len} extended data record(s)'
	}, false
}

fn (mut app App) dtc_set_detail(req DiagReq, d DtcDetail) {
	app.mu.lock()
	if diaghold.view_writable(req.epoch, app.diag_epoch) && app.dtc_view.key == req.key {
		app.dtc_view = DtcView{
			...app.dtc_view
			detail: d
		}
	}
	app.mu.unlock()
	vgui.wake()
}

// ---- the tab ----

// dtc_press sends a DTC-tab press for the selected target. `auto` presses are the auto-refresh's
// and say nothing when refused.
fn (mut app App) dtc_press(kind string, code u32, on bool, auto bool, desc DiagDesc) {
	mut lens := map[u16]int{}
	if desc.ok {
		lens = desc.desc.did_sizes()
	}
	if kind == 'dtcs' {
		app.dtc_ui.asked_key = app.diag_sel_key
		app.dtc_ui.asked_ms = time.ticks()
	}
	app.diag_send(DiagReq{
		kind:     kind
		mask:     app.dtc_ui.mask()
		code:     code
		on:       on
		auto:     auto
		did_lens: lens
	})
}

// dtc_select selects a row and asks for its records — now, or once the press in flight is done.
fn (mut app App) dtc_select(code u32, busy bool, desc DiagDesc) {
	app.dtc_ui.sel_code = code
	app.dtc_ui.has_sel = true
	if busy {
		app.dtc_ui.want_sel = true
		app.dtc_ui.want_key = app.diag_sel_key
		return
	}
	app.dtc_ui.want_sel = false
	app.dtc_press('dtc_detail', code, false, false, desc)
}

fn draw_dtc_tab(mut app App, t DiagTarget, busy bool, st DiagHoldStatus) {
	sc := app.prefs.ui_scale
	desc := app.diag_desc(t)
	app.mu.lock()
	v := app.dtc_view
	app.mu.unlock()
	mine := v.key == t.key
	// where the names come from
	if desc.ok {
		vgui.text_dim_wrapped('names: ${desc.node} in ${os.file_name(os.dir(app.diag_sys.path))}/${os.file_name(app.diag_sys.path)} — ${desc.desc.faults.len} fault(s), ${desc.desc.dids.len} DID(s)')
		if desc.desc.errs.len > 0 {
			// read only in part: what was left out is said, so an entry missing from the
			// description is not mistaken for one the ECU does not have
			vgui.text_colored(230, 180, 60, '${desc.desc.errs.len} entry(ies) of ${desc.node}/ecu.toml not read — hover')
			vgui.set_item_tooltip(desc.desc.errs.join('\n'))
		}
	} else {
		vgui.text_dim_wrapped('no description: ${desc.why}; DTCs are shown by code')
	}
	// controls
	if vgui.button('Refresh') && !busy {
		app.dtc_press('dtcs', 0, false, false, desc)
	}
	vgui.same_line()
	vgui.set_next_item_width(150 * sc)
	mut masks := ['all (0xFF)']
	masks << uds.dtc_status_bits.map('${it.abbrev()} ${it.name} (0x${it.mask:02X})')
	app.dtc_ui.mask_sel = vgui.combo('##mask', masks, app.dtc_ui.mask_sel)
	vgui.set_item_tooltip('Status mask: list the DTCs with any of these bits (0x19 02).')
	vgui.same_line()
	app.dtc_ui.auto = vgui.checkbox('auto', app.dtc_ui.auto)
	vgui.set_item_tooltip('Read the list again every ${diaghold.autorefresh_ms / 1000} s while this tab is shown. A read that finds what the last one found is not logged.')
	if vgui.button('Clear all…') && !busy {
		vgui.open_popup('Clear all DTCs?')
	}
	vgui.same_line()
	vgui.align_text_to_frame_padding()
	vgui.text('DTC setting')
	vgui.same_line()
	if vgui.button('off') && !busy {
		app.dtc_press('dtc_setting', 0, false, false, desc)
	}
	vgui.set_item_tooltip('0x85 02: the ECU stops recording faults. Served outside the default session, so the panel switches to the extended session (0x10 03) first when it is not in one.')
	vgui.same_line()
	if vgui.button('on') && !busy {
		app.dtc_press('dtc_setting', 0, true, false, desc)
	}
	vgui.set_item_tooltip('0x85 01: the ECU records faults again.')
	if st.conn == .held && st.dtc_off {
		vgui.same_line()
		vgui.text_colored(230, 180, 60, 'is OFF')
		vgui.set_item_tooltip('0x85 02 was answered on this connection: the ECU records no faults until 0x85 01, or until it returns to the default session.')
	}
	if busy {
		vgui.same_line()
		vgui.text_dim('busy…')
	}
	if vgui.begin_popup_modal('Clear all DTCs?') {
		vgui.text('Send 0x14 FFFFFF to ${t.label}?')
		vgui.text_dim('Every DTC is cleared, with its snapshot and extended data.')
		if busy {
			// a press is out (an auto-refresh, say): the clear waits for it rather than being
			// dropped with the dialog closed as if it had gone
			vgui.text_dim('waiting for the request in flight…')
		} else if vgui.button('Clear all') {
			app.dtc_press('dtc_clear', 0, false, false, desc)
			vgui.close_current_popup()
		}
		vgui.same_line()
		if vgui.button('Cancel') {
			vgui.close_current_popup()
		}
		vgui.end_popup()
	}
	// a row clicked while a press was out
	match diaghold.deferred_selection(app.dtc_ui.want_sel, busy, app.dtc_ui.want_key, t.key) {
		.send {
			app.dtc_select(app.dtc_ui.sel_code, false, desc)
		}
		.drop {
			app.dtc_ui.want_sel = false
			app.dtc_ui.has_sel = false
		}
		else {}
	}
	// the auto-refresh
	// (no wake needed: an idle GUI still draws a frame every half second)
	mut last := if mine { v.times.tried_ms } else { i64(0) }
	if app.dtc_ui.asked_key == t.key && app.dtc_ui.asked_ms > last {
		last = app.dtc_ui.asked_ms
	}
	if diaghold.autorefresh_due(app.dtc_ui.auto, true, busy, last, time.ticks()) {
		app.dtc_press('dtcs', 0, false, true, desc)
	}
	h := vgui.content_avail_h()
	vgui.child_wh('##dtcarea', 0, h * 0.7)
	if !mine || !v.read {
		if mine && v.err != '' {
			vgui.text_colored(235, 90, 80, 'read failed: ${v.err}')
		} else {
			vgui.text_dim('not read from this target yet — Refresh')
		}
	} else {
		age := (time.ticks() - v.times.read_ms) / 1000
		mut head := '${v.rows.len} DTC(s) with any of 0x${v.mask:02X} · read ${age} s ago · availability 0x${v.avail:02X}'
		if v.err != '' {
			head += ' · last refresh failed: ${v.err}'
		}
		vgui.text_dim_wrapped(head)
		vgui.set_item_tooltip('status: the set bits by ISO 14229-1 abbreviation, hover a cell for every bit by name\no/a/c: occurrences / aging / failed operation cycles, from 0x19 06')
		if v.ext_note != '' {
			vgui.text_dim_wrapped(v.ext_note)
		}
		draw_dtc_table(mut app, v, desc, busy)
		draw_dtc_detail(mut app, v, desc, busy)
	}
	vgui.child_end()
	vgui.separator_text('responses (newest last)')
	draw_copyable_log(mut app, '##diag', app.diag_cache)
}

fn draw_dtc_table(mut app App, v DtcView, desc DiagDesc, busy bool) {
	sc := app.prefs.ui_scale
	if v.rows.len == 0 {
		vgui.text_dim('none')
		return
	}
	if !vgui.table_begin_flat('##dtcs', 4) {
		return
	}
	vgui.table_setup_col('DTC', 72 * sc)
	vgui.table_setup_col('name', 0)
	vgui.table_setup_col('status', 0)
	vgui.table_setup_col('o/a/c', 44 * sc)
	vgui.table_headers()
	for r in v.rows {
		vgui.table_row()
		vgui.table_next_col()
		sel := app.dtc_ui.has_sel && app.dtc_ui.sel_code == r.rec.code
		if vgui.selectable_row('${r.rec.name()}##${r.rec.code}', sel) {
			app.dtc_select(r.rec.code, busy, desc)
		}
		if desc.ok {
			if f := desc.desc.fault(r.rec.code) {
				vgui.table_cell(f.name)
				freeze := f.freeze.map('0x${it:04X}').join(', ')
				vgui.set_item_tooltip('${f.name} — tested by ${f.source}\nconfirmed after ${f.confirm} failed cycle(s), aged out after ${f.aging} passing one(s) (0 = never)\nsnapshot: ${if freeze == '' { 'none' } else { freeze }}')
			} else {
				vgui.table_cell_dim('not in ${desc.node}')
			}
		} else {
			vgui.table_cell_dim('—')
		}
		vgui.table_next_col()
		draw_dtc_status(r.rec.status)
		if r.ext_ok {
			vgui.table_cell(r.cnt.shown())
		} else {
			vgui.table_cell_dim('—')
		}
	}
	vgui.table_end()
}

// dtc_headline_bits are the status bits a reader looks for first, in the order drawn ahead of
// the rest: confirmed, pending, failing now, and the warning lamp.
const dtc_headline_bits = [uds.dtc_confirmed, uds.dtc_pending, uds.dtc_test_failed,
	uds.dtc_warning_indicator]

// dtc_bits_in_reading_order is uds.dtc_status_bits with the headline bits first; the rest in the
// list's own order.
fn dtc_bits_in_reading_order() []uds.DtcBit {
	mut out := []uds.DtcBit{}
	for m in dtc_headline_bits {
		out << uds.dtc_status_bits.filter(it.mask == m)
	}
	out << uds.dtc_status_bits.filter(it.mask !in dtc_headline_bits)
	return out
}

// draw_dtc_status draws a status byte as its set bits' ISO abbreviations, the headline bits
// first — confirmed in red, pending in amber, failing now in orange — with every bit named in full
// on hover.
fn draw_dtc_status(status u8) {
	mut first := true
	for b in dtc_bits_in_reading_order() {
		if status & b.mask == 0 {
			continue
		}
		if !first {
			vgui.same_line()
		}
		first = false
		match b.mask {
			uds.dtc_confirmed { vgui.text_colored(235, 90, 80, b.abbrev()) }
			uds.dtc_pending { vgui.text_colored(230, 180, 60, b.abbrev()) }
			uds.dtc_test_failed { vgui.text_colored(235, 140, 80, b.abbrev()) }
			else { vgui.text(b.abbrev()) }
		}
	}
	if first {
		vgui.text_dim('none')
	}
	mut tip := ['status 0x${status:02X}']
	for b in uds.dtc_status_bits {
		tip << '${if status & b.mask != 0 { 'x' } else { ' ' }}  ${b.abbrev():-7} ${b.name}'
	}
	vgui.set_item_tooltip(tip.join('\n'))
}

fn draw_dtc_detail(mut app App, v DtcView, desc DiagDesc, busy bool) {
	if !app.dtc_ui.has_sel {
		vgui.text_dim('select a DTC for its snapshot and extended data')
		return
	}
	code := app.dtc_ui.sel_code
	rec := v.rows.filter(it.rec.code == code)[0] or {
		vgui.text_dim('${uds.dtc_name(code)} is not in this list')
		return
	}
	mut title := rec.rec.name()
	if desc.ok {
		if f := desc.desc.fault(code) {
			title += ' — ${f.name}'
			if f.source != '' {
				title += ' (${f.source})'
			}
		}
	}
	vgui.separator_text(title)
	d := v.detail
	if !d.loaded || d.code != code {
		// in flight, or asked and never answered (refused, or the connection failed — the log says)
		vgui.text_dim(if busy || app.dtc_ui.want_sel {
			'reading its records…'
		} else {
			'its records were not read — click the row to ask again'
		})
		return
	}
	vgui.separator_text('snapshot (0x19 04)')
	if !d.snap_ok {
		vgui.text_colored(235, 90, 80, d.snap_err)
	} else if d.snap.records.len == 0 {
		vgui.text_dim('none stored')
	} else {
		for r in d.snap.records {
			vgui.text_dim('record 0x${r.number:02X}')
			for x in r.dids {
				mut name := uds.standard_did_name(x.id)
				mut val := ''
				if desc.ok {
					name = desc.desc.did_name(x.id)
					val = desc.desc.decode_did(x.id, x.data)
				}
				label := if name != '' { '0x${x.id:04X} ${name}' } else { '0x${x.id:04X}' }
				shown := if val != '' { '${val}   (${hex(x.data)})' } else { '${hex(x.data)}  "${printable(x.data)}"' }
				vgui.text('  ${label} = ${shown}')
			}
		}
	}
	vgui.separator_text('extended data (0x19 06)')
	if !d.ext_ok {
		vgui.text_colored(235, 90, 80, d.ext_err)
	} else if d.ext.records.len == 0 {
		vgui.text_dim('none stored')
	} else {
		for r in d.ext.records {
			name := uds.blobly_ext_record_name(r.number)
			label := if name != '' { '0x${r.number:02X} ${name}' } else { '0x${r.number:02X}' }
			vgui.text('  ${label} = ${r.value()}   (${hex(r.data)})')
		}
	}
	// the newer of the list's status and the DTC's own answer's
	status, own := diaghold.shown_status(rec.rec.status, v.times.read_ms, d.status_ok, d.status,
		d.at_ms)
	from := if own { 'its own answer' } else { 'the list' }
	vgui.separator_text('status (from ${from})')
	// the bits set, by name; the clear ones in one line
	mut clear := []string{}
	for b in dtc_bits_in_reading_order() {
		if status & b.mask != 0 {
			vgui.text('[x] ${b.name}')
		} else {
			clear << b.abbrev()
		}
	}
	vgui.text_dim_wrapped('status 0x${status:02X}; clear: ${if clear.len > 0 { clear.join(' ') } else { 'none' }}')
}
