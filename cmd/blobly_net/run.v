module main

import os
import sync
import time
import project
import transport
import wiretap
import candb
import sim
import script
import doip

// open_transport opens `iface`, appending the vendor bitrate (`@<rate>`) for pcan/kvaser
// buses so the driver uses the configured rate. The logical KEY stays the raw iface —
// tx_buses, sender targets and channels all key on it consistently — and only the physical
// open carries the suffix. Non-vendor buses (socketcan/vcan configure bitrate via `ip link`;
// inproc/udp have none) open unchanged.
// Untapped: the only caller is the monitor loop, which never emits. Everything that DOES emit
// goes through open_tap so the trace can say whose frame it is.
fn (app &App) open_transport(iface string) !transport.Bus {
	return transport.open(app.bitrate_iface(iface))
}

// bitrate_iface returns `iface` with the vendor bitrate suffix (`@<rate>`) for a pcan/kvaser
// channel configured at a non-default rate, else `iface` unchanged. Used wherever a channel's
// physical bus is opened — transport.open (via open_transport) AND isotp.open_software (the
// diagnostics ISO-TP paths) — so UDS reaches the vendor driver at the configured bitrate too.
// bitrate_iface finds the channel owning this interface and applies its configured rate.
// The per-channel rule lives in project.Channel.iface_with_bitrate, shared with the runner.
// for_open is this channel as the project model sees it, for the questions about HOW A BUS IS
// OPENED that project.Channel answers — today the bitrate suffix and the listen-only mode.
//
// In ONE place, because the fields are copied by hand: Chan mirrors project.Channel rather than
// containing one, so a call site that rebuilds it inline silently drops whatever it forgets.
// This one forgot listen_only, and every Vector channel a project had marked listen-only opened
// able to acknowledge — the promise that backend exists to keep, lost between two structs with
// the same field names. Anything added here is added once.
// EVERY FIELD iface_with_bitrate READS, which is the contract this projection has to keep and
// the one it silently broke. It exists to hand that function a Channel; a field it composes the
// address from and this does not copy becomes a DEFAULT — and `fd` defaults to false, so a
// CAN-FD row was projected into a classic one and opened `vector:<n>@<rate>` with no data phase.
// Every FD frame was then refused by VectorBus.send, on the GUI path only, because the headless
// runner passes real project rows and never comes through here (codex #181 r1).
// rejected_edit reports why this channel's editor fields would not commit, or none. By NAME,
// because that is what a CfgInvalid entry and a runtime row have in common — the entry is built
// from the project model and the Buses panel acts on the runtime one.
fn (app &App) rejected_edit(name string) ?string {
	for bad in app.cfg_invalid {
		if bad.name == name {
			return bad.why
		}
	}
	return none
}

fn (c Chan) for_open() project.Channel {
	return project.Channel{
		iface:        c.iface
		adapter:      c.adapter
		bitrate:      c.bitrate
		fd:           c.fd
		data_bitrate: c.data_bitrate
		listen_only:  c.listen_only
	}
}

// dbs_for_dest merges the databases of EVERY channel row on this wire. The verifier sets are
// grouped by destination, so resolving one against a single row's DBCs left a verifier that came
// from the sibling alias unable to adopt a name or a layout from its own database.
fn (app &App) dbs_for_dest(iface string) []candb.Database {
	want := transport.destination_key(iface)
	mut out := []candb.Database{}
	mut seen := map[string]bool{}
	for c in app.chans {
		if transport.destination_key(c.iface) != want || c.iface in seen {
			continue
		}
		seen[c.iface] = true
		out << app.dbs_for(c.iface)
	}
	if out.len == 0 {
		return app.dbs_for(iface)
	}
	return out
}

// dest_is_read_locked reports whether ANY enabled row on this wire has its monitor open. Caller
// holds app.mu.
//
// The distinction exists because one reader serves a destination: `running` is a property of the
// row that opened the port, while "is this bus being watched" is a property of the wire, and
// every caller that was asking the first meant the second.
// dest_left_the_run_locked reports a destination whose rows are ALL disabled, having existed in
// this project — which is what rx_loop does to a wire whose adapter failed. A destination with no
// rows at all (an anonymous tap, a generator's own target) has not left anything. Caller holds
// app.mu.
fn (app &App) dest_left_the_run_locked(iface string) bool {
	want := transport.destination_key(iface)
	mut seen := false
	for c in app.chans {
		if transport.destination_key(c.iface) != want {
			continue
		}
		seen = true
		if c.enabled {
			return false
		}
	}
	return seen
}

fn (app &App) dest_is_read_locked(iface string) bool {
	want := transport.destination_key(iface)
	for c in app.chans {
		if c.enabled && c.running && transport.destination_key(c.iface) == want {
			return true
		}
	}
	return false
}

