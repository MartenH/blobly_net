module main

import time
import uds
import vgui
import sysview
import diaghold

// ---- The Diagnostics panel's DIDs tab ----
//
// The selected target's data identifiers — the ones its description declares (sysview: each
// `[[did]]`, with its layout and its read and write gates) and the ISO identification DIDs every
// ECU may answer — read one at a time or all at once (0x22) on the held connection, each value
// decoded by the description's layout beside its bytes. A writable DID is written (0x2E) from an
// editor that encodes through the SAME layout (sysview.DidDesc.encode, the inverse of the decode),
// behind a confirmation that states what the write will do first: the session it switches to and
// the level it unlocks (diaghold.write_plan), or why the panel cannot. A node's R7 parameters
// (`[[param]]`, each coded through a DID) are listed by name with their default and, where the
// ECU exposes a status DID, whether each is coded.

// DidVal is one DID as its last read found it.
struct DidVal {
	ok      bool
	data    []u8
	err     string
	refused bool // the ECU answered without the value (a negative response, or unreadable)
	nrc     u8   // the negative response's code; 0 = none
	at_ms   i64
	t       diaghold.Timing
}

// did_val is a 0x22's outcome as the tab records it.
fn did_val(data []u8, err IError, t diaghold.Timing) DidVal {
	if err is none {
		return DidVal{
			ok:    true
			data:  data
			at_ms: time.ticks()
			t:     t
		}
	}
	return DidVal{
		err:     err.msg()
		refused: answered(err)
		nrc:     if err is uds.NegativeResponse { err.nrc } else { u8(0) }
		at_ms:   time.ticks()
		t:       t
	}
}

// DidView is what the tab's reads found, for one target. Written by the holder under app.mu and
// only ever replaced whole, its map included, so a frame's copy of it is consistent.
struct DidView {
	key   string
	ident string // the description it was read under: bytes are laid out by THAT one
	vals  map[u16]DidVal
}

// owns: the view is the target's under this description — a reload that changed it (a layout, a
// name) makes the bytes read before it something else's to decode.
fn (v DidView) owns(key string, ident string) bool {
	return v.key == key && v.ident == ident
}

// DidUi is the tab's controls. GUI thread only.
struct DidUi {
mut:
	select_tab bool // the autopress hook brings the tab forward
	free_buf   []u8 = mkbuf('F190', 16)
	// the write editor: which DID, on which target, and one buffer per part
	edit_id   u16
	edit_key  string
	edit_ident string // the description it was filled from
	edit_bufs [][]u8
	edit_open bool // asks the popup to open next frame
	// an autopress `did_write` presses the editor's Write without a click
	auto_write bool
	// leave out the DIDs the ECU refused (off: every described DID is a row, its Read with it)
	hide_refused bool
}

// ---- the holder's side (diag_request hands these over) ----

// diag_did_request serves one DIDs-tab press. The second value says an error was the ECU
// answering, which keeps the connection.
fn (mut app App) diag_did_request(gen u64, mut h HeldConn, req DiagReq) (DiagOut, bool) {
	match req.kind {
		'did_read_all' {
			return app.did_read_all(mut h, req)
		}
		'did_write' {
			return app.did_write(gen, mut h, req)
		}
		else {
			return app.did_read(mut h, req, req.did)
		}
	}
}

// did_read reads one DID and publishes it; its line is the press's.
fn (mut app App) did_read(mut h HeldConn, req DiagReq, id u16) (DiagOut, bool) {
	name := did_label(req.desc, id)
	r := h.cli.read_data_by_identifier(id) or {
		app.did_publish(req, id, did_val([], err, h.timing()))
		return DiagOut{
			line: '0x22 ${name}: ${err}'
			err:  true
		}, answered(err)
	}
	app.did_publish(req, id, did_val(r, none, h.timing()))
	return DiagOut{
		line: '0x22 ${name} = ${did_shown(req.desc, id, r)}'
	}, false
}

