module main

import candb
import os
import project
import transport
import vgui
import mf4
import pickrule
import panerule
import player

// is_recording_target: does this picker action open a recording? ONE predicate — the ext
// filter, the samples shortcut and the title each asked separately, and two of the three had
// already drifted to the colon-less prefix (matching a hypothetical 'replaysrc2' target the
// confirm dispatch would not).
fn is_recording_target(t string) bool {
	return t == 'recording' || t.starts_with('replaysrc:')
}

// open_browser opens the file browser for a target action:
//   'open'          — load a project (.blobnet)
//   'saveas'        — Save As (.blobnet, filename input)
//   'dbc:<ci>'      — attach a DBC to bus ci (.dbc)
//   'manifest:<ci>' — attach a telemetry manifest to bus ci (.csv)
//   'script'        — the Script panel's .lua (#270)
fn (mut app App) open_browser(target string) {
	app.fb_target = target
	app.fb_save = target == 'saveas'
	app.fb_ext = if target == 'open' || target == 'saveas' {
		['.blobnet', '.yml', '.yaml']
	} else if target.starts_with('dbc') {
		['.dbc', '.arxml'] // an ARXML attaches as is; a multi-cluster one is refused at load, naming them
	} else if target.starts_with('manifest') {
		['.csv']
	} else if target == 'system' {
		['.toml']
	} else if target == 'flash' {
		['.img', '.bin'] // wrapped .img preferred, raw .bin allowed
	} else if target == 'script' {
		['.lua']
	} else if is_recording_target(target) {
		['.log', '.mf4'] // recordings come in both formats; one picker shows both
	} else {
		[]string{}
	}
	// For recordings, START WHERE RECORD WRITES — one function decides both sides.
	mut dir := if target == 'recording' {
		app.recordings_dir()
	} else if target == 'script' {
		app.script_dir()
	} else if app.proj_path != '' {
		os.dir(app.proj_path)
	} else {
		'projects'
	}
	if !os.is_dir(dir) {
		dir = '.'
	}
	app.fb_enter(os.abs_path(dir))
	initname := if app.fb_save && app.proj_path != '' { os.file_name(app.proj_path) } else { '' }
	app.fb_name_buf = mkbuf(initname, 128)
	app.fb_open = true
}

// script_dir is where the Script picker starts: beside the script the panel names, else the
// repo's tests/, else beside the project — the places a suite lives, in the order a hand looks.
fn (app &App) script_dir() string {
	cur := vgui.buf_str(app.script_path_buf).trim_space()
	if cur != '' {
		d := os.dir(cur)
		if os.is_dir(d) {
			return d
		}
	}
	if os.is_dir('tests') {
		return 'tests'
	}
	if app.proj_path != '' {
		return os.dir(app.proj_path)
	}
	return '.'
}

// fb_enter moves the browser to `dir` — a folder, or pickrule.drives for the list of drive
// roots. The selection goes with the listing it belonged to, the path field follows, and the
// listing is read ONCE here (fb_refresh), not per frame.
fn (mut app App) fb_enter(dir string) {
	app.fb_dir = dir
	app.fb_sel = ''
	app.fb_path_buf = mkbuf(dir, 512)
	app.fb_refresh()
}

// fb_refresh reads the listing: the drive roots at pickrule.drives, else the folder's
// sub-folders and the files the filter passes. On entering a folder and on the Refresh button —
// not per frame, because os.ls plus one is_dir per entry is a syscall per row per frame, and
// on a folder that answers slowly (a disconnected network drive, which the drives view now
// lists) it is the whole GUI thread stalled for as long as the picker is open.
fn (mut app App) fb_refresh() {
	// The roots too — a drive attached or a distribution registered while the picker is open
	// (codex #307 r2). GetLogicalDrives and a registry walk, not a probe of each root.
	app.fb_roots = fs_roots()
	app.fb_roots << wsl_roots()
	app.fb_root_lbl = ['drive…'] // the dropdown's items: a placeholder, then the roots
	app.fb_root_lbl << app.fb_roots.map(root_label(it))
	app.fb_dirs = []
	app.fb_files = []
	if app.fb_dir == pickrule.drives {
		app.fb_dirs = app.fb_roots.clone() // the same list as the drive row: drives and WSL
		return
	}
	entries := os.ls(app.fb_dir) or { []string{} }
	for e in entries {
		full := fb_join(app.fb_dir, e)
		if os.is_dir(full) {
			app.fb_dirs << e
		} else if app.match_ext(e) {
			app.fb_files << e
		}
	}
	app.fb_dirs.sort()
	app.fb_files.sort()
}

// fb_join is `dir` + separator + `name`, and nothing else: os.join_path normalises, and its
// normalisation collapses the `\\` a UNC path starts with, so every folder under
// `\\wsl.localhost\Ubuntu\` was filed under a path that does not exist (self-review on #307).
fn fb_join(dir string, name string) string {
	if dir.ends_with(os.path_separator) || dir.ends_with('/') {
		return dir + name
	}
	return dir + os.path_separator + name
}

// fb_go is the typed path: a folder is entered; a file that passes the filter is selected in
// the folder it lives in (and, in save mode, becomes the name); anything else is said rather
// than ignored — a file the filter rejects included, or the picker would advertise `(*.dbc)`
// and hand over something else.
fn (mut app App) fb_go(typed string) {
	if typed == '' {
		return
	}
	// `C:` alone is "the current directory on C" to the OS and abs_path glues it onto the CWD;
	// the root a hand means is `C:` plus the separator.
	p := if pickrule.is_drive_root(typed) && typed.len == 2 {
		typed + os.path_separator
	} else {
		typed
	}
	if os.is_dir(p) {
		app.fb_enter(os.abs_path(p))
		return
	}
	if os.is_file(p) {
		ap := os.abs_path(p)
		name := os.file_name(ap)
		if !app.match_ext(name) {
			app.notify('${name} is not one of ${app.fb_ext.join(' ')}')
			return
		}
		app.fb_enter(os.dir(ap))
		app.fb_sel = name
		if app.fb_save {
			app.fb_name_buf = mkbuf(name, 128)
		}
		return
	}
	app.notify('no such folder or file: ${typed}')
}

// browser_confirm runs the pending target action with the chosen path, then closes.
fn (mut app App) browser_confirm(path string) {
	t := app.fb_target
	app.fb_open = false
	if t == 'open' {
		app.load_project(path)
	} else if t == 'saveas' {
		app.save_as(path)
	} else if t.starts_with('dbc:') {
		app.add_dbc(t['dbc:'.len..].int(), path)
	} else if t.starts_with('manifest:') {
		app.set_manifest(t['manifest:'.len..].int(), path)
	} else if t == 'system' {
		app.load_system(path)
	} else if t == 'flash' {
		app.flash_img_buf = mkbuf(path, 256)
	} else if t == 'script' {
		app.script_path_buf = mkbuf(path, 256)
	} else if t == 'recording' {
		app.load_recording(path)
	} else if t.starts_with('replaysrc:') {
		app.set_replay_source(t['replaysrc:'.len..].int(), path)
	}
}

