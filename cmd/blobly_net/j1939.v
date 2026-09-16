module main

import transport
import candb
import j1939

// J1939 in the trace (#171): what a 29-bit id MEANS, a multi-packet message as one row, and a
// source address named by the node that claimed it. All of it read-side — the engine is
// `modules/j1939`, and this file is the GUI's use of it: where the reading is decided and
// computed, where a rejoined message becomes a TraceRow, where a fault or a claim becomes a
// Log line.
//
// THE READING IS PER WIRE, and it is chosen, not inferred. A 29-bit id is not evidence of the
// protocol on its own — UDS on 29-bit ids is PDU1-shaped — and one project can carry a J1939
// truck bus beside a 29-bit diagnostic bus, so a single answer for the process would put a
// confident wrong reading on one of them. The default comes from the databases attached to
// each wire (`Database.j1939_declared()`, computed at rebuild into `App.j1939_dbs`) and the
// Trace panel's tick is a TRI-STATE override — follow the databases, force on, force off —
// because a bool has no value spare for "the operator has not said" (the `player/control.v`
// lesson), and a rebuild recomputing a bool overwrote a tick the operator had set every time
// they saved (self-review of #171). Only a project load clears the override.

// J1939Gate is the operator's answer: follow what the databases declare, or override it.
enum J1939Gate {
	follow
	on
	off
}

// J1939Obs is one reader's listener state: the transport-protocol sessions in progress on its
// wire (or on one recorded bus of an import) and how much it has already said about faults.
// Per rx_loop and per recorded bus, never shared: a session is keyed by (source, destination)
// and two buses can carry the same pair — a gateway forwarding a BAM does exactly that.
struct J1939Obs {
mut:
	tp j1939.Reassembler
	// Narration budget. A fault per dropped packet is right on a quiet bench and a flood in an
	// error storm; past the budget the Log says once that it stopped, and the rows keep coming.
	said int
	// Orphans — data frames of a transfer already in progress when listening began — are the
	// normal case of attaching to a running bus, up to 255 of them per session, so they are
	// said ONCE and counted after. A budget shared with the real faults would be spent on them.
	orphans int
}

// How many transport-protocol faults one reader narrates per run before going quiet.
const j1939_fault_budget = 20

// LabelCache is one wire's display names by id (App.j1939_labels). A reference, so the RX path
// writes into it in place: V does not copy a map out of a map and back.
struct LabelCache {
mut:
	by_id   map[u32]string // the display name: the database's name and the reading
	reading map[u32]string // the reading alone
}

// j1939_join is the ONE spelling of a name cell: the database's name, two spaces, the reading;
// either alone when the other is empty.
fn j1939_join(name string, reading string) string {
	if reading == '' {
		return name
	}
	if name == '' {
		return reading
	}
	return '${name}  ${reading}'
}

// j1939_on_locked says whether the J1939 reading applies to a wire, by the key its databases
// were filed under (a destination key; an import's unresolved label falls back to whether ANY
// database declares it, the best answer for a bus the project cannot place). Caller holds app.mu.
fn (app &App) j1939_on_locked(gate string) bool {
	return match app.j1939_override {
		.on {
			true
		}
		.off {
			false
		}
		.follow {
			if gate == j1939_gate_undecidable {
				false
			} else if gate == '' {
				// the one gate that means "a recorded bus the project could not place": the
				// project-wide default is the best answer for a file whose buses name no wire
				app.j1939_any
			} else {
				// a live wire the project did not configure — a generator's `bus:` aimed at a
				// bare interface — declares nothing and reads as nothing, whatever an unrelated
				// configured wire declares (codex on #329)
				app.j1939_dbs[gate] or { false }
			}
		}
	}
}

// j1939_gate_undecidable is the gate of a recorded bus whose label two configured wires answer
// to: in auto it reads as NOT J1939 — the project-wide default would read it as whichever wire
// declares it, which is a guess about a bus that may have come from the other one (codex on
// #329) — while on / off still override it like any wire. Distinct from '' (a label no wire
// answers to, which takes the project-wide default). Spelled with a NUL byte, which no
// destination key can carry — every one is derived from an interface string that reaches a C
// API — so a wire cannot be named into it (codex on #329, on a readable spelling).
const j1939_gate_undecidable = '\x00undecidable'

