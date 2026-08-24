module main

import os
import project
import sysview
import sim
import vgui

// rel_path makes an absolute path relative to the cwd when it lives under it, so a saved
// project references e.g. `dbc/foo.dbc` rather than an absolute machine-specific path.
// Separators are normalized to `/` first, so it also works for the file browser's
// backslash paths on Windows (and the stored `.blobnet` path stays portable).
fn rel_path(p string) string {
	np := p.replace('\\', '/')
	cwd := os.getwd().replace('\\', '/')
	if np.starts_with(cwd + '/') {
		return np[cwd.len + 1..]
	}
	return np
}

// parse_u16_hex reads a 16-bit address ("0x"-hex or bare hex). Any malformed input — empty,
// a bare "0x", a non-hex character, or a value above 16 bits — returns `deflt` (the previous
// value) rather than silently accepting a wrong address like 0x0000.
fn parse_u16_hex(s string, deflt u16) u16 {
	mut t := s.trim_space().trim('"')
	if t.starts_with('0x') || t.starts_with('0X') {
		t = t[2..]
	}
	if t == '' {
		return deflt
	}
	mut v := u32(0)
	for c in t {
		d := if c >= `0` && c <= `9` {
			u32(c - `0`)
		} else if c >= `a` && c <= `f` {
			u32(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			u32(c - `A`) + 10
		} else {
			return deflt // non-hex character — keep the previous value
		}
		v = v * 16 + d
		if v > 0xFFFF {
			return deflt // out of 16-bit range — keep the previous value
		}
	}
	return u16(v)
}

// sync_cfg_bufs rebuilds the per-bus edit buffers to parallel app.proj.channels (on open,
// and after add/remove bus/DBC).
fn (mut app App) sync_cfg_bufs() {
	app.cfg_bufs = []
	for ch in app.proj.channels {
		mut rsrc := ''
		mut rspeed := '1'
		if r := ch.replay {
			rsrc = r.source
			rspeed = '${r.speed}'
		}
		app.cfg_bufs << CfgBuf{
			name_buf:         mkbuf(ch.name, 48)
			network_buf:      mkbuf(ch.network, 48)
			address_buf:      mkbuf(ch.address, 64)
			bitrate_buf:      mkbuf('${ch.bitrate}', 12)
			dbitrate_buf:     mkbuf(if ch.data_bitrate > 0 { '${ch.data_bitrate}' } else { '' },
				12)
			manifest_buf:     mkbuf(ch.manifest, 128)
			dbc_buf:          mkbuf('', 128)
			tester_buf:       mkbuf('0x${ch.tester_addr:X}', 12)
			ecu_buf:          mkbuf('0x${ch.ecu_addr:X}', 12)
			vin_buf:          mkbuf(ch.vin, 20)
			replay_src_buf:   mkbuf(rsrc, 128)
			replay_speed_buf: mkbuf(rspeed, 12)
		}
	}
}

// commit_cfg flushes all bus edit buffers into app.proj (called before Save and before any
// structural change so edits aren't lost). No-op if the buffers are out of sync.
fn (mut app App) commit_cfg() {
	if app.cfg_bufs.len != app.proj.channels.len {
		return
	}
	// REBUILT WHOLESALE each time, not appended to: a field corrected since the last commit must
	// stop blocking Start, and a stale entry would wedge the run forever.
	app.cfg_invalid = []
	for i in 0 .. app.proj.channels.len {
		b := app.cfg_bufs[i]
		mut ch := &app.proj.channels[i]
		ch.name = vgui.buf_str(b.name_buf)
		ch.network = vgui.buf_str(b.network_buf)
		ch.address = vgui.buf_str(b.address_buf)
		ch.iface = project.compose_iface(ch.adapter, ch.address)
		ch.manifest = vgui.buf_str(b.manifest_buf)
		br := vgui.buf_str(b.bitrate_buf).int()
		if br > 0 {
			ch.bitrate = br
		}
		// EMPTY IS A VALUE HERE, unlike the nominal rate above, which keeps its old figure rather
		// than accepting a zero. Clearing this field deliberately says "no separate data phase",
		// so it must write 0 — skipped, the previous rate would survive the edit that removed it,
		// and the channel would go on opening with a data phase the dialog no longer shows.
		//
		// DIGITS OR NOTHING otherwise, the same rule transport.vendor_bitrate applies to the address — and
		// the reason it exists there is this exact coercion. V's `.int()` takes a numeric prefix,
		// so `2000000oops` became 2000000 and a wholly non-numeric entry became 0, which then
		// selected the nominal-rate fallback: either way the channel opened with a data phase the
		// operator had not typed, and a Save wrote that number into the project as though it had
		// been chosen. A permissive copy of a rule the engine made strict is the drift this repo
		// keeps paying for (codex #181 r2).
		//
		// A REJECTED VALUE LEAVES THE MODEL ALONE rather than resetting it to 0. Committing runs
		// on every structural change and before every Save, so zeroing here would quietly discard
		// a good stored rate the moment the buffer held a typo mid-edit.
		dbr_txt := vgui.buf_str(b.dbitrate_buf).trim_space()
		if dbr_txt == '' {
			ch.data_bitrate = 0
		} else if project.is_all_digits(dbr_txt) && dbr_txt.int() > 0 {
			ch.data_bitrate = dbr_txt.int()
		} else {
			app.notify('${ch.name}: "${dbr_txt}" is not a data bitrate — digits only, in bits per second; keeping ${ch.data_bitrate}')
			// RECORDED, not only announced. The model keeps its previous rate, so without this the
			// editor shows one thing and the run uses another with nothing to stop it.
			app.cfg_invalid << '${ch.name}: data rate "${dbr_txt}"'
		}
		if ch.adapter == 'doip' {
			ch.tester_addr = parse_u16_hex(vgui.buf_str(b.tester_buf), ch.tester_addr)
			ch.ecu_addr = parse_u16_hex(vgui.buf_str(b.ecu_buf), ch.ecu_addr)
			vin := vgui.buf_str(b.vin_buf)
			if vin == '' || vin.len == 17 {
				ch.vin = vin
			}
		}
		if ch.mode == .replay {
			spd := vgui.buf_str(b.replay_speed_buf).f64()
			// Rebuilt from the buffers the editor HAS, carrying over the keys it does not: the
			// dialog offers source/speed/loop, while `bus:` and `exclude:` are typed into the
			// file. Reconstructing the struct from the widgets alone deleted them on every Save
			// — after which a multi-bus recording fails to resolve and the ECU under test is no
			// longer subtracted, with nothing on screen having changed.
			old := ch.replay or { project.Replay{} }
			ch.replay = project.Replay{
				...old
				source: vgui.buf_str(b.replay_src_buf)
				speed:  if spd > 0 { spd } else { 1.0 }
			}
		}
	}
}

// add_bus appends a default driver-free virtual bus (the from-scratch building block).
fn (mut app App) add_bus() {
	n := app.proj.channels.len + 1
	app.add_bus_spec('virtual', 'CAN${n}')
}

// add_bus_spec appends a bus for a specific adapter+address (used by + Add bus, the Discover
// dialog's Add-ticked, and the quick-add buttons). The name defaults to the address.
fn (mut app App) add_bus_spec(adapter string, address string) {
	app.commit_cfg()
	base := if address != '' { address } else { adapter }
	app.proj.channels << project.Channel{
		name:    app.unique_bus_name(base)
		adapter: adapter
		address: address
		iface:   project.compose_iface(adapter, address)
		typ:     'can'
		mode:    .monitor
		// LISTEN-ONLY UNTIL SOMEBODY SAYS OTHERWISE, on Vector. Every other adapter here is a
		// virtual bus or one whose driver cannot be told to stay quiet, but a VN channel added
		// from Discover is hardware that may already be wired to a running vehicle — and it
		// arrives with the 500 kbit/s default, which nobody has confirmed. Going on that bus
		// able to acknowledge, at a rate that is a guess, is how a tester disturbs the thing it
		// came to observe. Untick it in the editor once the rate is known.
		listen_only: adapter == 'vector'
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// unique_bus_name returns `base`, or base_2/base_3/… if the name is already taken.
fn (app &App) unique_bus_name(base string) string {
	mut name := base
	mut n := 2
	for {
		mut taken := false
		for c in app.proj.channels {
			if c.name == name {
				taken = true
				break
			}
		}
		if !taken {
			return name
		}
		name = '${base}_${n}'
		n++
	}
	return base
}

// refresh_discovery re-scans the machine's transports for the Discover dialog.
fn (mut app App) refresh_discovery() {
	app.disc_list = app.discover_all()
	app.disc_tick = []bool{len: app.disc_list.len}
}

// next_free_vcan returns the first vcanN not already in the project (for the + vcan quick-add).
fn (app &App) next_free_vcan() string {
	for n in 0 .. 32 {
		addr := 'vcan${n}'
		if !app.iface_added('vcan', addr) {
			return addr
		}
	}
	return 'vcan0'
}

// drop_index_bound_ui invalidates everything whose identity is a channel INDEX: a pending
// file-picker action, and the Scan results the Configure replay row displays. Called at every
// event that shifts indices or replaces the channel set — a picker opened for slot 3 must not
// deliver its file to whatever channel slides into slot 3, nor to a slot that no longer exists
// (codex #133 r5, found on replaysrc; the class is every index-bound target). The index is the
// only identity a pending target has (channel names are user-editable and need not be unique),
// so the stale state is dropped, not re-resolved — and the two invalidations live in ONE
// function because a site that remembers one and forgets the other is how the class returns.
// Channel-bound picker targets are exactly the ones carrying ':<ci>'; the project-level
// targets (open/saveas/recording/flash/system) have no colon.
fn (mut app App) drop_index_bound_ui() {
	if app.fb_target.contains(':') {
		app.fb_open = false
	}
	app.mu.lock()
	app.replay_scans.clear()
	app.mu.unlock()
}

// drop_replay_scan forgets ONE channel's Scan: its source or its databases changed, so the
// buses and census on display describe a file or an attribution that is no longer the row's.
fn (mut app App) drop_replay_scan(ci int) {
	app.mu.lock()
	app.replay_scans.delete(ci)
	app.mu.unlock()
}

fn (mut app App) remove_bus(i int) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	app.drop_index_bound_ui()
	app.commit_cfg()
	removed_iface := app.proj.channels[i].iface
	app.proj.channels.delete(i)
	// drop generator bus-overrides that pointed at the removed bus, so start() won't reopen and
	// transmit on an interface that's no longer configured (they fall back to their own channel).
	for si in 0 .. app.senders.len {
		if app.senders[si].sender.bus == removed_iface {
			app.senders[si].sender.bus = ''
		}
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// set_adapter changes a bus's transport backend, recomposing its iface and keeping the
// can/doip protocol coherent.
fn (mut app App) set_adapter(i int, a string) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	old_iface := app.proj.channels[i].iface
	was := app.proj.channels[i].adapter
	app.proj.channels[i].adapter = a
	// SILENT BY DEFAULT when a bus BECOMES a Vector one, for the same reason a discovered
	// Vector channel starts that way: it is hardware that may already be wired to a running
	// vehicle, arriving with a 500 kbit/s guess nobody has confirmed. Exposing the adapter in
	// the picker without this made the manual route the unsafe one while Discover was careful.
	if a == 'vector' && was != 'vector' {
		app.proj.channels[i].listen_only = true
	} else if was == 'vector' && a != 'vector' && app.proj.channels[i].listen_only {
		// KEPT NOW, and said out loud. This used to CLEAR the flag: `,silent` reaches only the
		// Vector transceiver, so on any other backend the tick promised "no ACKs" that nothing
		// delivered, and clearing it was the honest half of a bad choice. Since #117 the flag
		// stops every emitter in this process on every backend, so most of what it says is true
		// everywhere -- and silently clearing a safety tick is the worse direction to be wrong
		// in. What actually changes with the adapter is the transceiver, so that is what the
		// message is now about.
		app.notify('${app.proj.channels[i].name}: still listen-only — nothing here will transmit, but ${a} cannot silence the transceiver, so it still ACKs (only Vector can)')
	}
	if a == 'doip' {
		app.proj.channels[i].typ = 'doip'
	} else if app.proj.channels[i].typ == 'doip' {
		app.proj.channels[i].typ = 'can'
	}
	app.proj.channels[i].iface = project.compose_iface(a, vgui.buf_str(app.cfg_bufs[i].address_buf))
	app.rebind_senders(old_iface, app.proj.channels[i].iface) // keep this bus's generators bound
	app.dirty = true
	app.rebuild_preserving_senders()
}

// rebuild_preserving_senders folds unsaved Generators-panel edits (gen_bufs id/data) into
// app.proj before rebuilding the runtime view — so a structural config change (add/remove
// bus/DBC, adapter/mode) doesn't discard them when rebuild_from_proj repopulates senders from
// the model. Use this instead of rebuild_from_proj for edits made while the editor is open.
fn (mut app App) rebuild_preserving_senders() {
	app.sync_senders_into_proj()
	app.rebuild_from_proj()
}

// rebind_senders repoints a channel's flattened generators from an old iface to a new one, so
// editing a bus address doesn't orphan them: sync_senders_into_proj groups senders by iface
// (and firing opens tx_buses[iface]), so a stale SenderRT.iface would drop all of a renamed
// bus's generators on the next Save/Start. Also follows explicit per-sender bus overrides.
fn (mut app App) rebind_senders(old_iface string, new_iface string) {
	if old_iface == new_iface || old_iface == '' {
		return
	}
	for si in 0 .. app.senders.len {
		if app.senders[si].iface == old_iface {
			app.senders[si].iface = new_iface
		}
		if app.senders[si].sender.bus == old_iface {
			app.senders[si].sender.bus = new_iface
		}
	}
}

fn (mut app App) set_protocol(i int, pr string) {
	app.proj.channels[i].typ = pr
	app.proj.channels[i].fd = pr == 'canfd'
	app.dirty = true
}

fn (mut app App) set_mode(i int, md string) {
	// indices do not shift, but a mode change repurposes what a pending picker or a Scan for
	// this slot MEANS — a Browse confirmed after the switch would write a replay: block onto
	// a monitor channel (update_replay refuses that too; this closes the door it knocks on)
	app.drop_index_bound_ui()
	app.proj.channels[i].mode = project.mode_from(md)
	app.dirty = true
	app.rebuild_preserving_senders()
}

fn (mut app App) add_dbc(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.drop_replay_scan(ci) // the census on display was attributed through the OLD databases
	app.commit_cfg()
	app.proj.channels[ci].databases << rel_path(path)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

fn (mut app App) remove_dbc(ci int, di int) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	if di < 0 || di >= app.proj.channels[ci].databases.len {
		return
	}
	app.drop_replay_scan(ci) // the census on display was attributed through the OLD databases
	app.commit_cfg()
	app.proj.channels[ci].databases.delete(di)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

fn (mut app App) set_manifest(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	app.proj.channels[ci].manifest = rel_path(path)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// update_replay is the ONE mutation frame for a channel's Replay struct — the sequence IS
// the invariant: commit the buffered edits (so the spread the callers build starts from what
// the user typed, not a stale model), write, dirty, sync, rebuild PRESERVING senders. Codex
// #133 r3 caught the one copy of this frame that said rebuild_from_proj and silently dropped
// unsaved generator edits; one copy means one place for that class to exist. The mode guard
// covers the non-modal picker: a Browse confirmed after the channel was switched away from
// replay must not write a replay: block onto a monitor channel.
fn (mut app App) update_replay(ci int, f fn (project.Replay) project.Replay) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	if app.proj.channels[ci].mode != .replay {
		return
	}
	app.commit_cfg()
	old := app.proj.channels[ci].replay or { project.Replay{} }
	app.proj.channels[ci].replay = f(old)
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// The three Replay keys the GUI writes, each a one-field spread over update_replay — the
// spread carries the keys only the .blobnet can express, the same reason commit_cfg's does.
// All of it lands in app.proj with dirty set, so Save writes the .blobnet: these are project
// edits, not runtime ones.
fn (mut app App) set_replay_source(ci int, path string) {
	rel := rel_path(path)
	app.update_replay(ci, fn [rel] (old project.Replay) project.Replay {
		return project.Replay{
			...old
			source: rel
		}
	})
	// the census on display was taken through the OLD source — forget it
	app.drop_replay_scan(ci)
}

fn (mut app App) set_replay_bus(ci int, bus string) {
	app.update_replay(ci, fn [bus] (old project.Replay) project.Replay {
		return project.Replay{
			...old
			bus: bus
		}
	})
}

fn (mut app App) set_replay_exclude(ci int, exclude []string) {
	ex := exclude.clone()
	app.update_replay(ci, fn [ex] (old project.Replay) project.Replay {
		return project.Replay{
			...old
			exclude: ex.clone()
		}
	})
}

// set_chan_enabled_stopped is the Replay panel's enable tick: a PROJECT edit (dirty — Save
// persists it) that also moves the runtime row, so Start needs no intervening apply. This is
// deliberately NOT the Buses panel's tick, which is runtime-only and does not survive Save,
// and not the Configure header's, which edits the model alone and reaches the runtime through
// apply_edits — three surfaces with three intents; this one's is named here and single-sited.
fn (mut app App) set_chan_enabled_stopped(ci int, en bool) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.mu.lock()
	if ci < app.chans.len {
		app.chans[ci].enabled = en
	}
	app.proj.channels[ci].enabled = en
	// chans[].enabled moved, so the wire list has to move with it -- the marks are consulted per
	// send, and a script that outlived Stop is holding a bus that will ask.
	app.push_listen_only_locked()
	app.mu.unlock()
	app.dirty = true
	app.replay_view_gen++ // the tick changes which members of a replay group will PLAY
}

// save_project writes the whole project to its file (config + generators). An unsaved
// project (no path) routes to Save As. Reformats the .blobnet — comments are not preserved.
// load_cfg_text reads the project file into the edit buffer.
//
// Only when the buffer does not already hold this path: re-reading on every frame — or every
// tab switch — would throw away whatever the user had typed.
fn (mut app App) load_cfg_text() {
	// Cached. The File tab calls this every render, so re-reading whenever the buffer was
	// clean meant a synchronous file read and a 64 KiB allocation at frame rate. Freshness
	// comes from EXPLICIT invalidation instead — cfg_invalidate() at every path that rewrites
	// or replaces the project — which is also the only way to be right about a file changed
	// by something other than us.
	if app.cfg_loaded == app.proj_path && app.proj_path != '' {
		return
	}
	if app.proj_path == '' {
		app.cfg_text = mkbuf('', 4096)
		app.cfg_loaded = ''
		app.cfg_text_dirty = false
		app.cfg_err = 'no file yet — save the project once (File ▸ Save As), then edit it here'
		return
	}
	txt := os.read_file(app.proj_path) or {
		// Still allocate: draw_config_text renders the box regardless, and ImGui cannot be
		// handed a zero-capacity buffer.
		app.cfg_text = mkbuf('', 4096)
		// Mark it LOADED even though it failed: the tab calls this every frame, and leaving the
		// marker empty meant re-attempting the read and reallocating the buffer at frame rate
		// for as long as the file stayed missing. Reload and invalidation still retry.
		app.cfg_loaded = app.proj_path
		app.cfg_text_dirty = false
		app.cfg_chans = -1
		app.cfg_err = 'cannot read ${app.proj_path}: ${err}'
		return
	}
	// Generous headroom: ImGui writes into this buffer and cannot grow it, so the room to type
	// has to be reserved up front. The fill level is shown once it gets close.
	cap := if txt.len * 3 > 65536 { txt.len * 3 } else { 65536 }
	app.cfg_text = mkbuf(txt, cap)
	app.cfg_text_len = txt.len
	app.cfg_loaded = app.proj_path
	app.cfg_text_dirty = false
	// Validate what was just READ. Assuming a file on disk is well-formed made the status claim
	// "YAML well-formed · -1 channel(s)" for a file the very next Save would reject — the tool
	// disagreeing with itself about the bytes on screen.
	app.cfg_err = cfg_text_error(txt)
	app.cfg_chans = cfg_text_channels(txt)
}

// set_config_open is the ONE way the Configuration window is shown or hidden.
//
// Hiding it by any route that is not its own [X] means draw_config never runs again, so its
// close-time apply_edits() never fires and a half-typed bus field is resynced away from the old
// model when the window reopens. There were three such routes and the fix reached one of them,
// so they now share this.
fn (mut app App) set_config_open(open bool) {
	if open == app.show_config {
		return
	}
	if !open {
		if !app.running && app.dirty {
			app.apply_edits()
		}
		app.show_config = false
		return
	}
	app.show_config = true
	app.sync_cfg_bufs()
}

// cfg_invalidate drops the cached project text, so the File tab re-reads it next render.
// Called wherever the file or the active project changes underneath the editor.
fn (mut app App) cfg_invalidate() {
	app.cfg_loaded = ''
	app.cfg_text_dirty = false
}

// cfg_text_error returns why this text would not load, or '' if it parses.
//
// What this can and cannot promise, measured rather than assumed: `parse` rejects malformed
// YAML — unterminated flow collections, tab indentation — and nothing else. A file with no
// `project:` key, an unknown key, a channel with no name, or a non-numeric bitrate all parse
// happily, defaulting or ignoring. So this is a SYNTAX check, and the UI says so instead of
// claiming the configuration is valid.
fn cfg_text_error(txt string) string {
	p := project.parse(txt) or { return '${err}' }
	if !p.is_supported() {
		return p.version_note()
	}
	return ''
}

// cfg_text_channels reports how many channels the text yields — the number that tells a reader
// whether an edit did what they meant, and the one that catches the destructive case below.
fn cfg_text_channels(txt string) int {
	p := project.parse(txt) or { return -1 }
	return p.channels.len
}

// save_cfg_text writes the edit buffer back to the project file and reloads from it.
//
// The TEXT is written, not a re-serialisation of the parsed model: the model does not carry
// comments, and this file is where a bench setup explains itself.
fn (mut app App) save_cfg_text() {
	if app.dirty {
		// The mirror of the guard in save_project: applying this text would replace a model
		// that holds unsaved bus or generator edits.
		app.cfg_err = 'unsaved bus edits would be lost — save or discard them above first'
		app.notify('not saved — resolve the unsaved bus edits first')
		return
	}
	txt := vgui.buf_str(app.cfg_text)
	if e := non_empty(cfg_text_error(txt)) {
		app.cfg_err = e
		app.notify('not saved — ${e}')
		return
	}
	// Refuse the one edit that silently destroys work: a well-formed file that parses to no
	// channels at all, over a project that had some. Almost always a truncated buffer or a
	// mangled top level, never a thing anyone means to save.
	if cfg_text_channels(txt) == 0 && app.proj.channels.len > 0 {
		app.cfg_err = 'refused: this text yields no channels, which would empty the project — use Reload to get the file back'
		app.notify('not saved — it would empty the project')
		return
	}
	path := app.proj_path
	os.write_file(path, txt) or {
		app.notify('save failed: ${err}')
		return
	}
	app.notify('saved -> ${path}')
	app.dirty = false
	app.cfg_text_dirty = false
	// rebuild_from_proj, NOT load_project: the full open path calls set_project, which clears
	// the trace rows, grouped counts, telemetry records, diagnostic and script logs and signal
	// watches. Editing one config line while stopped must not throw away a captured session —
	// the structured Buses Save does not, and neither should this.
	app.apply_parsed_text(txt)
	app.load_cfg_text()
}

// apply_parsed_text folds already-validated project text into the model and rebuilds the
// runtime view, leaving the captured session alone.
fn (mut app App) apply_parsed_text(txt string) bool {
	p := project.parse(txt) or { return false }
	if !p.is_supported() {
		return false
	}
	// Injected faults are keyed by interface/node/message; a config edit can rename or remove
	// any of those, and a fault left pointing at the old names would apply to whatever now
	// occupies them.
	sim.clear_all()
	// The File tab replaces the channel set as thoroughly as loading a project does — the same
	// index-bound UI (pending picker, Scan results) goes stale with it. This was the one
	// replacement path the invalidation missed (self-review of the Scan work).
	app.drop_index_bound_ui()
	app.mu.lock()
	app.proj = p
	app.proj_name = p.name
	app.mu.unlock()
	app.cfg_bufs = [] // re-derived from the new channel list on the next Buses render
	app.rebuild_from_proj()
	return true
}

// revert_proj_from_disk throws away unsaved STRUCTURED edits by re-reading the file, without
// the session reset that load_project performs.
fn (mut app App) revert_proj_from_disk() {
	txt := os.read_file(app.proj_path) or {
		app.notify('cannot re-read ${app.proj_path}: ${err}')
		return
	}
	// Clear the flags only if the file actually replaced the model. Clearing them regardless
	// left the edited model live and looking clean, so a later save would persist changes the
	// user had been told were discarded.
	if !app.apply_parsed_text(txt) {
		app.notify('nothing discarded — ${app.proj_path} does not parse; fix it on the File tab')
		return
	}
	app.dirty = false
	app.cfg_invalidate()
	app.load_cfg_text()
	app.notify('unsaved model edits discarded (buses + generators)')
}

// non_empty is `?string` sugar: Some(s) when s is not empty.
fn non_empty(s string) ?string {
	return if s == '' { none } else { s }
}

fn (mut app App) save_project() {
	if app.proj_path == '' {
		app.open_browser('saveas')
		return
	}
	// The model and the file text are two representations of one project, and writing either
	// over the other loses work. Only one may be modified at a time, and that is enforced HERE
	// rather than in the File tab alone — the Buses Save button and File ▸ Save reach this
	// function without passing through any of that tab's controls.
	if app.cfg_text_dirty {
		app.notify('not saved — the Configuration ▸ File tab has unsaved text; save or revert it there first')
		app.show_config = true
		app.cfg_tab = 1
		return
	}
	app.apply_edits()
	// THE SAME REFUSAL AS START'S, and Save needs it more: writing the file would persist the
	// value the rejected field replaced, so a typo the operator can still see on screen becomes
	// a stored rate they never chose — and the evidence that anything was wrong is gone as soon
	// as the buffers are rebuilt from the saved model.
	if app.cfg_invalid.len > 0 {
		app.notify('not saved — ${app.cfg_invalid.join('; ')} (correct it in Configuration ▸ Buses, or clear the field)')
		app.show_config = true
		return
	}
	app.mu.lock()
	p := app.proj
	path := app.proj_path
	app.mu.unlock()
	p.save(path) or {
		app.notify('save failed: ${err}')
		return
	}
	app.dirty = false
	app.cfg_invalidate() // the file just changed under the File tab
	app.notify('saved -> ${path}')
}

// apply_edits folds pending editor state into app.proj so Start/Save act on exactly what the
// editor shows. While STOPPED it also rebuilds the runtime view; while RUNNING it only folds
// generator edits into the model for the file write and does NOT rebuild — rebuilding app.chans
// mid-measurement would reset the running flags / desync the live RX/gen threads and tx_buses
// (the config editor is stopped-only, so there are no live config edits to apply anyway).
fn (mut app App) apply_edits() {
	if app.running {
		app.sync_senders_into_proj() // generators may be edited live; persist them, don't rebuild
		return
	}
	app.commit_cfg() // Configuration-editor buffers -> app.proj (no-op if the editor never opened)
	app.sync_senders_into_proj() // session generators -> app.proj
	app.rebuild_from_proj() // rebuild app.chans/dbs/sims from the updated model
}

// save_as sets the path (from the browser) and saves.
fn (mut app App) save_as(path string) {
	// BEFORE the path moves. The centralised guard in save_project refuses the write, but by
	// then proj_path already names the new destination — so the next File render sees a cache
	// miss and replaces the unsaved buffer with that file's contents, or an empty error buffer
	// for a file that does not exist yet.
	if app.cfg_text_dirty {
		app.notify('not saved — the Configuration ▸ File tab has unsaved text; save or revert it there first')
		app.show_config = true
		app.cfg_tab = 1
		return
	}
	mut p := path
	if !p.ends_with('.blobnet') && !p.ends_with('.yml') && !p.ends_with('.yaml') {
		p += '.blobnet'
	}
	app.proj_path = p
	app.proj.name = app.proj_name
	app.save_project()
}

// new_project resets to a blank, unsaved project (0 buses) — the from-scratch entry point.
fn (mut app App) new_project() {
	app.drop_index_bound_ui() // pending pickers and Scan results index the OLD channel set
	app.stop()
	// A blank project inherits nothing: set_project bypasses load_project's reset, so without
	// this the System panel kept showing the PREVIOUS project's ECUs and annotated any newly
	// added channel from that stale model (codex #65 r5) — the same staleness fixed for the
	// load path in r3, in the one entry point it did not cover.
	app.sys = sysview.System{}
	app.sys_loaded = false
	app.sel_ecu = ''
	app.show_sys = false
	app.set_project(project.Project{ name: 'untitled' }, '')
	app.notify('new project — add buses in Configure…')
}
