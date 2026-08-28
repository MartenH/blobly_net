module main

import math
import project
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
		vgui.same_line()
	}
	vgui.set_next_item_width(70 * app.ui_scale)
	vgui.input_text('id (hex)', mut app.send_id_buf)
	vgui.same_line()
	vgui.set_next_item_width(200 * app.ui_scale)
	vgui.input_text('data (hex)', mut app.send_data_buf)
	vgui.same_line()
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
		vgui.text_dim('start to send')
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
	if app.running && iface != '' && tx_bus_key(cname, iface) !in app.tx_buses {
		if b := app.open_tap_on(iface, org_tx, cname) {
			// the OPEN runs unlocked (a vendor open can block ~2s), the INSERT re-takes the
			// lock: a cyclic generator may be inside tx_on_chan's locked lookup of this very
			// map, and a V map is not safe for a concurrent read and write (the invariant
			// tx_on_chan documents; this site was the one sibling violating it)
			app.mu.lock()
			if tx_bus_key(cname, iface) !in app.tx_buses {
				app.tx_buses[tx_bus_key(cname, iface)] = b
			}
			app.mu.unlock()
		} else {
			// a generator added mid-run onto a bus that will not open must not just
			// quietly never fire
			app.notify('${cname}: generator transmit tap failed to open — ${err}')
		}
	}
}

// remove_generator drops generator `i` from the session.
fn (mut app App) remove_generator(i int) {
	app.mu.lock()
	if i >= 0 && i < app.senders.len {
		app.senders.delete(i)
		if i < app.gen_bufs.len {
			app.gen_bufs.delete(i)
		}
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
					mut v := f64(0)
					for o in old {
						if o.name == sig.name {
							v = o.value
							break
						}
					}
					sigs << project.SenderSig{
						name:  sig.name
						value: v
					}
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
	mut tap_err := ''
	app.mu.lock()
	if i < app.senders.len {
		app.senders[i].sender.bus = bus
		tgt := app.senders[i].target()
		if chan_name != '' {
			app.senders[i].chan = chan_name
		}
		own := app.senders[i].chan
		if app.running && tgt != '' && tx_bus_key(own, tgt) !in app.tx_buses {
			if b := app.open_tap_on(tgt, org_tx, own) {
				app.tx_buses[tx_bus_key(own, tgt)] = b
			} else {
				tap_err = '${own}: generator transmit tap failed to open — ${err}'
			}
		}
	}
	app.mu.unlock()
	if tap_err != '' {
		app.notify(tap_err)
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
	if !app.running || vgui.want_text_input() || vgui.any_item_active() {
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

fn (mut app App) fire_index(i int) {
	if i < 0 || i >= app.senders.len {
		return
	}
	s := app.senders[i].sender
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
							sig.encode(mut data, ss.value)
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
	app.tx_on_chan(app.senders[i].chan, app.senders[i].target(), transport.CanFrame{
		id:       id
		extended: ext
		data:     data
	})
}
