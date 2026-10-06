module main

import candb
import gaterule
import transport

// WHICH WIRE A ROW IS FILED UNDER, and which databases a frame on it decodes against (#330).
//
// Every CAN row carries the wire it came off (`TraceRow.wire`), and every watch, the Signals
// panel's selection and the decode of both are scoped by it (`watchrule`). The wire and not the
// row: two rows aliasing one wire carry the same frames, filed under whichever row read or sent
// each one, so a scope by row would split one wire's traffic by who put it there.

// rec_wire_prefix marks a recorded bus the project cannot place: a NUL, so no live destination
// key can spell it (codex on #329).
const rec_wire_prefix = '\x00rec:'

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

// wire_configured reports whether a configured CAN channel is on this wire.
// NOTE concurrency: app.chans is read unlocked, as every panel reads it.
fn (app &App) wire_configured(wire string) bool {
	if wire == '' {
		return false
	}
	p := gaterule.placement(wire)
	for c in app.chans {
		if !c.doip && !c.someip && transport.destination_key_for(c.adapter, c.iface) == p {
			return true
		}
	}
	return false
}

// frame_db_indices is the databases a FRAME on `wire` decodes against, as indices into
// `app.dbs` in lookup order: the wire's own (every row on it, `db_indices_for_gate`) — empty
// included, since another wire's layout is exactly the mixing this scoping stops — or every
// loaded one for a wire no configured channel is on: an import's unplaced bus, which decoded
// that way before it had a wire and has no better answer now.
fn (app &App) frame_db_indices(wire string) []int {
	if app.wire_configured(wire) {
		return app.db_indices_for_gate(wire)
	}
	return []int{len: app.dbs.len, init: index}
}

// frame_message_on is the message a frame `(id, ext)` on `wire` decodes against: the first of
// the wire's databases that defines it.
fn (app &App) frame_message_on(wire string, id u32, ext bool) ?candb.Message {
	for i in app.frame_db_indices(wire) {
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
		if _ := app.dbs[i].lookup_frame(id, ext) {
			return false
		}
	}
	return false
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