// runtime_rows is app.chans in the shape modules/project's shared policies take. Extracted
// because there are two of them now -- the destination conflicts below and the listen-only wire
// list -- and both must see the SAME rows: the runtime set, which a live enable/disable moves
// without touching the file.
fn (app &App) runtime_rows() []project.Channel {
	mut rows := []project.Channel{}
	for c in app.chans {
		rows << project.Channel{
			name:    c.name
			adapter: c.adapter
			iface:   c.iface
			typ:     c.typ
			bitrate: c.bitrate
			// THE SAME OMISSION AS for_open's, with a different consequence: these rows are what
			// destination_conflicts and fd_capability_warnings are asked about, so a dropped `fd`
			// does not merely open the wrong thing — it makes both checks answer as though no row
			// in the run were CAN-FD at all. A wire asked to be classic AND FD passed, and the
			// warning about an FD row on a backend that refuses FD could never fire in the GUI.
			fd:           c.fd
			data_bitrate: c.data_bitrate
			listen_only:  c.listen_only
			enabled:      c.enabled
		}
	}
	return rows
}

// push_listen_only_locked republishes which wires refuse to transmit. Called wherever the runtime
// channel set changes -- a rebuild, and every live enable/disable -- because the marks are
// consulted per send, so a stale list is a wire transmitting that was ticked silent.
//
// _locked: it reads app.chans, so the caller holds app.mu -- and must, or a republish could
// interleave with the mutation it is meant to describe. EVERY path that writes chans[].enabled
// calls it: the Buses panel toggle, the stopped Replay tick (config.v) and rx_loop retiring a
// dead destination (workers.v). It was three of four, and the one it missed could leave a script
// that outlived Stop transmitting on a wire the operator had ticked silent (codex #164 r2).
fn (app &App) push_listen_only_locked() {
	project.apply_listen_only(app.runtime_rows())
}

// destination_conflict asks project.destination_conflicts about the rows as they stand.
//
// ONE POLICY, and this is its third home: the GUI had its own mode check and its own rate check,
// the headless runner had neither, and when the shared rule was tightened — a mode disagreement
// is invalid whether or not a row LOOKS like a transmitter, because Quick Send, the shell, a
// script and the diagnostic panel can all make one talk — the GUI kept the old reading and the
// two front ends disagreed about the same project again. There is nothing here left to drift.
fn (app &App) destination_conflict() ?string {
	problems := project.destination_conflicts(app.runtime_rows())
	if problems.len == 0 {
		return none
	}
	return problems[0]
}

fn (app &App) bitrate_iface(iface string) string {
	// SILENCE WINS across every channel on this wire, not just the first one listed. Two channel
	// entries can share one interface, and this returned whichever came first — so a bus with
	// one listen-only entry and one ordinary entry opened according to list order, and a bench
	// that had asked to stay quiet could acknowledge because a sibling row did not. The
	// transceiver has one mode; of the two answers only one is safe on a live bus.
	// BY DESTINATION, not by spelling. `vector:1` and `vector:ch1` are one wire and one
	// transceiver; comparing the strings let a listen-only row and an ordinary row spelled
	// differently miss each other entirely, which is the same substitution of a lookup for an
	// identity this file has made before.
	want := transport.destination_key(iface)
	// ENABLED ROWS DECIDE. A disabled alias — `vector:ch1` at 250k, switched off, beside an
	// enabled `vector:1` at 500k — used to win this scan and set the rate for a channel it is
	// not part of, while the conflict check at Start skips disabled rows and never noticed the
	// disagreement. A row that is not in the run has no say in how the run opens its wire; one
	// is consulted only if nothing enabled matches at all.
	mut found := false
	mut chosen := Chan{}
	for want_enabled in [true, false] {
		if found {
			break
		}
		for c in app.chans {
			if c.enabled != want_enabled {
				continue
			}
			if transport.destination_key(c.iface) != want {
				continue
			}
			if !found {
				found = true
				chosen = c
			} else if c.listen_only && !chosen.listen_only {
				chosen = c
			}
		}
	}
	if !found {
		return iface
	}
	return chosen.for_open().iface_with_bitrate()
}