// j1939_display_locked is the row's NAME cell on a J1939 wire: the database's name and the
// reading — `EEC1  PGN 0xF004 SA 0x00 Engine` — or the reading alone where the database has no
// name. `gate` decides whether the reading applies, `key` is where the wire's claims are filed
// (both the destination key live; the resolved wire and the recording's label for an import).
//
// CACHED per wire and id, because this runs on the RX path under app.mu for every extended
// frame and a formatted string per frame is the allocation class #300 took out of that path: a
// J1939 bus has a few hundred distinct ids, so after the first frame of each the cost is one
// map lookup. The cache for a wire is dropped when its directory changes (a claim renames a
// source address), and all of it when the databases or the override change. Caller holds app.mu.
fn (mut app App) j1939_display_locked(gate string, key string, id u32, ext bool, name string) string {
	if !ext || !app.j1939_on_locked(gate) {
		return name
	}
	if c := app.j1939_labels[key] {
		if s := c.by_id[id] {
			return s
		}
	}
	reading := app.j1939_reading_locked(gate, key, id, ext)
	disp := j1939_join(name, reading)
	mut c := app.j1939_labels[key] or {
		nc := &LabelCache{}
		app.j1939_labels[key] = nc
		nc
	}
	c.by_id[id] = disp
	return disp
}

// j1939_reading_locked is the reading alone — `PGN 0xF004 SA 0x00 Engine` — cached like the
// display name, '' where the reading is off or the frame is not extended. Caller holds app.mu.
fn (mut app App) j1939_reading_locked(gate string, key string, id u32, ext bool) string {
	if !ext || !app.j1939_on_locked(gate) {
		return ''
	}
	if c := app.j1939_labels[key] {
		if s := c.reading[id] {
			return s
		}
	}
	i := j1939.decompose(id)
	mut reading := i.label()
	if d := app.j1939_nodes[key] {
		n := d.label(i.sa)
		if n != '' {
			reading += ' ${n}'
		}
	}
	mut c := app.j1939_labels[key] or {
		nc := &LabelCache{}
		app.j1939_labels[key] = nc
		nc
	}
	c.reading[id] = reading
	return reading
}

// j1939_iface_locked is the display name and the reading for an EMITTED frame, whose caller
// holds the wire's interface and not its key. Everything that can say "no" is asked before the
// key is derived, and the key comes from a cache, because this is the emit path: a string built
// per frame for a reading nobody asked for is exactly what #300 removed from it. Caller holds
// app.mu.
fn (mut app App) j1939_iface_locked(iface string, f transport.CanFrame, name string) (string, string) {
	if !f.extended || app.j1939_override == .off {
		return name, ''
	}
	if app.j1939_override == .follow && !app.j1939_any {
		return name, ''
	}
	dest := app.dest_cached_locked(iface)
	return app.j1939_display_locked(dest, dest, f.id, true, name), app.j1939_reading_locked(dest,
		dest, f.id, true)
}

// dest_cached_locked is transport.destination_key(iface), remembered per interface: the answer
// is a property of the emitter and never changes for a loaded project (the cache is reset with
// the runtime view), and deriving it per frame costs several strings on a vendor address. Caller
// holds app.mu.
fn (mut app App) dest_cached_locked(iface string) string {
	if d := app.dest_cache[iface] {
		return d
	}
	d := transport.destination_key(iface)
	app.dest_cache[iface] = d
	return d
}

// j1939_frame_locked is the display name and the reading for a RECEIVED frame, with the one
// case the directory cannot answer: an Address Claimed frame names its own sender in its
// payload, and a claim that LOST — a higher NAME contesting an address the directory keeps for
// the lower one — would otherwise wear the winner's name (codex on #329). Uncached: claims are
// rare. Caller holds app.mu.
fn (mut app App) j1939_frame_locked(gate string, key string, f transport.CanFrame, name string) (string, string) {
	if f.extended && !f.rtr && f.data.len == 8 && app.j1939_on_locked(gate) {
		i := j1939.decompose(f.id)
		if j1939.is_address_claim(i) {
			if n := j1939.decode_name(f.data) {
				reading := '${i.label()} ${n.label()}'
				return j1939_join(name, reading), reading
			}
		}
	}
	return app.j1939_display_locked(gate, key, f.id, f.extended, name), app.j1939_reading_locked(gate,
		key, f.id, f.extended)
}

