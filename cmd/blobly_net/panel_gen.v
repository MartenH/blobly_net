module main

import math
import project
import sim
import time
import transport
import candb
import vgui

// ---- Send ----
// draw_quick_send is the folded-in Send: a one-shot raw id+data transmit at the top of the
// Generators panel. It fires immediately without creating a saved generator — the fast ad-hoc
// path. Fields stay editable while stopped; only firing needs a running bus.
fn draw_quick_send(mut app App) {
	vgui.separator_text('quick send')
	// target bus: validate the stored quick-send iface against the current channels; fall back to
	// the default send_iface if it was removed/renamed.
	mut target := app.send_iface
	mut cur := 0
	for k, c in app.chans {
		if c.iface == app.qs_iface {
			target = app.qs_iface
			cur = k
		} else if c.iface == target {
			cur = k
		}
	}
	if app.chans.len > 1 {
		mut names := []string{cap: app.chans.len}
		for c in app.chans {
			names << c.name
		}
		vgui.set_next_item_width(120 * app.ui_scale)
		nsel := vgui.combo('bus##qsbus', names, cur)
		if nsel != cur && nsel >= 0 && nsel < app.chans.len {
			app.qs_iface = app.chans[nsel].iface
			target = app.qs_iface
		}
	}
	// Stopped, `send_iface` is empty (stop() clears it) and `qs_iface` is only set once the
	// combo has been touched, so the row the button will send on is the selected one, or the
	// first (codex round 1 on #256).
	if target == '' && app.chans.len > 0 {
		target = app.chans[cur].iface
	}
	// ONE FIELD PER LINE, and a Send that is always there. The bus, id and data used to share
	// one row, which grew past the panel with any data worth typing; and the Send button
	// existed only while running, so a stopped panel showed a field to type into and nothing
	// to press, with "start to send" as the only hint (2026-08-29). Now the button is drawn
	// either way and greyed when stopped, the way the File tab greys its Save.
	vgui.set_next_item_width(90 * app.ui_scale)
	vgui.input_text('id (hex)', mut app.send_id_buf)
	// A fixed width with the label AFTER it, as ImGui draws labels: the full remaining width
	// pushed "data (hex)" off the panel edge (codex round 1 on #256).
	vgui.set_next_item_width(260 * app.ui_scale)
	vgui.input_text('data (hex)', mut app.send_data_buf)
	if app.running {
		if vgui.button('Send##quicksend') {
			id := u32(('0x' + vgui.buf_str(app.send_id_buf)).u64())
			data := parse_hex_bytes(vgui.buf_str(app.send_data_buf))
			app.tx_on(target, transport.CanFrame{
				id:   id
				data: data
			})
		}
		vgui.same_line()
		vgui.text_dim('on ${app.chan_name_for(target)}')
	} else {
		vgui.text_dim('[ Send ]')
		vgui.same_line()
		vgui.text_dim('on ${app.chan_name_for(target)} · Start to send')
	}
}

