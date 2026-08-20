module main

import candb
import vgui

fn draw_trace(mut app App, rows []TraceRow, gcount map[string]u64, rx u64, run_base u64) {
	vis, op := vgui.begin_closable('Trace', app.show_trace)
	app.show_trace = op
	if !vis {
		vgui.end()
		return
	}
	if vgui.small_button(if app.trace_grouped { 'View: grouped' } else { 'View: all' }) {
		app.trace_grouped = !app.trace_grouped
	}
	vgui.same_line()
	vgui.text('RX ${rx} · ${vgui.fps():.0}fps')
	vgui.same_line()
	vgui.set_next_item_width(200)
	vgui.input_text('filter', mut app.trace_filter_buf)
	vgui.same_line()
	// The capture controls live with the capture. Pause freezes what the views take in,
	// Clear empties them, Record writes what they hold — all three act on THIS data, and in
	// the toolbar they read as app-global (Clear even existed in both places at once).
	// Opening a recording moved the other way, to File ▸ Open Recording: it is a file
	// operation, and a bare path field here read as a third kind of replay.
	if vgui.small_button(if app.paused { 'Resume' } else { 'Pause' }) {
		app.paused = !app.paused
	}
	vgui.same_line()
	if vgui.small_button('Clear') {
		app.clear_trace()
	}
	vgui.same_line()
	if vgui.small_button(if app.recording { 'Stop Rec' } else { 'Record' }) {
		app.toggle_record()
	}
	if app.recording {
		vgui.same_line()
		// the destination, while it still matters — a capture that only names its file in a
		// toast after the fact is a capture nobody could point a colleague at
		vgui.text_colored(230, 120, 120, '● ${app.rec_path}')
	}
	if app.viewing_rec != '' {
		// SAY when the rows are a file, and hand back the way out. Opening a recording is a
		// one-shot import, so there is nothing to "stop" — but a trace that silently becomes
		// a file's contents looks exactly like a live view that stopped updating.
		vgui.text_colored(230, 170, 70, 'viewing recording: ${app.viewing_rec}')
		vgui.same_line()
		if vgui.small_button('back to live##unrec') {
			app.clear_trace()
		}
	}
	// add the selected frame (click a row) to the Trace (filter) watch list
	if app.sel_id >= 0 {
		vgui.same_line()
		sid := u32(app.sel_id)
		sext := app.sel_ext
		if vgui.small_button('+ Add ${idstr(sid, sext)} to filter') {
			app.add_fwatch(sid, sext)
		}
	}
	if app.chans.len > 1 {
		app.trace_bus = bus_chips(app.chans, app.trace_bus, 't')
	}
	brows := app.filter_bus(rows, app.trace_bus)
	filt := vgui.buf_str(app.trace_filter_buf).to_lower()
	if app.trace_grouped {
		vgui.separator_text('by id (click to expand · click row to select)')
		draw_trace_grouped(mut app, brows, gcount, filt, run_base)
	} else {
		vgui.separator_text('frames (newest first)')
		draw_trace_all('trace9', brows, filt, run_base)
	}
	vgui.end()
}

// draw_ftrace is the "Trace (filter)" watch list: it shows ONLY the frames you've added
// (via "+ Add to filter" in the Trace panel, or "+" in Symbols), over the same buffer.
fn draw_ftrace(mut app App, rows []TraceRow, gcount map[string]u64, run_base u64) {
	vis, op := vgui.begin_closable('Trace (filter)', app.show_ftrace)
	app.show_ftrace = op
	if !vis {
		vgui.end()
		return
	}
	if vgui.small_button(if app.trace_grouped2 { 'View: grouped' } else { 'View: all' }) {
		app.trace_grouped2 = !app.trace_grouped2
	}
	vgui.same_line()
	vgui.set_next_item_width(180)
	vgui.input_text('find', mut app.trace_filter2_buf)
	vgui.same_line()
	if vgui.small_button('Clear watch') {
		app.fwatch = []
	}
	// watched-frame chips (click one to remove it from the list)
	if app.fwatch.len == 0 {
		vgui.text_dim('empty — select a frame in Trace and click "+ Add to filter", or "+" in Symbols')
	} else {
		vgui.text('watching:')
		for f in app.fwatch {
			nm := app.lookup_name(f.id, f.ext)
			vgui.same_line()
			if vgui.small_button('${idstr(f.id, f.ext)} ${nm} x##fw${f.id}_${f.ext}') {
				app.remove_fwatch(f.id, f.ext)
			}
		}
	}
	if app.chans.len > 1 {
		app.ftrace_bus = bus_chips(app.chans, app.ftrace_bus, 'f')
	}
	vgui.separator()
	if app.fwatch.len == 0 {
		vgui.end()
		return
	}
	// restrict to watched frames + optional bus, then apply the optional text find
	frows := app.filter_bus(rows.filter(app.is_fwatched(it.id, it.ext)), app.ftrace_bus)
	filt := vgui.buf_str(app.trace_filter2_buf).to_lower()
	if app.trace_grouped2 {
		draw_trace_grouped(mut app, frows, gcount, filt, run_base)
	} else {
		draw_trace_all('ftrace9', frows, filt, run_base)
	}
	vgui.end()
}

