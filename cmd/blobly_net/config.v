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

// close_chan_picker closes the file browser when its pending action is bound to a channel
// INDEX ('dbc:<ci>' / 'manifest:<ci>' / 'replaysrc:<ci>'). Called wherever indices shift or
// the channel set is replaced — a picker opened for slot 3 must not deliver its file to
// whatever channel slides into slot 3, nor to a slot that no longer exists (codex #133 r5,
// found on replaysrc; the class is every index-bound target). The index is the only identity
// a pending target has: channel names are user-editable and need not be unique, so closing
// the stale picker is the honest move, not re-resolving it.
fn (mut app App) close_chan_picker() {
	t := app.fb_target
	if t.starts_with('dbc:') || t.starts_with('manifest:') || t.starts_with('replaysrc:') {
		app.fb_open = false
	}
}

// drop_replay_scans throws away Scan results. They are keyed by channel INDEX, exactly like a
// pending picker's target, and go stale at exactly the events close_chan_picker fires on — the
// two are called together at every such site.
fn (mut app App) drop_replay_scans() {
	app.mu.lock()
	app.replay_scans.clear()
	app.mu.unlock()
}

fn (mut app App) remove_bus(i int) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	app.close_chan_picker()
	app.drop_replay_scans()
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
		// AND TAKE IT BACK when the row stops being a Vector one. Setting the flag above and
		// never clearing it left the editor showing "never transmit (no ACKs)" on a PCAN or
		// SocketCAN row, where `,silent` does not exist and the transceiver acknowledges
		// everything it hears — the safety promise this default exists to make, made by a
		// backend that cannot keep it. Of the two ways to be wrong, an operator who can SEE
		// the channel is not listen-only is better off than one who believes it is.
		app.proj.channels[i].listen_only = false
		app.notify('${app.proj.channels[i].name}: listen-only cleared — ${a} cannot silence the transceiver, only Vector can')
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
	app.proj.channels[i].mode = project.mode_from(md)
	app.dirty = true
	app.rebuild_preserving_senders()
}

fn (mut app App) add_dbc(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
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

// set_replay_source points a replay channel at a recording, FROM THE MODEL SIDE: the value
// lands in app.proj (dirty set), so Save writes it into the .blobnet — the Replay panel's
// Browse is a project edit, not a runtime one. The spread carries `bus:`/`exclude:` for the
// same reason commit_cfg's does: rebuilding the struct from the one field on offer deleted
// the keys only the file can express. Rebuild PRESERVING senders, like every other stopped
// mutation here — rebuild_from_proj would reconstruct the generators from the still-stale
// proj and drop unsaved Generators-panel edits (codex #133 r3).
fn (mut app App) set_replay_source(ci int, path string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	old := app.proj.channels[ci].replay or { project.Replay{} }
	app.proj.channels[ci].replay = project.Replay{
		...old
		source: rel_path(path)
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

// set_replay_bus and set_replay_exclude write the two Replay keys the structured editor
// could not touch before the Scan existed to populate them: WHICH recorded bus feeds the
// channel, and which nodes are withheld for a rest bus. Same shape as set_replay_source —
// commit the buffered edits, spread the rest, mark dirty; Save persists to the .blobnet.
fn (mut app App) set_replay_bus(ci int, bus string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	old := app.proj.channels[ci].replay or { project.Replay{} }
	app.proj.channels[ci].replay = project.Replay{
		...old
		bus: bus
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

fn (mut app App) set_replay_exclude(ci int, exclude []string) {
	if ci < 0 || ci >= app.proj.channels.len {
		return
	}
	app.commit_cfg()
	old := app.proj.channels[ci].replay or { project.Replay{} }
	app.proj.channels[ci].replay = project.Replay{
		...old
		exclude: exclude.clone()
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
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
	app.close_chan_picker() // a pending dbc/manifest/replaysrc picker indexes the OLD channel set
	app.drop_replay_scans()
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