// ---- Generators (interactive send blocks) ----
// Always visible and editable regardless of run state; Start/Stop only gates *firing*.
// Add / remove / edit happen in the session; Save persists them to the project .blobnet.
fn draw_gen(mut app App) {
	vis, op := vgui.begin_closable('Generators', app.show_gen)
	app.show_gen = op
	if !vis {
		vgui.end()
		return
	}
	// folded-in Send: fast ad-hoc raw transmit
	draw_quick_send(mut app)
	vgui.separator_text('generators')
	if vgui.button('+ Add generator') {
		app.add_generator()
	}
	if app.dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified — Ctrl+S saves')
	}
	if app.running {
		vgui.text_dim('edit freely · Send now fires once · cyclic auto-repeats · on-key fires on its key')
	} else {
		vgui.text_dim('edit freely · press Start to fire')
	}
	if app.senders.len == 0 {
		vgui.text_dim('no generators — click "+ Add generator"')
		vgui.end()
		return
	}
	// one collapsed tree node per generator; the header summarises name + trigger so the list
	// stays scannable when everything is folded (start state).
	mut remove_idx := -1
	for i, sr in app.senders {
		// keep the model in sync with the edit buffers (name/key are UI-thread-only fields);
		// do it before the header so the collapsed label reflects the latest edit.
		app.senders[i].sender.name = vgui.buf_str(app.gen_bufs[i].name_buf)
		app.senders[i].sender.key = vgui.buf_str(app.gen_bufs[i].key_buf)
		mut s := app.senders[i].sender
		cm := if s.cycle_ms > 0 { s.cycle_ms } else { 100 }
		trig := match s.trigger {
			'key' {
				if s.key != '' { 'key "${s.key}"' } else { 'key (unset)' }
			}
			'cyclic' {
				'cyclic ${cm} ms'
			}
			else {
				'manual'
			}
		}

		nm := if s.name != '' { s.name } else { '(unnamed)' }
		// ### keys the node on the index only, so editing the visible name doesn't collapse it.
		if vgui.tree_node('${nm}   ·   ${trig}###gennode${i}') {
			vgui.set_next_item_width(200 * app.ui_scale)
			if vgui.input_text('name##gn${i}', mut app.gen_bufs[i].name_buf) {
				app.dirty = true
			}
			vgui.same_line()
			vgui.set_next_item_width(36 * app.ui_scale)
			if vgui.input_text('key##gk${i}', mut app.gen_bufs[i].key_buf) {
				app.dirty = true
			}
			vgui.same_line()
			if vgui.small_button('remove##rm${i}') {
				remove_idx = i // indices shift on delete — do it after the loop
			}
			// fire: Send now only fires while running (stopped = editable, just no TX)
			if app.running {
				if vgui.button('Send now##${i}') {
					app.fire_index(i)
				}
			} else {
				vgui.text_dim('Send now (start to fire)')
			}
			vgui.same_line()
			vgui.text('fires:')
			vgui.same_line()
			if vgui.toggle_button('manual##${i}', s.trigger == 'manual', 0) {
				app.set_trigger(i, 'manual')
			}
			vgui.same_line()
			if vgui.toggle_button('on key##${i}', s.trigger == 'key', 0) {
				app.set_trigger(i, 'key')
			}
			vgui.same_line()
			if vgui.toggle_button('cyclic##${i}', s.trigger == 'cyclic', 0) {
				app.set_trigger(i, 'cyclic')
			}
			if s.trigger == 'cyclic' {
				vgui.same_line()
				vgui.text('every ${cm} ms')
				vgui.same_line()
				if vgui.small_button('-##c${i}') {
					app.set_cycle(i, if cm > 60 { cm - 50 } else { 10 })
				}
				vgui.same_line()
				if vgui.small_button('+##c${i}') {
					app.set_cycle(i, cm + 50)
				}
			}
			// target bus: which wire this generator transmits on (defaults to its own channel)
			if app.chans.len > 1 {
				cur := app.senders[i].target()
				vgui.text('bus:')
				for ci, c in app.chans {
					vgui.same_line()
					// selected by NAME, not by interface: with two channels on one wire an
					// interface comparison lights BOTH buttons and cannot say which is current
					// with no owner resolved, fall back to the interface — otherwise NO chip
					// lights and the picker looks broken
					sel := if sr.chan != '' {
						c.name == sr.chan && c.iface == cur
					} else {
						c.iface == cur
					}
					if vgui.toggle_button('${c.name}##b${i}_${ci}', sel, 0) {
						app.set_sender_bus(i, if c.iface == sr.iface { '' } else { c.iface },
							c.name)
					}
				}
			}
			// message picker: build the frame from a DBC message (→ per-signal values) or send a
			// raw id + data. Option 0 = raw; the rest are the messages on THIS generator's bus.
			gen_iface := app.senders[i].target()
			msg_names := app.message_names_for(gen_iface)
			mut msg_opts := ['(raw id / data)']
			msg_opts << msg_names
			mut cur_msg := 0
			if s.message != '' {
				for k, mn in msg_names {
					if mn == s.message {
						cur_msg = k + 1
						break
					}
				}
			}
			vgui.set_next_item_width(220 * app.ui_scale)
			nsel := vgui.combo('message##msg${i}', msg_opts, cur_msg)
			if nsel != cur_msg {
				app.set_sender_message(i, if nsel <= 0 { '' } else { msg_opts[nsel] })
				s = app.senders[i].sender // reflect the switch in this frame's payload block
			}
			// payload: DBC message -> per-signal values; raw -> id + data hex
			if s.message != '' {
				vgui.text('message ${s.message} · signal values:')
				cmsg := app.find_message_cdb_for(gen_iface, s.message) or { candb.Message{} }
				for j, ss in s.signals {
					mut sig := candb.Signal{}
					mut have := false
					for cs in cmsg.signals {
						if cs.name == ss.name {
							sig = cs
							have = true
							break
						}
					}
					app.signal_input(i, j, sig, have)
				}
			} else {
				vgui.set_next_item_width(70 * app.ui_scale)
				if vgui.input_text('id##id${i}', mut app.gen_bufs[i].id_buf) {
					app.dirty = true
				}
				vgui.same_line()
				vgui.set_next_item_width(260 * app.ui_scale)
				if vgui.input_text('data (hex)##dt${i}', mut app.gen_bufs[i].data_buf) {
					app.dirty = true
				}
			}
			vgui.tree_pop()
		}
	}
	if remove_idx >= 0 {
		app.remove_generator(remove_idx)
	}
	vgui.end()
}