// start opens every enabled, monitorable channel on its own RX thread.
fn (mut app App) start() {
	if app.running {
		return
	}
	// flush any unsaved editor edits into the model + runtime view first, so the measurement
	// attaches to exactly what the Configuration editor shows (not stale buffered values).
	if app.dirty {
		app.apply_edits()
	}
	// AN EDITOR FIELD THAT WOULD NOT COMMIT STOPS THE RUN. apply_edits has just folded the buffers
	// into the model, and a field it could not parse left its PREVIOUS value standing — which is
	// the right thing to do with a typo mid-edit and the wrong thing to run on, because the value
	// the channel would open with is then one the editor no longer shows anywhere. Refusing here
	// is what makes keeping the old value safe (codex #181 r5).
	// ENABLED ROWS ONLY. A disabled channel is never opened, so a field it could not commit is not
	// a reason to refuse the run — blocking on one stopped every other bus until an unused row was
	// corrected. Save still checks the whole project, because a save writes all of it (#183 r2),
	// and the Buses panel refuses to ENABLE such a row mid-run, which is the door this exemption
	// would otherwise leave open (#183 r3).
	blocking := app.cfg_invalid.filter(it.enabled).map('${it.name}: ${it.why}')
	if blocking.len > 0 {
		app.notify('not starting — ${blocking.join('; ')} (correct it in Configuration ▸ Buses, or clear the field)')
		app.show_config = true
		return
	}
	// ONE WIRE, ONE RATE. Two enabled rows on the same destination that disagree about the
	// bitrate are a contradiction the backend cannot see: bitrate_iface picks one of them and
	// hands every monitor and transmit open the same string, so the Vector layer's own
	// "already open at a different bitrate" refusal never fires and the bus quietly runs at
	// whichever row was listed first. Caught here, before anything is opened.
	// A WIRE FORCED SILENT CANNOT CARRY A REPLAY. bitrate_iface opens every port on a
	// destination in listen-only mode as soon as ONE row asks for it — the transceiver has a
	// single mode and silence is the safe reading — but a replay row with its own flag clear
	// still starts, opens that silent bus, and has every frame refused. The operator gets a
	// failed run where the honest answer is that they asked for two different things on one
	// wire. Said before anything opens.
	// One wire, one mode and one rate — the same verdict the headless runner reaches.
	if bad := app.destination_conflict() {
		// Not "one wire, one mode and one rate" any more: #167 added a third kind this check
		// reports — two application channels on one physical channel — and each problem states
		// itself. A summary that lists two of three is the kind of claim that goes stale.
		app.notify('${bad} — not starting')
		return
	}
	// SAID ONCE, HERE, before anything opens — issue #170. An FD row on a backend that refuses FD
	// otherwise announces itself only as a rising `failed` count while traffic flows, which on a
	// part-classic recording reads as a successful measurement with some of its traffic missing.
	// A warning rather than a refusal: the classic half of that run is real.
	for w in project.fd_capability_warnings(app.runtime_rows()) {
		app.notify(w)
	}
	if app.cfg_text_dirty {
		// Text edits are NOT folded in automatically: the file is the authority for everything
		// the structured editor cannot express, and guessing that a half-typed YAML buffer
		// should become the running configuration is the wrong default. Say so instead.
		app.notify('note: the Configuration ▸ File tab has unsaved text — it is not part of this run')
	}
	// unsaved DBC-editor edits exist only in the app.dbs union — sims and the
	// per-channel generator databases still hold the on-disk definitions, so a
	// measurement would encode with one schema and decode with another.
	// (Ghost entries for paths a project swap detached are pruned first —
	// the panel may be closed, and a ghost would wedge Start forever.)
	for pth, _ in app.dbc_ed.dirty.clone() {
		if app.dbs_paths.index(pth) < 0 {
			app.dbc_ed.dirty.delete(pth)
			app.notify('unsaved DBC edits for detached ${os.file_name(pth)} were discarded')
		}
	}
	// An edit still in the field is not in the dirty map yet, so it would slip past the check
	// below AND miss the measurement's schema. The click that starts the run is also the click
	// that ends the edit, and the toolbar is drawn first — so resolve it here.
	app.resolve_pending_bit_edit()
	for _, d in app.dbc_ed.dirty {
		if d {
			app.notify('DBC editor has unsaved edits — Save or Revert them before starting')
			return
		}
	}
	// Pending echoes belong to the run that is ending: an emission from just before the last
	// Stop would otherwise sit at the front of this run's ring, where an identical healthy frame
	// claims it and the new run's own record then expires as never sent. Done HERE, not in
	// stop(), because stop() runs while the emitters are still winding down — a worker mid
	// -iteration can append after the reset and put the stale record back. Nothing of ours is
	// emitting yet at this point. (A trace Clear is different: same run, so those records stay.)
	//
	// Every SEND LOCK first, then app.mu. A worker from the previous run can be between its
	// note_emit and its physical send — it holds the interface's send lock across exactly that
	// interval — and resetting in the gap removes its record moments before the frame goes out,
	// so the echo comes back with nothing to match and is filed as the device under test's.
	// Taking each send lock waits for those to finish; taking them BEFORE app.mu keeps the same
	// order the emitters use (send lock, then app.mu), so the two cannot deadlock.
	// tx_map_mu is held ACROSS the whole reset, not just the snapshot. A script from the previous
	// run is not cancelled by Stop, and its BusOpener can lazily open a tap for an interface
	// nobody used before — creating a send lock this drain never took, so that emitter could
	// note, be descheduled, and physically send after the ring was cleared. Holding the map lock
	// makes a new tap wait instead. Order is map lock, send locks, app.mu, the same order an
	// emitter acquires them in (open, then send, then note), so the two cannot deadlock.
	app.tx_map_mu.lock()
	mut held := []&sync.Mutex{}
	for _, m in app.tx_mutexes {
		held << m
	}
	for m in held {
		m.lock()
	}
	app.mu.lock()
	app.taps = wiretap.Ring{}
	// The consumer counters belong to ONE run. Cleared here, with the generation, under the same
	// lock: carried across a restart they would count a previous run's arrivals towards this
	// run's gate, which is the readiness check passing before anything is actually listening.
	app.consumers_want = map[string]int{}
	app.consumers_ready = map[string]int{}
	app.consumers_failed = map[string]int{}
	// The generation moves WITH the ring, under one lock. Advancing it afterwards left a window
	// where a stale rx_loop returning from recv passed both of its checks and processed the
	// previous run's frame against the newly empty ring — as this run's bus traffic.
	app.run_gen++
	start_gen := app.run_gen // the run every consumer spawned below belongs to
	// The view transition rides the SAME lock, AFTER the generation bump. A fresh measurement
	// supersedes any recording view (the chip comes down; the pause load_recording set is
	// lifted) — but unpausing before the bump left a window where a stale rx_loop waking from
	// recv passed the old-generation checks and dropped its frame into the freshly unpaused
	// trace. After every validation return, too: a refused Start must leave the imported REP
	// rows wearing the label that explains them (codex #128 r1, r4).
	app.viewing_rec = ''
	app.paused = false
	// And the idx base: a fresh measurement numbers from 0. Without this, Start after a trimmed
	// 600k-frame import numbered the first live frame ~600000 — the documented phantom-loss
	// symptom trace_run_base exists to prevent, reintroduced through the import's seq advance
	// (codex #130 pre-review). Rows already in the ring keep their frozen idx.
	app.trace_run_base = app.trace_seq
	app.mu.unlock()
	for m in held {
		m.unlock()
	}
	app.tx_map_mu.unlock()
	// The file picker is a stopped-world affordance: every project-mutating target (dbc,
	// manifest, replaysrc) is offered from surfaces that gate on running at DRAW time, so a
	// picker left floating across Start is the one path where a confirm lands mid-run and
	// rebuilds the runtime arrays live workers are reading (codex #133 r3, on replaysrc — but
	// the class is every target). Closed at the state change, once, instead of teaching each
	// confirm about app.running.
	app.fb_open = false
	app.running = true
	// The quiet-bus verdict measures THIS run. Carrying a previous run's first/last across a
	// Stop would have every wire reading "quiet for 4 minutes" the instant Start is pressed —
	// an alarm about the interval the operator spent not measuring.
	for ci in 0 .. app.chans.len {
		app.chans[ci].rx_last = 0
		app.chans[ci].rx_seen = 0
	}
	// Which wires already have a reader, so aliases do not each open one.
	mut monitored := map[string]bool{}
	mut anon_tap_failed := map[string]bool{}
	mut named_tap_failed := map[string]bool{}
	for ci, ch in app.chans {
		// EVERY row, before the monitorable gate: a disabled row keeping an earlier run's
		// BUS-OFF became the reader on a mid-run enable and showed it forever — a fresh
		// healthy backend reports .unknown and never overwrites (codex #143 r1)
		app.chans[ci].health = .unknown
		if !ch.monitorable() {
			continue
		}
		// running is set by rx_loop once its bus is OPEN. Setting it here made it mean "about to
		// start": the simulation emits its first cyclic frames immediately, and with inproc —
		// which broadcasts only to already-attached subscribers — those frames genuinely had no
		// listener, yet were tracked as if one existed and later marked as never sent.
		app.chans[ci].link_down = !iface_link_up(ch.adapter, ch.address)
		// the same guard the mid-run toggle uses: disabling and re-enabling while this open is
		// still pending would otherwise start a SECOND loop for one channel, and both would
		// claim against the same monitor index — one gets the echo, the other files its copy
		// under the device under test
		// ONE READER PER WIRE. Two rows spelling one destination differently each opened their
		// own RX port, and every external frame was then delivered twice — two trace rows, two
		// verifier passes over the same message, and an E2E counter check seeing each frame
		// twice in a row. The second row still transmits and is still configured; it simply does
		// not need its own pair of eyes on a bus somebody is already watching.
		rx_key := transport.destination_key(ch.iface)
		if rx_key in monitored {
			app.chans[ci].spawning = false
		} else {
			monitored[rx_key] = true
			app.chans[ci].spawning = true
			spawn rx_loop(app, ci, ch.iface, app.run_gen)
		}
		// A TX bus per CHANNEL (each generator fires on its target bus), plus one anonymous tap
		// per wire for the paths with no particular channel — Quick Send, diagnostics, shell.
		if tx_bus_key(ch.name, ch.iface) !in app.tx_buses {
			// same silence class as rx_loop's open: a tap that fails here is a channel that
			// cannot transmit, and swallowing the error left a dead Send button with no
			// explanation anywhere a Windows user can see
			if b := app.open_tap_on(ch.iface, org_tx, ch.name) {
				app.tx_buses[tx_bus_key(ch.name, ch.iface)] = b
			} else {
				// recorded in the same set the generator loop consults, or a generator on
				// this channel re-pays the ~2s vendor open and re-logs the line
				named_tap_failed[tx_bus_key(ch.name, ch.iface)] = true
				app.notify('${ch.name}: transmit tap failed to open — ${err}')
			}
		}
		// ONE line per wire, not per row: nothing lands in tx_buses on failure, so every
		// aliased row would re-attempt this shared tap and repeat the identical message —
		// one dead wire read as several failures
		anon_key := transport.destination_key(ch.iface)
		if tx_bus_key('', ch.iface) !in app.tx_buses && anon_key !in anon_tap_failed {
			if b := app.open_tap(ch.iface, org_tx) {
				app.tx_buses[tx_bus_key('', ch.iface)] = b
			} else {
				anon_tap_failed[anon_key] = true
				app.notify('${ch.iface}: shared transmit tap failed to open — ${err}')
			}
		}
		if app.send_iface == '' {
			app.send_iface = ch.iface // Send panel default = first monitor channel
		}
	}
	for ch in app.chans {
		if ch.enabled && ch.mode == 'replay' && !ch.doip {
			if ch.replay_src == '' {
				app.notify('${ch.name}: mode is replay but no recording is configured — monitoring only')
			} else if ch.listen_only {
				app.notify('${ch.name}: replay is configured but the channel is listen-only — nothing will be transmitted')
			}
		}
	}
	// a generator may target a bus whose channel isn't itself monitored — open those too
	for sr in app.senders {
		tgt := sr.target()
		// dedupe in the OUTER condition, like the named branch below: gating only the log
		// line still re-attempted the open per sender, and a vendor open can block ~2s
		// waiting for a port release — hundreds of generators on one dead target turned
		// Start into minutes of retrying an answer it already had (codex #141 r3)
		if tgt != '' && tx_bus_key('', tgt) !in app.tx_buses
			&& transport.destination_key(tgt) !in anon_tap_failed {
			// the anonymous tap FIRST: tx_on falls back to it for the paths with no owning
			// channel — Quick Send, diagnostics, shell — and a bus that is only a generator
			// target would otherwise have none, so those reported "no open bus for …".
			if b := app.open_tap(tgt, org_tx) {
				app.tx_buses[tx_bus_key('', tgt)] = b
			} else {
				// a generator whose only bus fails to open is a silent dead generator —
				// the same class as the channel taps above, one loop down
				anon_tap_failed[transport.destination_key(tgt)] = true
				app.notify('generator target ${tgt}: transmit tap failed to open — ${err}')
			}
		}
		if tgt != '' && tx_bus_key(sr.chan, tgt) !in app.tx_buses
			&& tx_bus_key(sr.chan, tgt) !in named_tap_failed {
			if b := app.open_tap_on(tgt, org_tx, sr.chan) {
				app.tx_buses[tx_bus_key(sr.chan, tgt)] = b
			} else {
				named_tap_failed[tx_bus_key(sr.chan, tgt)] = true
				app.notify('${sr.chan}: generator transmit tap failed to open — ${err}')
			}
		}
	}
	// spawn the in-process simulation workloads (driver-free sim ECUs + a UDS server)
	for sc in app.sims {
		// DoIP carries diagnostics, not frames. sim_loop would call transport.open('doip:…'),
		// which on Linux falls through to SocketCAN, logs a failure and exits the thread — the
		// no-hardware demo trying to open its Ethernet endpoint as a CAN interface.
		if sc.pch.is_doip() {
			continue
		}
		if sc.nodes.len > 0 {
			consumer_expected(mut app, sc.iface, start_gen)
			spawn sim_loop(app, sc, start_gen) // a verify-only channel has nothing to transmit
		}
	}
	// Diagnostics are per BUS, decided ONCE. Two channel entries may share an interface, and
	// resolving them per entry produced a duplicate default responder on the second pass while
	// the panel independently re-resolved and listed targets startup had rejected. The plan is
	// computed here, spawned from here, and stored for the panel to read — one answer to "what
	// is running on this wire".
	app.diag_plan = []
	mut seeded := []string{}
	for sc in app.sims {
		for w in sim.validate_verify(sc.db, sc.verify) {
			app.notify('${sc.iface}: ${w}')
		}
		// DoIP is hosted from the project, not from here — see start_doip_hosts().
		if sc.pch.is_doip() {
			continue
		}
		if sc.nodes.len == 0 {
			// A verify-only channel WATCHES a real bus. Starting the built-in 0x7E0/0x7E8
			// server on it would put our diagnostic responses on the wire beside the ECU under
			// test's — a collision on the bench this configuration exists to observe.
			continue
		}
		// ONCE PER WIRE, and a wire is a destination rather than a spelling. Keyed on the raw
		// interface, `vector:1` and `vector:ch1` seeded independently — two built-in responders
		// answering on 0x7E0/0x7E8 at once when neither row named its own addresses, which is a
		// bus with two ECUs claiming one identity. Fifth place this substitution has turned up.
		sc_key := transport.destination_key(sc.iface)
		if sc_key in seeded {
			continue
		}
		seeded << sc_key
		mut peers := []project.NodeCfg{}
		// Which CHANNEL each node came from, BY POSITION. Diagnostics are seeded once per bus,
		// but two entries can share that bus and sim_key() puts the channel in the key, so a
		// server keyed on the wrong entry's channel reads a key the panel never writes. Keyed
		// by node NAME this went wrong again: names are not unique across a bus, so two "SUT"s
		// collapsed onto one owner. UdsNode.src indexes back into `peers`, which is exact.
		mut owners := []project.Channel{}
		for other in app.sims {
			// A DoIP entry is here only so the Simulation panel can show its ECU. Its nodes are
			// not CAN peers: a disabled `type: doip` channel with no `interface:` inherits
			// vcan0, and copied rx/tx on its node would then start a CAN responder for a
			// channel that is switched off.
			if other.pch.is_doip() {
				continue
			}
			if transport.destination_key(other.iface) == sc_key {
				peers << other.nodes
				for _ in other.nodes {
					owners << other.pch
				}
			}
		}
		for w in sim.validate_uds(peers) {
			app.notify(w)
		}
		mut diag_nodes := sim.uds_nodes(peers)
		if diag_nodes.len == 0 {
			consumer_expected(mut app, sc.iface, start_gen)
			spawn diag_server_loop(app, sc.iface, sc.pch.name, start_gen) // the built-in default for this bus
			app.diag_plan << DiagTarget{
				key:   diag_key_can(sc.iface, diag_tx_id, diag_rx_id)
				label: 'default on ${sc.iface}  (0x${diag_tx_id:X}/0x${diag_rx_id:X})'
				iface: sc.iface
				chan:  sc.pch.name
				rx:    diag_tx_id
				tx:    diag_rx_id
			}
			continue
		}
		// Configure a per-ECU server and you own diagnostics on this bus: the default does NOT
		// also run, or the two would both answer whenever their ids overlapped.
		for mut u in diag_nodes {
			own := if u.src >= 0 && u.src < owners.len { owners[u.src] } else { sc.pch }
			consumer_expected(mut app, sc.iface, start_gen)
			spawn uds_node_loop(app, own, sc.iface, u.name, u.rx, u.tx, u.ext, u.server, start_gen)
			app.diag_plan << DiagTarget{
				key:   diag_key_can(sc.iface, u.rx, u.tx)
				label: '${u.name}  (0x${u.rx:X}/0x${u.tx:X})'
				iface: sc.iface
				chan:  own.name // this node's OWN channel, not the first one on the wire
				rx:    u.rx
				tx:    u.tx
				ext:   u.ext
			}
		}
	}
	// DoIP hosts start LAST. Their supervisors publish targets from their own threads as soon
	// as a bind succeeds — a localhost bind is fast enough to land mid-loop — and the CAN plan
	// above appends to the same array without the lock. Finishing that construction first is
	// what makes the unlocked appends safe, rather than adding a lock to every one of them.
	app.start_doip_hosts()
	spawn gen_loop(app) // cyclic senders
	// The players go LAST -- after the monitors, and after every in-process consumer has been
	// spawned. Two separate reasons, and only the first was handled before:
	//
	// the opening frames must find a READER attached, or they go out with nothing able to claim
	// their echoes and come back filed as the device under test's traffic;
	//
	// and on a bus that also hosts simulated ECUs or a diagnostic responder, they must find
	// those SUBSCRIBED. The in-process bus broadcasts only to subscribers that already exist, so
	// a stimulus or an opening request sent before they attach is not delayed, it is gone. The
	// player waits for both -- see the consumer gate in replay_group.
	//
	// Grouped by RECORDING, one worker each. Channels reading the same file share a clock, which
	// is what keeps the buses in the relationship the car had; channels reading different files
	// cannot be synchronised at all, since timestamps from two recordings are not comparable.
	app.mu.lock()
	replay_spawns := app.spawn_replay_workers_locked()
	app.mu.unlock()
	app.run_replay_spawns(replay_spawns)
}

