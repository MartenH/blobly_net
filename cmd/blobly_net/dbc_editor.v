module main

import os
import candb
import vgui

// ---- DBC Editor (docs/dbc_editor.md P1) -------------------------------------
// Edits the IN-MEMORY app.dbs — the same databases the Trace panel decodes
// against, so an edit re-decodes live traffic instantly. Save renders the
// canonical form (candb.to_dbc, fixpoint-tested) back to the loaded path;
// canonical order keeps the file git-diff-reviewable. All model mutations
// take app.mu briefly: decode runs on worker threads.
// NOTE: dbs_by_iface holds value copies (the generator picker) — it refreshes
// on save/reload, not per keystroke; the Trace union (app.dbs) is live.

struct DbcEd {
mut:
	db    int = -1 // dbs index
	msg   int = -1
	sig   int = -1
	dirty map[string]bool // unsaved edits keyed by dbc PATH (survives rebuilds/index shifts)
	// the messages box height, dragged via the horizontal splitter under it (the signals box
	// fills whatever remains). Same lifetime as left_w: survives frames, resets with DbcEd.
	msgs_h         f32
	loaded_key     string // which db:msg:sig the string buffers hold
	mname_buf      []u8
	sender_buf     []u8
	sname_buf      []u8
	unit_buf       []u8
	desc_buf       []u8
	msg_filter_buf []u8
	sig_filter_buf []u8
	val_key_buf    []u8
	val_name_buf   []u8
	node_buf       []u8
	view_tree      bool = true // toggle between Tree view and Table view
	left_w         f32 // draggable width (px) of the messages&signals pane; 0 = use the default
	// An in-progress bit-endpoint edit. An input field commits on EVERY keystroke, so a handler
	// that derives the width from the opposite endpoint would measure each keystroke against an
	// anchor the previous one already moved — typing a higher start collapsed the span to one
	// bit (#68). The edit is therefore held here and applied once, on deactivation, against the
	// anchor captured when it began.
	bit_edit_key    string // '<field>:<db>:<msg>:<sig>' while that field is being edited
	bit_edit_val    int    // the in-progress value (the field shows this, not the model)
	bit_edit_anchor int    // the opposite endpoint, snapshotted when the edit began
	bit_edit_db     int = -1 // where to apply it, kept apart from the key so resolve need not parse
	bit_edit_msg    int = -1
	bit_edit_sig    int = -1
	bit_edit_name   string // the signal's NAME at edit time — an index can be re-used after a
	// delete, and applying an edit to whatever now sits at that index would corrupt it
	bit_edit_msg_name string // and the MESSAGE's name: deleting a message shifts the next one
	// into the stored index, where a same-named signal (Counter, Status…) would pass a
	// name-only check and take the edit meant for a different message entirely
}

// resolve_pending_bit_edit applies a bit-endpoint edit still held in the editor's buffer.
//
// WHY A CHOKE POINT: deferring the commit to deactivation (so a per-keystroke commit cannot
// measure each digit against an anchor the previous one moved) opens a window where the FIELD
// holds the value and the model does not. Every action that reads or replaces app.dbs during
// that window would otherwise act on stale data — and the toolbar is drawn BEFORE the editor,
// so the very click that ends an edit is processed first: Start ran workers against the old
// schema, and Save serialised the old endpoint and only then committed, leaving the file dirty.
// Guarding each consumer separately is how that turned into a series of one-off patches; this
// is the single place the window is closed instead.
//
// Safe to call at any time: with no edit pending it does nothing.
fn (mut app App) resolve_pending_bit_edit() {
	if app.dbc_ed.bit_edit_key == '' {
		return
	}
	di := app.dbc_ed.bit_edit_db
	mi := app.dbc_ed.bit_edit_msg
	si := app.dbc_ed.bit_edit_sig
	is_start := app.dbc_ed.bit_edit_key.starts_with('start:')
	anchor := app.dbc_ed.bit_edit_anchor
	val := app.dbc_ed.bit_edit_val
	name := app.dbc_ed.bit_edit_name
	msg_name := app.dbc_ed.bit_edit_msg_name
	key := app.dbc_ed.bit_edit_key
	app.dbc_ed.bit_edit_key = '' // clear FIRST: every path below is now a no-op or an apply

	// Has the user moved on? The key names the signal the edit began on; if that is no longer
	// the selection, the edit was abandoned by clicking away and must not be committed.
	// This check belongs HERE and not at the top of the editor, because the toolbar is drawn
	// before the editor (main.v ~1322 vs ~1368): pressing Start after selecting a different
	// signal reached the resolver first, and the stored names/indices still matched the
	// original signal — which exists and is unchanged — so an abandoned edit was applied and
	// the DBC marked dirty, blocking the run. Every caller funnels through here, so one check
	// covers Start, Save, rebuild and deactivation alike.
	if !key.ends_with(':${app.dbc_ed.db}:${app.dbc_ed.msg}:${app.dbc_ed.sig}') {
		return
	}

	// `warn` is collected under the lock and emitted after it. notify() takes app.mu, which is
	// not recursive, so notifying from in here deadlocks the app on the value-table path —
	// reachable from deactivation, Save, Start and rebuild alike.
	mut warn := '' // refuses the edit outright
	mut note := '' // the edit is applied, but not exactly as typed
	mut dirty := -1
	app.mu.lock()
	ok := di >= 0 && di < app.dbs.len && mi >= 0 && mi < app.dbs[di].messages.len && si >= 0
		&& si < app.dbs[di].messages[mi].signals.len
	if ok && app.dbs[di].messages[mi].name == msg_name
		&& app.dbs[di].messages[mi].signals[si].name == name {
		// Both names must match. An index alone is not identity: deleting a message shifts the
		// next into its slot, and a same-named signal there would otherwise take this edit.
		sg := app.dbs[di].messages[mi].signals[si]
		be := sg.byte_order == .big_endian
		mut ns := sg.start_bit
		mut nl := sg.length
		if is_start {
			ns = if val < 0 { 0 } else { val }
			if !be && ns > anchor {
				ns = anchor // start cannot pass stop: the span may not invert
			}
			if !be {
				// A signal is at most 64 bits, and editing the START must hold the STOP — that
				// is the whole contract of the two fields. Capping the LENGTH here would keep
				// the typed start and drag the stop down with it (100..107, start := 0, gives
				// 0..63: the stop silently moved from 107 to 63 and the signal decodes
				// completely different bits). Clamp the start instead, so the anchor survives
				// and the span is the widest legal one that still ends where it did.
				if anchor - ns + 1 > 64 {
					ns = anchor - 63
					note = 'start clamped to ${ns}: a signal is at most 64 bits and the stop bit ${anchor} is held'
				}
				nl = anchor - ns + 1
			}
		} else {
			nl = if be { val } else { val - anchor + 1 }
		}
		if nl < 1 {
			nl = 1
		}
		if nl > 64 {
			nl = 64
		}
		// the value-table guard both fields enforce: a narrowing that cannot hold the existing
		// VAL_ keys is refused, or the writer masks them on save and remaps or collides them
		nmask := if nl >= 64 { ~u64(0) } else { (u64(1) << nl) - 1 }
		mut clash := false
		for k, _ in sg.values {
			if k & ~nmask != 0 {
				clash = true
			}
		}
		if clash {
			warn = '${sg.name}: ${nl} bit(s) cannot hold the existing value-table keys — edit discarded'
		} else {
			app.dbs[di].messages[mi].signals[si].start_bit = ns
			app.dbs[di].messages[mi].signals[si].length = nl
			dirty = di
		}
	}
	app.mu.unlock()
	if dirty >= 0 {
		app.mark_dirty(dirty)
	}
	if warn != '' {
		app.notify(warn)
	}
	if note != '' {
		app.notify(note)
	}
}