// draw_filebrowser is a small self-contained file picker (no native dialog — imgui has
// none, and WSL isn't the primary target). Lists the current directory, filters by
// extension, and (save mode) takes a filename. What a row does is the native picker's
// grammar (pickrule.activate): a click SELECTS, a double click ENTERS a folder or ACCEPTS a
// file, and Enter / Open act on the selection the same way. Entering on a single click was
// #270: the hand that double-clicks landed its second click on a row of the folder it had
// just entered. Above a Windows drive root the list is the drives (pickrule.drives, fs_roots),
// so `D:` is reachable from `C:`; the path field takes a typed folder or file too.
fn draw_filebrowser(mut app App) {
	title := if app.fb_target == 'open' {
		'Open Project'
	} else if app.fb_target == 'saveas' {
		'Save Project As'
	} else if app.fb_target.starts_with('dbc') {
		'Attach DBC'
	} else if app.fb_target == 'system' {
		'Open system.toml'
	} else if app.fb_target == 'recording' {
		'Open Recording'
	} else if app.fb_target.starts_with('replaysrc:') {
		'Replay Recording'
	} else if app.fb_target == 'script' {
		'Run Script'
	} else if app.fb_target == 'flash' {
		// fell through to 'Attach Manifest' before — the firmware picker wore another
		// feature's title, which is what an else-catchall does the day a target is added
		'Firmware Image'
	} else {
		'Attach Manifest'
	}
	sc := app.prefs.ui_scale
	vgui.set_next_window(260, 140, 640, 560)
	vis, op := vgui.begin_dialog('${title}##filebrowser', app.fb_open) // the X is Cancel
	app.fb_open = op
	if !vis {
		vgui.end()
		return
	}
	// The folder, typed: Enter SUBMITS it (input_text_enter — not "deactivated after edit",
	// which fires on a click aimed at the list and would navigate under it), or Go.
	// the field takes what the button beside it leaves: 'Open path' plus its padding
	vgui.set_next_item_width(vgui.content_avail_w() - 96 * sc)
	mut jump := vgui.input_text_enter('##fbpath', mut app.fb_path_buf)
	vgui.same_line()
	if vgui.small_button('Open path') {
		jump = true
	}
	vgui.set_item_tooltip('Go to the typed path: a folder is entered, a file is selected where it lives. Enter in the field does the same.')
	if jump {
		app.fb_go(vgui.buf_str(app.fb_path_buf).trim_space())
	}
	if vgui.small_button('.. up') {
		app.fb_enter(pickrule.parent(app.fb_dir, drive_roots))
	}
	vgui.same_line()
	if vgui.small_button('projects/') {
		p := os.abs_path('projects')
		if os.is_dir(p) {
			app.fb_enter(p)
		}
	}
	// The shipped demo capture lives in samples/ — the old Trace path field defaulted to it,
	// and removing that field removed the only pointer a fresh setup had to a file this
	// picker can open. Only for the recording target; other pickers have no business there.
	if is_recording_target(app.fb_target) && os.is_dir('samples') {
		vgui.same_line()
		if vgui.small_button('samples/') {
			app.fb_enter(os.abs_path('samples'))
		}
	}
	vgui.same_line()
	if vgui.small_button('Refresh') {
		app.fb_refresh() // the listing is read on entering a folder, not per frame
	}
	filt := if app.fb_ext.len > 0 { '(' + app.fb_ext.map('*' + it).join(' ') + ')' } else { '' }
	vgui.same_line()
	vgui.text_dim(filt)
	// The drive dropdown (#306): a drive, or a WSL distribution, from the start — not `..` until
	// the root and then once more. Read at open (fb_roots); only where roots are drives. It shows
	// the root the folder is under, and picking another enters it.
	if drive_roots && app.fb_roots.len > 0 {
		mut cur := 0 // item 0 is the placeholder: no listed root holds this folder
		low := app.fb_dir.to_lower()
		for i, r in app.fb_roots {
			if low.starts_with(r.to_lower()) {
				cur = i + 1
				break
			}
		}
		// Its own row: appended to the button row it was clipped past the dialog's edge at
		// 150% and above (codex #307 r1).
		vgui.text_dim('drive:')
		vgui.same_line()
		vgui.set_next_item_width(200 * sc)
		pick := vgui.combo('##fb_root', app.fb_root_lbl, cur)
		if pick != cur && pick > 0 {
			app.fb_enter(app.fb_roots[pick - 1])
		}
	}
	vgui.separator()

	at_drives := app.fb_dir == pickrule.drives
	// What was double-clicked this frame, applied AFTER end() so the imgui stack stays balanced.
	mut on := ''
	mut on_kind := pickrule.Entry.file
	// The list keeps its distance from the button row: its frame, the separator and their
	// spacing. Reserve the row alone and the buttons sit a spacing below the window's edge,
	// with a scrollbar to reach them.
	vgui.child_begin('fb_list', -(vgui.frame_height() + vgui.line_height()))
	for d in app.fb_dirs {
		lbl := if at_drives { '[drive] ${d}' } else { '[dir]  ${d}' }
		if vgui.selectable(lbl, app.fb_sel == d) {
			app.fb_sel = d
		}
		if vgui.is_item_double_clicked() {
			on = d
			on_kind = .dir
		}
	}
	for f in app.fb_files {
		if vgui.selectable('      ${f}', app.fb_sel == f) {
			app.fb_sel = f
			if app.fb_save {
				app.fb_name_buf = mkbuf(f, 128)
			}
		}
		if vgui.is_item_double_clicked() {
			on = f
			on_kind = .file
		}
	}
	vgui.child_end()
	// Enter on the selection: only with this window focused (the key is read globally), only
	// when no field owns it, and not on the frame the path field was submitted — ImGui drops
	// the field's active state inside that submit, so "no item active" is already true here.
	mut activate := !jump && vgui.window_focused() && !vgui.any_item_active()
		&& vgui.key_enter_pressed()
	mut chosen := '' // save mode: the named path
	vgui.separator()
	if app.fb_save {
		vgui.set_next_item_width(300 * sc)
		mut save := vgui.input_text_enter('name', mut app.fb_name_buf) // Enter in the name saves
		vgui.same_line()
		if vgui.button('Save') {
			save = true
		}
		if save {
			name := vgui.buf_str(app.fb_name_buf)
			if at_drives {
				// join_path('', name) is a path relative to the process working directory —
				// a file written somewhere the dialog does not show.
				app.notify('pick a drive first')
			} else if name != '' {
				chosen = fb_join(app.fb_dir, name)
			}
		}
		vgui.same_line()
	} else {
		if vgui.button('Open') {
			if app.fb_sel == '' {
				app.notify('select a folder or a file first')
			} else {
				activate = true
			}
		}
		vgui.same_line()
	}
	if vgui.button('Cancel') {
		app.fb_open = false
	}
	vgui.end()
	if activate && on == '' && app.fb_sel != '' {
		// The selection is a row of the listing, or nothing: a name that is in neither list
		// (typed and then rejected, or gone since the listing was read) is not acted on.
		if app.fb_dirs.contains(app.fb_sel) {
			on = app.fb_sel
			on_kind = .dir
		} else if app.fb_files.contains(app.fb_sel) {
			on = app.fb_sel
			on_kind = .file
		}
	}
	if on != '' {
		match pickrule.activate(on_kind, app.fb_save) {
			.enter {
				// a drive root is a whole path already; joined onto the empty view it would be relative
				app.fb_enter(if at_drives { on } else { fb_join(app.fb_dir, on) })
			}
			.accept {
				chosen = fb_join(app.fb_dir, on)
			}
			.select {}
		}
	}
	if chosen != '' {
		app.browser_confirm(chosen)
	}
}