// add_generator appends a new raw generator to the session, targeting the first channel.
// Session-only until Save writes it to the project.
fn (mut app App) add_generator() {
	iface := if app.chans.len > 0 { app.chans[0].iface } else { '' }
	cname := if app.chans.len > 0 { app.chans[0].name } else { '' }
	app.mu.lock()
	app.senders << SenderRT{
		iface:  iface
		chan:   cname
		sender: project.Sender{
			name:    'New generator'
			id:      0x100
			trigger: 'manual'
		}
	}
	app.gen_bufs << GenBuf{
		name_buf: mkbuf('New generator', 48)
		key_buf:  mkbuf('', 2)
		id_buf:   mkbuf('100', 24)
		data_buf: mkbuf('', 96)
	}
	app.dirty = true
	app.mu.unlock()
	// The tap for a generator added mid-run opens on a worker (spawn_tap_for): opened here it
	// ran on the GUI thread, and read tx_buses without the lock (codex round 4 on #257).
	app.spawn_tap_for(cname, iface)
}

// remove_generator drops generator `i` from the session.
fn (mut app App) remove_generator(i int) {
	app.mu.lock()
	if i >= 0 && i < app.senders.len {
		app.senders.delete(i)
		if i < app.gen_bufs.len {
			app.gen_bufs.delete(i)
		}
		// index-keyed: everything after `i` has just shifted down onto another generator's count
		app.gen_send_n = map[int]int{}
		app.gen_state_epoch++ // and an in-flight fire must not write its old count back
		app.dirty = true
	}
	app.mu.unlock()
}

// sync_senders_into_proj flushes the Generators panel edit buffers into app.proj so a Save
// persists them (a sender belongs to its channel; its `bus:` override travels as a field).
fn (mut app App) sync_senders_into_proj() {
	app.mu.lock()
	defer { app.mu.unlock() }
	for i in 0 .. app.senders.len {
		if app.senders[i].sender.message == '' && i < app.gen_bufs.len {
			app.senders[i].sender.id = u32(('0x' + vgui.buf_str(app.gen_bufs[i].id_buf)).u64())
			app.senders[i].sender.data = parse_hex_bytes(vgui.buf_str(app.gen_bufs[i].data_buf))
		}
	}
	mut p := app.proj
	for ci in 0 .. p.channels.len {
		mut ss := []project.Sender{}
		for sr in app.senders {
			if sr.iface == p.channels[ci].iface {
				ss << sr.sender
			}
		}
		p.channels[ci].senders = ss
	}
	app.proj = p
}

// dbs_for returns the DBCs attached to the channel transmitting on `iface` (a generator's target
// bus). Scoping the message picker/lookup here — not the global app.dbs — means a generator on
// bus B never resolves a same-named message from bus A's database.
fn (app &App) dbs_for(iface string) []candb.Database {
	return app.dbs_by_iface[iface] or { [] }
}

// message_names_for lists the DBC message names on `iface` (deduplicated, load order) — the
// picker options for a generator whose target bus is `iface`.
fn (app &App) message_names_for(iface string) []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	for db in app.dbs_for(iface) {
		for m in db.messages {
			if m.name in seen {
				continue
			}
			seen[m.name] = true
			out << m.name
		}
	}
	return out
}

