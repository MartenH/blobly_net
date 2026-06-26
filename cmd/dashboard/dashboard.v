// GUI capability demo — NOT part of the product, a throwaway to de-risk vlang/gui.
//
// Purpose: prove vlang/gui can do the things a professional tester depends on,
// before we build deep on it:
//   1. A live signal TABLE (data_grid) with conditional cell formatting.
//   2. NICE line drawing — anti-aliased polylines for signal-over-time plots.
//   3. LIVE updates at ~25 fps (the trace-view performance risk).
//   4. Real layout: toolbar + side-by-side panels + status bar + a control.
//
// Run with: scripts/run.sh cmd/dashboard/dashboard.v  (software GL under WSLg)
module main

import gui
import math
import time

const hist_len = 160 // samples kept per signal for the chart

struct Sig {
	name string
	unit string
	lo   f64
	hi   f64
}

// Static signal definitions (stand-ins for decoded CAN signals).
const sigs = [
	Sig{'EngineSpeed', 'rpm', 700, 6500},
	Sig{'VehicleSpeed', 'km/h', 0, 220},
	Sig{'CoolantTemp', '°C', 70, 110},
	Sig{'ThrottlePos', '%', 0, 100},
	Sig{'BatteryVolt', 'V', 11.5, 14.8},
]

@[heap]
struct DashApp {
mut:
	t       f64
	running bool = true
	ticks   int
	values  []f64   // current value per signal (parallel to sigs)
	history [][]f32 // recent values per signal (for the chart)
}

fn main() {
	mut window := gui.window(
		title:   'Blobly Net — vlang/gui capability demo'
		state:   &DashApp{}
		width:   980
		height:  600
		on_init: fn (mut w gui.Window) {
			mut app := w.state[DashApp]()
			app.values = []f64{len: sigs.len}
			app.history = [][]f32{len: sigs.len, init: []f32{}}
			w.update_view(main_view)
			start_sim_loop(mut w)
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

// start_sim_loop re-arms a short timer that advances the simulated signals —
// same pattern a real RX feed would use to pump live data into the UI.
fn start_sim_loop(mut w gui.Window) {
	w.animation_add(mut gui.TweenAnimation{
		id:       'sim_tick'
		from:     0
		to:       1
		duration: 40 * time.millisecond
		on_value: fn (_ f32, mut _ gui.Window) {}
		on_done:  fn (mut w gui.Window) {
			mut app := w.state[DashApp]()
			if app.running {
				app.advance()
			}
			start_sim_loop(mut w)
		}
	})
}

fn (mut app DashApp) advance() {
	app.t += 0.04
	app.ticks++
	for i, s in sigs {
		// A distinct waveform per signal so the chart looks alive.
		phase := app.t * (0.6 + 0.25 * f64(i))
		norm := 0.5 + 0.5 * math.sin(phase) * math.cos(0.3 * phase + f64(i))
		v := s.lo + norm * (s.hi - s.lo)
		app.values[i] = v
		app.history[i] << f32(v)
		if app.history[i].len > hist_len {
			app.history[i].delete(0)
		}
	}
}

fn main_view(mut window gui.Window) gui.View {
	w, h := window.window_size()
	app := window.state[DashApp]()

	// Build table rows from current signal values.
	mut rows := []gui.GridRow{cap: sigs.len}
	for i, s in sigs {
		rows << gui.GridRow{
			id:    '${i}'
			cells: {
				'name':  s.name
				'value': fmt2(app.values[i])
				'unit':  s.unit
				'range': '${fmt2(s.lo)} … ${fmt2(s.hi)}'
			}
		}
	}

	// Snapshot two signals for the chart closure (Engine + Vehicle speed).
	eng := app.history[0].clone()
	veh := app.history[1].clone()

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_medium
		spacing: 10
		content: [
			// Toolbar
			gui.row(
				v_align: .middle
				sizing:  gui.fill_fit
				spacing: 12
				content: [
					gui.text(text: 'Blobly Net', text_style: gui.theme().b1),
					gui.text(text: 'live signal table + plot', text_style: gui.theme().b3),
					gui.button(
						id_focus: 1
						content:  [gui.text(text: if app.running { '⏸ Pause' } else { '▶ Run' })]
						on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[DashApp]()
							a.running = !a.running
						}
					),
					gui.text(text: 'ticks: ${app.ticks}', text_style: gui.theme().n4),
				]
			),
			// Main area: signal table | live chart
			gui.row(
				sizing:  gui.fill_fill
				spacing: 10
				content: [
					window.data_grid(
						id:         'signals'
						max_height: 460
						columns:    [
							gui.GridColumnCfg{ id: 'name', title: 'Signal', width: 150 },
							gui.GridColumnCfg{ id: 'value', title: 'Value', width: 100, align: .end },
							gui.GridColumnCfg{ id: 'unit', title: 'Unit', width: 70 },
							gui.GridColumnCfg{ id: 'range', title: 'Range', width: 150 },
						]
						rows:       rows
						on_cell_format: sig_cell_format
					),
					gui.draw_canvas(
						id:      'plot'
						version: u64(app.ticks) // bump version so it redraws each tick
						width:   440
						height:  460
						color:   gui.Color{28, 28, 38, 255}
						radius:  8
						padding: gui.Padding{16, 16, 16, 16}
						on_draw: fn [eng, veh] (mut dc gui.DrawContext) {
							draw_plot(mut dc, eng, veh)
						}
					),
				]
			),
			gui.text(
				text:       'vlang/gui ${sigs.len} signals · chart history ${hist_len} samples · software GL (WSLg)'
				text_style: gui.theme().n4
			),
		]
	)
}

// Conditional formatting: turn a value red as it nears the top of its range.
fn sig_cell_format(row gui.GridRow, _ int, col gui.GridColumnCfg, value string, mut _ gui.Window) gui.GridCellFormat {
	if col.id == 'value' {
		idx := row.id.int()
		if idx >= 0 && idx < sigs.len {
			s := sigs[idx]
			frac := (value.f64() - s.lo) / (s.hi - s.lo)
			if frac > 0.85 {
				return gui.GridCellFormat{
					has_text_color: true
					text_color:     gui.Color{232, 108, 97, 255}
				}
			}
		}
	}
	return gui.GridCellFormat{}
}

fn draw_plot(mut dc gui.DrawContext, eng []f32, veh []f32) {
	cw := dc.width
	ch := dc.height
	grid := gui.Color{70, 70, 90, 255}
	for i in 0 .. 5 {
		y := ch * f32(i) / 4
		dc.line(0, y, cw, y, grid, 1)
	}
	draw_series(mut dc, eng, gui.Color{90, 170, 250, 255})
	draw_series(mut dc, veh, gui.Color{120, 230, 150, 255})
}

fn draw_series(mut dc gui.DrawContext, series []f32, color gui.Color) {
	if series.len < 2 {
		return
	}
	cw := dc.width
	ch := dc.height
	mut mn := series[0]
	mut mx := series[0]
	for v in series {
		if v < mn { mn = v }
		if v > mx { mx = v }
	}
	span := if mx > mn { mx - mn } else { f32(1) }
	mut pts := []f32{cap: series.len * 2}
	for i, v in series {
		x := cw * f32(i) / f32(series.len - 1)
		y := ch - ch * (v - mn) / span
		pts << x
		pts << y
	}
	dc.polyline(pts, color, 2.0, .round, .round)
}

fn fmt2(v f64) string {
	return '${v:.1f}'
}