// did_read_all reads every listed DID in turn, publishing each as it is answered, and says the
// batch in ONE line (diaghold.DidBatch): each DID's own value and time is in the table.
fn (mut app App) did_read_all(mut h HeldConn, req DiagReq) (DiagOut, bool) {
	mut b := diaghold.DidBatch{}
	for id in req.dids {
		if !b.going() {
			break
		}
		r := h.cli.read_data_by_identifier(id) or {
			app.did_publish(req, id, did_val([], err, h.timing()))
			if err is uds.NegativeResponse {
				b.refusal(h.timing(), err.nrc)
			} else if answered(err) {
				b.refusal(h.timing(), 0)
			} else {
				b.failure(h.timing(), '0x22 ${did_label(req.desc, id)}: ${err}')
			}
			continue
		}
		b.answered(h.timing())
		app.did_publish(req, id, did_val(r, none, h.timing()))
	}
	return DiagOut{
		line:  b.summary(req.dids.len)
		err:   b.failed != ''
		timed: true
		t:     b.t
	}, false
}

// did_write writes one DID as the description gates it: the session it is written in and the
// level it needs established first (diaghold.write_plan, asked HERE, of what this connection has
// established, not of what the panel last showed), then 0x2E, then 0x22 of it and of anything the
// write changes (a parameter's status DID). Each step is its own timed line.
fn (mut app App) did_write(gen u64, mut h HeldConn, req DiagReq) (DiagOut, bool) {
	name := did_label(req.desc, req.did)
	plan := diaghold.write_plan(req.writable, h.session, req.sessions, req.level, h.security,
		req.ref_key)
	if plan.refusal != '' {
		// nothing sent: the connection is as it was
		return DiagOut{
			line: '0x2E ${name}: not written — ${plan.refusal}'
			err:  true
		}, true
	}
	if plan.session != 0 {
		out, negative := app.diag_session_change(gen, mut h, plan.session)
		if out.err {
			return out, negative
		}
		app.diag_say_for(req, '${out.line} (0x2E ${name} is written in it)', false)
	}
	if plan.unlock != 0 {
		sub := diaghold.seed_sub(plan.unlock)
		seed := h.cli.security_request_seed(sub) or {
			return DiagOut{
				line: '0x27 ${sub:02X} (request seed): ${err}'
				err:  true
			}, answered(err)
		}
		if seed.any(it != 0) {
			app.diag_say_for(req, '0x27 ${sub:02X}: seed ${hex(seed)}', false)
			h.cli.security_send_key(sub + 1, uds.security_key(seed)) or {
				return DiagOut{
					line: '0x27 ${sub + 1:02X} (reference key): ${err}'
					err:  true
				}, answered(err)
			}
			app.diag_say_for(req, '0x27 ${sub + 1:02X}: level ${plan.unlock} unlocked (reference key)',
				false)
		} else {
			// an all-zero seed: ISO 14229-1's "already unlocked", and no key is sent
			app.diag_say_for(req, '0x27 ${sub:02X}: seed ${hex(seed)} — level ${plan.unlock} already unlocked',
				false)
		}
		h.security = plan.unlock
		mut st := app.diag_status_copy()
		st.security = plan.unlock
		app.diag_set_status(gen, st)
	}
	// the last thing before the send: the description it was encoded by is still the loaded one
	app.mu.lock()
	stale := diaghold.write_still_current(req.ident, app.diag_sys_ident)
	app.mu.unlock()
	if stale != '' {
		return DiagOut{
			line: '0x2E ${name}: ${stale}'
			err:  true
		}, true // nothing sent: the connection is as it was
	}
	h.cli.write_data_by_identifier(req.did, req.data) or {
		mut line := '0x2E ${name} ← ${hex(req.data)}: ${err}'
		if err is uds.NegativeResponse {
			// the ECU left the session or relocked on its own: what that took back is forgotten,
			// so the next write plans it again
			match diaghold.write_refusal_forgets(err.nrc) {
				.session {
					app.diag_forget(gen, mut h, true)
					line += ' — the session is no longer known; the next write switches and unlocks again'
				}
				.security {
					app.diag_forget(gen, mut h, false)
					line += ' — the level relocked; the next write unlocks again'
				}
				.nothing {}
			}
		}
		return DiagOut{
			line: line
			err:  true
		}, answered(err)
	}
	app.diag_say_for(req, '0x2E ${name} ← ${hex(req.data)} (${did_shown(req.desc, req.did,
		req.data)}): written', false)
	for id in req.follow {
		out, negative := app.did_read(mut h, req, id)
		if out.err && !negative {
			return out, false // the connection failed under the read-back
		}
		app.diag_say_for(req, out.line, out.err)
	}
	return app.did_read(mut h, req, req.did)
}