// set_sender_message switches generator `i` between raw (msg == '') and DBC-message mode. When a
// message is picked, its signals are seeded (values preserved by name across a re-pick) so the
// editor shows one input per signal; picking raw clears them so the id/data hex inputs return.
// The message is resolved on the generator's OWN target bus, not globally.
fn (mut app App) set_sender_message(i int, msg string) {
	if i < 0 || i >= app.senders.len {
		return
	}
	iface := app.senders[i].target()
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if msg == '' {
		app.senders[i].sender.message = ''
		app.senders[i].sender.signals = []
	} else {
		old := app.senders[i].sender.signals.clone()
		app.senders[i].sender.message = msg
		mut sigs := []project.SenderSig{}
		for db in app.dbs_for(iface) {
			mut found := false
			for m in db.messages {
				if m.name != msg {
					continue
				}
				for sig in m.signals {
					// carry the WHOLE matching signal across, not just its number: the value
					// source (wave) is part of what the user configured, and copying only
					// `value` silently dropped a waveform when the message was switched and
					// switched back.
					mut keep := project.SenderSig{
						name: sig.name
					}
					for o in old {
						if o.name == sig.name {
							keep = o
							keep.name = sig.name
							break
						}
					}
					sigs << keep
				}
				found = true
				break
			}
			if found {
				break
			}
		}
		app.senders[i].sender.signals = sigs
	}
	app.dirty = true
}

// find_message_cdb_for returns the candb.Message `name` from the DBCs on `iface` (signal
// metadata: units, value tables, integer-vs-float scaling) — scoped to the generator's bus.
fn (app &App) find_message_cdb_for(iface string, name string) ?candb.Message {
	for db in app.dbs_for(iface) {
		for m in db.messages {
			if m.name == name {
				return m
			}
		}
	}
	return none
}

// signal_is_integer is true when every representable physical value of the signal is a whole
// number (integer factor + offset) — so it should get an integer input, not a float box.
fn signal_is_integer(sig candb.Signal) bool {
	return sig.factor == math.trunc(sig.factor) && sig.offset == math.trunc(sig.offset)
}

// signal_input renders one generator signal value using its DBC type: an enum dropdown for a
// signal with a VAL_ table, an integer spinner for integer-scaled signals, else a float box.
// `sig` is the DBC metadata (valid only when `have`); without it we fall back to a float box.
fn (mut app App) signal_input(i int, j int, sig candb.Signal, have bool) {
	ss := app.senders[i].sender.signals[j]
	unit := if have && sig.unit != '' { ' [${sig.unit}]' } else { '' }
	lbl := '${ss.name}${unit}##sig${i}_${j}'
	pv := unsafe { &app.senders[i].sender.signals[j].value }
	vgui.set_next_item_width(170 * app.ui_scale)
	if have && sig.values.len > 0 {
		// enum: dropdown of "value — name" states. VAL_ keys are stored two's-complement for
		// signed signals, so map key<->physical through the signal (phys_from_raw / raw_from_phys)
		// — never a bare f64(rawkey), which would turn -1 into 1.8e19.
		mut raws := sig.values.keys()
		raws.sort()
		mut labels := []string{cap: raws.len}
		for r in raws {
			labels << '${sig.phys_from_raw(r):g} — ${sig.values[r]}'
		}
		curraw := sig.raw_from_phys(ss.value)
		mut cur := 0
		for k, r in raws {
			if r == curraw {
				cur = k
				break
			}
		}
		nsel := vgui.combo(lbl, labels, cur)
		if nsel != cur && nsel >= 0 && nsel < raws.len {
			unsafe {
				*pv = sig.phys_from_raw(raws[nsel])
			}
			app.dirty = true
		}
	} else if have && signal_is_integer(sig) {
		mut iv := int(math.round(ss.value))
		if vgui.input_int(lbl, &iv) {
			unsafe {
				*pv = f64(iv)
			}
			app.dirty = true
		}
	} else {
		if vgui.input_double(lbl, pv) {
			app.dirty = true
		}
	}
	app.signal_source(i, j)
}

// wave_kinds: the value sources a signal can have, in the order the picker shows them. 'value'
// is the absence of a source (send the static number above) and maps to GenCfg.typ == ''.
// 'value' is the absence of a source (send the static number). 'const' is deliberately NOT here:
// for a generator a constant source IS that static value, and offering both put two `value:` keys
// in one saved mapping and two independently editable numbers behind one field (codex #269).
const wave_kinds = ['value', 'sine', 'sawtooth', 'counter', 'stepmod']

fn wave_typ_of(sel int) string {
	if sel <= 0 || sel >= wave_kinds.len {
		return ''
	}
	return wave_kinds[sel]
}

