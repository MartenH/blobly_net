// Frame -> signals visualizer (GUI demo).
//
// Shows a live CAN frame decomposed "in a nice way": a bit-layout grid where
// each signal's bits are colour-coded (bright = bit set), beside a table of the
// decoded signals (raw + physical value). Decode logic comes from the candb
// module — this file is just the view.
//
// Run: scripts/run.sh cmd/signal_decode/decode.v
module main

import gui
import math
import time
import sampledb

// The message we decode (shared catalog; same layout the SUT emits).
const msg = sampledb.powertrain()

const palette = [
	gui.Color{90, 170, 250, 255},
	gui.Color{120, 230, 150, 255},
	gui.Color{250, 170, 80, 255},
	gui.Color{220, 120, 220, 255},
	gui.Color{240, 220, 90, 255},
	gui.Color{120, 220, 230, 255},
]

@[heap]
struct DecApp {
mut:
	t       f64
	running bool = true
	ticks   int
	data    []u8
}

fn main() {
	mut window := gui.window(
		title:   'CANTester — frame → signals'
		state:   &DecApp{}
		width:   860
		height:  520
		on_init: fn (mut w gui.Window) {
			mut app := w.state[DecApp]()
			app.data = []u8{len: 8}
			w.update_view(main_view)
			start_loop(mut w)
		}
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

fn start_loop(mut w gui.Window) {
	w.animation_add(mut gui.TweenAnimation{
		id:       'tick'
		from:     0
		to:       1
		duration: 50 * time.millisecond
		on_value: fn (_ f32, mut _ gui.Window) {}
		on_done:  fn (mut w gui.Window) {
			mut app := w.state[DecApp]()
			if app.running {
				app.advance()
			}
			start_loop(mut w)
		}
	})
}

fn osc(t f64, k int) f64 {
	return math.sin(t * (0.7 + 0.2 * f64(k)) + f64(k))
}

fn (mut app DecApp) advance() {
	app.t += 0.05
	app.ticks++
	targets := [
		1600.0 + 1500.0 * osc(app.t, 0), // rpm
		70.0 + 60.0 * osc(app.t, 1),     // km/h
		90.0 + 15.0 * osc(app.t, 2),     // °C
		45.0 + 45.0 * osc(app.t, 3),     // %
		f64(int(app.t) % 6 + 1),         // gear 1..6
		f64(int(app.t * 0.5) % 2),       // cruise 0/1
	]
	mut d := []u8{len: 8}
	for i, s in msg.signals {
		s.encode(mut d, targets[i])
	}
	app.data = d
}

fn main_view(mut window gui.Window) gui.View {
	w, h := window.window_size()
	app := window.state[DecApp]()

	// Per-bit owner signal + bit value, for the layout grid.
	mut owners := []int{len: 64, init: -1}
	mut bitset := []bool{len: 64}
	for g in 0 .. 64 {
		owners[g] = msg.signal_at(g)
		byte_idx := g / 8
		if byte_idx < app.data.len {
			bitset[g] = (app.data[byte_idx] >> (g % 8)) & 1 == 1
		}
	}

	mut hex := ''
	for b in app.data {
		hex += '${b:02X} '
	}

	mut rows := []gui.GridRow{cap: msg.signals.len}
	for i, s in msg.signals {
		raw := s.raw_value(app.data)
		phys := s.physical(app.data)
		rows << gui.GridRow{
			id:    '${i}'
			cells: {
				'name':  s.name
				'bits':  '${s.start_bit}:${s.length}'
				'raw':   '0x${raw:X}'
				'value': '${phys:.2f} ${s.unit}'
			}
		}
	}

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_medium
		spacing: 10
		content: [
			gui.row(
				v_align: .middle
				sizing:  gui.fill_fit
				spacing: 12
				content: [
					gui.text(text: '${msg.name}  id 0x${msg.id:X}', text_style: gui.theme().b1),
					gui.button(
						id_focus: 1
						content:  [gui.text(text: if app.running { '⏸ Pause' } else { '▶ Run' })]
						on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[DecApp]()
							a.running = !a.running
						}
					),
				]
			),
			gui.text(text: 'data:  ${hex}', text_style: gui.theme().b3),
			gui.row(
				sizing:  gui.fill_fill
				spacing: 14
				content: [
					gui.column(
						spacing: 4
						content: [
							gui.text(text: 'bit layout (MSB → LSB, byte 0 top)', text_style: gui.theme().n4),
							gui.draw_canvas(
								id:      'bits'
								version: u64(app.ticks)
								width:   360
								height:  320
								color:   gui.Color{24, 24, 32, 255}
								radius:  8
								padding: gui.Padding{10, 10, 10, 10}
								on_draw: fn [owners, bitset] (mut dc gui.DrawContext) {
									draw_bits(mut dc, owners, bitset)
								}
							),
						]
					),
					window.data_grid(
						id:             'sigs'
						max_height:     320
						columns:        [
							gui.GridColumnCfg{ id: 'name', title: 'Signal', width: 140 },
							gui.GridColumnCfg{ id: 'bits', title: 'Bits', width: 70 },
							gui.GridColumnCfg{ id: 'raw', title: 'Raw', width: 90, align: .end },
							gui.GridColumnCfg{ id: 'value', title: 'Physical', width: 140, align: .end },
						]
						rows:           rows
						on_cell_format: dec_cell_format
					),
				]
			),
		]
	)
}

// Colour the signal-name cell to match its colour in the bit grid.
fn dec_cell_format(row gui.GridRow, _ int, col gui.GridColumnCfg, value string, mut _ gui.Window) gui.GridCellFormat {
	if col.id == 'name' {
		idx := row.id.int()
		if idx >= 0 && idx < palette.len {
			return gui.GridCellFormat{
				has_text_color: true
				text_color:     palette[idx]
			}
		}
	}
	return gui.GridCellFormat{}
}

fn draw_bits(mut dc gui.DrawContext, owners []int, bitset []bool) {
	cols := 8
	rows := 8
	gap := f32(3)
	cw := (dc.width - gap * f32(cols + 1)) / f32(cols)
	ch := (dc.height - gap * f32(rows + 1)) / f32(rows)
	for r in 0 .. rows { // byte index, top = byte 0
		for c in 0 .. cols { // column 0 = MSB (bit 7)
			bit := 7 - c
			g := r * 8 + bit
			x := gap + f32(c) * (cw + gap)
			y := gap + f32(r) * (ch + gap)
			owner := owners[g]
			mut col := gui.Color{52, 52, 62, 255} // free bit, unset
			if owner >= 0 {
				base := palette[owner % palette.len]
				col = if bitset[g] { base } else { dim(base) }
			} else if bitset[g] {
				col = gui.Color{95, 95, 110, 255}
			}
			dc.filled_rect(x, y, cw, ch, col)
		}
	}
}

fn dim(c gui.Color) gui.Color {
	return gui.Color{u8(c.r / 4), u8(c.g / 4), u8(c.b / 4), 255}
}