// did_publish records one DID's read for the tab: only for the project it was asked under, and a
// read of another target starts that target's view.
fn (mut app App) did_publish(req DiagReq, id u16, v DidVal) {
	app.mu.lock()
	if diaghold.view_writable(req.epoch, app.diag_epoch) {
		// a NEW map each time, never written in place: a frame's copy of the view shares the old
		// one (V maps are references) and reads it outside the lock
		mut vals := if app.did_view.owns(req.key, req.ident) {
			app.did_view.vals.clone()
		} else {
			map[u16]DidVal{}
		}
		vals[id] = v
		app.did_view = DidView{
			key:   req.key
			ident: req.ident
			vals:  vals
		}
	}
	app.mu.unlock()
	vgui.wake()
}

// did_label is a DID as a line names it: its id and the description's (or ISO's) name.
fn did_label(d sysview.EcuDesc, id u16) string {
	name := d.did_name(id)
	return if name != '' { '${id:04X} ${name}' } else { '${id:04X}' }
}

// did_shown is a value as the tab and the log show it: through the description's layout where
// it has one, as text where every byte is printable, else its bytes.
fn did_shown(d sysview.EcuDesc, id u16, data []u8) string {
	v := d.decode_did(id, data)
	if v != '' {
		return v
	}
	if data.len > 0 && data.all(it >= 0x20 && it < 0x7F) {
		return '"${data.bytestr()}"'
	}
	return hex(data)
}

// ---- the tab ----

// did_press sends a DIDs-tab press for the selected target, the description's copy with it for
// naming and decoding the lines.
fn (mut app App) did_press(r DiagReq, desc DiagDesc) {
	app.diag_send(DiagReq{
		...r
		desc:  if desc.ok { desc.desc } else { sysview.EcuDesc{} }
		ident: desc.ident
	})
}

// did_rows: what the tab lists — the description's DIDs in its order, then the ISO identification
// DIDs it does not declare (every one without a description).
fn did_rows(desc DiagDesc) ([]sysview.DidDesc, []sysview.DidDesc) {
	d := if desc.ok { desc.desc } else { sysview.EcuDesc{} }
	return d.dids, d.iso_dids()
}