fn wave_sel_of(typ string) int {
	for k, w in wave_kinds {
		if w == typ && k > 0 {
			return k
		}
	}
	return 0
}

// signal_source draws the per-signal VALUE SOURCE: pick a waveform and it sweeps on every send,
// exactly as a simulated ECU's signal does (same GenCfg, same sim.gen_from_cfg evaluator). The
// difference is only who is sending — a generator is the tester, so its frames are TX, not TX-S.
fn (mut app App) signal_source(i int, j int) {
	w := app.senders[i].sender.signals[j].wave
	vgui.same_line()
	vgui.set_next_item_width(110 * app.ui_scale)
	sel := vgui.combo('##src${i}_${j}', wave_kinds, wave_sel_of(w.typ))
	if sel != wave_sel_of(w.typ) {
		app.set_wave_typ(i, j, wave_typ_of(sel))
	}
	if w.typ == '' {
		return
	}
	// only the parameters the chosen source actually reads — the same fields gen_from_cfg maps
	pw := unsafe { &app.senders[i].sender.signals[j].wave }
	mut fields := [][]string{}
	match w.typ {
		'const' { fields = [['value', 'value']] }
		'sine' { fields = [['offset', 'offset'], ['amplitude', 'amplitude'], ['freq (rad/s)', 'freq'],
			['phase', 'phase']] }
		'sawtooth' { fields = [['min', 'min'], ['max', 'max'], ['period (s)', 'period']] }
		'counter' { fields = [['start', 'start'], ['step', 'step'], ['modulo', 'modulo']] }
		'stepmod' { fields = [['period (s)', 'period'], ['count', 'count'], ['base', 'base']] }
		else {}
	}
	// TWO PER LINE, on their own rows under the signal. Sine alone has four parameters, and
	// trailing them all off the value row ran them past the panel's right edge where a narrow
	// dock clipped them out of reach.
	for k, f in fields {
		if k % 2 == 1 {
			vgui.same_line()
		}
		vgui.set_next_item_width(70 * app.ui_scale)
		// A COPY, written back through a locked setter. Writing through a pointer into the live
		// sender raced the fire path's snapshot (the GUI thread edits while gen_loop clones), and
		// left a value the Start-time check could never see — these fields stay editable during a
		// run, so an edit that makes the source unusable has to say so when it is made.
		mut cur := wave_param(w, f[1])
		if vgui.input_double('${f[0]}##wv${i}_${j}_${f[1]}', &cur) {
			app.set_wave_param(i, j, f[1], cur)
		}
	}
}

// wave_param reads one named parameter of a value source.
fn wave_param(g project.GenCfg, field string) f64 {
	return match field {
		'value' { g.value }
		'offset' { g.offset }
		'amplitude' { g.amplitude }
		'freq' { g.freq }
		'phase' { g.phase }
		'min' { g.min }
		'max' { g.max }
		'period' { g.period }
		'start' { g.start }
		'step' { g.step }
		'modulo' { g.modulo }
		'count' { g.count }
		'base' { g.base }
		else { f64(0) }
	}
}

// set_wave_param writes one parameter under app.mu (the fire path clones the sender under it) and
// says immediately when the edit leaves the source unusable — the Start-time warning has already
// run by then, and silently falling back to the static value is the thing this PR is trying not
// to do. notify() re-takes the non-reentrant mutex, so it is called after the unlock.
fn (mut app App) set_wave_param(i int, j int, field string, v f64) {
	mut why := ''
	app.mu.lock()
	if i < app.senders.len && j < app.senders[i].sender.signals.len {
		mut w := &app.senders[i].sender.signals[j].wave
		match field {
			'value' { w.value = v }
			'offset' { w.offset = v }
			'amplitude' { w.amplitude = v }
			'freq' { w.freq = v }
			'phase' { w.phase = v }
			'min' { w.min = v }
			'max' { w.max = v }
			'period' { w.period = v }
			'start' { w.start = v }
			'step' { w.step = v }
			'modulo' { w.modulo = v }
			'count' { w.count = v }
			'base' { w.base = v }
			else {}
		}
		why = project.gen_source_invalid(*w)
	}
	app.mu.unlock()
	app.dirty = true
	if why != '' {
		app.notify('generator signal: ${why} — sending its static value instead')
	}
}

