// blobly_vgui — the Dear ImGui + ImPlot frontend for blobly_net (phased migration off
// vlang/gui; see docs/gui_toolkit_evaluation.md). Phase 1: load a project, monitor its
// enabled CAN channels on background RX threads, and render a live decoded **Trace** table
// + the **Trace Chart** swimlane (telemetry) — reusing the GUI-free engine modules
// (project / transport / candb / telem) unchanged. gui's src/main.v stays the shipping app
// until this reaches parity.
//
// Build: eval/vgui/build_deps.sh  then
//   v -enable-globals -cc gcc -path "@vlib|@vmodules|modules|eval" run cmd/blobly_vgui/main.v
// Project via BLOBLY_PROJECT (default projects/trace-demo.blobnet — monitors vcan0 + a manifest).
// Feed it: python3 blobly_emb .../trace_demo vcan0, or cansend/cangen vcan0.
//
// Env: VGUI_WAKE_MS=<ms> repaint cap (default 33 ≈ 30fps). VGUI_FRAMES / VGUI_SHOT for headless.
module main

import os
import sync
import time
import project
import transport
import candb
import telem
import vgui

const trace_cap = 2000
const telem_cap = 20000

struct TraceRow {
	t_ms f64
	ch   string
	id   u32
	ext  bool
	rtr  bool
	name string
	data []u8
}

struct TRec {
	ch  int
	rec telem.Record
}

struct App {
mut:
	mu           sync.Mutex
	trace        []TraceRow
	trecs        []TRec
	rx           u64
	rev          u64 // bumps on telem ingest -> swimlane re-tessellate key
	stop         bool
	dbs          []candb.Database
	manifest     telem.Manifest
	has_manifest bool
	t0           i64
	wake_ms      i64
	last_wake    i64
}

// decode a frame's message name across all loaded DBCs (first hit).
fn (a &App) lookup_name(id u32, ext bool) string {
	for db in a.dbs {
		if m := db.lookup_frame(id, ext) {
			return m.name
		}
	}
	return ''
}

fn rx_loop(app &App, chname string, ci int, iface string) {
	mut bus := transport.open(iface) or {
		eprintln('rx ${chname}: open ${iface} failed: ${err}')
		return
	}
	mut a := unsafe { app }
	for {
		if a.stop {
			break
		}
		f := bus.recv(200) or { continue }
		t_ms := f64(time.ticks() - a.t0)
		name := a.lookup_name(f.id, f.extended)

		a.mu.lock()
		a.trace << TraceRow{
			t_ms: t_ms
			ch:   chname
			id:   f.id
			ext:  f.extended
			rtr:  f.rtr
			name: name
			data: f.data.clone()
		}
		if a.trace.len > trace_cap {
			a.trace = a.trace[a.trace.len - trace_cap..].clone()
		}
		// telemetry ingest (0x7E5 Record) when this channel has a manifest
		if a.has_manifest && !f.extended && !f.rtr && f.data.len == 8 && f.id == telem.id_record {
			a.trecs << TRec{ci, telem.decode_record(f.data)}
			if a.trecs.len > telem_cap {
				a.trecs = a.trecs[a.trecs.len - telem_cap..].clone()
			}
			a.rev++
		}
		a.rx++
		a.mu.unlock()

		// coalesced repaint request (best-effort across threads)
		now := time.ticks()
		if now - a.last_wake >= a.wake_ms {
			a.last_wake = now
			vgui.wake()
		}
	}
	bus.close()
}

fn hex(b []u8) string {
	mut p := []string{cap: b.len}
	for x in b {
		p << '${x:02X}'
	}
	return p.join(' ')
}

const lane_palette = [
	[u8(66), 135, 245],
	[u8(76), 175, 80],
	[u8(245), 166, 35],
	[u8(233), 80, 80],
	[u8(155), 100, 210],
	[u8(0), 172, 193],
	[u8(233), 110, 170],
	[u8(140), 160, 60],
]