fn draw_did_tab(mut app App, t DiagTarget, busy bool, st DiagHoldStatus) {
	desc := app.diag_desc(t)
	app.mu.lock()
	if app.did_view.key == t.key && app.did_view.ident != desc.ident {
		// the description was reloaded and is another: what was read under the old one is not
		// laid out by this one, so it goes
		app.did_view = DidView{}
	}
	view := if app.did_view.owns(t.key, desc.ident) { app.did_view } else { DidView{} }
	app.mu.unlock()
	own, iso := did_rows(desc)
	if desc.ok {
		vgui.text_dim_wrapped('${desc.node}: ${own.len} DID(s) and ${desc.desc.params.len} parameter(s) in its ecu.toml, plus the ISO identification DIDs')
	} else {
		vgui.text_dim_wrapped('no description: ${desc.why}; the ISO identification DIDs and any DID by number')
	}
	if app.diag_button('Read all') && !busy {
		mut ids := own.map(it.id)
		ids << iso.map(it.id)
		app.did_press(DiagReq{
			kind: 'did_read_all'
			dids: ids
		}, desc)
	}
	vgui.set_item_tooltip('0x22 for every DID listed, in turn, on the held connection. One line in the log for the batch; each value and its time is in the table.')
	vgui.same_line()
	vgui.set_next_item_width(70 * app.prefs.ui_scale)
	vgui.input_text('##didfree', mut app.did_ui.free_buf)
	vgui.same_line()
	if app.diag_button('Read DID') && !busy {
		typed := vgui.buf_str(app.did_ui.free_buf)
		if id := diaghold.parse_did(typed) {
			app.did_press(DiagReq{
				kind: 'did_read'
				did:  id
			}, desc)
		} else {
			app.diag_push_refusal(t.key, t.label, 'Read DID: "${typed}" is not a DID (one to four hex digits)')
		}
	}
	vgui.set_item_tooltip('0x22 for any identifier, in hex.')
	vgui.same_line()
	app.did_ui.hide_refused = vgui.checkbox('hide refused', app.did_ui.hide_refused)
	vgui.set_item_tooltip('Leave out the DIDs this ECU answered with a negative response. Their Read stays useful after a session change, so they are listed by default.')
	if st.conn == .held && st.key == t.key && st.security != 0 {
		vgui.same_line()
		vgui.text_colored(230, 180, 60, 'level ${st.security} unlocked')
	}
	if busy {
		vgui.same_line()
		vgui.text_dim('busy…')
	}
	pane := app.diag_tab_area('##didarea')
	hide := app.did_ui.hide_refused
	// the parameters first: a name and a value is what coding is about; their DIDs are below too
	if desc.ok && desc.desc.params.len > 0 {
		vgui.separator_text('parameters')
		draw_param_table(mut app, view, desc, busy, st)
	}
	if own.len > 0 {
		vgui.separator_text('${desc.node}')
		draw_did_table(mut app, '##didown2', own, view, desc, busy, hide)
	}
	// a DID read by number that neither list has
	mut other := []sysview.DidDesc{}
	for id, _ in view.vals {
		if !own.any(it.id == id) && !iso.any(it.id == id) {
			other << sysview.DidDesc{
				id: id
			}
		}
	}
	other.sort(a.id < b.id)
	if other.len > 0 {
		vgui.separator_text('read by number')
		draw_did_table(mut app, '##didother2', other, view, desc, busy, hide)
	}
	// the ISO identification DIDs: every one a row, the ones this ECU refused dimmed with its
	// answer — a refusal in one session is not one in the next, and the row's Read asks again
	refused := iso.filter(fn [view] (x sysview.DidDesc) bool {
		v := view.vals[x.id] or { return false }
		return v.refused // the ECU's answer; a silence or a lost connection stays as it is
	}).len
	head := if refused > 0 { '${iso.len}, ${refused} refused' } else { '${iso.len}' }
	if vgui.tree_node_open('ISO identification (${head})##diso') {
		draw_did_table(mut app, '##didiso2', iso, view, desc, busy, hide)
		vgui.tree_pop()
	}
	app.diag_tab_divider('##did_split', pane)
	draw_did_editor(mut app, t, view, desc, busy, st)
	draw_diag_log(mut app, t)
}