// host_key identifies a hosted DoIP entity by its CHANNEL and interface. The supervisor uses it
// to publish, look up and tear down servers, so a collision means one channel's entity reported —
// or closed — under another's name.
fn host_key(name string, iface string) string {
	return project.compose_key(name, iface)
}

// start_doip_hosts supervises every DoIP channel that simulates an ECU — enabled or not.
//
// Driven from the PROJECT rather than app.sims, because a channel disabled when the project
// loaded is excluded from app.sims entirely: there would be no supervisor, and enabling it
// later would leave the entity permanently idle with no worker to notice.
fn (mut app App) start_doip_hosts() {
	for c in app.proj.channels {
		if !c.is_doip() {
			continue
		}
		nodes := c.all_nodes()
		for w in sim.validate_uds_doip(nodes) {
			app.notify('${c.name}: ${w}')
		}
		if nodes.len == 0 {
			// Tester-only, as the headless runner treats it: a channel that simulates no ECU
			// exists to address an EXTERNAL one. Hosting would bind the endpoint and answer
			// with stock data, so a bench would read results from an ECU nobody asked for.
			app.notify('${c.name}: DoIP tester only (no simulated entity)')
			continue
		}
		ent := sim.doip_entity(c, nodes) or {
			app.notify('${c.name}: ${err}')
			app.notify('${c.name}: DoIP entity NOT started')
			continue
		}
		if ent.extra > 0 {
			app.notify('${c.name}: ${ent.extra + 1} UDS nodes on one DoIP entity; serving "${ent.node}" (0x${c.ecu_addr:04X})')
		}
		// Which node's tick in the Simulation panel switches this entity on and off. The
		// shorthand `simulate: [SUT]` configures no `uds:` block, so doip_entity() serves the
		// built-in server and returns an empty node name — keying enablement on that alone
		// meant unticking SUT in the shipped demos did nothing at all.
		key := if ent.node != '' { ent.node } else { nodes[0].name }
		spawn doip_watch(app, c, ent, key, app.run_gen)
	}
}

