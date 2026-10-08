module main

import os
import candb
import project
import vgui

// ArxmlImportUi is the "Import system from ARXML" dialog (#439): one row per CAN cluster, each
// mapped onto an interface or left out, the ECUs under test, and whether the others are
// simulated. What it writes is project.import_arxml's answer; the dialog only collects the
// decisions. MODAL, like the cluster picker, so the rows it appends to cannot change under it;
// closed besides wherever a run starts or the project is replaced (run.v, set_project), since its
// Import rebuilds the runtime view.
struct ArxmlImportUi {
mut:
	open     bool
	popped   bool
	path     string      // the ARXML, resolved
	a        candb.Arxml // as parsed when the dialog opened: what is shown is what is imported
	rows     []ArxmlImportRow
	sut      map[string]bool // ticked ECUs under test, by name
	restbus  bool = true
	err      string
	ignored  string // what the file holds that is not imported, one line
	adapters []string
}

struct ArxmlImportRow {
mut:
	bus      string
	rates    project.ClusterRates
	frames   int
	senders  []string
	ecus     []string // project.arxml_ecus: what may be marked under test
	adapter  int      // index into ArxmlImportUi.adapters; 0 leaves the cluster out
	addr_buf []u8
}

// import_adapters is what a cluster can be put on: the platform's CAN adapters.
fn import_adapters() []string {
	mut out := ['(leave out)']
	out << project.platform_adapters().filter(it !in ['doip', 'someip'])
	return out
}

// default_address is the address a fresh mapping starts from: the cluster's name for a software
// bus, the lowest vcanN nothing else uses for vcan, nothing where only the operator knows
// (hardware). `taken` is every address the project's rows and the dialog's other rows hold.
fn default_address(adapter string, bus string, taken []string) string {
	return match adapter {
		'virtual' {
			bus
		}
		'vcan' {
			mut n := 0
			for 'vcan${n}' in taken {
				n++
			}
			'vcan${n}'
		}
		else {
			''
		}
	}
}

// taken_addresses is what default_address must not reuse: the project's interfaces and the
// addresses the dialog's other rows hold.
fn (app &App) taken_addresses(skip int) []string {
	mut out := app.proj.channels.map(it.iface)
	for k, r in app.arxml_import.rows {
		if k != skip && r.adapter > 0 {
			out << vgui.buf_str(r.addr_buf).trim_space()
		}
	}
	return out
}

// import_ecus is the ECUs that may be marked under test: those of the clusters being imported,
// project.arxml_ecus per row — the list import_arxml validates against, so a tick is never
// refused after the fact.
fn (ui ArxmlImportUi) import_ecus() []string {
	mut out := []string{}
	for r in ui.rows {
		if r.adapter == 0 {
			continue
		}
		for e in r.ecus {
			if e !in out {
				out << e
			}
		}
	}
	return out
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
	mut taken := app.proj.channels.map(it.iface)
	for c in a.clusters {
		// the first offered adapter: virtual, so an import runs with no hardware
		addr := default_address(adapters[1], c.bus, taken)
		taken << addr
		rows << ArxmlImportRow{
			bus:      c.bus
			rates:    project.arxml_cluster_rates(c)
			frames:   c.db.messages.len
			senders:  project.arxml_senders(c)
			ecus:     project.arxml_ecus(c)
			adapter:  1
			addr_buf: mkbuf(addr, 128)
		}
	}
	mut kinds := a.report.ignored.keys()
	kinds.sort()
	app.arxml_import = ArxmlImportUi{
		open:     true
		path:     path
		a:        a
		rows:     rows
		ignored:  kinds.map('${a.report.ignored[it]} × ${it}').join(', ')
		adapters: adapters
	}
}

// arxml_import_confirm appends the rows project.import_arxml builds; on a refusal the dialog
// stays open with the reason.
fn (mut app App) arxml_import_confirm() bool {
	ui := app.arxml_import
	if app.running {
		// closed at Start already (run.v); kept so a new path to this cannot rebuild mid-run
		app.arxml_import.err = 'a measurement is running: Stop to import'
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
	sut := ui.import_ecus().filter(ui.sut[it])
	// the panel's unsaved edits first: import_arxml names the new rows clear of the existing ones
	app.commit_cfg()
	chans, notes := project.import_arxml(ui.a, project.ArxmlImport{
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

const ecu_cols = 4 // ECUs under test per line: a system names dozens, and one line would clip them

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
	ecus := app.arxml_import.import_ecus()
	lines := app.arxml_import.rows.len + (ecus.len + ecu_cols - 1) / ecu_cols
	vgui.set_next_window(140, 100, 980, 330 + 26 * f32(lines))
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
			vgui.table_cell(rate_text(r.rates.bitrate) + if r.rates.no_baudrate { ' (unstated)' } else { '' })
			vgui.table_cell(if !r.rates.fd {
				'classic'
			} else if r.rates.no_fd_rate {
				'${rate_text(r.rates.bitrate)} (unstated)'
			} else {
				rate_text(r.rates.data_bitrate)
			})
			vgui.table_cell('${r.frames}')
			vgui.table_next_col()
			vgui.set_next_item_width(140 * sc)
			pick := vgui.combo('##imad${k}', ui.adapters, r.adapter)
			if pick != r.adapter {
				app.arxml_import.rows[k].adapter = pick
				addr := if pick > 0 {
					default_address(ui.adapters[pick], r.bus, app.taken_addresses(k))
				} else {
					''
				}
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
	vgui.text_dim('Not simulated: the real ones on the bench. Listed from the clusters being imported.')
	if ecus.len > 0 && vgui.table_begin_flat('##arxml_import_sut', ecu_cols) {
		for k, e in ecus {
			if k % ecu_cols == 0 {
				vgui.table_row()
			}
			vgui.table_next_col()
			app.arxml_import.sut[e] = vgui.checkbox('${e}##imsut${k}', ui.sut[e])
		}
		vgui.table_end()
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