fn draw_did_table(mut app App, id string, rows []sysview.DidDesc, view DidView, desc DiagDesc, busy bool, hide_refused bool) {
	shown := rows.filter(fn [view, hide_refused] (x sysview.DidDesc) bool {
		v := view.vals[x.id] or { return true }
		return !(hide_refused && v.refused)
	})
	if shown.len == 0 {
		vgui.text_dim('every one refused (hide refused is ticked)')
		return
	}
	if !vgui.table_begin_flat(id, 4) {
		return
	}
	d := if desc.ok { desc.desc } else { sysview.EcuDesc{} }
	// sized by every row the table may list, shown or hidden, so a tick or a read never moves it
	diag_col('DID', ['FFFF'])
	diag_col('name', rows.map(if it.name != '' { it.name } else { d.did_name(it.id) })) // hover for the gates
	diag_col('value', [])
	diag_button_col(['Read', 'Write…'])
	vgui.table_headers()
	for x in shown {
		vgui.table_row()
		v := view.vals[x.id] or { DidVal{} }
		read := x.id in view.vals
		// a DID the ECU refused is dimmed, its answer by name; its Read stays
		dim := read && v.refused
		name := if x.name != '' { x.name } else { d.did_name(x.id) }
		if dim {
			vgui.table_cell_dim('${x.id:04X}')
			vgui.table_cell_dim(if name != '' { name } else { '—' })
		} else {
			vgui.table_cell('${x.id:04X}')
			vgui.table_cell(if name != '' { name } else { '—' })
		}
		vgui.set_item_tooltip(did_gate_words(x))
		// the value as the layout reads it, its bytes beneath
		vgui.table_next_col()
		if read {
			age := (time.ticks() - v.at_ms) / 1000
			when := 'read ${age} s ago, ${v.t.prefix()}'
			if v.ok {
				vgui.text(did_shown(d, x.id, v.data))
				vgui.set_item_tooltip(when)
				vgui.text_dim(if v.data.len > 0 { hex(v.data) } else { '(empty)' })
			} else if v.refused {
				words := did_refusal(v)
				vgui.text_dim(words)
				vgui.set_item_tooltip('${words}\n${v.err}\n${when}') // whole where a narrow column cuts it
			} else {
				vgui.text_colored(235, 90, 80, did_err_short(v))
				vgui.set_item_tooltip('${v.err}\n${when}')
			}
		} else {
			vgui.text_dim('—')
		}
		vgui.table_next_col()
		if app.diag_small_button('Read##r${x.id:04X}${id}') && !busy {
			app.did_press(DiagReq{
				kind: 'did_read'
				did:  x.id
			}, desc)
		}
		if x.write_gate.declared { // beneath Read: the row is two lines high anyway
			if vgui.small_button('Write…##w${x.id:04X}${id}') {
				app.did_edit(x, view, desc)
			}
		}
	}
	vgui.table_end()
}

// did_refusal is a DID the ECU refused, as its row says it: the NRC by name (diaghold.refused_words).
fn did_refusal(v DidVal) string {
	if v.nrc == 0 {
		return did_err_short(v) // answered with what cannot be read: no code to name
	}
	return diaghold.refused_words(v.nrc, uds.nrc_name(v.nrc))
}

// did_err_short is a failed read as a table cell: its NRC, else the error, cut by characters.
fn did_err_short(v DidVal) string {
	if v.nrc != 0 {
		return 'NRC 0x${v.nrc:02X}'
	}
	r := v.err.runes()
	return if r.len > 40 { r[..40].string() + '…' } else { v.err }
}

// did_gate_words is a DID's gates, as the name cell's tooltip says them.
fn did_gate_words(x sysview.DidDesc) string {
	mut lines := []string{}
	if x.size >= 0 {
		lines << '${x.size} byte(s), ${x.kind}'
	}
	lines << 'read: ${if x.read != '' { x.read } else { 'open' }}'
	lines << 'write: ${if x.write != '' { x.write } else { 'not writable' }}'
	return lines.join('\n')
}