// bus_chips renders "show: [All] [bus…]" toggle-chips from the configured buses (labelled
// network/name when a network label is set) and returns the selected bus name ('' = all).
// `key` disambiguates the two Trace panels' widget ids.
fn bus_chips(chans []Chan, cur string, key string) string {
	mut sel := cur
	vgui.text('show:')
	vgui.same_line()
	if vgui.toggle_button('All##bc${key}', cur == '', 0) {
		sel = ''
	}
	for c in chans {
		label := if c.network != '' { '${c.network}/${c.name}' } else { c.name }
		vgui.same_line()
		if vgui.toggle_button('${label}##bc${key}_${c.name}', cur == c.name, 0) {
			sel = if cur == c.name { '' } else { c.name }
		}
	}
	return sel
}

// filter_bus keeps only rows on the selected bus (by configured name); '' = all. Live rows
// carry the bus name in `ch`, but rows from a loaded recording carry the log interface string
// (e.g. `vcan0`) instead of the bus name (e.g. `CAN0`), so also match the selected bus's
// iface/address — otherwise a chip would filter every imported row out.
fn (app &App) filter_bus(rows []TraceRow, bus string) []TraceRow {
	if bus == '' {
		return rows
	}
	mut aliases := [bus]
	for c in app.chans {
		if c.name == bus {
			if c.iface != '' && c.iface !in aliases {
				aliases << c.iface
			}
			if c.address != '' && c.address !in aliases {
				aliases << c.address
			}
		}
	}
	return rows.filter(it.ch in aliases)
}

fn idstr(id u32, ext bool) string {
	return if ext { '0x${id:08X}' } else { '0x${id:03X}' }
}

// kind_mark labels a frame whose KIND is not classic CAN. A 64-byte payload is obvious from the
// data column, but an FD frame carrying eight bytes or fewer looks exactly like a classic one,
// and BRS never shows at all — so the trace would claim a frame that was never on the bus.
// Empty for classic, which is the overwhelming majority and needs no decoration.
// flags_str is the FLAGS column: the frame kinds that are invisible from the payload alone.
// EXT is deliberately absent — the 8-digit id already shows it, and a column repeating a
// neighbouring column teaches the reader to skip both. (This absorbed kind_mark, whose leading
// space existed only for the data-cell suffix the flags column replaced.)
fn flags_str(r TraceRow) string {
	if r.rtr {
		return 'RTR'
	}
	if !r.fd {
		return ''
	}
	mut m := 'FD'
	if r.brs {
		m += '-BRS'
	}
	if r.esi {
		m += '-ESI' // the transmitter was error-passive: the reason this bit is kept at all
	}
	return m
}

// The idx and t (s) cells appear in both trace views; one implementation, so the two views
// cannot drift into showing the same frame with different numbers. idx is per-MEASUREMENT
// (seq minus the base recorded at the last reset); t is seconds at fixed six decimals — the
// decimals are real since the clock behind t_ms went monotonic-ns, and %f keeps trailing
// zeros so the column does not go ragged.
fn trace_idx_t_cells(r TraceRow, run_base u64) {
	vgui.table_cell('${r.seq - run_base}')
	vgui.table_cell('${r.t_ms / 1000.0:.6f}')
}

// trace_pass: case-insensitive substring match over id / name / ch / dir / data.
fn trace_pass(r TraceRow, filt string) bool {
	if filt == '' {
		return true
	}
	// the violation is searchable, so "!crc" in the filter box shows only bad frames — the
	// gesture someone reaches for the moment they suspect one
	// An origin on its own means the ORIGIN FIELD, not a substring of everything: a message
	// called BusStatus or a channel named SimBus would otherwise satisfy "bus" and "sim" for
	// every row, while the docs promise those two show only the real ECU and only the
	// simulation. Anything else searches the row as before.
	// `tx-s` is awkward to type, so `s` and `sim` reach the simulation too; `tx`, `rx` and `rep`
	// are already short. An alias only ever selects an origin — it never widens the search.
	origin_filter := match filt {
		's', 'sim' {
			org_tx_sim
		}
		else {
			if filt in [org_tx, org_tx_sim, org_rep, org_rx].map(it.to_lower()) { filt } else { '' }
		}
	}

	if origin_filter != '' {
		return r.origin.to_lower() == origin_filter.to_lower()
	}
	hay :=
		'${idstr(r.id, r.ext)} ${r.name} ${r.ch} ${r.origin}${origin_mark(r)} ${hex(r.data)} ${r.e2e}'.to_lower()
	return hay.contains(filt)
}