fn (mut app App) set_wave_typ(i int, j int, typ string) {
	app.mu.lock()
	if i < app.senders.len && j < app.senders[i].sender.signals.len {
		mut sg := &app.senders[i].sender.signals[j]
		sg.wave.typ = typ
		// Seed a new source from what the signal already sends, so picking a waveform starts
		// AT the current value rather than snapping to zero: a const takes it outright, a sine
		// centres on it, a sawtooth spans up to it.
		if typ == 'const' && sg.wave.value == 0 {
			sg.wave.value = sg.value
		} else if typ == 'sine' && sg.wave.offset == 0 && sg.wave.amplitude == 0 {
			sg.wave.offset = sg.value
			sg.wave.freq = 1.0
		} else if typ == 'sawtooth' && sg.wave.max == 0 {
			sg.wave.max = sg.value
			sg.wave.period = 1.0
		} else if typ == 'stepmod' && sg.wave.count == 0 {
			sg.wave.count = 4
			sg.wave.period = 1.0
		}
		if sg.wave.step == 0 {
			sg.wave.step = 1.0
		}
	}
	app.mu.unlock()
	app.dirty = true
}

fn (mut app App) set_trigger(i int, t string) {
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.trigger = t
		if t == 'cyclic' && app.senders[i].sender.cycle_ms <= 0 {
			app.senders[i].sender.cycle_ms = 100
		}
	}
	app.mu.unlock()
}

fn (mut app App) set_cycle(i int, ms int) {
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.cycle_ms = ms
	}
	app.mu.unlock()
}

// set_sender_bus points generator `i` at a target bus ('' = its own channel). A newly
// targeted bus is opened if the measurement is running and it isn't open yet.
// `bus` is an INTERFACE (project.Sender.bus is documented as one, and '' means the sender's own
// channel); `chan_name` is the channel the user actually picked. They are different facts, and
// only the second one survives two channels sharing a wire — an interface cannot say which of
// them the generator now belongs to.
fn (mut app App) set_sender_bus(i int, bus string, chan_name string) {
	// a failure found while app.mu is held is said AFTER the unlock — notify re-takes the
	// non-reentrant mutex, and an inline call here would deadlock the GUI thread
	mut want_tgt := ''
	mut want_own := ''
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.bus = bus
		tgt := app.senders[i].target()
		if chan_name != '' {
			app.senders[i].chan = chan_name
		}
		own := app.senders[i].chan
		if app.running && tgt != '' && tx_bus_key(own, tgt) !in app.tx_buses {
			// NOT HERE: this is the GUI thread with app.mu held, and a CANsub tap open is
			// seconds. Opened on a worker and filed under the lock when it comes up — the
			// same rule as Start's (open_taps_for_run), for the same freeze (2026-08-29).
			want_tgt = tgt
			want_own = own
		}
	}
	app.mu.unlock()
	if want_tgt != '' {
		app.spawn_tap_for(want_own, want_tgt)
	}
}

// fire_index sends generator `i`'s CURRENT (edited) frame once. DBC-message generators
// encode the edited signal values; raw generators use the edited id/data hex fields.
// poll_hotkeys fires any 'key'-triggered generator whose key went down this frame. Runs on the
// UI thread once per frame (fire_index reads UI-thread edit buffers).
//
// Suppressed while a widget holds the keyboard, which takes BOTH tests. want_text_input covers
// an editable field; it is set only for editable ones (imgui gates it on !is_readonly), so a
// READ-ONLY console the user has clicked into does not raise it -- and key_pressed asks whether
// the bare key went down, ignoring modifiers. Since net#153 those consoles carry the Log, Flash,
// Diagnostics and Script panels and say "Ctrl+A / Ctrl+C" on screen, so with the Log docked by
// default and a generator bound to `a` or `c`, following that instruction during a run would
// have put a frame on the wire. any_item_active closes it.
fn (mut app App) poll_hotkeys() {
	// AND NOT WHILE CTRL IS HELD: a generator bound to `s` would fire on Ctrl+S an instant before
	// the save it was meant to be — a frame on the wire for pressing Save (codex round 1 on
	// #250). A chord is a command, never a hotkey.
	if !app.running || vgui.want_text_input() || vgui.any_item_active() || vgui.key_ctrl() {
		return
	}
	for i, sr in app.senders {
		s := sr.sender
		if s.trigger != 'key' || s.key == '' {
			continue
		}
		if vgui.key_pressed(s.key[0]) {
			app.fire_index(i)
		}
	}
}