// j1939_obs_locked is the listener for a wire, created on first use. ON THE APP, by wire, not
// in the reader: an aliased wire's reader is handed to a sibling row when its own is disabled,
// and a listener local to the loop went with it — a transfer announced before the handoff had
// no session after it, and its packets were orphans (codex on #329). Reset with the directory.
// Caller holds app.mu.
fn (mut app App) j1939_obs_locked(key string) &J1939Obs {
	if o := app.j1939_obs[key] {
		return o
	}
	o := &J1939Obs{}
	app.j1939_obs[key] = o
	return o
}

// j1939_note_locked feeds one frame OFF THE WIRE to the wire's listener and returns the
// transport-protocol messages it completed. An Address Claimed frame moves the directory and is
// narrated; every other extended frame goes to the reassembler, which advances its sessions and
// expires the stalled ones — fed every frame, not only TP ones, or a sender that stopped
// mid-transfer on a bus with no other TP traffic would never be timed out. Faults are narrated
// here, within the budget. Called BEFORE the frame's own row is pushed, so a claim names its
// sender from its own row on. With the reading OFF for the wire the listener's state is dropped
// rather than kept: a session that outlived an off interval would fault, or complete out of
// nothing, when the reading came back (codex on #329). Caller holds app.mu.
fn (mut app App) j1939_note_locked(mut obs J1939Obs, ch string, gate string, key string, f transport.CanFrame, t_ms f64) []j1939.Assembled {
	if !app.j1939_on_locked(gate) {
		if obs.tp.open() > 0 {
			obs.tp = j1939.Reassembler{}
		}
		return []
	}
	if !f.extended || f.rtr {
		// Not a frame the listener reads, but a frame that says time passed: on a mixed wire
		// with continuous standard traffic the poll never times out and no extended frame need
		// come, so a stalled session would otherwise wait forever for either (codex on #329).
		if obs.tp.open() > 0 {
			app.j1939_expire_locked(mut obs, ch, gate, t_ms)
		}
		return []
	}
	id := j1939.decompose(f.id)
	if j1939.is_address_claim(id) {
		mut dir := app.j1939_nodes[key] or { j1939.Directory{} }
		if c := dir.observe(id.sa, f.data, t_ms) {
			app.j1939_nodes[key] = dir
			// a source address changed hands: every cached reading on this wire may name it
			app.j1939_labels.delete(key)
			app.log_append_locked('${ch}: J1939 ${c.str()}')
		}
		// and FALL THROUGH to the reassembler, which reads nothing from a claim but expires
		// the stalled: a wire carrying claims every 100 ms neither times the poll out nor
		// need carry any other extended frame (codex on #329, the third early return of this
		// kind — every frame this function sees now reaches expiry)
	}
	ev := obs.tp.feed(f, t_ms)
	for fl in ev.faults {
		app.j1939_narrate_locked(mut obs, ch, fl)
	}
	return ev.done
}

// j1939_expire_locked times out the wire's stalled sessions when nothing has been received to
// feed them — the RX loop's poll timeout — and narrates them like any fault; with the reading
// off for the wire it drops them instead, as j1939_note_locked does. Caller holds app.mu.
fn (mut app App) j1939_expire_locked(mut obs J1939Obs, ch string, gate string, t_ms f64) {
	if !app.j1939_on_locked(gate) {
		obs.tp = j1939.Reassembler{}
		return
	}
	for fl in obs.tp.expire(t_ms) {
		app.j1939_narrate_locked(mut obs, ch, fl)
	}
}

// j1939_push_tp_locked gives each completed message a row of its own — the channel and origin
// of the frame that completed it, the whole parameter group as data, flags TP, and the id a
// single frame of the PGN would carry so the database decodes it like one. `push` says whether
// the table is taking rows (not while paused, not for the trimmed prefix of an import); `count`
// whether the grouped view's total counts it (as frames are counted: not while paused, but over
// the whole of an import). Returns how many rows were pushed. Caller holds app.mu.
fn (mut app App) j1939_push_tp_locked(done []j1939.Assembled, ch string, gate string, key string, t_ms f64, origin string, imported bool, push bool, count bool) int {
	mut n := 0
	for a in done {
		id := a.id()
		// The database's name BY PGN — what the announcement carried, never the id composed
		// from it, which an unrelated extended `BO_` can sit at exactly (codex on #329) — else
		// the protocol's own name for the few PGNs it has one for, else nothing: the reading in
		// the same cell says PGN and sender either way.
		mut name := ''
		if m := find_pgn_message_in(app.dbs_for_gate(gate), a.pgn, a.sa) {
			name = m.name
		} else {
			name = j1939.pgn_name(a.pgn) or { '' }
		}
		how := if a.bam { 'BAM' } else { 'RTS/CTS' }
		reading := '${app.j1939_reading_locked(gate, key, id, true)} · ${a.packets()} packets ${how}'
		row := TraceRow{
			t_ms:     t_ms
			ch:       ch
			origin:   origin
			id:       id
			ext:      true
			name:     j1939_join(name, reading)
			reading:  reading
			data:     a.data
			imported: imported
			tp:       true
			wire:     gate
		}
		// The key from the row's own fields (gkey formats it when `key` is empty), never a
		// positional list of flags: one transposed bool there is absorbed silently by the
		// grouped view's fallback, which is the trap gkey_fmt's comment names.
		k := row.gkey()
		if count {
			app.gcount[k]++
		}
		if push {
			app.push_row_locked(TraceRow{
				...row
				key: k
			})
			n++
		}
	}
	return n
}