fn main() {
	proj_path := os.getenv_opt('BLOBLY_PROJECT') or { 'projects/trace-demo.blobnet' }
	proj := project.load(proj_path) or {
		eprintln('load ${proj_path}: ${err}')
		return
	}
	mut wake_ms := os.getenv('VGUI_WAKE_MS').i64()
	if wake_ms <= 0 {
		wake_ms = 33
	}
	max_frames := os.getenv('VGUI_FRAMES').int()
	shot := os.getenv('VGUI_SHOT')

	mut app := &App{
		t0:      time.ticks()
		wake_ms: wake_ms
	}
	// load DBCs + a telem manifest from the project channels
	for ch in proj.channels {
		for dbpath in ch.databases {
			if db := candb.load_dbc_file(dbpath) {
				app.dbs << db
			} else {
				eprintln('dbc ${dbpath}: ${err}')
			}
		}
		if ch.manifest != '' && !app.has_manifest {
			if m := telem.load_manifest(ch.manifest) {
				app.manifest = m
				app.has_manifest = true
			} else {
				eprintln('manifest ${ch.manifest}: ${err}')
			}
		}
	}
	// open enabled monitor CAN channels on their own RX threads
	mut opened := 0
	for ci, ch in proj.channels {
		if !ch.enabled || ch.mode != .monitor || ch.is_doip() {
			continue
		}
		spawn rx_loop(app, ch.name, ci, ch.iface)
		opened++
	}
	println('blobly_vgui: ${proj.name} — ${opened} monitor channel(s), ${app.dbs.len} DBC(s), manifest=${app.has_manifest}')

	if !vgui.init('blobly_net — ${proj.name} (imgui/ImPlot)', 1400, 820, true) {
		eprintln('vgui.init failed')
		return
	}

	mut frame := 0
	for vgui.running() {
		frame++
		last := max_frames > 0 && frame >= max_frames
		if last && shot != '' {
			vgui.dump_ppm(shot)
		}

		app.mu.lock()
		rx := app.rx
		rows := app.trace.clone()
		trecs := app.trecs.clone()
		app.mu.unlock()

		vgui.frame_begin()
		// dock the two panels side by side inside the main window (one-time; user can
		// re-arrange or tear a tab off afterwards).
		vgui.dock_2col('Trace', 'Trace Chart', 0.6)

		// --- Trace (live decoded frames) ---
		vgui.begin('Trace')
		vgui.text('RX ${rx} · ${rows.len} shown · ${vgui.fps():.0}fps · ${proj_path}')
		vgui.separator_text('frames (newest first)')
		if vgui.table_begin('trace', 5) {
			vgui.table_col('t (ms)')
			vgui.table_col('ch')
			vgui.table_col('id')
			vgui.table_col('name')
			vgui.table_col('data')
			vgui.table_headers()
			mut i := rows.len - 1
			mut shown := 0
			for i >= 0 && shown < 200 {
				r := rows[i]
				idw := if r.ext { '0x${r.id:08X}' } else { '0x${r.id:03X}' }
				vgui.table_row()
				vgui.table_cell('${r.t_ms:.1}')
				vgui.table_cell(r.ch)
				vgui.table_cell(idw)
				vgui.table_cell(r.name)
				vgui.table_cell(if r.rtr { 'RTR' } else { hex(r.data) })
				i--
				shown++
			}
			vgui.table_end()
		}
		vgui.end()

		// --- Trace Chart (telemetry swimlane, ImPlot) ---
		vgui.begin('Trace Chart')
		if app.has_manifest {
			labels, bars, span := build_swimlane(app, trecs)
			vgui.text('${trecs.len} records · ${labels.len} handlers · gaps = idle')
			vgui.text_dim('drag = pan · scroll = zoom · double-click = fit')
			if bars.len > 0 {
				vgui.swimlane('##swim', labels, bars, span)
			} else {
				vgui.text_dim('waiting for Record frames (0x7E5) — run a trace_demo + dump')
			}
		} else {
			vgui.text_dim('no telemetry manifest on any channel')
		}
		vgui.end()

		vgui.frame_end()
		if last {
			eprintln('rendered ${frame} frames; RX ${rx}')
			break
		}
	}
	app.stop = true
	vgui.shutdown()
}

// build_swimlane turns telem Records into per-handler lanes + coloured bars (t in µs,
// relative to the first record).
fn build_swimlane(app &App, trecs []TRec) ([]string, []vgui.Bar, f32) {
	if trecs.len == 0 {
		return []string{}, []vgui.Bar{}, f32(1)
	}
	mut lane_of := map[u8]int{}
	mut labels := []string{}
	for tr in trecs {
		id := tr.rec.handler_id
		if id !in lane_of {
			lane_of[id] = labels.len
			labels << app.manifest.label(id)
		}
	}
	mut tmin := f32(3.4e38)
	mut tmax := f32(0)
	for tr in trecs {
		s := f32(tr.rec.start_us)
		e := s + f32(tr.rec.cpu_us)
		if s < tmin {
			tmin = s
		}
		if e > tmax {
			tmax = e
		}
	}
	span := if tmax > tmin { tmax - tmin } else { f32(1) }
	mut bars := []vgui.Bar{cap: trecs.len}
	for tr in trecs {
		r := tr.rec
		li := lane_of[r.handler_id]
		c := lane_palette[li % lane_palette.len]
		bars << vgui.Bar{
			t0:        f32(r.start_us) - tmin
			dur:       f32(r.cpu_us)
			lane:      li
			color:     vgui.rgba(c[0], c[1], c[2], 235)
			warn:      if (r.flags & (telem.flag_overran | telem.flag_saturated)) != 0 { 1 } else { 0 }
			preempted: if (r.flags & telem.flag_preempted) != 0 { 1 } else { 0 }
		}
	}
	return labels, bars, span
}