// doip_publish_if_current publishes a freshly bound entity, but ONLY if this run still wants
// it — the test and the publication happen under one lock, so Stop cannot interleave between
// them and leave a listener behind its own snapshot. Returns false when the caller should close
// what it just bound.
fn (mut app App) doip_publish_if_current(pch project.Channel, ent sim.DoipEntity, srv &doip.DoipServer, gen u64, key string) bool {
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if !app.running || app.run_gen != gen {
		return false
	}
	if ci := app.chan_index_locked(pch) {
		if !app.chans[ci].enabled {
			return false
		}
	}
	if key != '' {
		if !(app.sim_enabled[sim_key(pch, key)] or { true }) {
			return false
		}
	}
	app.doip_hosts[host_key(pch.name, pch.iface)] = srv
	if ci := app.chan_index_locked(pch) {
		app.chans[ci].running = true
	}
	tgt := DiagTarget{
		key:     diag_key_doip(pch)
		label:   '${ent.node_label()} on ${pch.name}  (DoIP 0x${pch.ecu_addr:04X})'
		iface:   pch.iface
		carrier: script.carrier_of(pch)
	}
	if !app.diag_plan.any(it.key == tgt.key) {
		app.diag_plan << tgt
	}
	return true
}

// doip_is_hosted reports whether THIS application currently has the entity listening.
fn (app &App) doip_is_hosted(name string, iface string) bool {
	a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	return host_key(name, iface) in a.doip_hosts
}