// loaded_dbs_for returns the CURRENT in-memory database for each of these paths — the edited
// copy where the editor has unsaved changes, skipping any path no longer loaded.
fn (app &App) loaded_dbs_for(paths []string) []candb.Database {
	mut out := []candb.Database{}
	for p in paths {
		i := app.dbs_paths.index(p)
		if i >= 0 && i < app.dbs.len {
			out << app.dbs[i]
		}
	}
	return out
}

// merge_dbs_from flattens several loaded databases into one, for callers that already hold
// Database values rather than paths.
fn merge_dbs_from(dbs []candb.Database) candb.Database {
	mut msgs := []candb.Message{}
	mut nodes := []string{}
	mut seen := map[string]bool{}
	for d in dbs {
		for m in d.messages {
			k := '${m.id}|${m.ext}'
			if k in seen {
				continue
			}
			seen[k] = true
			msgs << m
		}
		nodes << d.nodes
	}
	return candb.Database{
		messages: msgs
		nodes:    nodes
	}
}

// trace_name_cell is the name column, with any end-to-end verdict appended.
//
// Shared by the flat and GROUPED views because grouped is the default: a violation rendered
// only in the flat table is invisible unless the user happens to switch modes, which is the
// same as not reporting it.
fn trace_name_cell(r TraceRow) string {
	return if r.e2e == '' { r.name } else { '${r.name}  ${r.e2e}' }
}

fn draw_trace_all(id string, rows []TraceRow, filt string, run_base u64) {
	if vgui.table_begin(id, 9) {
		// Column order follows the layout every CAN tool's summary view has taught people to
		// read: index and time lead, then where (ch) and what (id/name), then the frame's shape.
		vgui.table_setup_col('idx', 60)
		// SECONDS, six decimals. The old `t (ms)` at one decimal quantised a 1 kHz bus to rows
		// that all read alike; the clock behind t_ms is ns-resolution now, so the decimals are
		// real, and seconds is the unit candump readers already think in.
		vgui.table_setup_col('t (s)', 100)
		vgui.table_setup_col('ch', 52)
		vgui.table_setup_col('id', 82)
		vgui.table_setup_col('name', 150)
		vgui.table_setup_col('origin', 64)
		vgui.table_setup_col('len', 34)
		vgui.table_setup_col('flags', 58)
		vgui.table_setup_col('data', 0) // stretch
		vgui.table_freeze_top()
		vgui.table_headers()
		mut i := rows.len - 1
		mut shown := 0
		for i >= 0 && shown < 300 {
			r := rows[i]
			i--
			if !trace_pass(r, filt) {
				continue
			}
			shown++
			vgui.table_row()
			trace_idx_t_cells(r, run_base)
			vgui.table_cell(r.ch)
			vgui.table_cell(idstr(r.id, r.ext))
			// A violation is appended to the NAME rather than given a column: it is rare, and
			// a permanently-empty column costs width on every row for the frames that are fine.
			vgui.table_cell(trace_name_cell(r))
			vgui.table_cell('${r.origin}${origin_mark(r)}')
			vgui.table_cell('${r.data.len}')
			vgui.table_cell(flags_str(r))
			// the FD/BRS suffix moved out of this cell into the flags column — payload only here
			vgui.table_cell(if r.rtr { '' } else { hex(r.data) })
		}
		vgui.table_end()
	}
}

struct GAgg {
mut:
	origin string
	ch     string
	id     u32
	ext    bool
	fd     bool
	brs    bool
	count  int
	// t_ms of the group's OLDEST frame still in the visible ring — the denominator of the fps
	// column. The ring holds 2000 rows, so this is the rate over the window the reader is
	// looking at, not over all time: a group that stops sending keeps its last computed rate
	// until its frames age out, exactly like the count next to it.
	first_t f64
	// Any frame in this group that never reached the wire. Taken across the whole group, not
	// from `last`: the newest row is the one whose echo window has had least time to close, so
	// reading the flag off it would hide every miss but the stalest.
	missed bool
	last   TraceRow // newest frame of this group in the window
	prev   TraceRow // the frame before `last` (empty data if only one seen) — for byte-delta dim
}