// match_ext reports whether a filename passes the browser's current extension filter.
// The project filter also accepts legacy `.yml`/`.yaml`; an empty filter accepts anything.
fn (app &App) match_ext(name string) bool {
	if app.fb_ext.len == 0 {
		return true
	}
	n := name.to_lower()
	for e in app.fb_ext {
		if n.ends_with(e) {
			return true
		}
	}
	return false
}

// draw_discover_dialog is the "Discover interfaces" dialog (mirrors the old app): it lists
// every detected transport — real CAN hardware (with product/state), vcan, a UDP bus, an
// in-process sim net — with tick boxes and + Add ticked, plus + vcan / + Sim net quick-adds.
fn draw_discover_dialog(mut app App) {
	// A list with a hardware section under it: sized for both (#270 item 6).
	vgui.set_next_window(160, 90, 960, 640)
	vis, op := vgui.begin_dialog('Discover interfaces', app.disc_open)
	app.disc_open = op
	if !vis {
		vgui.end()
		return
	}
	busy, landed, note := app.cansub_browse_state()
	if landed {
		// A browse landed since the list was built: merge its rows, on this thread, ticks kept.
		app.rebuild_discover_list()
	}
	if vgui.button('Refresh') {
		app.refresh_discovery()
		app.start_cansub_browse()
	}
	// LOOKING IS FINE WHILE RUNNING; ADDING A BUS IS NOT. The three buttons in THIS group each
	// add one, which rebuilds the runtime view — app.chans emptied and re-appended — under the
	// readers of a live run. Refresh above only re-reads the drivers, so it stays. The same rule
	// the Configuration editor has always had, in the one dialog that could still reach a rebuild
	// mid-measurement (the drain in rebuild_from_proj cannot help here: these workers are not
	// leaving, they belong to the run that is still on).
	//
	// SCOPED TO THESE THREE, and said so rather than "every button below": the per-row Assign
	// further down writes VECTOR DRIVER state, not this app's, and is a different question with
	// a different answer — see #288.
	if app.running {
		vgui.same_line()
		vgui.text_dim('(stop the measurement to add buses)')
	} else {
		vgui.same_line()
		if vgui.button('+ vcan') {
			app.add_bus_spec('vcan', app.next_free_vcan())
			app.refresh_discovery()
		}
		vgui.same_line()
		if vgui.button('+ Sim net') {
			app.add_bus_spec('virtual', app.unique_bus_name('SIM'))
			app.refresh_discovery()
		}
		vgui.same_line()
		if vgui.button('+ Add ticked') {
			for k, d in app.disc_list {
				if k < app.disc_tick.len && app.disc_tick[k] && !d.added {
					app.add_bus_spec(d.adapter, d.address)
				}
			}
			app.refresh_discovery()
		}
	}
	vgui.separator()
	if app.disc_list.len == 0 {
		vgui.text_dim('click Refresh to scan for interfaces')
	}
	if busy {
		vgui.text_dim('browsing mDNS for CANsub devices…')
	} else if note != '' {
		// Could not LOOK, or could ask only some interfaces -- which is not the same as none
		// attached: said, not blanked (#192).
		vgui.text_colored(u8(240), u8(150), u8(60), note)
	}
	// One column per fact, so the rows line up (#270 item 6). Content-sized: a scrolling table
	// with no height would take the whole dialog and push the Vector section below out of reach.
	// With a hardware section under it the list sits in a child of draggable height (#306): the
	// clamp before the child is drawn, a drag persists, unscaled like the other dividers.
	sc := app.prefs.ui_scale
	boxed := app.disc_vector.len > 0 && app.disc_list.len > 0
	mut box_h := f32(0)
	box_min := 60 * sc
	box_max := vgui.content_avail_h() - 200 * sc // the hardware section, the tip and Close keep room
	if boxed {
		mut kept := f32(0)
		box_h, kept = panerule.drawn(app.disc_list_h, 160, sc, box_min, box_max)
		app.disc_list_h = kept
		vgui.child_begin('##disc_list_box', box_h)
	}
	if app.disc_list.len > 0 && vgui.table_begin_flat('##disc_ifaces', 4) {
		vgui.table_setup_col('add', 52 * sc)
		vgui.table_setup_col('address', 240 * sc)
		vgui.table_setup_col('adapter', 90 * sc)
		vgui.table_setup_col('description', 0)
		vgui.table_headers()
		for k, d in app.disc_list {
			vgui.table_row()
			vgui.table_next_col()
			if d.added {
				vgui.text_dim('added')
				vgui.table_cell_dim(d.address)
				vgui.table_cell_dim(d.adapter)
				vgui.table_cell_dim(d.desc)
				continue
			}
			t := if k < app.disc_tick.len { app.disc_tick[k] } else { false }
			nt := vgui.checkbox('##dt${k}', t)
			if nt != t && k < app.disc_tick.len {
				app.disc_tick[k] = nt
			}
			vgui.table_cell(d.address)
			vgui.table_cell(d.adapter)
			vgui.table_cell(d.desc)
		}
		vgui.table_end()
	}
	if boxed {
		vgui.child_end()
		moved := vgui.splitter_h('##disc_split', box_h, box_min, box_max)
		app.disc_list_h = app.pane_moved('discover_list', app.disc_list_h, box_h, moved, sc)
	}
	// VECTOR HARDWARE, below the interfaces and separate from them on purpose. The list above is
	// "what could this app open"; a channel nothing is mapped to cannot appear in it, and those
	// are precisely the ones a fresh bench has (#186). Drawn only where there is Vector hardware
	// to talk about, so nothing changes for a bench without it.
	if app.disc_vector.len > 0 {
		vgui.separator()
		vgui.text('Vector hardware')
		vgui.same_line()
		vgui.help_marker('The XL library addresses APPLICATION channels, not hardware, so a physical channel must be mapped to one of ours before it can be opened. This writes only under the application name "blobly_net" — another application\'s assignments (CANoe, CANalyzer) are not touched. The mapping is stored by the driver and survives reboots.')
		// THE FIRST-RUN STATE, said plainly. A bench that has never run this app — or one where
		// somebody deleted the application in Vector Hardware Manager — has hardware and no
		// mappings, and every per-channel lookup fails. Without this the section would show a
		// list of Assign buttons with no explanation of why nothing is mapped, and the Log would
		// carry a driver-malfunction message for an ordinary, fixable state (#190).
		// WHAT WAS OBSERVED, not what it implies. Nothing answering is what an absent application
		// looks like — and also what a driver that has stopped answering looks like, which vxlapi
		// gives no way to tell apart. The sentence is true either way, and the ACTION is safe
		// either way, so the dialog does not need the certainty it cannot have (codex #192 r2).
		vgui.same_line()
		vgui.set_next_item_width(50)
		vgui.input_text('application channel to assign##vach', mut app.disc_vector_ch_buf)
		vgui.same_line()
		vgui.help_marker('The number this hardware becomes: type 2 and the channel opens as `vector:2`. Any 1-64 that is not already assigned; the mapped rows below show which are taken. Nothing is proposed for you — the driver cannot reliably tell an unused channel from one it simply could not read, so the number is yours to choose.')
		// WHICH CHANNELS THE DRIVER CONFIRMED FREE. Reporting is not proposing: nothing here picks
		// one, and the operator may still type any number. But refusing `vector:2` as unreadable
		// while offering no hint of what WOULD work is a dead end, and the sweep already knows —
		// so it says, and the choice stays theirs (#192, option 3).
		if app.disc_vector_free != '' {
			vgui.text_dim('   application channels the driver reports free: ${app.disc_vector_free}')
		}
		// THE ONE WRITE THE DRIVER CANNOT VOUCH FOR, so the operator says it rather than the code
		// guessing. An unregistered channel and a momentary read failure on an OCCUPIED one are the
		// same generic XL error, and no retry separates them — see assign_refusal. Off by default,
		// so a mistyped number cannot silently retarget a persistent mapping (codex #192 r9).
		app.disc_vector_create = vgui.checkbox('create unregistered channel##vacreate',
			app.disc_vector_create)
		vgui.same_line()
		vgui.help_marker('Needed only for a channel the application does not have yet — including every channel on a bench where "blobly_net" has never run. The driver reports "no such channel" with its GENERIC error, which is also what one failed read of an occupied channel looks like, so this asks you to confirm you mean to create rather than replace.')
		if !app.disc_vector_app_seen {
			vgui.text_dim('   no application channels could be read for "blobly_net" — assigning below creates the mapping (and the application, if it is not there)')
		}
		// The same shape as the interface list above: one column per fact (#270 item 6). One row
		// body: the first column says the channel's state, the other two are the hardware.
		if vgui.table_begin_flat('##disc_vector', 3) {
			vgui.table_setup_col('channel', 170 * sc)
			vgui.table_setup_col('hardware', 230 * sc)
			vgui.table_setup_col('transceiver · bitrate · CAN-FD', 0)
			vgui.table_headers()
			for vm in app.disc_vector {
				// THE TRANSCEIVER'S OWN VERDICT on CAN-FD, from the driver rather than its part
				// number (#187). Blank for a channel that carries none — a D/A IO card, say.
				fd := vm.hw.fd_note()
				rate := if vm.hw.bitrate > 0 { '${vm.hw.bitrate}' } else { '-' }
				detail := '${vm.hw.transceiver} · ${rate}${if fd == '' {
					''
				} else {
					' · CAN-FD ${fd}'
				}}'
				// Offered — an Assign button — only when unmapped, CAN, and KNOWN to be unowned:
				offered := vm.app == 0 && vm.hw.can_capable && vm.owner_known
				vgui.table_row()
				vgui.table_next_col()
				if vm.app > 0 {
					// Already ours: name the address, because that is what a Buses row will carry.
					vgui.text_dim('vector:${vm.app}')
				} else if !vm.hw.can_capable {
					// NOT EVERY CHANNEL IS A CAN CHANNEL. A VN1630A reports its D/A IO channel here
					// alongside the four CAN ones, and everything this dialog assigns is addressed as
					// CAN — so an Assign button on that row could only produce a mapping that fails to
					// open as the interface it was offered as. Listed, because it is real hardware and
					// its absence would read as a missing channel; not offered (codex #192 r1).
					vgui.text_dim('(not a CAN channel)')
				} else if !vm.owner_known {
					// UNOWNED, OR MERELY NOT SEEN TO BE OWNED? An application channel that would not
					// answer may be pointing at this very row, so offering Assign here would invite the
					// operator to create the #167 alias — two application channels on one physical
					// wire. Shown, because the hardware is real and hiding it reads as a missing
					// channel; not offered, and the row says which of the two it is (codex #192 r6).
					vgui.text_dim('(owner unknown)')
					vgui.same_line()
					vgui.help_marker('The driver did not answer for every application channel, so this hardware may already be assigned to one of the channels it would not describe. Refresh to ask again.')
				} else {
					// UNMAPPED. The button is the only path that writes; see assign_vector_hw. The
					// channel number comes from the field above — NOTHING PROPOSES ONE. Four rounds of
					// review went into inferring which application channels were free, and the fourth
					// pair of findings contradicted each other, because vxlapi cannot separate "outside
					// the application's channel list" from "failed this time". The operator knows
					// which number they want; asking is both safer and shorter than any inference
					// (#192, option 3).
					if vgui.small_button('Assign##va${vm.hw.hw_type}_${vm.hw.hw_index}_${vm.hw.hw_channel}') {
						n := vgui.buf_str(app.disc_vector_ch_buf).trim_space()
						if n == '' || !project.is_all_digits(n) {
							app.notify('type the Vector application channel to assign (1-64) before pressing Assign')
						} else {
							app.assign_vector_hw(vm.hw, n.int())
						}
					}
					vgui.same_line()
					vgui.text_dim('(unassigned)')
				}
				if offered {
					vgui.table_cell(vm.hw.name)
				} else {
					vgui.table_cell_dim(vm.hw.name)
				}
				vgui.table_cell_dim(if vm.hw.can_capable { detail } else { vm.hw.transceiver })
			}
			vgui.table_end()
		}
	}
	vgui.separator()
	vgui.text_dim('Tip: a PCAN/Kvaser device on Linux/WSL appears here as SocketCAN (canN) — add those, not the pcan/kvaser adapter (Windows-only).')
	if vgui.button('Close##disc') {
		app.disc_open = false
	}
	vgui.end()
}

