module main

import candb
import os
import time
import genhome
import project
import saverule
import transport
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
	app.cfg_invalid = []
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
			dbitrate_buf:     mkbuf(if ch.data_bitrate > 0 { '${ch.data_bitrate}' } else { '' }, 12)
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
	// Captured BEFORE the buffers overwrite them, NAME AND INTERFACE both, because a commit can
	// change either and what an override means depends on both. Once the model holds the new
	// values there is nothing left to ask the old question of (#97).
	mut was_rows := []project.Channel{cap: app.proj.channels.len}
	for c in app.proj.channels {
		was_rows << project.Channel{
			name:  c.name
			iface: c.iface
		}
	}
	defer {
		app.rebind_sender_commit(was_rows)
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
		// THE SAME CONDITION THE PANEL DRAWS IT UNDER. A row switched from canfd back to can hides
		// this field, and validating it anyway blocked Start and Save on text the operator could
		// no longer see or reach without turning FD back on — a refusal with no visible cause,
		// which is worse than the silent coercion the validation replaced. The stale text is
		// dropped rather than kept, because a row with no data phase has nothing to remember it
		// for (codex #181 r6).
		if !(ch.fd && ch.can_carry_fd()) {
			// NOT `continue`: the DoIP and replay blocks below belong to this same row, and
			// skipping the rest of the body would drop their edits on any classic channel.
			ch.data_bitrate = 0
		} else if dbr_txt == '' {
			ch.data_bitrate = 0
		} else if project.is_all_digits(dbr_txt) && dbr_txt.int() > 0 {
			ch.data_bitrate = dbr_txt.int()
		} else {
			app.notify('${ch.name}: "${dbr_txt}" is not a data bitrate — digits only, in bits per second; keeping ${ch.data_bitrate}')
			// RECORDED, not only announced. The model keeps its previous rate, so without this the
			// editor shows one thing and the run uses another with nothing to stop it.
			app.cfg_invalid << CfgInvalid{
				idx:  i
				name: ch.name
				why:  'data rate "${dbr_txt}" is not a number'
			}
		}
		// AND THE RATES AS A PAIR, through the engine's own parser. Digits-only says nothing about
		// whether the two phases make sense together: a 250000 data phase under a 500000 nominal
		// is a perfectly good number that no FD channel can open, and it was accepted, saved, and
		// refused only at Start — long after the field that caused it left the screen.
		if why := ch.address_config_error() {
			app.notify('${ch.name}: ${why}')
			app.cfg_invalid << CfgInvalid{
				idx:  i
				name: ch.name
				why:  why
			}
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
	// APPENDING A ROW IS AN EDIT TO THE NAMESPACE, so the same reconciliation the other edits get
	// applies here (codex round 6 on #97). `unique_bus_name` keeps the new name clear of existing
	// NAMES, and nothing kept it clear of existing INTERFACES: add a virtual row defaulting to
	// `CAN2` beside a socketcan row already on `CAN2`, and every legacy `bus: CAN2` moved from the
	// SocketCAN wire to `inproc:CAN2` — by the name-first rule, with no writer involved. Captured
	// before the append; commit_cfg's own reconciliation has already run and cannot see this.
	mut before := []project.Channel{cap: app.proj.channels.len}
	mut row_map := []int{cap: app.proj.channels.len}
	for j, c in app.proj.channels {
		before << project.Channel{
			name:  c.name
			iface: c.iface
		}
		row_map << j // the new row goes on the end; no existing row moves
	}
	base := if address != '' { address } else { adapter }
	app.proj.channels << project.Channel{
		name:    app.unique_bus_name(base)
		adapter: adapter
		address: address
		iface:   project.compose_iface(adapter, address)
		typ:     'can'
		mode:    .normal
		// Normal unless the adapter rule says otherwise — project.adapter_starts_silent, which
		// answers false for every adapter since 2026-08-29 and says why.
		listen_only: project.adapter_starts_silent(adapter)
	}
	app.mu.lock()
	said := app.follow_channel_edits_locked(before, row_map)
	app.mu.unlock()
	for w in said {
		app.notify(w)
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
	app.disc_scan = app.scan_local()
	app.rebuild_discover_list()
	// Empty on any machine without the XL driver, which is the honest answer rather than a
	// placeholder — the Linux stub returns nothing and the section below draws nothing.
	app.disc_vector = transport.vector_mappings()
	// WHAT THE DRIVER CONFIRMED, in the two ways a channel can be usable. `empty` is registered and
	// pointing at nothing; `absent` is not registered at all, which is equally free — writing it
	// creates it. Listing only `empty` named the 5 channels this application happens to have and hid
	// the other 57 an operator may legitimately type (codex #192 r6).
	mut free := []string{}
	mut absent := 0
	for i, s in transport.vector_app_slots() {
		match s {
			.empty { free << '${i + 1}' }
			.absent { absent++ }
			else {}
		}
	}
	// Not enumerated: on an ordinary bench `absent` is most of the range, and a list of 57 numbers
	// is not an answer anybody reads. The count says the same thing and stays short.
	app.disc_vector_free = if absent > 0 && free.len > 0 {
		'${free.join(', ')} (and ${absent} not yet registered, which Assign would create)'
	} else if absent > 0 {
		'${absent} channels not yet registered, which Assign would create'
	} else {
		free.join(', ')
	}
	app.disc_vector_app_seen = transport.vector_application_seen() or {
		if app.disc_vector.len > 0 {
			app.notify('${err}')
		}
		true
	}
	// CLEARED EVERY TIME, including after the assign that used it — assign_vector_hw ends by calling
	// this. It authorizes the one write the driver cannot vouch for, so it has to be stated for that
	// write rather than left ticked from an earlier one (codex #192 r9).
	app.disc_vector_create = false
}

// assign_vector_hw points a free application channel at one physical channel, which is what
// Vector Hardware Manager would otherwise be opened to do (#186).
//
// EXPLICIT, NEVER IMPLICIT. This is persistent machine state — it survives reboots and it is what
// every later `vector:<n>` resolves through — so it happens on a button and nowhere else. Nothing
// on the Start path may create a mapping on the operator's behalf.
//
// UNDER THE INTERPROCESS LOCK, for the reason vector_borrow_lock exists: `cmd/vectorcheck --pair`
// borrows two application channels and restores them, and a GUI writing the same table between
// its read and its restore would leave a channel pointed somewhere nobody chose. A GUI is just
// another process here.
fn (mut app App) assign_vector_hw(hw transport.VectorChannel, app_channel int) {
	// CHECKED HERE TOO, not only where the button is drawn. The panel hides Assign for a non-CAN
	// channel, but that is a display rule and this is the function that WRITES — a second caller
	// added later would otherwise create a mapping addressed as CAN for a channel that is not one.
	if !hw.can_capable {
		app.notify('${hw.name} is not a CAN channel — it cannot be assigned as one')
		return
	}
	transport.vector_borrow_lock_now() or {
		app.notify('could not assign ${hw.name}: ${err}')
		return
	}
	defer {
		transport.vector_borrow_unlock()
	}
	// THE NAMED CHANNEL, RE-READ INSIDE THE LOCK. The dialog's list is a snapshot from the last
	// Refresh, and between that scan and this click another process — a second copy of this app, or
	// `vectorcheck` — may have written the very channel the operator typed. Both writers serialise
	// correctly on the lock and both act on stale reads, so the check has to happen in here
	// (codex #192 r3).
	//
	// ABOUT THE ONE CHANNEL BEING WRITTEN, which is what makes this stronger than the sweep it
	// replaces: `taken` is the driver saying that THIS channel points at hardware, not an inference
	// from what other channels did or did not answer.
	// No `vector_application_seen()` here any more. It was passed in to decide which of two meanings
	// `unknown` had, and the driver now answers that itself — see assign_refusal (codex #192 r6).
	slot := transport.vector_app_slot(app_channel)
	if why := transport.assign_refusal(app_channel, slot, app.disc_vector_create) {
		app.notify('${why}')
		return
	}
	// AND THE HARDWARE, still under the same lock. The channel check above says the DESTINATION is
	// free; this says the SOURCE is still unclaimed. Two processes acting on the same refreshed row
	// pick different application channels — so neither collides on the channel check — and both map
	// the same physical wire, which is the alias destination_conflicts refuses a project for (#167).
	// The rewrite for option 3 dropped this check along with the ownership machinery it used to
	// live beside; it was doing a second job (codex #192 r5).
	mut taken_by := 0
	mut row_known := true
	mut found := false
	for m in transport.vector_mappings() {
		if m.hw.hw_type == hw.hw_type && m.hw.hw_index == hw.hw_index
			&& m.hw.hw_channel == hw.hw_channel {
			taken_by = m.app
			row_known = m.owner_known
			found = true
			break
		}
	}
	if taken_by > 0 {
		app.notify('${hw.name} is already assigned to vector:${taken_by} — Refresh to see the current mapping')
		return
	}
	// AN UNOWNED ROW IS ONLY UNOWNED IF WE COULD SEE ALL THE OWNERS. Some application channel would
	// not answer, and it may be the one already pointing here — assigning a second channel to it is
	// the #167 alias, made by the dialog that exists to set the bench up (codex #192 r6).
	if !found || !row_known {
		app.notify('could not confirm whether ${hw.name} is already assigned — the Vector driver did not answer for every application channel. Refresh and try again.')
		return
	}
	transport.vector_assign(app_channel, hw) or {
		app.notify('could not assign ${hw.name}: ${err}')
		return
	}
	app.notify('vector:${app_channel} now points at ${hw.name} (${hw.transceiver}) — add it as a bus to use it')
	app.refresh_discovery()
}

// rebuild_discover_list is the cached local scan plus the mailbox's CANsub rows, with the
// operator's ticks carried over by key -- a browse landing while rows are ticked must not clear
// them.
fn (mut app App) rebuild_discover_list() {
	mut ticked := map[string]bool{}
	for k, d in app.disc_list {
		if k < app.disc_tick.len && app.disc_tick[k] {
			ticked[project.compose_iface(d.adapter, d.address)] = true
		}
	}
	app.mu.lock()
	rows := app.disc_cansub.clone()
	app.disc_cansub_shown = app.disc_cansub_landed
	app.mu.unlock()
	app.disc_list = app.merge_discovered(app.disc_scan, rows)
	app.disc_tick = []bool{len: app.disc_list.len}
	for k, d in app.disc_list {
		app.disc_tick[k] = ticked[project.compose_iface(d.adapter, d.address)] or { false }
	}
}

// start_cansub_browse asks mDNS for attached CANsub devices on its own thread (#235), one at a
// time: a click while one is in flight is that one. The mailbox is cleared first, so a browse
// in flight contributes nothing rather than yesterday's answer.
fn (mut app App) start_cansub_browse() {
	app.mu.lock()
	if app.disc_cansub_started != app.disc_cansub_landed {
		app.mu.unlock()
		return
	}
	app.disc_cansub_started++
	gen := app.disc_cansub_started
	app.disc_cansub = []
	app.disc_cansub_note = ''
	app.mu.unlock()
	app.rebuild_discover_list()
	spawn cansub_browse_worker(app, gen)
}

fn cansub_browse_worker(app &App, gen u64) {
	mut a := unsafe { app }
	mut note := ''
	rows, browse_note := transport.discover_cansub() or {
		note = 'CANsub browse unavailable — ${err.msg()}'
		[]transport.Iface{}, ''
	}
	if browse_note != '' {
		note = 'CANsub browse: ${browse_note}'
	}
	a.mu.lock()
	if a.disc_cansub_started == gen {
		a.disc_cansub = rows
		a.disc_cansub_note = note
		a.disc_cansub_landed = gen
	}
	a.mu.unlock()
	vgui.wake()
}

// cansub_browse_state reads the mailbox under the lock for the frame: whether a browse is in
// flight, whether one landed since the list was built, and the note to show.
fn (mut app App) cansub_browse_state() (bool, bool, string) {
	app.mu.lock()
	busy := app.disc_cansub_started != app.disc_cansub_landed
	landed := app.disc_cansub_landed != app.disc_cansub_shown
	note := app.disc_cansub_note
	app.mu.unlock()
	return busy, landed, note
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
	// The rows as they stand BEFORE the deletion: what an override means is a question about the
	// whole set, so it cannot be asked once the set has changed.
	rows_before := app.proj.channels.clone()
	app.proj.channels.delete(i)
	app.mu.lock()
	// THE REMOVED ROW'S OWN GENERATORS GO WITH IT, and the indices behind it restack —
	// `genhome.restack`, tested. Deleting a bus has always taken its generators (they simply
	// matched no channel on the next Save); doing it explicitly is what lets genhome.homes treat
	// "matched nothing" as the bookkeeping slip it now is. Applied BACKWARDS so the deletions
	// cannot shift the indices of the entries not yet reached.
	mut gens := []genhome.Gen{cap: app.senders.len}
	for sr in app.senders {
		gens << genhome.Gen{
			own:     sr.own
			own_idx: sr.own_idx
			iface:   sr.iface
		}
	}
	stacked := genhome.restack(gens, i)
	for si := app.senders.len - 1; si >= 0; si-- {
		if si >= stacked.len {
			continue
		}
		if stacked[si] == genhome.dropped {
			app.senders.delete(si)
			if si < app.gen_bufs.len {
				app.gen_bufs.delete(si)
			}
			continue
		}
		app.senders[si].own_idx = stacked[si]
	}
	// And what the deletion did to every override, through the one rule: a value that named the
	// deleted row is cleared, one that named a survivor is re-spelled if the deletion changed how
	// that row is spelled, and one whose wire did not move is left alone.
	mut before := []project.Channel{cap: rows_before.len}
	mut row_map := []int{cap: rows_before.len}
	for j, c in rows_before {
		before << project.Channel{
			name:  c.name
			iface: c.iface
		}
		row_map << if j == i {
			-1
		} else if j > i {
			j - 1
		} else {
			j
		}
	}
	said := app.follow_channel_edits_locked(before, row_map)
	app.mu.unlock()
	for w in said {
		app.notify(w)
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
	// A DoIP ROW IS NOT A CAN ROW, so it cannot still be CAN-FD. Left set, `fd` survived the
	// transition with no control left on screen to clear it — the CAN/CAN-FD toggles are hidden
	// for a DoIP adapter — so every Start warned that a DoIP channel was configured as CAN-FD, a
	// configuration error the editor itself had created and the operator could not undo. Save
	// persisted `fd: true` beside `type: doip` as well (codex #183 r2).
	if a == 'doip' {
		app.proj.channels[i].fd = false
		app.proj.channels[i].data_bitrate = 0
	}
	// SILENT BY DEFAULT when a bus BECOMES one of the adapters that starts silent, for the same
	// reason a discovered channel does: hardware that may already be wired to a running vehicle,
	// arriving with a 500 kbit/s guess nobody has confirmed. Exposing an adapter in the picker
	// without this makes the manual route the unsafe one while Discover stays careful — which is
	// exactly what happened to CANsub (codex round 5 on #204).
	// The RULE is project.adapter_change_starts_silent — here it is only applied. Written out in
	// this file as "starts silent now and did not before", it missed the case where both adapters
	// start silent, so a transmit-enabled Vector row switched to CANsub opened able to ACK (codex
	// round 6 on #204). It is a decision about adapters, so it lives with them, where a test holds
	// it.
	if project.adapter_change_starts_silent(was, a) {
		app.proj.channels[i].listen_only = true
	} else if project.adapter_silences_transceiver(was) && !project.adapter_silences_transceiver(a)
		&& app.proj.channels[i].listen_only {
		// KEPT NOW, and said out loud. This used to CLEAR the flag: `,silent` reaches only the
		// Vector transceiver, so on any other backend the tick promised "no ACKs" that nothing
		// delivered, and clearing it was the honest half of a bad choice. Since #117 the flag
		// stops every emitter in this process on every backend, so most of what it says is true
		// everywhere -- and silently clearing a safety tick is the worse direction to be wrong
		// in. What actually changes with the adapter is the transceiver, so that is what the
		// message is now about.
		// NAMED FROM THE REGISTRY, not written out. This said "only Vector can" while CANsub had
		// become the second adapter that silences its controller — a warning telling an operator
		// something false about what their hardware can do (codex round 14 on #204).
		can_silence := project.adapters.filter(project.adapter_silences_transceiver(it))
		app.notify('${app.proj.channels[i].name}: still listen-only — nothing here will transmit, but ${a} cannot silence the transceiver, so it still ACKs (${can_silence.join(' and ')} can)')
	}
	if a == 'doip' {
		app.proj.channels[i].typ = 'doip'
	} else if app.proj.channels[i].typ == 'doip' {
		app.proj.channels[i].typ = 'can'
	}
	// rebind_senders makes the assignment itself: it has to see the rows both before and after to
	// tell whether an override's destination moved (codex round 5 on #97).
	app.rebind_senders(i, old_iface, project.compose_iface(a,
		vgui.buf_str(app.cfg_bufs[i].address_buf)))
	app.dirty = true
	app.rebuild_preserving_senders()
}

// retarget_bus points an EXISTING row at a detected interface — adapter and address together —
// keeping its name, network, bitrates, DBCs and manifests. Before this the only way from
// SocketCAN to a CANsub was Discover's "+ Add ticked", which ADDS a row, so switching a project
// between the host's PCAN and the CANsub meant re-creating every bus and carrying its
// attachments across by hand, or editing the file. The adapter half goes through set_adapter so
// the listen-only and DoIP rules apply exactly as they do for the picker buttons.
fn (mut app App) retarget_bus(i int, adapter string, address string) {
	if i < 0 || i >= app.proj.channels.len || i >= app.cfg_bufs.len {
		return
	}
	if app.proj.channels[i].adapter != adapter {
		app.set_adapter(i, adapter)
	}
	old_iface := app.proj.channels[i].iface
	app.cfg_bufs[i].address_buf = mkbuf(address, 64)
	app.proj.channels[i].address = address
	// rebind_senders makes the assignment itself, for the reason it states.
	app.rebind_senders(i, old_iface, project.compose_iface(adapter, address))
	app.dirty = true
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
// editing a bus address doesn't orphan them: sync_senders_into_proj carries each generator home
// by the channel it is nested under, so a stale SenderRT.iface would drop all of a renamed bus's
// generators on the next Save/Start. Also follows explicit per-sender bus overrides written in
// the legacy interface form.
// follow_channel_edits_locked keeps every generator transmitting where it was, across an edit to
// the channel set. `before` is the rows as they stood; `row_map[j]` is where before-row j has
// ended up (-1 if it is gone). Returns what has to be said after the unlock; caller holds app.mu.
//
// THE RULE IS RESOLUTION, NOT REWRITING. Three rounds of review walked to this one: each edit path
// had its own idea of which overrides to touch, and each was wrong about a value it did not think
// it had changed. The last one is the clearest — a legacy `bus: X` targeting the channel whose
// INTERFACE is X, and an unrelated row renamed TO X: no writer touched that override, the
// name-first resolver simply started answering differently, and the generator moved to another
// wire in silence (codex round 5 on #97).
//
// So nothing here asks "did I rewrite this". It asks what the value MEANT before and what it
// means now, and acts only where the WIRE moved — which covers a renamed target, a retargeted
// address, a deleted row, and a namespace shadowed by an unrelated edit, without any of them
// being a case. Ownership becoming more or less resolvable is not a move; the wire is what the
// override chose.
//
// ONLY A VALUE THAT NAMED ONE ROW CAN BE PRESERVED. An ambiguous reference meant no single row,
// so there is nothing to follow and sender_bus_warnings already reports it; a bare wire has no
// row at all and is unaffected by anything done to the rows.
fn (mut app App) follow_channel_edits_locked(before []project.Channel, row_map []int) []string {
	mut said := []string{}
	mut after := []project.Channel{cap: app.proj.channels.len}
	for c in app.proj.channels {
		after << project.Channel{
			name:  c.name
			iface: c.iface
		}
	}
	for si in 0 .. app.senders.len {
		b := app.senders[si].sender.bus
		if b == '' {
			continue
		}
		own := project.Channel{
			name:  app.senders[si].own
			iface: app.senders[si].iface
		}
		was_r := project.resolve_sender_bus(b, own, before)
		now_r := project.resolve_sender_bus(b, own, after)
		// project.sender_target_moved is the comparison, tested there: three review rounds each
		// wanted a different answer for a case the others had not considered, so it is stated once
		// where every one of them is a line in a test.
		if !project.sender_target_moved(was_r, now_r) {
			continue
		}
		// WHICH ROW DID IT MEAN? By the resolution's KIND, because that is what says whether one
		// row was meant — not whether the owner has a NAME. Guarding on a non-empty owner treated a
		// uniquely configured UNNAMED row as "no single target", so editing that row's address
		// cleared the override instead of following it: the one case round 6 taught this function
		// to detect, and then could not act on (codex round 7 on #97).
		//
		// `.named` and `.iface` are one row by construction; `.ambiguous` is several, `.bare` is
		// none, and `.own` cannot occur here because an empty `bus:` was skipped above.
		mut k := -1
		if was_r.kind == .named || was_r.kind == .iface {
			// project.only_row_named, not a scan written here: the inline version of this had a
			// sentinel the next match overwrote, so an odd number of identical rows resolved to the
			// last one instead of to "several" (codex round 8 on #97).
			k = project.only_row_named(before, was_r.chan, was_r.iface) or { -1 }
		}
		dst := if k >= 0 && k < row_map.len { row_map[k] } else { -1 }
		if dst < 0 || dst >= after.len {
			app.senders[si].sender.bus = ''
			said << '${app.senders[si].sender.name}: the bus it targeted (`${b}`) is gone — the generator falls back to ${app.senders[si].own}'
			continue
		}
		if why := app.retarget_bus_locked(si, after[dst], after) {
			said << why
		}
	}
	return said
}

// retarget_bus_locked writes the `bus:` of generator `si` so it goes on transmitting on `target`,
// and reports what could not be said. Caller holds app.mu.
//
// EVERY WRITE OF `bus:` GOES THROUGH project.sender_bus_value — that is the point of it. It was
// introduced for the picker in round 3 and left the other two writers spelling values themselves
// (an address edit wrote the raw new interface, a rename wrote the raw new name), so the same
// class of misroute survived in the places the picker no longer had: a value that happens to be
// another channel's NAME resolves to that channel, on another wire. A policy in two places is the
// drift this repo keeps paying for; now there is one (codex round 4 on #97).
//
// WHERE THE TARGET HAS NO SPELLING the override is cleared rather than left pointing elsewhere:
// falling back to the generator's own channel is well defined and visible, and a value that
// silently addresses a different bus is not. The caller says so after the unlock.
fn (mut app App) retarget_bus_locked(si int, target project.Channel, rows []project.Channel) ?string {
	own := project.Channel{
		name:  app.senders[si].own
		iface: app.senders[si].iface
	}
	if v := project.sender_bus_value(target, own, rows) {
		app.senders[si].sender.bus = v
		return none
	}
	was := app.senders[si].sender.bus
	app.senders[si].sender.bus = ''
	return '${app.senders[si].sender.name}: `bus: ${was}` can no longer be written — that bus has no name and its interface is already another channel\'s name; the generator falls back to ${app.senders[si].own}'
}

// rebind_senders carries row `row`'s generators to its new interface when its address is edited,
// so the edit does not orphan them.
//
// CALLED BEFORE THE MODEL IS CHANGED. It has to resolve `bus:` overrides against the project as
// it still stands, and once `channels[row].iface` holds the new value there is nothing left to
// ask the old question of.
//
// BY ROW, not by interface. Matching on the old interface alone moved the generators of EVERY
// channel on that wire — two rows may share one deliberately — so retargeting one alias left the
// other's generators carrying an interface their own row does not have. They then failed the
// name-and-interface check in sync_senders_into_proj, failed its fallback too, and were DELETED
// from the project on the next Save: an edit to one row silently destroying another's work
// (codex round 1 on #97, P1).
//
// AN OVERRIDE FOLLOWS ONLY IF IT REALLY POINTED HERE. `bus:` is a channel NAME since #97 and an
// interface only when no channel answers to the value, so a value that spells this row's old
// interface may well belong to a channel NAMED that — a collision the name-first rule explicitly
// supports — and rewriting it would silently retarget that generator to this row's new address.
// The resolver is asked; only `.iface` follows. `.ambiguous` does not either: on a shared wire the
// value still names the sibling's wire after this row leaves it.
//
// UNDER app.mu, like every other writer of app.senders: gen_loop copies these same strings under
// the lock every 8 ms, and a V string assignment is not atomic. The lock is taken here rather
// than by the callers, which run from GUI edit handlers that hold nothing.
fn (mut app App) rebind_senders(row int, old_iface string, new_iface string) {
	if old_iface == new_iface || old_iface == '' {
		return
	}
	app.mu.lock()
	// The rows as they stand BEFORE the edit. What an override means is a question about the whole
	// set, so it cannot be asked once the set has changed — and this function is called before the
	// caller writes the new interface, for exactly that reason.
	mut before := []project.Channel{cap: app.proj.channels.len}
	mut row_map := []int{cap: app.proj.channels.len}
	for j, c in app.proj.channels {
		before << project.Channel{
			name:  c.name
			iface: c.iface
		}
		row_map << j // an address edit moves no row
	}
	if row >= 0 && row < app.proj.channels.len {
		app.proj.channels[row].iface = new_iface
	}
	for si in 0 .. app.senders.len {
		// The generator's own row carries it home on Save, so it follows its channel's address.
		// This is identity, not targeting; the `bus:` half is follow_channel_edits_locked's.
		if genhome.moves_with_row(genhome.Gen{ own_idx: app.senders[si].own_idx }, row) {
			app.senders[si].iface = new_iface
		}
	}
	said := app.follow_channel_edits_locked(before, row_map)
	app.mu.unlock()
	// notify re-takes the non-reentrant mutex, so nothing here is said before the unlock.
	for w in said {
		app.notify(w)
	}
}

// rebind_sender_commit follows a commit's edits into the generators. `before` is the rows as they
// stood when commit_cfg was entered, name and interface both, since a commit can change either.
//
// TWO SEPARATE JOBS, and only one of them is about renames. The `own` a generator carries home on
// Save is IDENTITY — row i is still row i however it was relabelled — so it is followed by index,
// in one pass over the whole commit: applied one rename at a time and matched by name, a commit
// renaming A -> B and B -> C skipped the second (B was still held, by the row that had just
// become B) and that row's generators answered to a name belonging to somebody else.
//
// Where its `bus:` now POINTS is not a rename question at all, and treating it as one is what
// left the last gap: a legacy `bus: X` targeting the channel whose interface is X was moved to
// another wire by renaming an unrelated row TO X — an override no rename map contains, because no
// rename touched it (codex round 5 on #97). follow_channel_edits_locked asks what every value
// MEANT and what it means now, which covers that without knowing it is a rename at all.
fn (mut app App) rebind_sender_commit(before []project.Channel) {
	app.mu.lock()
	for si in 0 .. app.senders.len {
		idx := app.senders[si].own_idx
		if idx >= 0 && idx < app.proj.channels.len && idx < before.len
			&& app.senders[si].own == before[idx].name {
			app.senders[si].own = app.proj.channels[idx].name
			app.senders[si].iface = app.proj.channels[idx].iface
		}
	}
	mut row_map := []int{cap: before.len}
	for j in 0 .. before.len {
		row_map << j // a commit relabels and re-addresses rows; it moves none
	}
	said := app.follow_channel_edits_locked(before, row_map)
	app.mu.unlock()
	for w in said {
		app.notify(w)
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
	// an ARXML with several CAN clusters needs one named (`file.arxml#Cluster`), and the
	// picker hands over a bare path: attach the FIRST cluster and say which others there
	// are, so the reference is complete and editable in the File tab — a bare path would
	// be refused at load with nowhere in the GUI to complete it
	mut frag := ''
	if candb.is_arxml_path(path) {
		if a := candb.load_arxml_file(path) {
			names := a.cluster_names()
			if names.len > 1 {
				frag = '#${names[0]}'
				app.notify('${os.file_name(path)} has ${names.len} CAN clusters (${names.join(', ')}): attached ${names[0]} — change the #cluster in the File tab for another')
			}
		} else {
			app.notify('${os.file_name(path)}: ${err}')
		}
	}
	app.drop_replay_scan(ci) // the census on display was attributed through the OLD databases
	app.commit_cfg()
	// the fragment rides on the RESOLVED path: rel_path asks the file system about it
	app.proj.channels[ci].databases << rel_path(path) + frag
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
// persists it) that also moves the runtime row, so Start needs no intervening apply. The Buses
// panel's tick is a project edit too since #249, and since #120 it is stopped-only like this one
// (panel_buses.v refuses while running rather than reconfiguring a live run), and the Configure
// header's edits the model alone and reaches the runtime through apply_edits. Three surfaces, one
// intent: the tick you see is the tick that is saved; what differs is when the runtime learns of
// it.
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
// load_cfg_text reads the project file into the edit buffer (TextFile.load: once per path,
// never over unsaved edits, an unreadable file marked loaded so it is not retried at frame
// rate — freshness is cfg_invalidate() at every path that rewrites or replaces the project) and
// validates what was just READ. Assuming a file on disk is well-formed made the status claim
// "YAML well-formed · -1 channel(s)" for a file the very next Save would reject — the tool
// disagreeing with itself about the bytes on screen.
fn (mut app App) load_cfg_text() {
	if app.proj_path == '' {
		if app.cfg_file.load('') != .cached {
			app.cfg_file.err = 'no file yet — save the project once (File ▸ Save As), then edit it here'
		}
		return
	}
	match app.cfg_file.load(app.proj_path) {
		.cached {}
		.failed {
			app.cfg_chans = -1
		}
		.read {
			txt := app.cfg_file.text()
			app.cfg_text_len = txt.len
			app.cfg_file.err = cfg_text_error(txt)
			app.cfg_chans = cfg_text_channels(txt)
		}
	}
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
	app.cfg_file.invalidate()
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
	// NOT WHILE RUNNING. Saving the text applies it to the model and REBUILDS the runtime from
	// it (apply_parsed_text -> rebuild_from_proj), which is stopped-only: done under live RX and
	// generator threads it replaces the channels beneath them. Start leaves dirty text
	// unapplied and warns; Ctrl+S mid-run must not finish what Start declined (codex round 2
	// on #250).
	if app.running {
		app.cfg_file.err = 'not saved while running — the text is applied to the model on save; Stop first'
		app.notify("not saved — the File tab's text is applied on save, and the model is not rebuilt while running; Stop first")
		return
	}
	if app.dirty {
		// The mirror of the guard in save_project: applying this text would replace a model
		// that holds unsaved bus or generator edits.
		app.cfg_file.err = 'unsaved bus edits would be lost — save or discard them above first'
		app.notify('not saved — resolve the unsaved bus edits first')
		return
	}
	txt := app.cfg_file.text()
	if e := non_empty(cfg_text_error(txt)) {
		app.cfg_file.err = e
		app.notify('not saved — ${e}')
		return
	}
	// Refuse the one edit that silently destroys work: a well-formed file that parses to no
	// channels at all, over a project that had some. Almost always a truncated buffer or a
	// mangled top level, never a thing anyone means to save.
	if cfg_text_channels(txt) == 0 && app.proj.channels.len > 0 {
		app.cfg_file.err = 'refused: this text yields no channels, which would empty the project — use Reload to get the file back'
		app.notify('not saved — it would empty the project')
		return
	}
	path := app.proj_path
	// through TextFile.write, which refuses once when the file changed on disk since it was
	// loaded (the buffer holds proj_path: load_cfg_text loaded it there)
	app.cfg_file.write() or {
		app.notify('not saved — ${err.msg()}')
		return
	}
	app.notify('saved -> ${path}')
	app.dirty = false
	app.cfg_file.dirty = false
	app.proj_disk = txt
	app.external_confirm = ''
	app.reserialize_confirm = '' // a File save persists the comments; a later Buses Save must re-warn (codex #268)
	app.saved_at = time.ticks()
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
	app.cfg_invalid = [] // …and the rejections describing them go with them
	// WHAT READING THE TEXT HAD TO SAY, on this path too. The File tab parses a project exactly
	// as Open does, so a v2 buffer applied here gets the same pre-v4 `bus:` migration — including
	// the case it can only REPORT, where a legacy value now resolves elsewhere and nothing later
	// says so (Start sees an ordinary `.named` target and has nothing to warn about). Dropped
	// here, saving v2 text through Configuration ▸ File activated a misrouted generator in
	// silence (codex round 8 on #97).
	for n in p.notes {
		app.notify(n)
	}
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
	app.proj_disk = txt
	app.external_confirm = ''
	// Clear the flags only if the file actually replaced the model. Clearing them regardless
	// left the edited model live and looking clean, so a later save would persist changes the
	// user had been told were discarded.
	if !app.apply_parsed_text(txt) {
		app.notify('nothing discarded — ${app.proj_path} does not parse; fix it on the File tab')
		return
	}
	app.dirty = false
	app.reserialize_confirm = '' // revert replaced the model; drop any pending confirmation (codex #268)
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
	if app.cfg_file.dirty {
		app.notify('not saved — the Configuration ▸ File tab has unsaved text; save or revert it there first')
		app.show_config = true
		app.cfg_tab = 1
		return
	}
	// Fold pending editor + generator buffers into app.proj FIRST, so the comment-guard snapshot
	// below is the EXACT model that would be written (a Buses text field or a generator edit made
	// after the warning must change it, or the confirmation would pass for the wrong content —
	// codex #268). This is the model half of apply_edits; the runtime rebuild (which resolves
	// assets against proj_path) is deferred until AFTER the guard, so a refusal never rebases.
	if app.running {
		app.sync_senders_into_proj()
	} else {
		app.commit_cfg()
		app.sync_senders_into_proj()
	}
	// #80: a reserializing Save (Buses tab / menu) rebuilds the file from the model and CANNOT
	// keep its comments — only File ▸ Save writes the buffer verbatim. Warn on the FIRST such Save
	// and remember (path, model); a second Save proceeds only if both are unchanged, so any edit /
	// load / revert / different target re-warns rather than counting as the confirmation.
	if os.exists(app.proj_path) {
		on_disk := os.read_file(app.proj_path) or {
			// present but unreadable: os.write_file may still truncate it and we cannot tell
			// whether reserializing is destructive — refuse rather than assume no comments.
			app.notify('not saved — could not read ${app.proj_path} to check for comments this Save would drop (${err}); resolve the read error first')
			return
		}
		// An EXTERNAL change first: the file is not what this app last read or wrote (Open in
		// editor, a checkout), so the model is stale and its Save would erase the edit. Refused
		// once, for that version of the file; a repeated Save overwrites it (codex #307 r21).
		if app.proj_disk != '' && on_disk != app.proj_disk && app.external_confirm != on_disk {
			app.external_confirm = on_disk
			app.notify('not saved yet — ${app.proj_path} changed on disk since it was loaded (an external editor?). Configuration ▸ File ▸ Reload, or File ▸ Revert, takes the file; repeat the Save to overwrite it.')
			return
		}
		if saverule.reserialize_drops_comments(on_disk) {
			// key the confirmation on the DESTINATION path AND the model: a snapshot alone would let
			// a Save As to a different commented file (or the original) match a prior warning's
			// snapshot and overwrite without its own warning (codex #268). '\x00' cannot occur in a
			// path or in to_yaml output, so it is an unambiguous separator.
			snap := app.proj_path + '\x00' + app.proj.to_yaml()
			if app.reserialize_confirm != snap {
				app.reserialize_confirm = snap
				app.notify('not saved yet — this Save rewrites the file from the model and would DROP its comments (the header + inline hints). Use Configuration ▸ File ▸ Save to keep them, or repeat the Save to reserialize anyway.')
				app.show_config = true
				return
			}
		}
	}
	if !app.running {
		// `!running` decides whether the runtime half happens at all; whether it is SAFE is
		// rebuild_from_proj's own business — it waits for the run's workers before it touches
		// anything, so a Save straight after a Stop pays that wait rather than racing them
		// (#107 / #125).
		app.rebuild_from_proj() // the runtime-rebuild half of apply_edits, now that the guard has passed
	}
	// THE SAME REFUSAL AS START'S, and Save needs it more: writing the file would persist the
	// value the rejected field replaced, so a typo the operator can still see on screen becomes
	// a stored rate they never chose — and the evidence that anything was wrong is gone as soon
	// as the buffers are rebuilt from the saved model.
	// EVERY ROW, as Start now also checks: a save writes the whole project, so a value that would
	// not commit is one the file would be wrong about whichever rows are ticked. The two used to
	// differ — Start exempted disabled rows — until that exemption turned out to rest on a false
	// premise (see run.v, #183 r5).
	if app.cfg_invalid.len > 0 {
		bad := app.cfg_invalid.map('${it.name}: ${it.why}')
		app.notify('not saved — ${bad.join('; ')} (correct it in Configuration ▸ Buses, or clear the field)')
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
	app.saved_at = time.ticks()
	app.reserialize_confirm = '' // the file was just rewritten (comments gone); re-warn if reopened
	app.proj_disk = os.read_file(path) or { '' } // what a later Save compares the file against
	app.external_confirm = ''
	app.cfg_invalidate() // the file just changed under the File tab
	app.notify('saved -> ${path}')
}

// save_what_is_being_edited is Ctrl+S: ONE shortcut, one meaning — write what you are editing.
// The File tab holds the project as TEXT in its own buffer, and a project save while that text
// is dirty is refused (save_project) because one of them would overwrite the other; so with the
// File tab showing dirty text, Ctrl+S saves the text, and otherwise it saves the project. The
// per-panel Save buttons that used to do the second half from four places are gone (#247): the
// menu's Save, this shortcut and the File tab's own button are the whole set.
fn (mut app App) save_what_is_being_edited() {
	// THE DECISION IS saverule.save_target — pure, tested, and the only place it is made. Five
	// review rounds on #250 each moved it; each fix was checked by reading, because the GUI has
	// no tests. Now the table is in saverule/save_rule_test.v and this is a switch.
	state := saverule.SaveState{
		text_dirty:   app.cfg_file.dirty
		file_visible: app.cfg_file_visible
		picker_open:  app.fb_open
		running:      app.running
	}
	match saverule.save_target(state) {
		.nothing {
			if app.running && app.cfg_file.dirty && app.cfg_file_visible {
				app.notify("not saved — the File tab's text is applied on save, and the model is not rebuilt while running; Stop first")
			}
		}
		.text {
			app.save_cfg_text()
		}
		.model {
			app.save_project()
		}
	}
}

// poll_shortcuts is read once per frame, beside the generator hotkeys — but unlike them it is
// NOT suppressed while a widget holds the keyboard: Ctrl is what makes S a command.
fn (mut app App) poll_shortcuts() {
	// The menu's Save lands here too: drawn in the menubar BEFORE the panels, it ran before
	// draw_gen had folded a generator's name and key buffers into the sender, and saved the
	// previous value (codex round 6 on #250 — the same defect the chord had in round 3). So
	// the menu only asks, and both are performed here, after every panel has drawn.
	if (vgui.key_ctrl_only() && vgui.key_pressed(`s`)) || app.save_requested {
		app.save_requested = false
		app.save_what_is_being_edited()
	}
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
	if app.cfg_file.dirty {
		app.notify('not saved — the Configuration ▸ File tab has unsaved text; save or revert it there first')
		app.show_config = true
		app.cfg_tab = 1
		return
	}
	// THE SAME ORDERING, for the same reason as the guard above and one this change had to be
	// taught: save_project refuses on a rejected editor field, but by then proj_path already names
	// the new destination — so a failed Save As wrote nothing and still rebound the application to
	// a file it had not written, moving the relative asset base and the target of the next plain
	// Save with it. Committing first is what makes the check meaningful here: cfg_invalid is
	// rebuilt by commit_cfg, so testing it before the buffers are folded in would read a stale
	// answer (codex #183 r3).
	app.commit_cfg()
	if app.cfg_invalid.len > 0 {
		bad := app.cfg_invalid.map('${it.name}: ${it.why}')
		app.notify('not saved — ${bad.join('; ')} (correct it in Configuration ▸ Buses, or clear the field)')
		app.show_config = true
		return
	}
	mut p := path
	if !p.ends_with('.blobnet') && !p.ends_with('.yml') && !p.ends_with('.yaml') {
		p += '.blobnet'
	}
	// Save As routes through save_project's #80 comment guard like any Save: if the destination
	// carries comments it warns (keyed on that path + model) and a repeated Save As confirms. The
	// guard biases to warn — an over-warn here costs one extra confirmation, which is why Save As is
	// NOT refused outright (an outright refusal would hard-block a destination whose only '#' is
	// inside a quoted value — codex #268). Nothing rebases on a refusal: save_project folds the
	// model but defers the runtime rebuild until the guard passes.
	prev_path := app.proj_path
	before := app.saved_at
	app.proj_path = p
	app.proj.name = app.proj_name
	app.save_project()
	if app.saved_at == before {
		// The Save As did not write (Project.save failed after the runtime was rebuilt against the
		// destination). Restore the path and rebuild WITH the sender-preserving helper, so unsaved
		// generator edits are not discarded merely because the destination was refused (codex #268).
		app.proj_path = prev_path
		if !app.running {
			app.rebuild_preserving_senders()
		}
	}
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