// draw_param_table lists the node's parameters by name: each field's value as its coding DID last
// read it, its default, and — when the ECU exposes a parameter status DID — whether it is coded.
fn draw_param_table(mut app App, view DidView, desc DiagDesc, busy bool, st DiagHoldStatus) {
	d := desc.desc
	status_did := d.param_status_did()
	cols := if status_did != none { 5 } else { 4 }
	if !vgui.table_begin_flat('##params2', cols) {
		return
	}
	diag_col('parameter', d.params.map(it.name))
	diag_col('value', [])
	diag_col('default', [])
	if status_did != none {
		diag_col('status', ['uncoded', 'reverted'])
	}
	diag_button_col(['Read', 'Code…'])
	vgui.table_headers()
	for i, p in d.params {
		vgui.table_row()
		vgui.table_cell(p.name)
		pd := d.param_did(p.name)
		coded_by := if x := pd { 'coded through DID ${x.id:04X}' } else { 'no DID codes it' }
		vgui.set_item_tooltip('${coded_by}\napplies: ${p.apply}' +
			p.ranges.keys().map('\n${it}: ${p.ranges[it].min}..${p.ranges[it].max}').join(''))
		// its value, from the coding DID
		mut shown := '—'
		if x := pd {
			if v := view.vals[x.id] {
				shown = if v.ok { did_shown(d, x.id, v.data) } else { did_err_short(v) }
			}
		}
		vgui.table_cell(shown)
		defaults := p.fields.filter(it.name in p.defaults).map(if p.fields.len == 1 {
			'${p.defaults[it.name]}'
		} else {
			'${it.name}=${p.defaults[it.name]}'
		})
		vgui.table_cell_dim(if defaults.len > 0 { defaults.join(' ') } else { '—' })
		if sd := status_did {
			mut word := '—'
			if v := view.vals[sd.id] {
				if v.ok && i < v.data.len {
					word = match v.data[i] {
						0 { 'default' }
						1 { 'coded' }
						2 { 'reverted' }
						else { '0x${v.data[i]:02X}' }
					}
				}
			}
			if word == 'coded' {
				vgui.table_next_col()
				vgui.text_colored(230, 180, 60, word)
			} else {
				vgui.table_cell(word)
			}
			vgui.set_item_tooltip('from DID ${sd.id:04X}: default = uncoded, coded = written by a tester, reverted = a stored value this firmware refused')
		}
		if x := pd {
			vgui.table_next_col()
			if app.diag_small_button('Read##pr${x.id:04X}') && !busy {
				mut ids := [x.id]
				if sd := status_did {
					ids << sd.id
				}
				app.did_press(DiagReq{
					kind: 'did_read_all'
					dids: ids
				}, desc)
			}
			if x.write_gate.declared {
				if vgui.small_button('Code…##pw${x.id:04X}') {
					app.did_edit(x, view, desc)
				}
			}
		} else {
			vgui.table_cell_dim('no DID')
		}
	}
	vgui.table_end()
}

// did_edit opens the write editor on `x`, filled with its last value where it was read, else the
// parameter's default, else empty.
fn (mut app App) did_edit(x sysview.DidDesc, view DidView, desc DiagDesc) {
	parts := x.parts()
	mut texts := []string{len: parts.len}
	mut filled := false
	if v := view.vals[x.id] {
		if v.ok {
			if ts := x.texts(v.data) {
				texts = ts.clone()
				filled = true
			}
		}
	}
	if !filled && x.kind == .param && desc.ok {
		if p := desc.desc.params.filter(it.name == x.name)[0] {
			for i, f in x.fields {
				if dv := p.defaults[f.name] {
					texts[i] = '${dv}'
				}
			}
		}
	}
	app.did_ui.edit_id = x.id
	app.did_ui.edit_key = app.diag_sel_key
	app.did_ui.edit_ident = desc.ident
	app.did_ui.edit_bufs = texts.map(mkbuf(it, did_edit_room(x, it)))
	app.did_ui.edit_open = true
}

// did_edit_room is an edit field's buffer for `text` (diaghold.edit_room): never one that cuts it.
fn did_edit_room(x sysview.DidDesc, text string) int {
	return diaghold.edit_room(x.size, text.len)
}

// did_write_req is the press the editor's Write sends — the bytes and the gate, the rest decided by
// the holder (diaghold.write_plan) — or why there is none.
fn did_write_req(x sysview.DidDesc, texts []string, desc DiagDesc) !DiagReq {
	// the CURRENT description's gate: absent is not writable (diaghold.write_plan says why)
	if !x.write_gate.declared {
		return error(diaghold.write_plan(false, 0, [], 0, 0, false).refusal)
	}
	data := x.encode(texts)!
	mut sessions := []u8{}
	for s in x.write_gate.sessions {
		sessions << sysview.session_id(s) or {
			return error('written in the "${s}" session, which the panel does not know')
		}
	}
	mut follow := []u16{}
	if x.kind == .param && desc.ok {
		if sd := desc.desc.param_status_did() {
			follow << sd.id
		}
	}
	return DiagReq{
		kind:     'did_write'
		did:      x.id
		data:     data
		sessions: sessions
		level:    u8(x.write_gate.level)
		ref_key:  desc.ok && desc.desc.security_key == 'reference'
		follow:   follow
		writable: true
	}
}