// draw_config is the dedicated Configuration editor (File → Configure…): add/edit/remove
// buses, pick adapters, attach DBCs. Stopped-only; Save persists to the .blobnet.
fn draw_config(mut app App) {
	vgui.set_next_window(120, 90, 720, 620)
	was_open := app.show_config
	vis, op := vgui.begin_dialog('Configuration', app.show_config)
	app.show_config = op
	if was_open && !op && !app.running && app.dirty {
		app.apply_edits() // closed via the [X] with unsaved edits — fold them into model + runtime
	}
	if !vis {
		vgui.end()
		return
	}
	if app.running {
		vgui.text_dim('Measurement running — Stop to edit the configuration.')
		if vgui.button('Close') {
			app.show_config = false
		}
		vgui.end()
		return
	}
	if app.cfg_bufs.len != app.proj.channels.len {
		app.sync_cfg_bufs()
	}
	// Two views of one configuration: the structured bus editor, and the file itself. The file
	// tab exists because most of what a project says — simulated ECUs, generators, responses,
	// protection, per-ECU UDS, verification, senders — has no structured editor at all, so
	// without it those are only reachable by leaving the app.
	if vgui.small_button(if app.cfg_tab == 0 { '[ Buses ]' } else { '  Buses  ' }) {
		app.cfg_tab = 0
	}
	vgui.same_line()
	if vgui.small_button(if app.cfg_tab == 1 { '[ File ]' } else { '  File  ' }) {
		app.cfg_tab = 1
		app.load_cfg_text()
	}
	// Close on the tab row, so BOTH tabs carry it — a dialog's Close is not the X alone (#306);
	// on the Buses tab it also folds unsaved bus edits into the model, as the X does.
	vgui.same_line()
	if vgui.button('Close') {
		app.show_config = false
		if app.dirty {
			app.apply_edits() // fold unsaved edits into the model + runtime view on close
		}
	}
	vgui.separator()
	if app.cfg_tab == 1 {
		app.cfg_file_visible = true // drawn this frame — see save_what_is_being_edited
		app.load_cfg_text() // every frame: a no-op while typing, and correct after a switch
		app.draw_config_text()
		vgui.end()
		return
	}
	if vgui.button('+ Add bus') {
		app.add_bus()
	}
	vgui.same_line()
	if vgui.button('Discover...') {
		app.refresh_discovery()
		app.start_cansub_browse()
		app.disc_open = true
	}
	if app.dirty || app.cfg_file.dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified')
	}
	vgui.separator()
	if app.proj.channels.len == 0 {
		vgui.text_dim('no buses — click "+ Add bus" to start a configuration')
		vgui.end()
		return
	}
	for i in 0 .. app.proj.channels.len {
		if app.draw_bus_editor(i) {
			break // a bus was removed — indices shifted, redraw next frame
		}
	}
	vgui.end()
}