// doip_host_failed reports whether THIS channel is one we are meant to host and are not.
//
// By channel identity, not by interface: an interface-wide lookup answered "simulated" for a
// TESTER-ONLY channel that merely shares an endpoint with a hosted peer — an alias using a
// different tester_address to exercise another role — so scripts lost a perfectly good channel
// that the Diagnostics panel and the headless runner both expose. Sixth defect in this change
// from an interface string standing in for a channel; see chan_index_locked.
fn (app &App) doip_host_failed(name string, iface string) bool {
	mut a := unsafe { app }
	mut simulated := false
	for c in a.proj.channels {
		if c.name == name && c.iface == iface && c.is_doip() {
			simulated = c.all_nodes().len > 0
			break
		}
	}
	if !simulated {
		return false // tester-only: nothing for us to host, so nothing can have failed
	}
	if !a.running {
		// Nothing is hosted when nothing is running. Calling that "failed" made a script run
		// before Start stall 750ms per DoIP channel and then drop every one of them, reporting
		// "unknown channel" with nothing in the Log to explain it.
		return false
	}
	// PENDING is not FAILED. A supervisor polls every 200ms, so a channel enabled live — or a
	// script started immediately after Start — can be legitimately mid-bind. Treating that as
	// failure removed the channel from the script environment PERMANENTLY, and uds.open()
	// reported it unknown while the listener appeared a moment later. Give the bind its window.
	for _ in 0 .. 15 {
		if a.doip_is_hosted(name, iface) {
			return false
		}
		time.sleep(50 * time.millisecond)
	}
	return true
}