// gkey is the stable per-group identity used for both the grouped-view rows and the
// persistent all-time frame count (App.gcount). Keep in sync with draw_trace_grouped.
fn gkey(origin string, ch string, id u32, ext bool, fd bool, brs bool) string {
	// Length-prefixed for the same reason as tx_bus_key: a channel name may contain '|', and a
	// key that two different channels can produce merges their rows in the grouped view — with
	// a count that silently adds them together, which is the very thing this column exists to
	// stop. (origin is one of four fixed labels, and id/ext cannot contain a separator.)
	// fd/brs belong here for the same reason ext does: a CAN-FD frame and a classic frame with
	// the same id are two different messages, and a key that cannot tell them apart merges their
	// rows and adds their counts together — the exact collapse #90 was about, one field on.
	return '${origin}|${ch.len}:${ch}|${id}|${ext}|${fd}|${brs}'
}

// origin_mark renders the wire verdict for a frame we emitted: '!' once its echo window closed
// with nothing coming back. A bus that never echoes is a bus nothing reached — no ACK from any
// other node, wrong bitrate, swapped CANH/CANL, or a down link — and today that is invisible.
fn origin_mark(r TraceRow) string {
	return if r.missed { '!' } else { '' }
}

// grouped: one collapsible row per (dir, ch, id), expand to decode its latest signals.
// Rows are sorted by a STABLE key (id, then dir) so they never jump as the ring trims —
// the order is fixed by identity, not by which frame arrived most recently.
// gtrace10's column indices, for the sub-rows that address columns absolutely. Keep in step
// with the table_setup_col list directly below — these two lines and that list are the ONE
// place the grouped view's geometry lives.
const gcol_name = 3
const gcol_data = 7