// draw_bus_editor renders one bus as a tree node: an enable checkbox + a header summary on
// the collapsed row, expanding to the editable fields. Returns true if the bus was removed
// (indices shifted — the caller stops iterating this frame). Enum/checkbox edits apply to
// app.proj live; text fields are flushed by commit_cfg on Save / structural change.
fn (mut app App) draw_bus_editor(i int) bool {
	ch := app.proj.channels[i]
	// header row: enable checkbox + the tree node (name · adapter:address · network)
	en := vgui.checkbox('##cfgen${i}', ch.enabled)
	if en != ch.enabled {
		app.proj.channels[i].enabled = en
		app.dirty = true
	}
	vgui.same_line()
	vgui.set_item_tooltip('enable this bus (attached on Start)')
	nm := vgui.buf_str(app.cfg_bufs[i].name_buf)
	addr := if ch.address != '' { ':${ch.address}' } else { '' }
	net := if ch.network != '' { '  ·  ${ch.network}' } else { '' }
	dis := if ch.enabled { '' } else { '   — disabled' } // visible feedback for the enable checkbox
	// header: collapsible tree node + a remove button that works whether expanded or not.
	// Use ### so the imgui ID is fixed to `bus<i>` — the visible label (adapter/address/name)
	// changes as you edit, and with plain ## that would re-key the node and collapse it.
	open := vgui.tree_node('${nm}   [${ch.adapter}${addr}]${net}${dis}###bus${i}')
	vgui.same_line()
	if vgui.small_button('remove##crm${i}') {
		if open {
			vgui.tree_pop()
		}
		app.remove_bus(i)
		return true
	}
	if !open {
		return false
	}
	// name · network
	vgui.set_next_item_width(160)
	if vgui.input_text('name##cn${i}', mut app.cfg_bufs[i].name_buf) {
		app.dirty = true
	}
	vgui.same_line()
	vgui.set_next_item_width(140)
	if vgui.input_text('network##cnw${i}', mut app.cfg_bufs[i].network_buf) {
		app.dirty = true
	}
	vgui.same_line()
	vgui.help_marker('Optional label grouping buses of one logical vehicle network. Buses that share a network name are grouped in the Buses tree and the Trace bus chips.')
	// adapter picker + tooltip (only backends usable on this platform)
	vgui.text('adapter:')
	vgui.same_line()
	vgui.help_marker(adapter_tip(ch.adapter))
	for a in available_adapters(ch.adapter) {
		vgui.same_line()
		if vgui.toggle_button('${a}##ad${i}_${a}', ch.adapter == a, 0) {
			app.set_adapter(i, a)
		}
	}
	// address (type it, or add detected interfaces via the Discover... dialog above)
	vgui.set_next_item_width(220)
	if vgui.input_text('address##cad${i}', mut app.cfg_bufs[i].address_buf) {
		old_iface := app.proj.channels[i].iface
		mut typed := vgui.buf_str(app.cfg_bufs[i].address_buf)
		// THE SAME LIFT the project loader does. A `,silent` typed here used to stay in the
		// address, so the port opened ACK-free while the model went on calling the channel
		// transmit-capable — no listen-only shown anywhere, and sends refused one frame at a
		// time. One rule, applied wherever an address can be written.
		if ch.adapter == 'vector' {
			stripped, want_silent, recognised := project.split_vector_mode(typed)
			had_suffix := stripped != typed
			if stripped != typed {
				// BACK INTO THE BUFFER as well. Normalising only the project value left
				// `1,silent` in the text field, and the next commit_cfg copied it back — the
				// interface flipping from `vector:1` to `vector:1,silent` behind the operator,
				// after which every generator bound to the old spelling no longer matched its
				// own bus. What the field shows has to be what the model holds.
				app.cfg_bufs[i].address_buf = mkbuf(stripped, 64)
			}
			typed = stripped
			// AGAINST WHAT WAS TYPED, which is `had_suffix` — captured before the buffer was
			// rewritten just above. Comparing with the buffer afterwards compared the stripped
			// value against itself and was always false, so `,normal` on a listen-only channel
			// still opened silent: the guard for the explicit request was unreachable.
			if recognised && had_suffix {
				// BOTH WAYS. `,normal` is an explicit request to acknowledge; setting the flag
				// only when the suffix said silent left a listen-only channel — a discovered
				// one starts that way — silent while its address said otherwise.
				app.proj.channels[i].listen_only = want_silent
			} else if want_silent {
				app.proj.channels[i].listen_only = true
			}
		}
		app.proj.channels[i].address = typed
		new_iface := project.compose_iface(ch.adapter, app.proj.channels[i].address)
		// BEFORE the assignment: rebind_senders resolves `bus:` against the project as it stands,
		// and moves only THIS row's generators (codex round 1 on #97).
		app.rebind_senders(i, old_iface, new_iface) // keep this bus's generators bound
		app.proj.channels[i].iface = new_iface
		app.dirty = true
	}
	vgui.same_line()
	vgui.text_dim(adapter_hint(ch.adapter))
	// pick from detected: the SAME list the Discover... dialog shows, applied to THIS row.
	// The mDNS browse lands on its own thread, so the row folds it in just as the dialog does.
	_, landed, _ := app.cansub_browse_state()
	if landed {
		app.rebuild_discover_list()
	}
	if vgui.small_button('rescan##pk${i}') { // a word: the font has no ↻ (#306)
		app.refresh_discovery()
		app.start_cansub_browse()
	}
	vgui.same_line()
	vgui.help_marker('Detect interfaces (SocketCAN/vcan on this host, CANsub devices by mDNS) and point this bus at one. Only the adapter and address change; the name, bitrates, DBCs and manifests stay.')
	vgui.same_line()
	vgui.set_next_item_width(360)
	sel := vgui.combo('##pick${i}', pick_items(app.disc_list), 0)
	if sel > 0 && sel - 1 < app.disc_list.len {
		d := app.disc_list[sel - 1]
		app.retarget_bus(i, d.adapter, d.address)
		app.refresh_discovery() // the [in project] marks follow the edit
	}

	if ch.adapter == 'doip' {
		vgui.set_next_item_width(90)
		if vgui.input_text('tester##ct${i}', mut app.cfg_bufs[i].tester_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.set_next_item_width(90)
		if vgui.input_text('ecu##ce${i}', mut app.cfg_bufs[i].ecu_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('DoIP logical addresses (ISO 13400): the tester (source) and ECU (target), e.g. 0x0E80 / 0x1000. They replace the CAN diagnostic id pair.')
		vgui.set_next_item_width(180)
		if vgui.input_text('vin##cv${i}', mut app.cfg_bufs[i].vin_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('17-character VIN reported by this entity in vehicle announcements (only used when this DoIP bus hosts a simulated entity).')
	} else {
		vgui.text('protocol:')
		for pr in ['can', 'canfd'] {
			vgui.same_line()
			if vgui.toggle_button('${pr}##pr${i}_${pr}', ch.typ == pr, 0) {
				app.set_protocol(i, pr)
			}
		}
		vgui.same_line()
		vgui.set_next_item_width(90)
		if vgui.input_text('bitrate##cb${i}', mut app.cfg_bufs[i].bitrate_buf) {
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('Nominal bit rate in bit/s (e.g. 500000). For virtual/vcan buses this is informational; for real hardware it configures the interface.')
		// ONLY WHEN THE CHANNEL IS FD, because on a classic channel there is no data phase for the
		// number to describe — an always-visible field would invite a value that nothing reads and
		// that a save would then persist as a property of a classic bus.
		// ONLY WHERE IT CAN BE CONFIGURED. On a classic row there is no data phase for the number
		// to describe — an editable field there invites a value nothing reads, which a Save would
		// then persist as a property of a bus that cannot have it. Every CAN backend carries FD
		// since #217, so the adapter half of this rule has no example left; the classic-row half
		// still does. Start says what a CAN-FD row means on the chosen adapter
		// (project.fd_capability_warnings, issue #170).
		if ch.fd && ch.can_carry_fd() {
			vgui.same_line()
			vgui.set_next_item_width(90)
			if vgui.input_text('data rate##cd${i}', mut app.cfg_bufs[i].dbitrate_buf) {
				app.dirty = true
			}
			vgui.same_line()
			// THE LIST IS DERIVED, NOT WRITTEN OUT. This said "configured by the Vector backend"
			// and went on saying it after Kvaser, CANsub and then PCAN could configure a data
			// phase too — telling operators their entered rate was ignored when it was not
			// (codex round 4 on #217). `adapter_configures_data_phase` is the one place that
			// answers, so the tooltip asks it rather than keeping a copy that drifts.
			configures := project.adapters.filter(transport.adapter_configures_data_phase(it))
			vgui.help_marker('CAN-FD data-phase bit rate in bit/s (e.g. 2000000) — the faster rate the payload is sent at. Leave empty to run the data phase at the nominal rate, which is CAN-FD without a bit-rate switch (64-byte payloads, no speed-up). Configured from the address by ${configures.join(', ')}; on SocketCAN the link carries it (ip link ... dbitrate).')
		}
		vgui.text('mode:')
		vgui.same_line()
		vgui.help_marker('normal = live traffic in and out · replay = play a recording onto the bus. To keep a row out of a run, untick it; to keep it from transmitting, tick listen-only.')
		for md in ['normal', 'replay'] {
			vgui.same_line()
			if vgui.toggle_button('${md}##md${i}_${md}', ch.mode.str() == md, 0) {
				app.set_mode(i, md)
			}
		}
		vgui.same_line()
		lo := vgui.checkbox('listen-only##lo${i}', ch.listen_only)
		if lo != ch.listen_only {
			app.proj.channels[i].listen_only = lo
			app.dirty = true
		}
		vgui.same_line()
		vgui.help_marker('Listen-only: this tester transmits NOTHING on the wire — not Quick Send, generators, simulated ECUs, replay, diagnostics or scripts. On Vector the transceiver is put in silent mode as well, so it does not even acknowledge; every other adapter still ACKs what it hears.')
		if ch.mode == .replay {
			vgui.text('replay:')
			vgui.same_line()
			vgui.set_next_item_width(220)
			if vgui.input_text('source##rs${i}', mut app.cfg_bufs[i].replay_src_buf) {
				app.dirty = true
				// the Replay panel's grouping reads this buffer (the pending source is what
				// Start will fold) — regroup as it changes (codex #136 r3)
				app.replay_view_gen++
			}
			vgui.same_line()
			if vgui.small_button('...##rsbrowse${i}') {
				app.open_browser('replaysrc:${i}')
			}
			vgui.same_line()
			vgui.help_marker("Recording to play on this channel (.log or .mf4). A multi-bus .mf4 needs a `bus:` key in the .blobnet naming WHICH recorded bus feeds this channel (the file's own bus name, or its `mf4:groupN` label) — the recording's names are not this project's, so nothing can infer the pairing; without it a multi-bus source is refused at Start. Channels replaying the same source play on ONE clock.")
			vgui.same_line()
			vgui.set_next_item_width(56)
			if vgui.input_text('x speed##rsp${i}', mut app.cfg_bufs[i].replay_speed_buf) {
				app.dirty = true
			}
			vgui.same_line()
			loopv := if r := ch.replay { r.repeat } else { false }
			nl := vgui.checkbox('loop##rl${i}', loopv)
			if nl != loopv {
				src := vgui.buf_str(app.cfg_bufs[i].replay_src_buf)
				spd := vgui.buf_str(app.cfg_bufs[i].replay_speed_buf).f64()
				// ...old for the same reason as commit_cfg: one click on a checkbox must not
				// delete the keys this dialog cannot edit.
				old := app.proj.channels[i].replay or { project.Replay{} }
				app.proj.channels[i].replay = project.Replay{
					...old
					source: src
					speed:  if spd > 0 { spd } else { 1.0 }
					repeat: nl
				}
				app.dirty = true
			}
			if app.draw_replay_scan(i, ch) {
				vgui.tree_pop()
				return true
			}
		}
	}
	// databases
	vgui.text('databases:')
	vgui.same_line()
	vgui.help_marker('DBC files describing this bus/network — used to decode frames into signals and to drive the simulated ECUs.')
	for di, dbp in ch.databases {
		vgui.text('   ${dbp}')
		vgui.same_line()
		if vgui.small_button('x##dbrm${i}_${di}') {
			app.remove_dbc(i, di)
			vgui.tree_pop()
			return true
		}
	}
	if vgui.small_button('+ Add DBC##adddbc${i}') {
		app.open_browser('dbc:${i}')
	}
	// manifest
	vgui.set_next_item_width(220)
	if vgui.input_text('manifest##cmf${i}', mut app.cfg_bufs[i].manifest_buf) {
		app.proj.channels[i].manifest = vgui.buf_str(app.cfg_bufs[i].manifest_buf)
		app.dirty = true
	}
	vgui.same_line()
	if vgui.small_button('...##mfbrowse${i}') {
		app.open_browser('manifest:${i}')
	}
	vgui.same_line()
	vgui.help_marker('Optional telemetry handler manifest (CSV) — resolves handler ids to FB/handler/core for the Trace Chart.')
	vgui.tree_pop()
	return false
}

fn draw_doip(mut app App) {
	vis, op := vgui.begin_dialog('DoIP Discovery', app.show_doip)
	app.show_doip = op
	if !vis {
		vgui.end()
		return
	}
	vgui.set_next_item_width(160)
	vgui.input_text('host', mut app.doip_host_buf)
	vgui.same_line()
	if vgui.button('Discover') {
		app.mu.lock()
		app.doip_ents = []
		app.mu.unlock()
		spawn doip_worker(app, vgui.buf_str(app.doip_host_buf))
	}
	app.mu.lock()
	ents := app.doip_ents.clone()
	app.mu.unlock()
	vgui.separator_text('entities')
	if ents.len == 0 {
		vgui.text_dim('none — Discover a DoIP host (default 127.0.0.1:13400)')
	}
	for e in ents {
		vgui.text('VIN ${e.vin}   logical 0x${e.logical_address:04X}')
	}
	vgui.separator()
	if vgui.button('Close##doip') {
		app.show_doip = false
	}
	vgui.end()
}

// draw_config_text is the File tab: edit the project as text, validate, write it back.
fn (mut app App) draw_config_text() {
	if app.dirty {
		// The two tabs edit different things — app.proj versus the file on disk — and either
		// action below overwrites one side, so say which is at risk before offering it.
		vgui.text_colored(230, 170, 70,
			'● unsaved edits in the model (buses/generators) are not in this text')
		if app.cfg_file.dirty {
			// Both sides modified: writing the model would overwrite the typing, so that
			// action is withheld rather than offered and silently destructive.
			vgui.text_colored(230, 120, 120,
				'  …and this text has unsaved edits too — Save the text, or Revert it, before folding bus edits in')
			if vgui.small_button('Revert the text') {
				app.cfg_invalidate() // clearing the flag alone leaves the cache holding the edits
				app.load_cfg_text()
			}
		} else {
			if vgui.small_button('Save those edits into the file') {
				app.save_project()
				app.load_cfg_text() // re-read what was just written
			}
			vgui.same_line()
			// "bus edits" was too narrow: app.dirty is also set by the Generators panel, and
			// revert re-reads the whole project, so a generator edit went with it under a label
			// that did not mention it.
			if vgui.small_button('Discard ALL unsaved edits (buses + generators)') {
				app.revert_proj_from_disk()
			}
		}
		vgui.separator()
	}
	// Gated, not merely ignored on click: os.write_file('') fails, and Save As serialises the
	// MODEL, which would throw away the text the user is looking at. The button says what it
	// writes: the TEXT, which is not the same save as Ctrl+S on any other tab
	// (save_what_is_being_edited).
	can_save := app.cfg_file.err == '' && app.proj_path != ''
	shown := if app.proj_path == '' { '(unsaved project)' } else { app.proj_path }
	match draw_textfile_strip(app.cfg_file, 'cfg', 'Save text', can_save, shown,
		app.proj_path != '') {
		.external {
			app.open_in_editor(app.proj_path)
		}
		.save {
			app.save_cfg_text()
		}
		.reload {
			app.cfg_invalidate()
			app.load_cfg_text()
		}
		.none {}
	}

	if app.cfg_file.err == '' {
		// The channel count, not just "OK": an empty file parses perfectly and yields zero
		// channels, so "OK" alone would reassure someone whose edit had emptied the project.
		// Cached — recomputing it per frame reparsed the whole document at frame rate, and a
		// typing frame parsed it twice.
		n := app.cfg_chans
		if n == 0 && app.proj.channels.len > 0 {
			vgui.text_colored(230, 170, 70,
				'YAML is well-formed but yields NO channels — saving would empty this project')
		} else {
			vgui.text_dim('YAML well-formed · ${n} channel(s) — syntax only, not a config check')
		}
	}
	if vgui.text_edit('##cfgtext', mut app.cfg_file.buf, 460) {
		// Validate as you type, so a mistake is visible where it was made rather than at Save.
		app.cfg_file.dirty = true
		t := vgui.buf_str(app.cfg_file.buf)
		app.cfg_file.err = cfg_text_error(t)
		app.cfg_chans = cfg_text_channels(t)
	}
}

// draw_replay_scan is the Configure replay row's Scan surface: read the recording and show
// what is IN it — its buses, and who talks on each through this channel's databases — so
// `bus:` and the rest-bus exclusions are picked from what the file and the DBC say instead of
// typed from memory. Display-only state; Start loads the recording for itself either way.
// Returns true when it mutated the project (the caller pops the tree node and ends the pass,
// the same contract as remove_bus).
fn (mut app App) draw_replay_scan(i int, ch project.Channel) bool {
	src_now := vgui.buf_str(app.cfg_bufs[i].replay_src_buf)
	rp := app.resolve_asset(src_now)
	mut sc_have := false
	mut sc_loading := false
	mut sc_err := ''
	mut sc_buses := []mf4.BusInfo{}
	mut sc_census := map[string]player.NodeCensus{}
	app.mu.lock()
	if sc := app.replay_scans[i] {
		// results for the file the ROW now names, only: after Browse or a typed edit the old
		// census describes a recording this channel no longer plays, and `use`/ticks would
		// write its labels and node names into the wrong file's config
		if sc.src == rp {
			sc_have = true
			sc_loading = sc.loading
			sc_err = sc.err
			sc_buses = sc.buses.clone()
			sc_census = sc.census.clone()
		}
	}
	app.mu.unlock()
	if sc_loading {
		vgui.text_dim('   scanning ${os.base(src_now)}…')
		return false
	}
	if src_now != '' && !sc_have {
		if vgui.small_button('Scan recording##rscan${i}') {
			app.start_replay_scan(i, rp)
		}
		vgui.same_line()
		vgui.help_marker('Decode the recording and list its buses and, per bus, the nodes the attached DBCs attribute frames to — with counts, so the ECU under test (usually the busiest) is easy to spot and exclude.')
		return false
	}
	if sc_err != '' {
		vgui.text_colored(230, 80, 80, '   scan: ${sc_err}')
		vgui.same_line()
		// the path is only ONE ingredient of the result: the file behind it can be created,
		// repaired or re-recorded without the path changing, so a terminal state always
		// keeps a way back to the button (codex #135 r2)
		if vgui.small_button('retry##rscan${i}') {
			app.start_replay_scan(i, rp)
		}
		return false
	}
	if !sc_have {
		return false
	}
	if vgui.small_button('Rescan##rscan${i}') {
		// same reason as the retry above: same path, possibly a different file by now
		app.start_replay_scan(i, rp)
		return false
	}
	// WHICH bus the config means is the module's question, never re-answered here: the GUI
	// and cmd/restbus each grew a copy of this rule once and drifted, which is why
	// player.resolve_bus exists — an inline match would be copy number three, and its
	// divergences (last-match-wins on an ambiguous name, a stale `bus:` silently shown as
	// selected) were exactly what the self-review caught in the first draft of this panel.
	cur_bus := if r := ch.replay { r.bus } else { '' }
	mut names := []player.BusName{}
	mut labels := []string{}
	for b in sc_buses {
		names << player.BusName{
			iface: b.iface
			name:  b.name
		}
		labels << b.iface
	}
	mut sel := ''
	mut sel_err := ''
	sel = player.resolve_bus(names, labels, cur_bus) or {
		sel_err = err.msg()
		''
	}
	for b in sc_buses {
		b_nm := if b.name != '' { " '${b.name}'" } else { '' }
		mark := if sel == b.iface && cur_bus != '' { '>' } else { ' ' }
		vgui.text('   ${mark} ${b.iface}${b_nm}  ${b.frames} frames')
		if sc_buses.len > 1 || cur_bus != '' {
			vgui.same_line()
			if cur_bus != '' && sel == b.iface {
				if vgui.small_button('clear##rbusc${i}') {
					app.set_replay_bus(i, '')
					return true
				}
			} else if vgui.small_button('use##rbus${i}_${b.iface}') {
				app.set_replay_bus(i, b.iface)
				return true
			}
		}
	}
	if cur_bus != '' && sel == '' {
		// the config names a bus this recording does not hold (or an ambiguous name) — the
		// exact refusal Start will give, shown before Start gives it
		vgui.text_colored(230, 80, 80, '   bus: `${cur_bus}` — ${sel_err}')
		vgui.same_line()
		if vgui.small_button('clear##rbusx${i}') {
			app.set_replay_bus(i, '')
			return true
		}
		return false
	}
	if sel == '' {
		vgui.text_dim('   several buses — `use` one to see who talks on it (and to satisfy `bus:`)')
		return false
	}
	cn := sc_census[sel] or { return false }
	cur_ex := if r := ch.replay { r.exclude.clone() } else { []string{} }
	// every node the DBCs attribute frames to, plus any already-excluded name the census
	// does not see — visible so its tick can be removed
	mut nodenames := cn.nodes.keys()
	for x in cur_ex {
		if x !in nodenames {
			nodenames << x
		}
	}
	nodenames.sort()
	if nodenames.len > 0 {
		vgui.text_dim('   tick a node to EXCLUDE it from replay — the ECU under test stays the only sender of its own frames:')
	} else {
		vgui.text_dim('   the attached DBCs attribute no frames on this bus to any node — nothing to exclude by sender')
	}
	for n in nodenames {
		cnt := cn.nodes[n] or { 0 }
		was := n in cur_ex
		vgui.text('     ')
		vgui.same_line()
		if vgui.checkbox('${n}  —  ${cnt} frames##rex${i}_${n}', was) != was {
			mut ex := cur_ex.clone()
			if !was {
				ex << n
			} else {
				ex = ex.filter(it != n)
			}
			app.set_replay_exclude(i, ex)
			return true
		}
	}
	if cn.unattributed > 0 || cn.unknown > 0 || cn.remote > 0 {
		// The remote count is its own clause rather than folded into the first: those frames ASK
		// for an id instead of sending it, so the DBC attributes the id perfectly well and simply
		// cannot say who requested it (#179). Summed with the no-transmitter frames, the number a
		// user reads as "the DBC is incomplete" would grow for a reason that is not that.
		// EACH CLAUSE ONLY WHEN IT HAS SOMETHING TO SAY. Widening the guard without doing this
		// left the first two unconditional, so a bus carrying only remote requests announced
		// "0 frames carry no declared sender · 0 are on ids the DBCs do not define" before the one
		// number that was not zero (self-review).
		mut parts := []string{}
		if cn.unattributed > 0 {
			parts << '${cn.unattributed} frames carry no declared sender'
		}
		if cn.unknown > 0 {
			parts << '${cn.unknown} are on ids the DBCs do not define'
		}
		// ONLY IF THERE IS SOMETHING TO SUMMARISE. A recording of nothing but remote requests
		// leaves `parts` empty, and this rendered a bare "— all replay regardless" directly above
		// the line saying they are not replayed: two lines contradicting each other, which is the
		// thing the split was meant to end (codex round 2 on #216).
		if parts.len > 0 {
			vgui.text_dim('   ${parts.join(' · ')} — all replay regardless')
		}
		// SEPARATE, because the sentence above ends "all replay regardless" and remote requests
		// are the one thing that does not. Folded in, the line contradicted itself.
		if cn.remote > 0 {
			vgui.text_dim('   ${cn.remote} remote request(s) — not replayed; this app does not transmit them')
		}
	}
	return false
}

// start_replay_scan replaces channel i's scan entry and decodes `rp` on a worker thread. The
// fresh &ReplayScan is the worker's ownership token: a previous scan still running writes
// back only if the map still holds ITS pointer, so replacement here is also cancellation.
fn (mut app App) start_replay_scan(i int, rp string) {
	if i < 0 || i >= app.proj.channels.len {
		return
	}
	mine := &ReplayScan{
		src:     rp
		loading: true
	}
	// Databases from the PROJECT channel, not the runtime row: proj is GUI-thread-owned
	// stopped-only state, while app.chans[i] is still being written by a winding-down
	// rx_loop under app.mu right after Stop — copying it here was an unlocked read of a
	// worker-mutated element, the exact class CLAUDE.md names (codex #135 r3).
	paths := app.proj.channels[i].databases.map(candb.canonical_database_ref(app.resolve_asset(it)))
	app.mu.lock()
	app.replay_scans[i] = mine
	db := merge_dbs_from(app.loaded_dbs_for(paths))
	app.mu.unlock()
	spawn scan_replay_source(app, i, rp, db, mine)
}
