module main

import os
import candb
import vgui

// ArxmlPick is the "which CAN cluster?" dialog: an ARXML describes every bus of a system, and
// one channel is one of them. Opened when an attached file has several clusters, and from an
// attached ARXML's `cluster...` button to change which one the row reads. Index-bound: closed
// wherever rows can shift or be replaced (drop_index_bound_ui, set_project, Start).
struct ArxmlPick {
mut:
	open    bool
	ci      int    // the channel row
	di      int    // the database entry being changed; -1 attaches a new one
	chan    string // the row's name, for the question
	rate    int    // the row's nominal bitrate
	fd_rate int    // the row's data rate (project.Channel.data_rate); 0 for a classic row
	before  string // the entry at `di` at open
	path    string // the ARXML, resolved
	rows    []ArxmlPickRow
	sel     int
}

struct ArxmlPickRow {
	bus      string // the identifier `cluster()` accepts and the reference carries
	path     string // the AUTOSAR path, shown so two same-named clusters can be told apart
	rate     int
	fd_rate  int
	frames   int
	used_by  []string // other channel rows already reading this cluster of this file
	this_row bool     // this row reads it through another entry, at open
}

// cluster_readers maps each cluster of `a` (by AUTOSAR path) to the rows whose entries read
// it, skipping entry `skip_di` of row `skip_ci`.
fn (app &App) cluster_readers(path string, a candb.Arxml, skip_ci int, skip_di int) map[string][]int {
	file := os.real_path(path)
	mut readers := map[string][]int{}
	for j, ch in app.proj.channels {
		for k, ref in ch.databases {
			if j == skip_ci && k == skip_di {
				continue
			}
			f, frag := candb.split_database_ref(ref)
			if frag == '' || os.real_path(app.resolve_asset(f)) != file {
				continue
			}
			if hit := a.cluster(frag) {
				readers[hit.path] << j
			}
		}
	}
	return readers
}

// open_arxml_pick lists the clusters of `path` for entry di of channel ci (-1: a new entry);
// `current` is the fragment the entry carries, '' for none.
fn (mut app App) open_arxml_pick(ci int, di int, path string, a candb.Arxml, current string) {
	if app.arxml_pick.open {
		app.notify('cluster picker for ${app.arxml_pick.chan} closed unanswered: nothing attached there')
	}
	// the row as the panel shows it: an edit still in its buffers is what Attach commits
	app.commit_cfg()
	readers := app.cluster_readers(path, a, ci, di)
	cur_path := if current == '' {
		''
	} else if hit := a.cluster(current) {
		hit.path
	} else {
		''
	}
	mut rows := []ArxmlPickRow{}
	mut sel := -1
	for k, c in a.clusters {
		js := readers[c.path] or { []int{} }
		rows << ArxmlPickRow{
			bus:      c.bus
			path:     c.path
			rate:     c.baudrate
			fd_rate:  c.fd_baudrate
			frames:   c.db.messages.len
			used_by:  js.filter(it != ci).map(app.proj.channels[it].name)
			this_row: ci in js
		}
		if c.path == cur_path {
			sel = k
		}
	}
	ch := app.proj.channels[ci]
	app.arxml_pick = ArxmlPick{
		open:    true
		ci:      ci
		di:      di
		chan:    ch.name
		rate:    ch.nominal_bitrate()
		fd_rate: ch.data_rate()
		before:  if di >= 0 { ch.databases[di] } else { '' }
		path:    path
		rows:    rows
		sel:     sel
	}
}

// pick_arxml_cluster opens the dialog for an ARXML already attached as entry di of channel ci.
fn (mut app App) pick_arxml_cluster(ci int, di int) {
	ref := app.proj.channels[ci].databases[di]
	f, frag := candb.split_database_ref(ref)
	path := app.resolve_asset(f)
	a := candb.load_arxml_file(path) or {
		app.notify('${os.file_name(f)}: ${err}')
		return
	}
	if a.clusters.len < 2 {
		what := if a.clusters.len == 0 { 'no CAN cluster' } else { 'one CAN cluster' }
		app.notify('${os.file_name(f)} describes ${what}: there is nothing to choose')
		return
	}
	app.open_arxml_pick(ci, di, path, a, frag)
}