// sender_value resolves one generator signal to the number that goes on the wire: its waveform
// evaluated at the run clock when it has one, else its static value. The counter/stepmod sources
// step per SEND, so each generator keeps its own send count (the simulated-ECU side counts the
// same way with SimMessage.send_n).
// sender_value resolves one signal of an ALREADY-SNAPSHOTTED sender: pure, so the caller holds no
// lock while encoding. `n` is the index reserved for this fire and `t0_ns` the run epoch.
fn sender_value(ss project.SenderSig, n int, el f64) f64 {
	if ss.wave.typ == '' {
		return ss.value
	}
	// An unusable source (unknown type, zero divisor) sends the STATIC value rather than a
	// constant nobody asked for or a non-finite number packed into raw bits. The condition is
	// also reported by project.generator_source_warnings, so it is said, not just survived.
	if project.gen_source_invalid(ss.wave) != '' {
		return ss.value
	}
	return sim.gen_from_cfg(ss.wave).value(el, n)
}


fn (mut app App) fire_index(i int) {
	// ONE FIRE AT A TIME PER GENERATOR, start to finish: reserving an index and rolling it back
	// could not keep the count equal to DELIVERED frames when two fires finished out of order.
	// A flag rather than a held lock, because the send must not be inside one — a generator
	// stalled in its driver's write would otherwise block every other generator's fire, and a
	// stalled write must cost its sender alone. A tick that finds its own generator still firing
	// is skipped: its previous frame has not left the wire, so there is nothing to overlap.
	app.mu.lock()
	if i < 0 || i >= app.senders.len {
		app.mu.unlock()
		return
	}
	if app.gen_firing[i] {
		app.mu.unlock()
		return
	}
	app.gen_firing[i] = true
	defer {
		app.mu.lock()
		app.gen_firing.delete(i)
		app.mu.unlock()
	}
	s := project.Sender{
		...app.senders[i].sender
		signals: app.senders[i].sender.signals.clone()
	}
	n := app.gen_send_n[i] or { 0 }
	epoch := app.gen_state_epoch
	wt0 := app.wave_t0_ns
	app.mu.unlock()
	// ONE clock sample for the whole frame. Read per signal, two time-based sources in one message
	// were sampled at different instants — the simulator passes a single `t` into its build() for
	// the same reason. FROM THE RUN EPOCH, not process start, so a restarted measurement begins at
	// the same phase instead of one that depends on how long the GUI had been open.
	el := if wt0 > 0 { f64(time.sys_mono_now() - wt0) / 1_000_000_000.0 } else { 0.0 }
	mut id := s.id
	mut ext := s.ext
	mut data := []u8{}
	if s.message != '' {
		mut found := false
		// resolve the message on the generator's own target bus (not globally)
		for db in app.dbs_for(app.senders[i].target()) {
			for m in db.messages {
				if m.name != s.message {
					continue
				}
				id = m.id
				ext = m.ext
				data = []u8{len: m.dlc}
				for ss in s.signals {
					for sig in m.signals {
						if sig.name == ss.name {
							// The value SOURCE, evaluated at send time: a waveform sweeps
							// (sine/sawtooth/counter/stepmod), no source sends the static value.
							// Same GenCfg vocabulary and the same evaluator a simulated ECU uses
							// — only the identity differs (this is the tester, so TX not TX-S).
							sig.encode(mut data, sender_value(ss, n, el))
							break
						}
					}
				}
				found = true
				break
			}
			if found {
				break
			}
		}
		if !found {
			app.notify('generator: message "${s.message}" not in any DBC')
			return
		}
	} else if i < app.gen_bufs.len {
		id = u32(('0x' + vgui.buf_str(app.gen_bufs[i].id_buf)).u64())
		data = parse_hex_bytes(vgui.buf_str(app.gen_bufs[i].data_buf))
	}
	if app.tx_on_chan(app.senders[i].chan, app.senders[i].target(), transport.CanFrame{
		id:       id
		extended: ext
		data:     data
	}) {
		// delivered frames only — a fire refused while the tap is still opening put nothing on
		// the bus, and counting it would make the sequence lie about what was transmitted.
		// ...and only onto the generator set this fire was snapshotted from: a removal or a new
		// run since would have shifted or cleared the counts, and this write would land on
		// whichever generator now sits at this index.
		app.mu.lock()
		if app.gen_state_epoch == epoch {
			app.gen_send_n[i] = n + 1
		}
		app.mu.unlock()
	}
}