// cancel_pending_bit_edit drops an in-progress endpoint edit without applying it. Used where
// the database it referred to is about to be replaced by something the user did NOT edit —
// Revert being the case that matters, since resolving there would write the pending value
// onto the freshly reloaded file.
fn (mut app App) cancel_pending_bit_edit() {
	app.dbc_ed.bit_edit_key = ''
}

// dbc_ed_color: a deterministic per-signal palette for the bit grid.
fn dbc_ed_color(i int) (int, int, int) {
	return match i % 8 {
		0 { 86, 156, 214 }
		1 { 220, 170, 80 }
		2 { 120, 190, 120 }
		3 { 200, 120, 190 }
		4 { 100, 200, 200 }
		5 { 230, 130, 110 }
		6 { 150, 150, 220 }
		else { 180, 200, 100 }
	}
}

// dbc_ident_ok: message/signal/sender names are UNQUOTED DBC tokens — a space
// or punctuation would emit a record our own parser rejects.
fn dbc_ident_ok(sv string) bool {
	if sv == '' {
		return false
	}
	for i, c in sv {
		alpha := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
		if i == 0 && !alpha {
			return false
		}
		if !(alpha || (c >= `0` && c <= `9`)) {
			return false
		}
	}
	return true
}

// dbc_signal_bits lists the global LSB-0 bit positions a signal occupies —
// the same walk candb.raw_value takes (Intel ascending, Motorola sawtooth).
fn dbc_signal_bits(s candb.Signal) []int {
	mut out := []int{cap: s.length}
	if s.byte_order == .little_endian {
		for i in 0 .. s.length {
			out << s.start_bit + i
		}
	} else {
		mut pos := s.start_bit
		for _ in 0 .. s.length {
			out << pos
			if pos % 8 == 0 {
				pos = pos + 15 // drop to the next byte's bit 7
			} else {
				pos--
			}
		}
	}
	return out
}

// dbc_ed_load_bufs refreshes the string edit buffers when the selection moves.
fn (mut app App) dbc_ed_load_bufs() {
	key := '${app.dbc_ed.db}:${app.dbc_ed.msg}:${app.dbc_ed.sig}'
	if app.dbc_ed.msg_filter_buf.len == 0 {
		app.dbc_ed.msg_filter_buf = mkbuf('', 64)
	}
	if app.dbc_ed.sig_filter_buf.len == 0 {
		app.dbc_ed.sig_filter_buf = mkbuf('', 64)
	}
	if app.dbc_ed.val_key_buf.len == 0 {
		app.dbc_ed.val_key_buf = mkbuf('', 24)
	}
	if app.dbc_ed.val_name_buf.len == 0 {
		app.dbc_ed.val_name_buf = mkbuf('', 96)
	}
	if app.dbc_ed.node_buf.len == 0 {
		app.dbc_ed.node_buf = mkbuf('', 48)
	}
	if app.dbc_ed.loaded_key == key {
		return
	}
	app.dbc_ed.loaded_key = key
	di, mi, si := app.dbc_ed.db, app.dbc_ed.msg, app.dbc_ed.sig
	if di < 0 || di >= app.dbs.len || mi < 0 || mi >= app.dbs[di].messages.len {
		return
	}
	m := app.dbs[di].messages[mi]
	// buffers sized past the current content: mkbuf's cap includes the NUL, so
	// a fixed cap would silently truncate long fields on first edit
	app.dbc_ed.mname_buf = mkbuf(m.name, m.name.len + 96)
	app.dbc_ed.sender_buf = mkbuf(m.sender, m.sender.len + 96)
	if si >= 0 && si < m.signals.len {
		sg := m.signals[si]
		app.dbc_ed.sname_buf = mkbuf(sg.name, sg.name.len + 96)
		app.dbc_ed.unit_buf = mkbuf(sg.unit, sg.unit.len + 64)
		app.dbc_ed.desc_buf = mkbuf(sg.desc, sg.desc.len + 256)
	}
}

// dbc_refresh_if_all_clean re-reads sims/dbs_by_iface/generator caches from
// disk once NO database holds unsaved edits (the rebuild re-reads every
// file). Preserves the editor's selected database across the index shuffle.
fn (mut app App) dbc_refresh_if_all_clean() {
	for _, d in app.dbc_ed.dirty {
		if d {
			app.notify('sim/generator databases refresh after ALL DBCs are saved')
			return
		}
	}
	sel_path := if app.dbc_ed.db >= 0 && app.dbc_ed.db < app.dbs_paths.len {
		app.dbs_paths[app.dbc_ed.db]
	} else {
		''
	}
	app.rebuild_preserving_senders()
	if sel_path != '' {
		app.dbc_ed.db = app.dbs_paths.index(sel_path)
	}
}

// dbc_refresh_trace_names re-resolves the cached name on captured trace rows
// after a message rename / id / kind edit — they hold the name captured at
// arrival and would otherwise display the stale identity.
fn (mut app App) dbc_refresh_trace_names() {
	app.mu.lock()
	for i, r in app.trace {
		nn := app.lookup_name(r.id, r.ext)
		if nn != r.name {
			app.trace[i] = TraceRow{
				...r
				name: nn
			}
		}
	}
	app.mu.unlock()
}

fn (app &App) db_path(di int) string {
	if di >= 0 && di < app.dbs_paths.len {
		return app.dbs_paths[di]
	}
	if di >= 0 && di < app.dbs.len {
		return 'dbc_${di}'
	}
	return ''
}

fn (mut app App) mark_dirty(di int) {
	pth := app.db_path(di)
	if pth != '' {
		app.dbc_ed.dirty[pth] = true
	}
}