// arxml_pick_confirm writes the chosen cluster into the row — a new entry, or entry di's
// fragment replaced — provided the entry is still the one the dialog was opened on.
fn (mut app App) arxml_pick_confirm() {
	p := app.arxml_pick
	app.arxml_pick.open = false
	if p.sel < 0 || p.sel >= p.rows.len || p.ci < 0 || p.ci >= app.proj.channels.len {
		return
	}
	dbs := app.proj.channels[p.ci].databases
	if p.di >= 0 && (p.di >= dbs.len || dbs[p.di] != p.before) {
		app.notify('${p.chan}: the database entry changed under the cluster picker; nothing changed')
		return
	}
	r := p.rows[p.sel]
	// asked of the file and the entries NOW: the dialog does not block the panel, and the file
	// may have been replaced — the cluster is found again by its path, under its current name
	a := candb.load_arxml_file(p.path) or {
		app.notify('${os.file_name(p.path)}: ${err}')
		return
	}
	mut bus := ''
	for c in a.clusters {
		if c.path == r.path {
			bus = c.bus
		}
	}
	if bus == '' {
		app.notify('${os.file_name(p.path)} no longer has ${r.path}; nothing changed')
		return
	}
	if p.ci in (app.cluster_readers(p.path, a, p.ci, p.di)[r.path] or { []int{} }) {
		app.notify('${p.chan} already reads ${bus} of ${os.file_name(p.path)}; nothing changed')
		return
	}
	ref := if p.di >= 0 {
		f, _ := candb.split_database_ref(p.before)
		f + '#' + bus
	} else {
		// the fragment rides on the RESOLVED path: rel_path asks the file system about it
		rel_path(p.path) + '#' + bus
	}
	if ref == p.before {
		return // the cluster the entry already names, under the name it already has
	}
	app.drop_replay_scan(p.ci) // the census on display was attributed through the OLD databases
	app.commit_cfg()
	if p.di >= 0 {
		app.proj.channels[p.ci].databases[p.di] = ref
	} else {
		app.proj.channels[p.ci].databases << ref
	}
	app.dirty = true
	app.sync_cfg_bufs()
	app.rebuild_preserving_senders()
}

fn rate_text(r int) string {
	if r <= 0 {
		return '-'
	}
	return if r % 1000 == 0 { '${r / 1000}k' } else { '${r}' }
}

// rate_cell is a cluster's rate, with the row's beside it where they differ: a cluster at
// another rate is another bus's database.
fn rate_cell(cluster int, row int) string {
	t := rate_text(cluster)
	return if cluster > 0 && row > 0 && cluster != row { '${t} (row ${rate_text(row)})' } else { t }
}

fn draw_arxml_pick(mut app App) {
	sc := app.prefs.ui_scale
	// sized to its rows (first use only; ImGui keeps a moved or resized dialog where it is left)
	vgui.set_next_window(180, 120, 760, 190 + 26 * f32(app.arxml_pick.rows.len))
	vis, op := vgui.begin_dialog('CAN cluster##arxmlpick', app.arxml_pick.open)
	app.arxml_pick.open = op
	if !vis {
		vgui.end()
		return
	}
	p := app.arxml_pick
	fd := if p.fd_rate > 0 { 'CAN-FD ${rate_text(p.fd_rate)}' } else { 'classic' }
	vgui.text('${os.file_name(p.path)} describes ${p.rows.len} CAN clusters. Which one is ${p.chan} (${rate_text(p.rate)}, ${fd})?')
	vgui.text_dim('A channel is one bus: it reads the frames of the cluster picked here.')
	if vgui.table_begin_flat('##arxml_clusters', 5) {
		vgui.table_setup_col('cluster', 180 * sc)
		vgui.table_setup_col('bitrate', 120 * sc)
		vgui.table_setup_col('data rate', 120 * sc)
		vgui.table_setup_col('frames', 60 * sc)
		vgui.table_setup_col('already on', 0)
		vgui.table_headers()
		for k, r in p.rows {
			vgui.table_row()
			vgui.table_next_col()
			if vgui.selectable_row('${r.bus}##apk${k}', k == p.sel) {
				app.arxml_pick.sel = k
			}
			vgui.set_item_tooltip(r.path)
			vgui.table_cell(rate_cell(r.rate, p.rate))
			vgui.table_cell(rate_cell(r.fd_rate, p.fd_rate))
			vgui.table_cell('${r.frames}')
			mut on := r.used_by.clone()
			if r.this_row {
				on.insert(0, 'this row')
			}
			vgui.table_cell_dim(on.join(', '))
		}
		vgui.table_end()
	}
	vgui.separator()
	label := if p.di >= 0 { 'Use' } else { 'Attach' }
	if p.sel >= 0 {
		if vgui.button(label) {
			app.arxml_pick_confirm()
		}
	} else {
		vgui.text_dim('Pick a cluster to ${label.to_lower()} it.')
	}
	vgui.same_line()
	if vgui.button('Cancel') {
		app.arxml_pick.open = false
	}
	vgui.end()
}