// doip_forget deregisters an entity that is no longer listening, so nothing offers it.
// doip_forget_if_current deregisters ONLY if this run still owns the entry, checking and
// mutating under ONE lock. The previous version checked, unlocked, then called doip_forget
// which re-locked — so a Stop and Start landing in that gap let a stale supervisor delete the
// NEW run's host entry and target. A function named "_if_current" that releases the lock
// before acting is not atomic; it just looks it.
// diag_key_doip / diag_key_can name a target uniquely. Interface + address, never the label.
fn diag_key_doip(pch project.Channel) string {
	// Length-prefixed for the same reason as host_key: interface and name are free text, and a
	// key two different targets can produce sends a request to the wrong ECU.
	return 'doip|' + project.compose_key(pch.iface, pch.name, '0x${pch.ecu_addr:04X}')
}

fn diag_key_can(iface string, rx u32, tx u32) string {
	// The ids cannot contain a separator, but the interface can.
	return 'can|' + project.compose_key(iface, '0x${rx:X}/0x${tx:X}')
}

fn (mut app App) doip_forget_if_current(pch project.Channel, ent sim.DoipEntity, gen u64) {
	app.mu.lock()
	if app.running && app.run_gen == gen {
		app.forget_locked(pch, ent)
	}
	app.mu.unlock()
}

