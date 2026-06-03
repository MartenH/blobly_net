// CANTester — minimal GUI bring-up (Phase 1).
//
// Goal of this file for now: prove that V + vlang/gui + WSLg render a window.
// No CAN logic yet — the transport/engine layers come in later phases and stay
// free of GUI imports (see CLAUDE.md). Keep this thin.
module main

import gui

// App state. `@[heap]` is required by gui for state that persists across view
// generations. For now we only track a trivial counter to prove interactivity.
@[heap]
struct App {
pub mut:
	heartbeats int
}

fn main() {
	mut window := gui.window(
		state:   &App{}
		width:   480
		height:  320
		title:   'CANTester'
		on_init: fn (mut w gui.Window) {
			w.update_view(main_view)
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

// View generator: a pure function of state, called on every event.
fn main_view(window &gui.Window) gui.View {
	w, h := window.window_size()
	app := window.state[App]()

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		h_align: .center
		v_align: .middle
		content: [
			gui.text(
				text:       'CANTester'
				text_style: gui.theme().b1
			),
			gui.text(
				text:       'CAN / Eth / LIN bus tester — GUI bring-up'
				text_style: gui.theme().b3
			),
			gui.button(
				id_focus: 1
				content:  [gui.text(text: 'Heartbeats: ${app.heartbeats}')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut app := w.state[App]()
					app.heartbeats += 1
				}
			),
		]
	)
}
