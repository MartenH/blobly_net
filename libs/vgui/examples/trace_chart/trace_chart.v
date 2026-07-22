// trace_chart — the vgui evaluation slice: a Trace table + the Trace Chart swimlane,
// both driven from V structs over the `vgui` module (Dear ImGui + ImPlot, multi-viewport).
//
// The swimlane window is opened at a position *outside* the main viewport, so with
// ImGuiConfigFlags_ViewportsEnable it auto-detaches into its own OS window (drag it to a
// second monitor). Drag any panel's title bar out for the same effect.
//
// Build (Linux/WSL):  libs/vgui/build_deps.sh  then
//   v -path "@vlib|@vmodules|libs" run libs/vgui/examples/trace_chart/trace_chart.v
// Build (Windows/mingw): see libs/vgui/README.md — same command with -cc gcc.
//
// Env knobs (headless / CI verification):
//   VGUI_POLL=1     — 60fps poll loop instead of event-driven (stress / screenshots)
//   VGUI_FRAMES=N   — render N frames then exit (0/unset = run until window closed)
//   VGUI_SHOT=path  — dump the main GL window to a .ppm on the last frame (WSLg-proof)
module main

import os
import vgui

// A trace row (what the Trace table shows), built from plain V data.
struct Row {
	t_ms f64
	id   string
	name string
	dir  string
	data string
}

// synthesize a handful of CAN-ish trace rows.
fn sample_rows() []Row {
	return [
		Row{0.20, '0x100', 'Powertrain', 'RX', '31 A4 00 05 12 00 00 00'},
		Row{0.30, '0x700', 'Heartbeat', 'RX', '01'},
		Row{5.10, '0x101', 'Request', 'TX', '01'},
		Row{5.14, '0x102', 'Response', 'RX', '01 00'},
		Row{10.2, '0x100', 'Powertrain', 'RX', '31 A6 00 05 13 00 00 00'},
		Row{10.3, '0x700', 'Heartbeat', 'RX', '02'},
		Row{15.0, '0x301', 'Brake', 'RX', '00 C8 40 00 00 00 00 00'},
	]
}

// synthesize a by-lane swimlane (3 lanes; one overrun, one preempted), µs on X.
fn sample_bars() []vgui.Bar {
	blue := vgui.rgba(90, 150, 230, 235)
	green := vgui.rgba(90, 200, 120, 235)
	amber := vgui.rgba(230, 180, 70, 235)
	return [
		vgui.Bar{t0: 0, dur: 1200, lane: 0, color: blue},
		vgui.Bar{t0: 1500, dur: 800, lane: 1, color: green},
		vgui.Bar{t0: 2600, dur: 2200, lane: 0, color: blue, preempted: 1},
		vgui.Bar{t0: 3000, dur: 600, lane: 2, color: amber, warn: 1}, // overran -> red outline
		vgui.Bar{t0: 5200, dur: 1400, lane: 1, color: green},
		vgui.Bar{t0: 7000, dur: 900, lane: 2, color: amber},
		vgui.Bar{t0: 8200, dur: 3000, lane: 0, color: blue},
	]
}

fn main() {
	poll := os.getenv('VGUI_POLL') == '1'
	max_frames := os.getenv('VGUI_FRAMES').int() // 0 = run until closed
	shot := os.getenv('VGUI_SHOT')

	if !vgui.init('vgui — Trace Chart (eval)', 1280, 760, !poll) {
		eprintln('vgui.init failed')
		exit(1)
	}

	rows := sample_rows()
	bars := sample_bars()
	labels := ['core0', 'core1', 'core2']
	full_span_us := f32(11500)

	mut frame := 0
	mut cur_a := f64(full_span_us) * 0.25 // A/B measurement markers (µs), persisted across frames
	mut cur_b := f64(full_span_us) * 0.75
	for vgui.running() {
		frame++
		last := max_frames > 0 && frame >= max_frames
		if last && shot != '' {
			vgui.dump_ppm(shot)
		}
		vgui.frame_begin()

		// --- Trace table (kept inside the main window; global desktop coords under
		// multi-viewport, so this must fall within the main OS window's screen rect) ---
		vgui.set_next_window(90, 130, 620, 360)
		vgui.begin('Trace')
		vgui.text('Live trace — ${rows.len} rows   (${vgui.fps():.0}fps)')
		vgui.separator_text('frames')
		if vgui.table_begin('trace', 5) {
			vgui.table_col('t (ms)')
			vgui.table_col('id')
			vgui.table_col('name')
			vgui.table_col('dir')
			vgui.table_col('data')
			vgui.table_headers()
			for r in rows {
				vgui.table_row()
				vgui.table_cell('${r.t_ms:.2}')
				vgui.table_cell(r.id)
				vgui.table_cell(r.name)
				vgui.table_cell(r.dir)
				vgui.table_cell(r.data)
			}
			vgui.table_end()
		}
		vgui.end()

		// --- Trace Chart swimlane (positioned OFF the main viewport -> own OS window) ---
		vgui.set_next_window(1420, 120, 720, 340)
		vgui.begin('Trace Chart')
		vgui.text_dim('drag = pan · scroll = zoom · double-click = fit · A/B markers to measure')
		vgui.swimlane('swim', labels, bars, []vgui.Link{}, full_span_us, &cur_a, &cur_b)
		vgui.end()

		vgui.frame_end()

		if last {
			break
		}
	}
	vgui.shutdown()
}
