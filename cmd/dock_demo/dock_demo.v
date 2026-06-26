// Dock-layout spike — validates gui's docking before we rebuild the app around it.
//
// Puts Blobly Net-style panels (Trace grid, Signals, Send, Stats, Log) into a
// dockable/splittable/tabbed layout. Drag a panel's tab to re-dock it; splits
// are resizable; the layout tree is persisted via on_layout_change.
//
// This is a throwaway: mock data, no bus. The goal is only to confirm gui's
// dock_layout (incl. a data_grid nested in a panel) is solid under WSLg.
//
// Run: scripts/run.sh cmd/dock_demo/dock_demo.v
module main

import gui

@[heap]
struct DockApp {
mut:
	dock_root &gui.DockNode = unsafe { nil }
	send_id   string        = '101'
	send_data string        = 'AABBCC'
	log       string        = 'dock demo started'
}

fn main() {
	mut app := &DockApp{}
	app.dock_root = default_layout()
	mut window := gui.window(
		title:   'Blobly Net — dock spike'
		state:   app
		width:   1100
		height:  680
		on_init: fn (mut w gui.Window) {
			w.update_view(main_view)
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

// Trace (left) | [ Signals/Send tabs ] over [ Stats/Log tabs ] (right).
fn default_layout() &gui.DockNode {
	return gui.dock_split('root', .horizontal, 0.6, gui.dock_panel_group('main', ['trace'],
		'trace'), gui.dock_split('right', .vertical, 0.55, gui.dock_panel_group('rt', ['signals', 'send'],
		'signals'), gui.dock_panel_group('rb', ['stats', 'log'], 'stats')))
}

fn main_view(mut window gui.Window) gui.View {
	w, h := window.window_size()
	app := window.state[DockApp]()

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_none
		content: [
			gui.dock_layout(
				id:               'dock'
				root:             app.dock_root
				panels:           [
					gui.DockPanelDef{ id: 'trace', label: 'Trace', content: [trace_panel(mut window)] },
					gui.DockPanelDef{ id: 'signals', label: 'Signals', content: [signals_panel()] },
					gui.DockPanelDef{ id: 'send', label: 'Send', content: [send_panel(app)] },
					gui.DockPanelDef{ id: 'stats', label: 'Statistics', content: [stats_panel()] },
					gui.DockPanelDef{ id: 'log', label: 'Log', content: [log_panel(app)] },
				]
				on_layout_change: fn (new_root &gui.DockNode, mut w gui.Window) {
					mut a := w.state[DockApp]()
					a.dock_root = unsafe { new_root }
				}
				on_panel_select:  fn (group_id string, panel_id string, mut w gui.Window) {
					mut a := w.state[DockApp]()
					a.dock_root = gui.dock_tree_select_panel(a.dock_root, group_id, panel_id)
				}
				on_panel_close:   fn (panel_id string, mut w gui.Window) {
					mut a := w.state[DockApp]()
					a.dock_root = gui.dock_tree_remove_panel(a.dock_root, panel_id)
				}
			),
		]
	)
}

fn trace_panel(mut window gui.Window) gui.View {
	rows := [
		grow('1', '0.0', '0x100', 'Powertrain', '8E 21 ...'),
		grow('2', '0.1', '0x700', 'Heartbeat', '2A'),
		grow('3', '0.2', '0x100', 'Powertrain', '90 22 ...'),
		grow('4', '0.3', '0x200', '', 'DE AD BE EF'),
		grow('5', '0.4', '0x700', 'Heartbeat', '2B'),
	]
	return window.data_grid(
		id:         'dock-trace'
		max_height: 520
		columns:    [
			gui.GridColumnCfg{ id: 'time', title: 'Time', width: 60, sortable: false },
			gui.GridColumnCfg{ id: 'id', title: 'ID', width: 90, sortable: false },
			gui.GridColumnCfg{ id: 'name', title: 'Message', width: 130, sortable: false },
			gui.GridColumnCfg{ id: 'data', title: 'Data', width: 200, sortable: false },
		]
		rows:       rows
	)
}

fn grow(t string, time string, id string, name string, data string) gui.GridRow {
	return gui.GridRow{
		id:    t
		cells: {
			'time': time
			'id':   id
			'name': name
			'data': data
		}
	}
}

fn signals_panel() gui.View {
	sigs := ['EngineSpeed: 2014.75 rpm', 'VehicleSpeed: 128.7 km/h', 'CoolantTemp: 91 °C',
		'ThrottlePos: 88 %', 'Gear: 4', 'CruiseOn: 1']
	mut lines := []gui.View{}
	lines << gui.text(text: '0x100 Powertrain', text_style: gui.theme().b3)
	for s in sigs {
		lines << gui.text(text: s, text_style: gui.theme().n4)
	}
	return gui.column(sizing: gui.fill_fill, padding: gui.padding_medium, spacing: 5, content: lines)
}

fn send_panel(app &DockApp) gui.View {
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 8
		content: [
			gui.text(text: 'Transmit a frame', text_style: gui.theme().b3),
			gui.row(
				v_align: .middle
				spacing: 6
				content: [
					gui.text(text: 'id', text_style: gui.theme().n4),
					gui.input(
						id_focus:        20
						text:            app.send_id
						width:           80
						sizing:          gui.fixed_fit
						on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
							mut a := w.state[DockApp]()
							a.send_id = s
						}
					),
					gui.text(text: 'data', text_style: gui.theme().n4),
					gui.input(
						id_focus:        21
						text:            app.send_data
						width:           160
						sizing:          gui.fixed_fit
						on_text_changed: fn (_ &gui.Layout, s string, mut w gui.Window) {
							mut a := w.state[DockApp]()
							a.send_data = s
						}
					),
				]
			),
			gui.button(
				id_focus: 22
				content:  [gui.text(text: '➤ Send')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[DockApp]()
					a.log = 'TX ${a.send_id} ${a.send_data}\n' + a.log
				}
			),
		]
	)
}

fn stats_panel() gui.View {
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		spacing: 5
		content: [
			gui.text(text: 'Bus statistics', text_style: gui.theme().b3),
			gui.text(text: 'Bus load: 12 %', text_style: gui.theme().n4),
			gui.text(text: 'Frames/s: 20', text_style: gui.theme().n4),
			gui.text(text: 'Unique IDs: 3', text_style: gui.theme().n4),
			gui.text(text: 'Errors: 0', text_style: gui.theme().n4),
		]
	)
}

fn log_panel(app &DockApp) gui.View {
	return gui.column(
		sizing:  gui.fill_fill
		padding: gui.padding_medium
		content: [gui.text(text: app.log, mode: .wrap, text_style: gui.theme().n4)]
	)
}
