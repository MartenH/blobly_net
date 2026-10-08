module main

import os
import candb
import vgui

// ArxmlPick is the "which CAN cluster?" dialog: an ARXML describes every bus of a system, and
// one channel is one of them. Opened when an attached file has several clusters, and from an
// attached ARXML's `cluster` button to change which one the row reads.
struct ArxmlPick {
mut:
	open   bool
	ci     int    // the channel row
	di     int    // the database entry being changed; -1 attaches a new one
	chan   string // the row's name and interface at open, so a confirm cannot land on another row
	iface  string
	before string // the entry at `di` at open
	path   string // the ARXML, resolved
	rows   []ArxmlPickRow
	sel    int
}

struct ArxmlPickRow {
	bus     string // the identifier `cluster()` accepts and the reference carries
	path    string // the AUTOSAR path, shown so two same-named clusters can be told apart
	rate    int
	fd_rate int
	frames  int
	used_by []string // other channel rows already reading this cluster of this file
}

// open_arxml_pick lists the clusters of `path` for channel ci; `current` is the selected
// cluster's identifier, '' for none.
fn (mut app App) open_arxml_pick(ci int, di int, path string, a candb.Arxml, current string) {
	file := os.real_path(path)
	mut rows := []ArxmlPickRow{}
	mut sel := -1
	for k, c in a.clusters {
		mut used := []string{}
		for j, ch in app.proj.channels {
			if j == ci {
				continue
			}
			for ref in ch.databases {
				f, frag := candb.split_database_ref(ref)
				if frag == '' || os.real_path(app.resolve_asset(f)) != file {
					continue
				}
				if hit := a.cluster(frag) {
					if hit.path == c.path {
						used << ch.name
					}
				}
			}
		}
		rows << ArxmlPickRow{
			bus:     c.bus
			path:    c.path
			rate:    c.baudrate
			fd_rate: c.fd_baudrate
			frames:  c.db.messages.len
			used_by: used
		}
		if current != '' && (c.bus == current || c.path == current) {
			sel = k
		}
	}
	app.arxml_pick = ArxmlPick{
		open:   true
		ci:     ci
		di:     di
		chan:   app.proj.channels[ci].name
		iface:  app.proj.channels[ci].iface
		before: if di >= 0 { app.proj.channels[ci].databases[di] } else { '' }
		path:   path
		rows:   rows
		sel:    sel
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
	app.open_arxml_pick(ci, di, path, a, frag)
}

// arxml_pick_confirm writes the chosen cluster into the row — a new entry, or entry di's
// fragment replaced — provided the row and the entry are still the ones the dialog was opened on.
fn (mut app App) arxml_pick_confirm() {
	p := app.arxml_pick
	app.arxml_pick.open = false
	if p.sel < 0 || p.sel >= p.rows.len || p.ci < 0 || p.ci >= app.proj.channels.len {
		return
	}
	ch := app.proj.channels[p.ci]
	if ch.name != p.chan || ch.iface != p.iface
		|| (p.di >= 0 && (p.di >= ch.databases.len || ch.databases[p.di] != p.before)) {
		app.notify('the configuration changed under the cluster picker; nothing attached')
		return
	}
	ref := if p.di >= 0 {
		f, _ := candb.split_database_ref(p.before)
		f + '#' + p.rows[p.sel].bus
	} else {
		// the fragment rides on the RESOLVED path: rel_path asks the file system about it
		rel_path(p.path) + '#' + p.rows[p.sel].bus
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
	vgui.text('${os.file_name(p.path)} describes ${p.rows.len} CAN clusters. Which one is ${p.chan}?')
	vgui.text_dim('A channel is one bus: it reads the frames of the cluster picked here.')
	if vgui.table_begin_flat('##arxml_clusters', 5) {
		vgui.table_setup_col('cluster', 200 * sc)
		vgui.table_setup_col('bitrate', 70 * sc)
		vgui.table_setup_col('data rate', 70 * sc)
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
			vgui.table_cell(rate_text(r.rate))
			vgui.table_cell(rate_text(r.fd_rate))
			vgui.table_cell('${r.frames}')
			vgui.table_cell_dim(r.used_by.join(', '))
		}
		vgui.table_end()
	}
	vgui.separator()
	chosen := app.arxml_pick.sel >= 0
	label := if p.di >= 0 { 'Use' } else { 'Attach' }
	if chosen {
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
