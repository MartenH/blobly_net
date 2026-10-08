module main

import os
import candb
import project
import vgui

// ArxmlImportUi is the "Import system from ARXML" dialog (#439): one row per CAN cluster, each
// mapped onto an interface or left out, the ECUs under test, and whether the others are
// simulated. What it writes is project.import_arxml's answer; the dialog only collects the
// decisions. MODAL, like the cluster picker, so the rows it appends to cannot change under it.
struct ArxmlImportUi {
mut:
	open     bool
	popped   bool
	path     string // the ARXML, resolved
	rows     []ArxmlImportRow
	ecus     []string
	sut      []bool // parallel to ecus
	restbus  bool = true
	err      string
	ignored  string // what the file holds that is not imported, one line
	adapters []string
}

struct ArxmlImportRow {
mut:
	bus      string
	rate     int
	fd_rate  int // the data rate the row would run at; 0 when classic
	frames   int
	senders  []string
	adapter  int // index into ArxmlImportUi.adapters; 0 leaves the cluster out
	addr_buf []u8
}

// import_adapters is what a cluster can be put on: the platform's CAN adapters.
fn import_adapters() []string {
	mut out := ['(leave out)']
	out << project.platform_adapters().filter(it !in ['doip', 'someip'])
	return out
}

// default_address is the address a fresh mapping starts from: the cluster's name for a software
// bus, the next vcanN for vcan, nothing where only the operator knows (hardware).
fn default_address(adapter string, bus string, k int) string {
	return match adapter {
		'virtual' { bus }
		'vcan' { 'vcan${k}' }
		else { '' }
	}
}

fn (mut app App) open_arxml_import(path string) {
	a := candb.load_arxml_file(path) or {
		app.notify('${os.file_name(path)}: ${err}')
		return
	}
	if a.clusters.len == 0 {
		app.notify('${os.file_name(path)} describes no CAN cluster: there is nothing to import')
		return
	}
	adapters := import_adapters()
	mut rows := []ArxmlImportRow{}
	mut ecus := []string{}
	for k, c in a.clusters {
		fd := project.arxml_cluster_fd(c)
		senders := project.arxml_senders(c)
		rows << ArxmlImportRow{
			bus:      c.bus
			rate:     c.baudrate
			fd_rate:  if fd { c.fd_baudrate } else { 0 }
			frames:   c.db.messages.len
			senders:  senders
			adapter:  1 // the first offered adapter: virtual, so an import runs with no hardware
			addr_buf: mkbuf(default_address(adapters[1], c.bus, k), 128)
		}
		for s in senders {
			if s !in ecus {
				ecus << s
			}
		}
	}
	mut kinds := a.report.ignored.keys()
	kinds.sort()
	app.arxml_import = ArxmlImportUi{
		open:     true
		path:     path
		rows:     rows
		ecus:     ecus
		sut:      []bool{len: ecus.len}
		ignored:  kinds.map('${a.report.ignored[it]} × ${it}').join(', ')
		adapters: adapters
	}
}

// arxml_import_confirm appends the rows project.import_arxml builds; on a refusal the dialog
// stays open with the reason.
fn (mut app App) arxml_import_confirm() bool {
	ui := app.arxml_import
	a := candb.load_arxml_file(ui.path) or {
		app.arxml_import.err = '${os.file_name(ui.path)}: ${err}'
		return false
	}
	mut plans := []project.ClusterPlan{}
	for r in ui.rows {
		plans << project.ClusterPlan{
			bus:     r.bus
			adapter: if r.adapter > 0 { ui.adapters[r.adapter] } else { '' }
			address: vgui.buf_str(r.addr_buf).trim_space()
		}
	}
	mut sut := []string{}
	for k, e in ui.ecus {
		if ui.sut[k] {
			sut << e
		}
	}
	app.commit_cfg()
	chans, notes := project.import_arxml(a, project.ArxmlImport{
		ref:      rel_path(ui.path)
		clusters: plans
		sut:      sut
		restbus:  ui.restbus
	}, app.proj.channels) or {
		app.arxml_import.err = err.msg()
		return false
	}
	app.add_channels(chans)
	for n in notes {
		app.notify(n)
	}
	app.notify('imported ${chans.len} bus${if chans.len == 1 { '' } else { 'es' }} from ${os.file_name(ui.path)}: ${chans.map(it.name).join(', ')}')
	return true
}