// draw_did_editor is the write dialog: one field per part with what it accepts, the bytes they
// encode to (or why they do not), what the write will do first, and Write behind it — the
// confirmation is this dialog, which states all of that before anything is sent.
fn draw_did_editor(mut app App, t DiagTarget, view DidView, desc DiagDesc, busy bool, st DiagHoldStatus) {
	title := 'Write DID'
	if app.did_ui.edit_open {
		vgui.open_popup(title)
		app.did_ui.edit_open = false
	}
	if !vgui.begin_popup_modal(title) {
		return
	}
	d := if desc.ok { desc.desc } else { sysview.EcuDesc{} }
	x := d.did(app.did_ui.edit_id) or {
		vgui.text_dim('DID ${app.did_ui.edit_id:04X} is not in the description any more')
		if vgui.button('Close') {
			vgui.close_current_popup()
		}
		vgui.end_popup()
		return
	}
	if app.did_ui.edit_key != t.key || app.did_ui.edit_ident != desc.ident {
		// the target moved under the dialog, or its description was reloaded: never written to
		// the one selected now, nor by a layout or gate the dialog was not filled from
		app.did_ui.auto_write = false
		vgui.text_dim(if app.did_ui.edit_key != t.key {
			'the target changed — nothing is written'
		} else {
			'${desc.node}\'s description changed since this opened — nothing is written; open it again'
		})
		if vgui.button('Close') {
			vgui.close_current_popup()
		}
		vgui.end_popup()
		return
	}
	vgui.text('${t.label}')
	vgui.text('DID ${x.id:04X} ${x.name}')
	if v := view.vals[x.id] {
		if v.ok {
			vgui.text_dim('now: ${did_shown(d, x.id, v.data)}   (${hex(v.data)})')
		}
	}
	parts := x.parts()
	if app.did_ui.edit_bufs.len != parts.len {
		app.did_ui.edit_bufs = parts.map(mkbuf('', did_edit_room(x, '')))
	}
	for i, p in parts {
		vgui.set_next_item_width(220 * app.prefs.ui_scale)
		vgui.input_text('${p.label}##e${i}', mut app.did_ui.edit_bufs[i])
		vgui.same_line()
		vgui.text_dim(p.hint)
	}
	texts := app.did_ui.edit_bufs.map(vgui.buf_str(it))
	mut ready := false
	mut why := ''
	mut req := DiagReq{}
	if r := did_write_req(x, texts, desc) {
		req = r
		vgui.text('bytes: ${hex(r.data)}')
		// what the connection has established, only if it is to THIS target: another target's
		// session says nothing about this one, and the holder opens a fresh connection for it
		mine := st.conn == .held && st.key == t.key
		plan := diaghold.write_plan(r.writable, if mine { st.session } else { u8(0) }, r.sessions, r.level,
			if mine { st.security } else { u8(0) }, r.ref_key)
		if plan.refusal != '' {
			why = plan.refusal
			vgui.text_colored(235, 90, 80, 'cannot write: ${plan.refusal}')
		} else {
			vgui.text_dim_wrapped('will ${plan.words()}')
			ready = true
		}
	} else {
		why = err.msg()
		vgui.text_colored(235, 90, 80, why)
	}
	if app.did_ui.auto_write && !ready && !busy {
		// the autopress hook's write, refused here: said, so its wait ends
		app.did_ui.auto_write = false
		app.diag_push_refusal(t.key, t.label, '0x2E ${x.id:04X}: not written (autopress) — ${why}')
		vgui.close_current_popup()
	}
	if busy {
		vgui.text_dim('waiting for the request in flight…')
	} else if ready && (app.diag_button('Write') || app.did_ui.auto_write) {
		app.did_ui.auto_write = false
		app.did_press(req, desc)
		vgui.close_current_popup()
	}
	vgui.same_line()
	if vgui.button('Cancel') {
		app.did_ui.auto_write = false
		vgui.close_current_popup()
	}
	vgui.end_popup()
}