fn draw_dbc_editor(mut app App) {
	// Cancel an edit the user walked away from — before ANY early return below, so selecting
	// the message, reverting the database or deleting the signal cannot leave it pending.
	//
	// This is NOT redundant with the identical-looking check in resolve_pending_bit_edit(),
	// and removing it as a duplicate was wrong. They answer different questions:
	//   here      — every frame: has the selection moved? then DROP the state, so reselecting
	//               the original signal cannot resurrect its stale value in the field.
	//   resolver  — on commit: does the key still name the selection? then REFUSE to apply,
	//               which is what catches Start, since the toolbar draws before this panel.
	// Without this one, edit A → select B → reselect A brought the abandoned value back and
	// let it be committed. Without the other, Start committed it outright. Selection is
	// assigned in a dozen places, so detecting the change per frame beats asking every
	// assignment site to remember.
	if app.dbc_ed.bit_edit_key != ''
		&& !app.dbc_ed.bit_edit_key.ends_with(':${app.dbc_ed.db}:${app.dbc_ed.msg}:${app.dbc_ed.sig}') {
		app.dbc_ed.bit_edit_key = ''
	}
	// A useful floating default (Once — the user's own size/pos wins afterwards): undocked by
	// default, and without this a fresh float opened at imgui's tiny fallback size.
	vgui.set_next_window(220, 120, 980, 640)
	vis, op := vgui.begin_closable('DBC Editor', app.show_dbc)
	app.show_dbc = op
	if !vis {
		vgui.end()
		return
	}
	if app.dbs.len == 0 {
		vgui.text_dim('no DBCs loaded — attach one to a channel (Config panel)')
		vgui.end()
		return
	}
	app.dbc_ed_load_bufs()
	// READ-ONLY while a measurement runs: rx/sim/generator workers iterate
	// app.dbs lock-free, and the save path rebuilds runtime state — both are
	// only safe stopped. (Editing a stopped capture still re-decodes it live:
	// the trace decodes signal values at draw time.)
	app.mu.lock()
	live_readers := app.dbc_readers
	app.mu.unlock()
	ro := app.running || live_readers > 0
	if ro {
		vgui.text_colored(230, 170, 70,
			'read-only while measuring — Stop to edit (workers drain briefly after Stop)')
	}
	// a project swap replaces dbs_paths: dirty entries for paths no longer
	// attached are unreachable ghosts — drop them (the swap discarded those
	// databases; keeping the flags would wedge Start forever)
	for pth, _ in app.dbc_ed.dirty.clone() {
		if app.dbs_paths.index(pth) < 0 {
			app.dbc_ed.dirty.delete(pth)
			app.notify('unsaved DBC edits for detached ${os.file_name(pth)} were discarded')
		}
	}
	sc := app.ui_scale

	// ---- TOP CONTROL BAR: Database selector, Save / Revert, ECU Nodes ----
	mut names := []string{cap: app.dbs.len}
	for i, db in app.dbs {
		pth := app.db_path(i)
		mark := if pth != '' && app.dbc_ed.dirty[pth] { '` ' } else { '' }
		disp := if i < app.dbs_paths.len {
			'${os.file_name(os.dir(pth))}/${os.file_name(pth)}'
		} else {
			'DBC #${i}'
		}
		names << '${mark}${disp} (${db.messages.len} msgs) ##${i}'
	}
	if app.dbc_ed.db < 0 && app.dbs.len > 0 {
		app.dbc_ed.db = 0
	}
	vgui.set_next_item_width(280 * sc)
	ndb := vgui.combo('database', names, app.dbc_ed.db)
	if ndb != app.dbc_ed.db {
		app.dbc_ed.db = ndb
		app.dbc_ed.msg = -1
		app.dbc_ed.sig = -1
	}
	di := app.dbc_ed.db
	if di < 0 || di >= app.dbs.len {
		vgui.end()
		return
	}
	dbc_path := app.db_path(di)

	// save / revert controls
	vgui.same_line()
	if !ro && dbc_path != '' && app.dbc_ed.dirty[dbc_path] {
		vgui.text_colored(230, 170, 70, '` modified')
		vgui.same_line()
	}
	if !ro && dbc_path != '' && vgui.small_button('Save') {
		// resolve first: this button is processed before the inspector, so without it the old
		// endpoint is serialised and the edit commits afterwards, leaving the file dirty again
		app.resolve_pending_bit_edit()
		app.mu.lock()
		for m in app.dbs[di].messages {
			if m.sender != '' && m.sender !in app.dbs[di].nodes {
				app.dbs[di].nodes << m.sender
			}
		}
		text := app.dbs[di].to_dbc()
		app.mu.unlock()
		tmp := dbc_path + '.tmp~'
		mut save_ok := true
		os.write_file(tmp, text) or {
			app.notify('dbc save failed (edits kept in memory): ${err}')
			save_ok = false
		}
		if save_ok {
			os.mv(tmp, dbc_path) or {
				os.rm(tmp) or {}
				app.notify('dbc save failed (edits kept in memory): ${err}')
				save_ok = false
			}
		}
		if save_ok {
			app.dbc_ed.dirty.delete(dbc_path)
			app.dbc_ed.loaded_key = ''
			app.notify('saved ${dbc_path}')
			app.dbc_refresh_trace_names()
			app.dbc_refresh_if_all_clean()
		}
	}
	vgui.same_line()
	if !ro && dbc_path != '' && vgui.small_button('Revert') {
		if db := candb.load_dbc_file(dbc_path) {
			// Cancel only on SUCCESS. Revert reloads the file and then refreshes, which reaches
			// the resolver before the next frame can cancel on selection mismatch, so the
			// pending value would land on the database the user just discarded. But if the
			// file has been deleted, made unreadable or become unparsable, the revert does not
			// happen at all — the database and its other in-memory edits stay — and dropping
			// the endpoint edit there would lose typing for an operation that failed.
			app.cancel_pending_bit_edit()
			app.mu.lock()
			app.dbs[di] = db
			app.mu.unlock()
			app.dbc_ed.dirty.delete(dbc_path)
			app.dbc_ed.msg = -1
			app.dbc_ed.sig = -1
			app.dbc_ed.loaded_key = ''
			app.notify('reverted ${dbc_path}')
			app.dbc_refresh_trace_names()
			mut kept := []Watch{cap: app.watch.len}
			for w in app.watch {
				if m := app.find_message(w.id, w.ext) {
					mut have := false
					for sg in m.signals {
						if sg.name == w.sig {
							have = true
						}
					}
					if have {
						kept << w
					}
				}
			}
			if kept.len != app.watch.len {
				app.notify('${app.watch.len - kept.len} plotted signal(s) removed: not in the reverted DBC')
			}
			app.watch = kept
			app.dbc_refresh_if_all_clean()
		} else {
			app.notify('dbc revert failed: ${err}')
		}
	}

	// ECU Nodes (BU_) inline section
	vgui.same_line()
	if vgui.tree_node('ECU Nodes (BU_) [${app.dbs[di].nodes.len}]##bunodes') {
		app.dbc_ed_load_bufs()
		if app.dbs[di].nodes.len > 0 {
			for ni, nname in app.dbs[di].nodes {
				vgui.text_colored(120, 190, 120, nname)
				vgui.same_line()
				if !ro && vgui.small_button('-##delnode_${ni}') {
					app.mu.lock()
					app.dbs[di].nodes.delete(ni)
					app.mu.unlock()
					app.mark_dirty(di)
				}
				vgui.same_line()
			}
		} else {
			vgui.text_dim('no ECU nodes declared')
			vgui.same_line()
		}
		if !ro {
			vgui.set_next_item_width(120 * sc)
			vgui.input_text('node name##newnode', mut app.dbc_ed.node_buf)
			vgui.same_line()
			if vgui.small_button('+ ECU Node') {
				nname := vgui.buf_str(app.dbc_ed.node_buf).trim_space()
				if dbc_ident_ok(nname) && nname !in app.dbs[di].nodes {
					app.mu.lock()
					app.dbs[di].nodes << nname
					app.mu.unlock()
					app.mark_dirty(di)
					app.dbc_ed.node_buf = mkbuf('', 48)
				} else {
					app.notify('invalid or duplicate ECU node name')
				}
			}
		}
		vgui.tree_pop()
	}

	vgui.separator()

	// ---- MAIN SPLIT PANES: Left (Navigation) vs Right (Inspector & Layout) ----
	// draggable divider (splitter_v below); width persists in dbc_ed.left_w
	if app.dbc_ed.left_w <= 0 {
		app.dbc_ed.left_w = 340 * sc
	}
	left_w := app.dbc_ed.left_w
	vgui.child_wh('##dbced_left_pane', left_w, 0)

	// --- LEFT PANE: Messages & Signals Browser ---
	vgui.separator_text('messages & signals')
	vgui.set_next_item_width(150 * sc)
	vgui.input_text('filter##mf', mut app.dbc_ed.msg_filter_buf)
	vgui.same_line()
	app.dbc_ed.view_tree = vgui.checkbox('Tree##tv', app.dbc_ed.view_tree)
	mfilter := vgui.buf_str(app.dbc_ed.msg_filter_buf).to_lower()

	// Messages tree/list child — height is DRAGGABLE (splitter_h below); the signals box takes
	// what remains, so the two trade space instead of both being frozen at a guess.
	if app.dbc_ed.msgs_h <= 0 {
		app.dbc_ed.msgs_h = 220 * sc
	}
	vgui.child_begin('##dbcmsgbox', app.dbc_ed.msgs_h)
	if app.dbc_ed.view_tree {
		for i, m in app.dbs[di].messages {
			idtxt := if m.ext { '0x${m.id.hex()}x' } else { '0x${m.id.hex()}' }
			if mfilter != '' {
				name_match := m.name.to_lower().contains(mfilter)
				id_match := idtxt.to_lower().contains(mfilter) || '${m.id}'.contains(mfilter)
				sender_match := m.sender.to_lower().contains(mfilter)
				if !name_match && !id_match && !sender_match {
					continue
				}
			}
			sender_tag := if m.sender != '' { ' [${m.sender}]' } else { '' }
			is_msg_open :=
				vgui.tree_node('${idtxt} ${m.name}${sender_tag} (${m.signals.len})###treem_${i}')
			if vgui.is_item_clicked() {
				if app.dbc_ed.msg != i {
					app.dbc_refresh_trace_names()
				}
				app.dbc_ed.msg = i
				app.dbc_ed.sig = -1
			}
			if is_msg_open {
				for si, sg in m.signals {
					cr, cg, cb := dbc_ed_color(si)
					vgui.text_colored(u8(cr), u8(cg), u8(cb), ' #')
					vgui.same_line()
					or_tag := if sg.byte_order == .little_endian { 'LE' } else { 'BE' }
					sgn := if sg.is_signed { 'i' } else { 'u' }
					end_b := sg.start_bit + sg.length - 1
					if vgui.selectable('${sg.name} [b${sg.start_bit}..${end_b}] @${or_tag} ${sgn}${sg.length}##tsig_${i}_${si}',

						app.dbc_ed.msg == i && app.dbc_ed.sig == si)
					{
						app.dbc_ed.msg = i
						app.dbc_ed.sig = si
					}
				}
				vgui.tree_pop()
			}
		}
	} else {
		for i, m in app.dbs[di].messages {
			idtxt := if m.ext { '0x${m.id.hex()}x' } else { '0x${m.id.hex()}' }
			if mfilter != '' {
				name_match := m.name.to_lower().contains(mfilter)
				id_match := idtxt.to_lower().contains(mfilter) || '${m.id}'.contains(mfilter)
				sender_match := m.sender.to_lower().contains(mfilter)
				if !name_match && !id_match && !sender_match {
					continue
				}
			}
			if vgui.selectable('${idtxt} ${m.name} (dlc ${m.dlc})##dm${i}', app.dbc_ed.msg == i) {
				if app.dbc_ed.msg != i {
					app.dbc_refresh_trace_names()
				}
				app.dbc_ed.msg = i
				app.dbc_ed.sig = -1
			}
		}
	}
	vgui.child_end()
	// drag to trade height between the messages box above and the signals box below (which
	// fills the remainder) — clamped so neither can be squeezed out entirely
	msgs_max := app.dbc_ed.msgs_h + vgui.content_avail_h() - 160 * sc
	app.dbc_ed.msgs_h = vgui.splitter_h('##dbced_hsplit', app.dbc_ed.msgs_h, 80 * sc, msgs_max)

	// Message Action Buttons
	if !ro && vgui.small_button('+ message') {
		app.mu.lock()
		mut nid := u32(0x100)
		mut id_free := false
		for {
			mut taken := false
			for m in app.dbs[di].messages {
				if !m.ext && m.id == nid {
					taken = true
				}
			}
			if !taken {
				id_free = true
				break
			}
			if nid >= 0x7FF {
				break
			}
			nid++
		}
		if !id_free {
			app.mu.unlock()
			app.notify('no free standard id in 0x100..0x7FF — delete a message or use extended ids')
			vgui.child_end()
			vgui.end()
			return
		}
		mut mname := 'NewMessage'
		mut mn := 1
		for {
			mut taken := false
			for odb in app.dbs {
				for m in odb.messages {
					if m.name == mname {
						taken = true
					}
				}
			}
			if !taken {
				break
			}
			mn++
			mname = 'NewMessage${mn}'
		}
		app.dbs[di].messages << candb.Message{
			name: mname
			id:   nid
			dlc:  8
		}
		app.mu.unlock()
		app.dbc_ed.msg = app.dbs[di].messages.len - 1
		app.dbc_ed.sig = -1
		app.mark_dirty(di)
		app.dbc_ed.loaded_key = ''
	}
	mi := app.dbc_ed.msg
	if mi >= 0 && mi < app.dbs[di].messages.len {
		vgui.same_line()
		if !ro && vgui.small_button('- delete message') {
			app.mu.lock()
			app.dbs[di].messages.delete(mi)
			app.mu.unlock()
			app.dbc_ed.msg = -1
			app.dbc_ed.sig = -1
			app.mark_dirty(di)
			app.dbc_ed.loaded_key = ''
			app.dbc_refresh_trace_names()
			vgui.child_end()
			vgui.end()
			return
		}

		// Signals List for Selected Message
		vgui.separator_text('signals (${app.dbs[di].messages[mi].signals.len})')
		// The +/- signal buttons live ABOVE the table: the signals box below fills every
		// remaining pixel of the pane, so anything after it would render off the bottom.
		if !ro && vgui.small_button('+ signal') {
			app.mu.lock()
			mut top := 0
			for sg in app.dbs[di].messages[mi].signals {
				for g in dbc_signal_bits(sg) {
					if g + 1 > top {
						top = g + 1
					}
				}
			}
			mut nn := 1
			mut nname := 'NewSignal'
			for {
				mut taken := false
				for sg in app.dbs[di].messages[mi].signals {
					if sg.name == nname {
						taken = true
					}
				}
				if !taken {
					break
				}
				nn++
				nname = 'NewSignal${nn}'
			}
			app.dbs[di].messages[mi].signals << candb.Signal{
				name:      nname
				start_bit: top
				length:    8
			}
			app.mu.unlock()
			app.dbc_ed.sig = app.dbs[di].messages[mi].signals.len - 1
			app.mark_dirty(di)
			app.dbc_ed.loaded_key = ''
		}
		si_left := app.dbc_ed.sig
		if si_left >= 0 && si_left < app.dbs[di].messages[mi].signals.len {
			vgui.same_line()
			if !ro && vgui.small_button('- delete signal') {
				if app.dbs[di].messages[mi].signals[si_left].is_multiplexor {
					mut deps := 0
					for oi, osg in app.dbs[di].messages[mi].signals {
						if oi != si_left && osg.is_multiplexed {
							deps++
						}
					}
					if deps > 0 {
						app.notify('cannot delete the multiplexor switch: ${deps} multiplexed signal(s) depend on it')
						vgui.child_end()
						vgui.end()
						return
					}
				}
				app.mu.lock()
				app.dbs[di].messages[mi].signals.delete(si_left)
				app.mu.unlock()
				app.dbc_ed.sig = -1
				app.mark_dirty(di)
				app.dbc_ed.loaded_key = ''
				vgui.child_end()
				vgui.end()
				return
			}
		}
		vgui.set_next_item_width(180 * sc)
		vgui.input_text('filter signals##sf', mut app.dbc_ed.sig_filter_buf)
		sfilter := vgui.buf_str(app.dbc_ed.sig_filter_buf).to_lower()

		// FILLS the remaining left-pane height (0): the old fixed 180*sc wasted every tall
		// window and starved every short one. The +/- signal buttons moved above the table for
		// exactly this — a filling child leaves no room below itself.
		vgui.child_begin('##dbcsigbox', 0)
		if vgui.table_begin('##dbcsigtable', 4) {
			vgui.table_setup_col('#', 18 * sc)
			vgui.table_setup_col('name', 130 * sc)
			vgui.table_setup_col('start|len', 65 * sc)
			vgui.table_setup_col('fmt', 45 * sc)
			vgui.table_headers()
			for i, sg in app.dbs[di].messages[mi].signals {
				if sfilter != '' {
					name_match := sg.name.to_lower().contains(sfilter)
					unit_match := sg.unit.to_lower().contains(sfilter)
					desc_match := sg.desc.to_lower().contains(sfilter)
					if !name_match && !unit_match && !desc_match {
						continue
					}
				}
				or_tag := if sg.byte_order == .little_endian { 'LE' } else { 'BE' }
				sgn := if sg.is_signed { 'i' } else { 'u' }
				cr, cg, cb := dbc_ed_color(i)
				vgui.table_row()
				vgui.table_next_col()
				vgui.text_colored(u8(cr), u8(cg), u8(cb), '#')
				vgui.table_next_col()
				if vgui.selectable('${sg.name}##ds${i}', app.dbc_ed.sig == i) {
					app.dbc_ed.sig = i
				}
				vgui.table_cell('${sg.start_bit}|${sg.length}')
				vgui.table_cell('@${or_tag}${sgn}')
			}
			vgui.table_end()
		}
		vgui.child_end()
	}
	vgui.child_end() // end left pane

	// draggable divider: grow/shrink the left (messages & signals) pane vs the right (inspector)
	vgui.same_line()
	// Clamp the persisted width against what the panel has NOW: left_w survives docking and
	// resizing, so a divider dragged wide in a large window could otherwise consume a narrower
	// one entirely and leave the inspector unreachable (#68). The right pane keeps 200*sc.
	// content_avail_w() is called AFTER the left child and same_line(), so it reports only the
	// space to the RIGHT of the left pane. Treating that as the panel total made max_left shrink
	// as the user widened the pane, dragging the divider back on the next frame (#69). The panel
	// total is the left pane plus what remains beside it.
	avail := vgui.content_avail_w()
	total_w := app.dbc_ed.left_w + avail
	mut max_left := 760 * sc
	if total_w > 0 && total_w - 200 * sc < max_left {
		max_left = total_w - 200 * sc
	}
	if max_left < 200 * sc {
		max_left = 200 * sc
	}
	if app.dbc_ed.left_w > max_left {
		app.dbc_ed.left_w = max_left
	}
	app.dbc_ed.left_w = vgui.splitter_v('##dbced_split', app.dbc_ed.left_w, 200 * sc, max_left)
	vgui.same_line()

	// --- RIGHT PANE: Message Properties, Bit Layout Grid, Signal Inspector ---
	vgui.child_wh('##dbced_right_pane', 0, 0)

	if mi < 0 || mi >= app.dbs[di].messages.len {
		vgui.text_dim('select a message on the left to edit properties & bit layout')
		vgui.child_end()
		vgui.end()
		return
	}

	msg := app.dbs[di].messages[mi]

	// 1. Message Properties Form
	id_hex_str := if msg.ext { '0x${msg.id.hex()}x' } else { '0x${msg.id.hex()}' }
	vgui.separator_text('Message Properties: ${msg.name} (${id_hex_str})')
	app.dbc_ed_load_bufs()

	vgui.set_next_item_width(160 * sc)
	if !ro && vgui.input_text('name##dbcm', mut app.dbc_ed.mname_buf) {
		nv := vgui.buf_str(app.dbc_ed.mname_buf)
		mut mname_taken := false
		for odi, odb in app.dbs {
			for oi, om in odb.messages {
				if !(odi == di && oi == mi) && om.name == nv {
					mname_taken = true
				}
			}
		}
		if dbc_ident_ok(nv) && !mname_taken {
			app.mu.lock()
			app.dbs[di].messages[mi].name = nv
			app.mu.unlock()
			app.mark_dirty(di)
		}
	}
	if !dbc_ident_ok(vgui.buf_str(app.dbc_ed.mname_buf)) {
		vgui.same_line()
		vgui.text_colored(205, 60, 60, 'invalid name')
	}

	vgui.same_line()
	mut idv := int(msg.id)
	vgui.set_next_item_width(100 * sc)
	if !ro && vgui.input_int('id (dec)', &idv) {
		id_max := if msg.ext { 0x1FFF_FFFF } else { 0x7FF }
		cl := if idv < 0 {
			0
		} else if idv > id_max {
			id_max
		} else {
			idv
		}
		mut id_taken := false
		for oi, om in app.dbs[di].messages {
			if oi != mi && om.id == u32(cl) && om.ext == msg.ext {
				id_taken = true
			}
		}
		if !id_taken {
			old_id := msg.id
			wext0 := msg.ext
			app.mu.lock()
			app.dbs[di].messages[mi].id = u32(cl)
			app.mu.unlock()
			mut id_shadowed := false
			for odi in 0 .. di {
				for om in app.dbs[odi].messages {
					if om.id == old_id && om.ext == wext0 {
						id_shadowed = true
					}
				}
			}
			for wi, w in app.watch {
				if id_shadowed {
					break
				}
				if w.id == old_id && w.ext == wext0 {
					app.watch[wi] = Watch{
						id:  u32(cl)
						ext: w.ext
						sig: w.sig
					}
				}
			}
			app.mark_dirty(di)
		} else {
			app.notify('id 0x${u32(cl).hex()} already used by another frame — not applied')
		}
	}
	vgui.same_line()
	vgui.text_dim('= 0x${msg.id.hex()}')

	vgui.same_line()
	next := vgui.checkbox('ext##dbcm', msg.ext)
	if !ro && next != msg.ext {
		mut nid := msg.id
		if !next && nid > 0x7FF {
			nid = 0x7FF
		}
		mut clash := false
		for oi, om in app.dbs[di].messages {
			if oi != mi && om.id == nid && om.ext == next {
				clash = true
			}
		}
		if clash {
			app.notify('cannot flip ext: 0x${nid.hex()} already exists as that frame kind')
		} else {
			old_id2 := msg.id
			old_ext2 := msg.ext
			app.mu.lock()
			app.dbs[di].messages[mi].ext = next
			app.dbs[di].messages[mi].id = nid
			app.mu.unlock()
			mut kind_shadowed := false
			for odi in 0 .. di {
				for om in app.dbs[odi].messages {
					if om.id == old_id2 && om.ext == old_ext2 {
						kind_shadowed = true
					}
				}
			}
			for wi, w in app.watch {
				if kind_shadowed {
					break
				}
				if w.id == old_id2 && w.ext == old_ext2 {
					app.watch[wi] = Watch{
						id:  nid
						ext: next
						sig: w.sig
					}
				}
			}
			app.mark_dirty(di)
		}
	}

	// second row: framing (dlc / cycle / sender) — keeps the identity row (name / id / ext)
	// from running off the right edge.
	mut dlcv := msg.dlc
	vgui.set_next_item_width(70 * sc)
	if !ro && vgui.input_int('dlc', &dlcv) {
		app.mu.lock()
		app.dbs[di].messages[mi].dlc = if dlcv < 0 {
			0
		} else if dlcv > 64 {
			64
		} else {
			dlcv
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}

	vgui.same_line()
	mut cycv := msg.cycle_ms
	vgui.set_next_item_width(70 * sc)
	if !ro && vgui.input_int('cycle ms', &cycv) {
		app.mu.lock()
		app.dbs[di].messages[mi].cycle_ms = if cycv < 0 { 0 } else { cycv }
		app.mu.unlock()
		app.mark_dirty(di)
	}

	// sender = the transmitting ECU. PICK it from the declared ECU nodes (BU_) — you can't invent
	// an arbitrary sender. Add/remove nodes under "ECU Nodes (BU_)" at the top; "(none)" = no
	// sender. A loaded frame naming a not-yet-declared node still shows it (Save adds it to BU_).
	vgui.same_line()
	mut sender_opts := ['(none)']
	sender_opts << app.dbs[di].nodes
	if msg.sender != '' && msg.sender !in app.dbs[di].nodes {
		sender_opts << msg.sender
	}
	cur_sel := if msg.sender == '' { 0 } else { sender_opts.index(msg.sender) }
	vgui.set_next_item_width(130 * sc)
	nsel := vgui.combo('sender', sender_opts, cur_sel)
	if !ro && nsel != cur_sel && nsel >= 0 && nsel < sender_opts.len {
		new_snd := if nsel == 0 { '' } else { sender_opts[nsel] }
		app.mu.lock()
		app.dbs[di].messages[mi].sender = new_snd
		app.mu.unlock()
		app.mark_dirty(di)
	}

	// 2. Bit Layout Matrix Grid
	vgui.separator_text('Bit Layout Matrix')
	if msg.dlc < 0 || msg.dlc > 64 {
		vgui.text_colored(205, 60, 60,
			'dlc ${msg.dlc} out of range — fix it above to see the layout')
	} else {
		nbits := msg.dlc * 8
		mut owner_cnts := [512]int{}
		mut owners := [512][4]int{}
		for six, sg in msg.signals {
			for g in dbc_signal_bits(sg) {
				if g >= 0 && g < nbits && g < 512 {
					if owner_cnts[g] < 4 {
						owners[g][owner_cnts[g]] = six
						owner_cnts[g]++
					}
				}
			}
		}
		mut conflict := [512]bool{}
		for g in 0 .. nbits {
			cnt := owner_cnts[g]
			for x in 0 .. cnt {
				for y in x + 1 .. cnt {
					a := msg.signals[owners[g][x]]
					bsig := msg.signals[owners[g][y]]
					coexist := !(a.is_multiplexed && bsig.is_multiplexed
						&& a.multiplexor_value != bsig.multiplexor_value)
					if coexist {
						conflict[g] = true
					}
				}
			}
		}
		cell := 21 * sc
		// scrollable: a large dlc (up to 64 bytes) shouldn't stretch the whole panel — show
		// ~10 byte rows and scroll for the rest.
		vis_rows := if msg.dlc < 10 { msg.dlc } else { 10 }
		vgui.child_begin('##bitmatrix', f32(vis_rows) * (cell + 4 * sc) + 6 * sc)
		for byte_i in 0 .. msg.dlc {
			vgui.text_dim('B${byte_i}')
			for bit_i := 7; bit_i >= 0; bit_i-- {
				vgui.same_line()
				g := byte_i * 8 + bit_i
				cnt := owner_cnts[g]
				mut r, mut gg, mut b := 58, 58, 62
				mut lbl := ' '
				if cnt == 1 {
					sidx := owners[g][0]
					r, gg, b = dbc_ed_color(sidx)
					if sidx == app.dbc_ed.sig {
						r, gg, b = r + 40, gg + 40, b + 40
					}
					sg := msg.signals[sidx]
					if sg.is_multiplexor {
						lbl = 'M'
					} else if sg.is_multiplexed {
						lbl = 'm'
					} else {
						lbl = '${sidx % 10}'
					}
				} else if cnt > 1 {
					if conflict[g] {
						r, gg, b = 205, 60, 60
						lbl = '!'
					} else {
						r, gg, b = dbc_ed_color(owners[g][0])
						r, gg, b = r / 2 + 20, gg / 2 + 20, b / 2 + 20
						lbl = 'm'
					}
				}
				if vgui.button_big('${lbl}##g${g}', r, gg, b, cell, cell) {
					if cnt > 0 {
						app.dbc_ed.sig = owners[g][0]
					}
				}
				if cnt > 0 {
					mut tt := 'bit ${g} (Byte ${byte_i}, bit ${bit_i})'
					for o_idx in 0 .. cnt {
						o := owners[g][o_idx]
						sg := msg.signals[o]
						mux_info := if sg.is_multiplexor {
							' [Mux Switch]'
						} else if sg.is_multiplexed {
							' [Mux ${sg.multiplexor_value}]'
						} else {
							''
						}
						tt += '\n${sg.name}${mux_info}'
					}
					vgui.set_item_tooltip(tt)
				}
			}
		}
		vgui.child_end()
		mut over := 0
		for g in 0 .. nbits {
			if conflict[g] {
				over++
			}
		}
		if over > 0 {
			vgui.text_colored(205, 60, 60, '${over} bit(s) claimed by more than one signal')
		}
		for sg in msg.signals {
			for g in dbc_signal_bits(sg) {
				if g >= nbits || g < 0 {
					vgui.text_colored(205, 60, 60, '${sg.name} exceeds the ${msg.dlc}-byte frame')
					break
				}
			}
		}
	}

	// 3. Signal Inspector Form (for selected signal)
	si := app.dbc_ed.sig
	if si < 0 || si >= msg.signals.len {
		vgui.separator_text('Signal Inspector')
		vgui.text_dim('select a signal in the left tree/table or layout grid to inspect properties')
		vgui.child_end()
		vgui.end()
		return
	}

	sg := msg.signals[si]
	cr, cg, cb := dbc_ed_color(si)
	vgui.separator_text('Signal Inspector: #${si + 1} ')
	vgui.same_line()
	vgui.text_colored(u8(cr), u8(cg), u8(cb), sg.name)

	app.dbc_ed_load_bufs()
	vgui.set_next_item_width(160 * sc)
	if !ro && vgui.input_text('name##dbcs', mut app.dbc_ed.sname_buf) {
		nv := vgui.buf_str(app.dbc_ed.sname_buf)
		mut name_taken := false
		for oi, osg in msg.signals {
			if oi != si && osg.name == nv {
				name_taken = true
			}
		}
		if dbc_ident_ok(nv) && !name_taken {
			old_sig := msg.signals[si].name
			app.mu.lock()
			app.dbs[di].messages[mi].signals[si].name = nv
			app.mu.unlock()
			app.mark_dirty(di)
			wid := msg.id
			wext := msg.ext
			mut shadowed := false
			for odi in 0 .. di {
				for om in app.dbs[odi].messages {
					if om.id == wid && om.ext == wext {
						shadowed = true
					}
				}
			}
			for wi, w in app.watch {
				if shadowed {
					break
				}
				if w.id == wid && w.ext == wext && w.sig == old_sig {
					app.watch[wi] = Watch{
						id:  w.id
						ext: w.ext
						sig: nv
					}
				}
			}
		}
	}
	if !dbc_ident_ok(vgui.buf_str(app.dbc_ed.sname_buf)) {
		vgui.same_line()
		vgui.text_colored(205, 60, 60, 'invalid name')
	}

	// A signal's bit span is defined by its two endpoints: start bit + stop bit (the width is
	// derived, stop - start + 1). No separate "len" field and no +/- steppers — you set where
	// the bits begin and end. (Little-endian contiguous span; big-endian keeps DBC semantics.)
	lnv := sg.length
	stop_bit := sg.start_bit + lnv - 1
	sb_key := 'start:${di}:${mi}:${si}'
	// While this field is being edited the FIELD owns the value, not the model — otherwise the
	// next frame resets it to the unchanged model and the edit snaps back mid-typing.
	mut sbv := if app.dbc_ed.bit_edit_key == sb_key { app.dbc_ed.bit_edit_val } else { sg.start_bit }

	vgui.same_line()
	vgui.set_next_item_width(65 * sc)
	if !ro && vgui.input_int('start bit', &sbv) {
		if app.dbc_ed.bit_edit_key != sb_key {
			// the edit begins here: snapshot the endpoint we will hold it against, so later
			// keystrokes are measured against where the span was BEFORE typing started (#68)
			app.dbc_ed.bit_edit_key = sb_key
			app.dbc_ed.bit_edit_anchor = stop_bit
			app.dbc_ed.bit_edit_db = di
			app.dbc_ed.bit_edit_msg = mi
			app.dbc_ed.bit_edit_sig = si
			app.dbc_ed.bit_edit_name = sg.name
			app.dbc_ed.bit_edit_msg_name = app.dbs[di].messages[mi].name
		}
		app.dbc_ed.bit_edit_val = sbv
	}
	// The edit finished. Applying it lives in resolve_pending_bit_edit() and ONLY there — the
	// same call Start, Save and rebuild make — so the deactivation path and the choke point
	// cannot drift into disagreeing about clamping or value-table validation.
	if !ro && app.dbc_ed.bit_edit_key == sb_key && vgui.is_item_deactivated_after_edit() {
		app.resolve_pending_bit_edit()
	}
	vgui.same_line()
	vgui.set_next_item_width(65 * sc)
	// Intel: the span is contiguous, so a stop-bit endpoint derives the width. Motorola
	// (big-endian) bits descend within a byte and jump +15 across bytes (a sawtooth), so
	// stop - start + 1 is NOT the width — editing an endpoint there would silently corrupt
	// it (codex #65). Edit the length directly for big-endian.
	be := sg.byte_order == .big_endian
	w_key := 'width:${di}:${mi}:${si}'
	mut widthv := if app.dbc_ed.bit_edit_key == w_key {
		app.dbc_ed.bit_edit_val
	} else if be {
		lnv
	} else {
		stop_bit
	}
	if !ro && vgui.input_int(if be { 'length' } else { 'stop bit' }, &widthv) {
		if app.dbc_ed.bit_edit_key != w_key {
			// same reasoning as the start field: hold the START endpoint as it was when typing
			// began, so intermediate keystrokes are not measured against a moving anchor (#68)
			app.dbc_ed.bit_edit_key = w_key
			app.dbc_ed.bit_edit_anchor = sg.start_bit
			app.dbc_ed.bit_edit_db = di
			app.dbc_ed.bit_edit_msg = mi
			app.dbc_ed.bit_edit_sig = si
			app.dbc_ed.bit_edit_name = sg.name
			app.dbc_ed.bit_edit_msg_name = app.dbs[di].messages[mi].name
		}
		app.dbc_ed.bit_edit_val = widthv
	}
	if !ro && app.dbc_ed.bit_edit_key == w_key && vgui.is_item_deactivated_after_edit() {
		app.resolve_pending_bit_edit()
	}
	vgui.same_line()
	vgui.text_dim('(${lnv} bit${if lnv == 1 { '' } else { 's' }})')
	vgui.same_line()
	// the contiguous start..stop range only describes an Intel span; a Motorola signal
	// walks the sawtooth, so show its start + width instead of a misleading range
	vgui.text_dim(if be {
		'(Motorola: start ${sbv}, ${lnv} bits)'
	} else {
		'(range: bit ${sbv} .. ${sbv + lnv - 1})'
	})

	cur_o := if sg.byte_order == .little_endian { 0 } else { 1 }
	vgui.set_next_item_width(120 * sc)
	no := vgui.combo('order', ['Intel (LE)', 'Motorola (BE)'], cur_o)
	if !ro && no != cur_o {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].byte_order = if no == 0 {
			candb.ByteOrder.little_endian
		} else {
			candb.ByteOrder.big_endian
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	nsg := vgui.checkbox('signed', sg.is_signed)
	if !ro && nsg != sg.is_signed {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].is_signed = nsg
		app.mu.unlock()
		app.mark_dirty(di)
	}

	mut fv := sg.factor
	vgui.same_line()
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('factor', &fv) {
		if fv != 0 {
			app.mu.lock()
			app.dbs[di].messages[mi].signals[si].factor = fv
			app.mu.unlock()
			app.mark_dirty(di)
		}
	}
	vgui.same_line()
	mut ov := sg.offset
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('offset', &ov) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].offset = ov
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	mut mnv := sg.minimum
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('min', &mnv) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].minimum = mnv
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	mut mxv := sg.maximum
	vgui.set_next_item_width(90 * sc)
	if !ro && vgui.input_double('max', &mxv) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].maximum = mxv
		app.mu.unlock()
		app.mark_dirty(di)
	}

	vgui.set_next_item_width(80 * sc)
	if !ro && vgui.input_text('unit', mut app.dbc_ed.unit_buf) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].unit = vgui.buf_str(app.dbc_ed.unit_buf)
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	vgui.set_next_item_width(280 * sc)
	if !ro && vgui.input_text('desc', mut app.dbc_ed.desc_buf) {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].desc = vgui.buf_str(app.dbc_ed.desc_buf)
		app.mu.unlock()
		app.mark_dirty(di)
	}

	// Multiplexing
	vgui.separator_text('multiplexing')
	mut is_mux := sg.is_multiplexor
	new_is_mux := vgui.checkbox('Multiplexor Switch (M)##muxm', is_mux)
	if !ro && new_is_mux != is_mux {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].is_multiplexor = new_is_mux
		if new_is_mux {
			app.dbs[di].messages[mi].signals[si].is_multiplexed = false
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}
	vgui.same_line()
	mut is_sub := sg.is_multiplexed
	new_is_sub := vgui.checkbox('Multiplexed Signal (m<N>)##muxsub', is_sub)
	if !ro && new_is_sub != is_sub {
		app.mu.lock()
		app.dbs[di].messages[mi].signals[si].is_multiplexed = new_is_sub
		if new_is_sub {
			app.dbs[di].messages[mi].signals[si].is_multiplexor = false
		}
		app.mu.unlock()
		app.mark_dirty(di)
	}
	if app.dbs[di].messages[mi].signals[si].is_multiplexed {
		vgui.same_line()
		mut mval := sg.multiplexor_value
		vgui.set_next_item_width(80 * sc)
		if !ro && vgui.input_int('Mux Value (N)##muxval', &mval) {
			app.mu.lock()
			app.dbs[di].messages[mi].signals[si].multiplexor_value = if mval < 0 { 0 } else { mval }
			app.mu.unlock()
			app.mark_dirty(di)
		}
	}

	// Value Table (VAL_)
	vgui.separator_text('value table (VAL_)')
	sg_vals := sg.values.clone()
	if sg_vals.len > 0 {
		vgui.child_begin('##valtablebox', 90 * sc)
		if vgui.table_begin('##valtable', 3) {
			vgui.table_setup_col('raw value', 90 * sc)
			vgui.table_setup_col('label / state', 180 * sc)
			vgui.table_setup_col('action', 50 * sc)
			vgui.table_headers()
			mut keys := sg_vals.keys()
			keys.sort()
			for k in keys {
				vgui.table_row()
				vgui.table_cell('${k} (0x${k:X})')
				vgui.table_cell(sg_vals[k])
				vgui.table_next_col()
				if !ro && vgui.small_button('-##delval_${k}') {
					app.mu.lock()
					app.dbs[di].messages[mi].signals[si].values.delete(k)
					app.mu.unlock()
					app.mark_dirty(di)
				}
			}
			vgui.table_end()
		}
		vgui.child_end()
	} else {
		vgui.text_dim('no value table mappings defined for this signal')
	}
	if !ro {
		vgui.set_next_item_width(90 * sc)
		vgui.input_text('raw key##vkey', mut app.dbc_ed.val_key_buf)
		vgui.same_line()
		vgui.set_next_item_width(180 * sc)
		vgui.input_text('state label##vlbl', mut app.dbc_ed.val_name_buf)
		vgui.same_line()
		if vgui.small_button('+ value') {
			kstr := vgui.buf_str(app.dbc_ed.val_key_buf).trim_space()
			lblstr := vgui.buf_str(app.dbc_ed.val_name_buf).trim_space()
			if kstr != '' && lblstr != '' {
				parsed_k := kstr.u64()
				app.mu.lock()
				app.dbs[di].messages[mi].signals[si].values[parsed_k] = lblstr
				app.mu.unlock()
				app.mark_dirty(di)
				app.dbc_ed.val_key_buf = mkbuf('', 24)
				app.dbc_ed.val_name_buf = mkbuf('', 96)
			} else {
				app.notify('enter both a raw value and state label')
			}
		}
	}

	vgui.child_end() // end right pane

	vgui.end()
}