fn draw_arxml_import(mut app App) {
	id := 'Import system from ARXML##arxmlimport'
	if !app.arxml_import.open {
		if vgui.begin_popup_modal(id) {
			vgui.close_current_popup()
			vgui.end_popup()
		}
		app.arxml_import.popped = false
		return
	}
	if !app.arxml_import.popped {
		vgui.open_popup(id)
		app.arxml_import.popped = true
	}
	sc := app.prefs.ui_scale
	vgui.set_next_window(140, 100, 980, 330 + 26 * f32(app.arxml_import.rows.len))
	if !vgui.begin_popup_modal(id) {
		app.arxml_import.open = false
		app.arxml_import.popped = false
		return
	}
	ui := app.arxml_import
	vgui.text('${os.file_name(ui.path)}: put each CAN cluster on an interface, or leave it out.')
	vgui.text_dim('Each becomes a channel reading that cluster. Frames, timing and E2E stay in the file.')
	if vgui.table_begin_flat('##arxml_import', 6) {
		vgui.table_setup_col('cluster', 150 * sc)
		vgui.table_setup_col('bitrate', 70 * sc)
		vgui.table_setup_col('data rate', 80 * sc)
		vgui.table_setup_col('frames', 55 * sc)
		vgui.table_setup_col('adapter', 150 * sc)
		vgui.table_setup_col('address', 0)
		vgui.table_headers()
		for k, r in ui.rows {
			vgui.table_row()
			vgui.table_cell(r.bus)
			vgui.set_item_tooltip('sent by: ${r.senders.join(', ')}')
			vgui.table_cell(rate_text(r.rate))
			vgui.table_cell(if r.fd_rate > 0 { rate_text(r.fd_rate) } else { 'classic' })
			vgui.table_cell('${r.frames}')
			vgui.table_next_col()
			vgui.set_next_item_width(140 * sc)
			pick := vgui.combo('##imad${k}', ui.adapters, r.adapter)
			if pick != r.adapter {
				app.arxml_import.rows[k].adapter = pick
				addr := if pick > 0 { default_address(ui.adapters[pick], r.bus, k) } else { '' }
				app.arxml_import.rows[k].addr_buf = mkbuf(addr, 128)
			}
			vgui.table_next_col()
			if r.adapter > 0 {
				vgui.set_next_item_width(-1)
				vgui.input_text('##imaddr${k}', mut app.arxml_import.rows[k].addr_buf)
			}
		}
		vgui.table_end()
	}
	vgui.separator_text('ECUs under test')
	vgui.text_dim('Not simulated: the real ones on the bench.')
	for k, e in ui.ecus {
		if k > 0 {
			vgui.same_line()
		}
		app.arxml_import.sut[k] = vgui.checkbox('${e}##imsut${k}', ui.sut[k])
	}
	app.arxml_import.restbus = vgui.checkbox('simulate every other ECU that sends on an imported cluster (rest bus)',
		ui.restbus)
	if ui.ignored != '' {
		vgui.text_dim('Not imported: ${ui.ignored}.')
	}
	if ui.err != '' {
		vgui.text_colored(230, 110, 90, ui.err)
	}
	vgui.separator()
	if vgui.button('Import') {
		app.arxml_import.err = ''
		if app.arxml_import_confirm() {
			app.arxml_import.open = false
		}
	}
	vgui.same_line()
	if vgui.button('Cancel') {
		app.arxml_import.open = false
	}
	if !app.arxml_import.open {
		vgui.close_current_popup()
		app.arxml_import.popped = false
	}
	vgui.end_popup()
}