// find_pgn_message_in is the message a J1939 parameter group FROM `sa` decodes against, over
// the given databases: one spelled at exactly that address first (a database may define one
// PGN at several addresses with several layouts — codex on #329), then by PGN alone; declared
// before undeclared at each step, the first database with a match winning.
fn find_pgn_message_in(dbs []candb.Database, pgn u32, sa u8) ?candb.Message {
	for db in dbs {
		if m := db.lookup_pgn_sa(pgn, sa) {
			if m.j1939 {
				return m
			}
		}
	}
	for db in dbs {
		if m := db.lookup_pgn_sa(pgn, sa) {
			return m
		}
	}
	for db in dbs {
		if m := db.lookup_pgn(pgn) {
			if m.j1939 {
				return m
			}
		}
	}
	for db in dbs {
		if m := db.lookup_pgn(pgn) {
			return m
		}
	}
	return none
}

// dbs_for_gate is the databases of the wire a gate names (every row on it, by the adapter-aware
// destination key), and all of them for a gate no wire answers to — an import's undecidable or
// unplaced bus. Two J1939 wires may define one PGN with two layouts, so a rejoined message is
// named and decoded against ITS wire's databases (codex on #329).
// NOTE concurrency: like dbs_for_dest — app.chans is read unlocked, as every panel reads it.
fn (app &App) dbs_for_gate(gate string) []candb.Database {
	mut out := []candb.Database{}
	mut seen := map[string]bool{}
	for c in app.chans {
		if c.doip || c.iface in seen {
			continue
		}
		if transport.destination_key_for(c.adapter, c.iface) == gate {
			seen[c.iface] = true
			out << app.dbs_for(c.iface)
		}
	}
	if out.len == 0 {
		return app.dbs
	}
	return out
}

// message_for is the message a trace identity decodes against: by PGN for a rejoined
// transport-protocol message (its id is composed, and an exact `BO_` there may be another
// message), by id like every frame otherwise; over `dbs`.
fn (app &App) message_for(id u32, ext bool, tp bool, dbs []candb.Database) ?candb.Message {
	if tp {
		return find_pgn_message_in(dbs, j1939.pgn(id), u8(id & 0xFF))
	}
	return app.find_message(id, ext)
}

// group_message is message_for a trace row, against the databases of the channel the row was
// filed under where that is a configured one (a live row's), and all of them for an import's.
fn (app &App) group_message(r TraceRow) ?candb.Message {
	if !r.tp {
		return app.find_message(r.id, r.ext)
	}
	// by the WIRE the row carries, never by its channel name: names are not unique, and two
	// channels of one name on two wires may define the PGN two ways (codex on #329)
	return app.message_for(r.id, r.ext, true, app.dbs_for_gate(r.wire))
}

// j1939_narrate_locked puts one fault in the Log, within the budget. Caller holds app.mu.
fn (mut app App) j1939_narrate_locked(mut obs J1939Obs, ch string, fl j1939.Fault) {
	if fl.kind == .orphan {
		obs.orphans++
		if obs.orphans == 1 {
			app.log_append_locked('${ch}: J1939 ${fl.str()} — further orphan data frames on this wire are not narrated')
		}
		return
	}
	if obs.said >= j1939_fault_budget {
		return
	}
	obs.said++
	app.log_append_locked('${ch}: J1939 ${fl.str()}')
	if obs.said == j1939_fault_budget {
		app.log_append_locked('${ch}: J1939 ${j1939_fault_budget} transport-protocol faults narrated; further ones on this wire are not')
	}
}
