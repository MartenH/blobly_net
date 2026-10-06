module main

import candb
import gaterule
import transport
import j1939
import watchrule

// WHICH WIRE A ROW IS FILED UNDER, and which databases a frame on it decodes against (#330).
//
// Every CAN row carries the wire it came off (`TraceRow.wire`), and every watch, the Signals
// panel's selection and the decode of both are scoped by it (`watchrule`). The wire and not the
// row: two rows aliasing one wire carry the same frames, filed under whichever row read or sent
// each one, so a scope by row would split one wire's traffic by who put it there.

// rec_wire_prefix marks a recorded bus the project cannot place (`watchrule.rec_prefix`).
const rec_wire_prefix = watchrule.rec_prefix

// trace_wire is the wire a row is filed under, from the gate that read it and the key that
// observed it. Live the two are one destination key. For an import it is the configured wire
// the recorded bus was placed on, and the recorded bus ITSELF where it was placed nowhere —
// the undecidable fallback is shared by every unplaced bus of a file, so filing them under it
// would put thirteen buses of one MF4 into one series.
fn trace_wire(gate string, key string) string {
	p := gaterule.placement(gate)
	if p == j1939_gate_undecidable || p == '' {
		return key
	}
	return p
}

// rec_wire is a recorded bus's own wire, for a label nothing in the project placed.
fn rec_wire(label string) string {
	return rec_wire_prefix + label
}

// build_wire_dbs is `wire_dbs`: every configured CAN wire, with the databases of every row on
// it as indices into `app.dbs` in lookup order, each file once — an entry with none is still a
// configured wire, and answers with nothing rather than with another wire's layout. Keyed by
// BOTH spellings of a row's wire, the adapter-aware one the configuration uses and the one a
// live row is filed under (`destination_key` of its interface), which differ only for a vendor
// adapter on a platform that has no such driver. Caller holds app.mu.
fn (app &App) build_wire_dbs() map[string][]int {
	mut out := map[string][]int{}
	for c in app.chans {
		if c.doip || c.someip {
			continue
		}
		mut keys := [transport.destination_key_for(c.adapter, c.iface)]
		live := transport.destination_key(c.iface)
		if live != keys[0] {
			keys << live
		}
		for raw in c.databases {
			idx := app.dbs_paths.index(candb.canonical_database_ref(app.resolve_asset(raw)))
			for k in keys {
				mut list := out[k] or { []int{} }
				if idx >= 0 && idx !in list {
					list << idx
				}
				out[k] = list
			}
		}
		for k in keys {
			if k !in out {
				out[k] = []int{}
			}
		}
	}
	return out
}

// unbind_lost_wires releases every watch on a wire this runtime view no longer configures —
// a channel's interface edited, a row deleted — so it binds again (`bind_watches`) instead of
// plotting nothing for good: a scoped watch cannot follow its channel to a new key by itself.
// A recorded bus is not a configured wire and is kept. Caller holds app.mu.
fn (mut app App) unbind_lost_wires(old []string) {
	for i, w in app.watch {
		if w.wire in old && w.wire !in app.wire_dbs {
			app.watch[i] = Watch{
				...w
				wire: ''
			}
		}
	}
}

// wire_configured reports whether a configured CAN channel is on this wire.
fn (app &App) wire_configured(wire string) bool {
	return gaterule.placement(wire) in app.wire_dbs
}

// frame_db_indices is the databases a FRAME on `wire` decodes against, as indices into
// `app.dbs` in lookup order: the wire's own (`wire_dbs`) — empty included, since another
// wire's layout is exactly the mixing this scoping stops — or every loaded one for a wire no
// configured channel is on: an import's unplaced bus, which decoded that way before it had a
// wire and has no better answer now.
fn (app &App) frame_db_indices(wire string) []int {
	if idxs := app.wire_dbs[gaterule.placement(wire)] {
		return idxs
	}
	return []int{len: app.dbs.len, init: index}
}

// frame_message_on is the message a frame `(id, ext)` on `wire` decodes against: the first of
// the wire's databases that defines it.
fn (app &App) frame_message_on(wire string, id u32, ext bool) ?candb.Message {
	for i in app.frame_db_indices(wire) {
		if i >= app.dbs.len {
			continue
		}
		if m := app.dbs[i].lookup_frame(id, ext) {
			return m
		}
	}
	return none
}