// forget_locked is the mutation itself. Caller holds app.mu.
fn (mut app App) forget_locked(pch project.Channel, ent sim.DoipEntity) {
	app.doip_hosts.delete(host_key(pch.name, pch.iface))
	if ci := app.chan_index_locked(pch) {
		app.chans[ci].running = false
	}
	// By the target's OWN label, not by endpoint. Two simulated channels can share an endpoint
	// and ECU address — two shorthand channels on the defaults — and exactly one of them binds.
	// An endpoint predicate then let the FAILING supervisor delete the successful channel's
	// target while its server stayed live: the panel loses an entity that is answering.
	mine := diag_key_doip(pch)
	app.diag_plan = app.diag_plan.filter(it.key != mine)
}

// doip_bind opens one entity and links it to its handler. The handler must exist before
// new_server() and the server before the handler can reach it, so the link is made after.
fn (mut app App) doip_bind(cfg doip.ServerCfg, host string, port int, mut hst sim.DoipHost) !&doip.DoipServer {
	handler := fn [mut hst] (req []u8) []u8 {
		return hst.handle(req)
	}
	mut s := doip.new_server(cfg, handler)
	hst.entity = s
	// The REAL error. Flattening it to "someone else owns it" sent people looking for a port
	// conflict when the host was not a local address, the family was unavailable, or the
	// address was malformed — none of which clear by waiting.
	s.listen(host, port)!
	return s
}

// chan_index_locked finds the runtime channel a project channel refers to.
//
// Identity is name AND interface. The interface string alone is NOT an identity — `type: doip`
// with no `interface:` keeps the CAN default `vcan0`, so two unrelated channels can share it —
// and substituting one for the other produced four separate defects in this change. One
// definition, so there is one place left to get it wrong. Caller holds app.mu.
fn (app &App) chan_index_locked(pch project.Channel) ?int {
	for ci in 0 .. app.chans.len {
		if app.chans[ci].name == pch.name && app.chans[ci].iface == pch.iface {
			return ci
		}
	}
	return none
}

// doip_should_host reports whether this entity should be listening right now: its channel
// ticked in Buses AND its ECU ticked in Simulation.
// chan_enabled reports a channel's LIVE tick from the Buses panel.
fn (app &App) chan_enabled(pch project.Channel) bool {
	a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if ci := a.chan_index_locked(pch) {
		return a.chans[ci].enabled
	}
	return pch.enabled // not started yet: the project's own value is all there is
}

fn (app &App) doip_should_host(pch project.Channel, key string) bool {
	a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if ci := a.chan_index_locked(pch) {
		if !a.chans[ci].enabled {
			return false
		}
	}
	if key != '' {
		return a.sim_enabled[sim_key(pch, key)] or { true }
	}
	return true
}

// sim_key names one simulated ECU. The interface alone is not an identity — a CAN channel and a
// `type: doip` channel can resolve to the same string and simulate the same node name, and the
// shared `<iface>:<node>` entry then made unticking one close the other. Seventh defect in this
// change from that substitution.
fn sim_key(pch project.Channel, node string) string {
	return '${pch.name}|${pch.iface}:${node}'
}

// stop signals the RX threads to exit (they re-check on the recv timeout) and tears down the
// hosted DoIP entities, whose sockets must be released before another Start can bind them.
fn (mut app App) stop() {
	// The run flag FIRST. A supervisor that is unbound and has just decided to rebind would
	// otherwise insert a fresh listener AFTER the snapshot below, escape this close, and
	// survive into the next Start — whose own bind would then fail against it.
	app.running = false
	// Then close: the serve loops block in accept for up to 200ms, and close() interrupts them
	// so the port is released now rather than whenever the last worker notices.
	// Snapshot under the lock the supervisor uses: it inserts and deletes entries as channels
	// are toggled, so iterating this map unlocked can race a concurrent write — and a listener
	// rebound between the read and the reset would escape the close entirely.
	app.mu.lock()
	mut hosted := []&doip.DoipServer{}
	for _, ds in app.doip_hosts {
		hosted << ds
	}
	app.doip_hosts = map[string]&doip.DoipServer{}
	app.mu.unlock()
	for mut ds in hosted {
		ds.close()
	}
	for ci in 0 .. app.chans.len {
		app.chans[ci].running = false
	}
	for _, mut b in app.tx_buses {
		b.close()
	}
	app.tx_buses = map[string]transport.Bus{}
	app.send_iface = ''
}