fn draw_trace_grouped(mut app App, rows []TraceRow, gcount map[string]u64, filt string, run_base u64) {
	mut agg := map[string]GAgg{}
	for r in rows {
		if !trace_pass(r, filt) {
			continue
		}
		// Grouping by ORIGIN as well as id means our simulated 0x120 and a real ECU's 0x120 are
		// two rows, not one row with a count that quietly adds them together.
		k := gkey(r.origin, r.ch, r.id, r.ext, r.fd, r.brs)
		mut g := agg[k] or {
			GAgg{
				origin:  r.origin
				ch:      r.ch
				id:      r.id
				ext:     r.ext
				fd:      r.fd
				brs:     r.brs
				first_t: r.t_ms
				last:    r
			}
		}
		if r.missed {
			g.missed = true
		}
		if g.count > 0 {
			g.prev = g.last // slide the previous-frame window forward
		}
		g.count++
		g.last = r
		agg[k] = g
	}
	mut groups := agg.values()
	groups.sort_with_compare(fn (a &GAgg, b &GAgg) int {
		if a.id != b.id {
			return if a.id < b.id { -1 } else { 1 }
		}
		if a.origin != b.origin {
			return if a.origin < b.origin { -1 } else { 1 }
		}
		if a.ch != b.ch {
			return if a.ch < b.ch { -1 } else { 1 }
		}
		// The comparator has to separate everything the GROUP KEY separates. fd/brs joined that
		// key, so without them two distinct rows compare equal and their order flips as the ring
		// trims and the map is rebuilt — a table that reshuffles under a reader for no visible
		// reason. Classic sorts before FD, and FD before FD-BRS.
		if a.fd != b.fd {
			return if !a.fd { -1 } else { 1 }
		}
		if a.brs != b.brs {
			return if !a.brs { -1 } else { 1 }
		}
		return 0
	})
	if vgui.table_begin('gtrace10', 10) {
		// idx and t lead, as in the chronological view and in every summary view readers come
		// from; the tree (expand) widget rides on the id/name column, wherever that column is.
		// (Table id carries the column count: imgui persists per-column widths BY INDEX under
		// the id, so reusing 'gtrace' would drape the 5-column layout's saved widths over
		// these 10 columns. A new id starts clean; the old entry is orphaned, not misapplied.)
		vgui.table_setup_col('idx', 60)
		vgui.table_setup_col('t (s)', 100)
		vgui.table_setup_col('ch', 52)
		vgui.table_setup_col('id / name', 210)
		vgui.table_setup_col('origin', 64)
		vgui.table_setup_col('len', 34)
		vgui.table_setup_col('flags', 58)
		vgui.table_setup_col('data', 0)
		vgui.table_setup_col('count', 60)
		vgui.table_setup_col('fps', 56)
		vgui.table_freeze_top()
		vgui.table_headers()
		for g in groups {
			r := g.last
			vgui.table_row()
			// idx and t are the NEWEST frame's — the same one the data column shows — so the
			// row reads as one frame plus its history, not as fields from different frames.
			trace_idx_t_cells(r, run_base)
			vgui.table_cell(g.ch)
			vgui.table_next_col()
			// ### keys the tree id on identity only, so the live label / sort don't reset it.
			open := vgui.tree_node_table('${idstr(g.id, g.ext)}  ${trace_name_cell(r)}###${gkey(g.origin,
				g.ch, g.id, g.ext, g.fd, g.brs)}')
			// clicking a row selects that frame (drives Signals/Graphics + "Add to filter")
			if vgui.is_item_clicked() {
				app.sel_id = int(g.id)
				app.sel_ext = g.ext
			}
			// right-click a row → context menu (plot its signals / add to filter)
			if vgui.begin_popup_context_item('rowctx##${gkey(g.origin, g.ch, g.id, g.ext, g.fd,
				g.brs)}')
			{
				if m := app.find_message(g.id, g.ext) {
					if vgui.menu_item('Add all signals to Graphics') {
						for s in m.active_signals(if r.has_payload() { r.data } else { []u8{} }) {
							app.add_watch(g.id, g.ext, s.name)
						}
						app.show_graphics = true
					}
				}
				if vgui.menu_item('Add to Trace (filter)') {
					app.add_fwatch(g.id, g.ext)
				}
				vgui.end_popup()
			}
			vgui.table_cell('${g.origin}${if g.missed { '!' } else { '' }}')
			vgui.table_cell('${r.data.len}')
			vgui.table_cell(flags_str(r))
			// data column: dim bytes that match the PREVIOUS frame of this group, normal for
			// ones that changed (conventional change highlight). Compared against the actual prior
			// frame in the trace buffer — not the last-rendered payload — so the delta is correct
			// regardless of repaint timing (a byte that flips and flips back between repaints still
			// shows against the real previous frame).
			vgui.table_next_col()
			// payload only: the flags column carries RTR and the FD/BRS kind now, and an RTR
			// frame has no payload to show
			if !r.rtr {
				prev := g.prev.data
				for i, b in r.data {
					if i > 0 {
						vgui.same_line()
					}
					tok := '${b:02X}'
					if i >= prev.len || prev[i] != b {
						vgui.text(tok) // changed → normal colour
					} else {
						vgui.text_dim(tok) // unchanged → dimmed
					}
				}
			}
			// all-time total (survives the ring trim); fall back to the window count.
			total := gcount[gkey(g.origin, g.ch, g.id, g.ext, g.fd, g.brs)] or { u64(g.count) }
			vgui.table_cell('${total}')
			// Rate over the frames the ring still holds: n-1 intervals across the span they
			// cover. Two frames minimum — a single frame has no interval, and inventing one
			// from "now" would show a rate for a message that may never come again.
			span_ms := r.t_ms - g.first_t
			if g.count >= 2 && span_ms > 0 {
				vgui.table_cell('${f64(g.count - 1) * 1000.0 / span_ms:.1}')
			} else {
				vgui.table_cell('-')
			}
			if open {
				// an expanded RTR group decodes nothing: its newest frame has no payload,
				// only a DLC placeholder (see TraceRow.has_payload)
				if m := app.find_message(g.id, g.ext) {
					for s in m.active_signals(if r.has_payload() { r.data } else { []u8{} }) {
						lbl := s.label(r.data)
						extra := if lbl != '' { ' (${lbl})' } else { '' }
						unit := if s.unit != '' { ' ${s.unit}' } else { '' }
						vgui.table_row()
						// absolute columns, so inserting a column cannot silently land these
						// cells under a neighbour: the name sits in the id/name column, the
						// value in the data column — the same ones the parent row uses
						vgui.table_set_col(gcol_name)
						// selectable spans the cell so the whole row is a right-click target
						vgui.selectable('    ${s.name}##sigrow${g.id}_${g.ext}_${s.name}', false)
						if vgui.begin_popup_context_item('sigctx##${g.id}_${g.ext}_${s.name}') {
							if vgui.menu_item('Add ${s.name} to Graphics') {
								app.add_watch(g.id, g.ext, s.name)
								app.show_graphics = true
							}
							vgui.end_popup()
						}
						vgui.table_set_col(gcol_data)
						vgui.text('${s.physical(r.data):.3}${unit}${extra}')
					}
				}
				vgui.tree_pop()
			}
		}
		vgui.table_end()
	}
}