// frame_backed_by reports whether database `di` is the one a frame `(id, ext)` on `wire`
// decodes against — on that wire's list, with nothing ahead of it there defining `(id, ext)`.
// What a DBC edit asks of a frame watch before moving it: the edit concerns the watch only
// where the edited file is the one that names it. Asked after the edit too, since it does not
// require `di` itself to define `(id, ext)` (an id edit has just moved it).
fn (app &App) frame_backed_by(wire string, di int, id u32, ext bool) bool {
	for i in app.frame_db_indices(wire) {
		if i == di {
			return true
		}
		if i >= app.dbs.len {
			continue
		}
		if _ := app.dbs[i].lookup_frame(id, ext) {
			return false
		}
	}
	return false
}

// lookup_name_on is a frame's name in the trace: its wire's lookup, the one its signals are
// decoded and plotted by, so the name column and the decode cannot name one row two ways.
fn (app &App) lookup_name_on(wire string, id u32, ext bool) string {
	m := app.frame_message_on(wire, id, ext) or { return '' }
	return m.name
}

// edit_reaches is whether a DBC edit to `(id, ext)` in database `di` concerns watch `w` — the
// one question the editor's three rewrites ask. A REJOINED watch: on one of `tp_wires`, the
// wires `di` backs where the edit is not shadowed, by group. A FRAME's: where `di` is the
// database its own wire decodes it with (`frame_backed_by`), by id.
fn (app &App) edit_reaches(w Watch, di int, id u32, ext bool, tp_wires []string) bool {
	if w.tp {
		return tp_wires.any(w.renamed_by(id, ext, it, j1939.pgn(id)))
	}
	return app.frame_backed_by(w.wire, di, id, ext) && w.renamed_by(id, ext, w.wire, 0)
}

// follow_pending_selection moves a selection picked from the database list and not yet bound
// with its message, when the DBC editor moves that message to another `(id, ext)`: the same
// `renamed_by` rule the watches follow, on the database it was picked from. A RENAME needs
// nothing — the pending selection is keyed by database and id, never by name (codex on #410).
fn (mut app App) follow_pending_selection(di int, old_id u32, old_ext bool, new_id u32, new_ext bool) {
	if app.sel_id < 0 || app.sel_wire != '' || app.sel_db != di {
		return
	}
	if app.sel_watch('').renamed_by(old_id, old_ext, '', 0) {
		app.sel_id = int(new_id)
		app.sel_ext = new_ext
	}
}

// bind_watches gives every UNBOUND watch a wire (`watchrule.Ident.bind`): the oldest row's
// among wires whose databases name its signal. Two that land on one identity are one watch.
fn (mut app App) bind_watches(rows []TraceRow) {
	if !app.watch.any(it.wire == '') {
		return
	}
	a := app
	mut kept := []Watch{cap: app.watch.len}
	for w in app.watch {
		mut b := w
		if w.wire == '' {
			b = Watch{
				...w
				wire: w.bind(rows.len, fn [rows] (k int) watchrule.Row {
					return watch_row(rows[k])
				}, fn [a] (wire string) bool {
					return a.wire_configured(wire)
				}, fn [a, w] (wire string) bool {
					m := a.message_on(wire, w.id, w.ext, w.tp) or { return false }
					return m.signals.any(it.name == w.sig)
				})
			}
		}
		if b.wire != '' && kept.any(it.same(b)) {
			continue
		}
		kept << b
	}
	app.watch = kept
}

// wire_label is a wire as the operator knows it: the configured channel on it (the first, where
// several alias it), a recorded bus by its label, else the key itself.
fn (app &App) wire_label(wire string) string {
	if wire.starts_with(rec_wire_prefix) {
		return wire[rec_wire_prefix.len..]
	}
	p := gaterule.placement(wire)
	for c in app.chans {
		if !c.doip && !c.someip && transport.destination_key_for(c.adapter, c.iface) == p {
			return c.name
		}
	}
	return p
}
