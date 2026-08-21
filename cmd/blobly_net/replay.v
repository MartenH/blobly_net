module main

import os
import time
import transport
import candb
import sim
import canlog
import mf4
import player

// ReplayState is one recording's lifecycle within a run.
// Who holds a destination. The token matters as much as the source: on an immediate Stop then
// Start, the replacement worker for the SAME recording can claim the wire before the outgoing
// one reaches its cleanup, and a release matched on the source alone would then delete the
// replacement's reservation and leave the wire looking free. Same reason replay_state carries
// one — a reservation belongs to a particular run of a particular recording, not to a filename.
// ReplayCtl is a replay group's face to the Replay panel: status the worker publishes each
// tick, and commands the panel leaves for the worker to apply on its next wake (<= 50ms).
// Everything under app.mu; the Player stays on the worker's stack, so the panel can never
// race the playback math — it talks to the worker, and only the worker talks to the player.
@[heap]
struct ReplayCtl {
mut:
	// status: worker -> panel
	src       string
	buses_lbl string // the group's bus names, joined — the same label its notifications use
	loading   bool   // registered but still decoding the recording / waiting for its wires
	dur_s     f64
	state     player.State
	pos_s     f64
	speed     f64
	cfg_speed f64 // the PROJECT's configured rate — panel changes are transport-transient
	repeat    bool
	loops     int
	sent      u64
	failed    u64
	// commands: panel -> worker (applied and cleared by the worker). want_state is a TARGET,
	// not a toggle: two clicks inside one worker tick collapsed a toggle into a no-op while
	// the button still showed the pre-click label (the state publishes up to 50ms late).
	want_state player.State = .stopped // .stopped = no request; .playing / .paused otherwise
	want_speed f64 // > 0: change rate, position preserved
	want_seek  f64 = -1.0 // >= 0: jump to this recording position (seconds)
}

struct ReplayOwner {
	src   string
	token u64
}

struct ReplayState {
	gen  u64  // the run it belongs to; anything older is stale
	live bool // a worker is running
	done bool // it played to the end and should not restart on its own
	// Which worker owns this entry. An interrupted group writes live:false on its way out, and a
	// channel re-enabled in that instant starts a REPLACEMENT for the same source and the same
	// run — after which the old worker's cleanup would clear the newcomer's state and leave a
	// live worker that nothing knows about. Only the token holder may write.
	token u64
}

// load_recording replaces the trace with a candump .log or ASAM .mf4 file.
fn (mut app App) load_recording(path string) {
	// Whether these labels are the FILE's or this project's. An MF4 names its buses by the
	// recording's own BusChannel numbering; a candump line names an interface the user actually
	// configured. That distinction decides whether the alias table applies at all — see below.
	from_mf4 := path.to_lower().ends_with('.mf4')
	entries := if from_mf4 {
		mf4.load_file(path) or {
			app.notify('mf4 ${path}: ${err}')
			return
		}
	} else {
		canlog.load_file(path) or {
			app.notify('log ${path}: ${err}')
			return
		}
	}
	t0 := if entries.len > 0 { entries[0].t_s } else { 0.0 }
	// Verify while building the rows. Entries arrive in time order and the project already
	// supplies the protection configuration, so a recording can be checked exactly as live
	// traffic is — otherwise a violation visible during a run vanished the moment it was saved
	// and reopened, and a capture taken elsewhere could not be checked at all.
	// A recording stores whatever label the writer used — the channel's display NAME for our
	// own live captures, and a bare 'can' from an MF4 import — never the project's interface
	// string. Keying the sets by iface alone therefore matched nothing and every imported frame
	// came back with an empty verdict, which is what the previous attempt at this did.
	mut verifiers := map[string]sim.VerifySet{}
	mut alias := map[string]string{} // recorded label -> destination key
	// destination key -> EVERY raw interface on it. Remembering only the first lost the later
	// alias's databases, so a verifier that came from `vector:ch1` was resolved against
	// `vector:1`'s DBCs alone and could not adopt a name or a J1939 PGN layout from its own.
	mut dbc_ifaces := map[string][]string{}
	for sc in app.sims {
		// A DoIP entry carries no frames and no `verify:`, so it must not create a verifier set
		// for its interface: an empty one made `verifiers.len == 1` false and an unlabelled MF4
		// import stopped resolving to the single simulated bus.
		if sc.pch.is_doip() {
			continue
		}
		// Per ENTRY, from the CURRENTLY LOADED databases. Two things have to hold at once: an
		// entry must see only its own DBCs (an interface-wide merge let a same-named message on
		// a neighbour's database win, leaving this entry's id unchecked after reopening a
		// capture that was checked live), and unsaved editor changes must be reflected, since
		// app.dbs already drives naming and decoding everywhere else in the UI.
		live := merge_dbs_from(app.loaded_dbs_for(sc.db_paths))
		// KEYED ON THE DESTINATION. Two rows spelling one wire differently kept separate
		// verifier sets, so an imported recording was checked against whichever row's rules
		// happened to be found — and rules split across the aliases silently stopped applying.
		sc_dest := transport.destination_key_for(sc.pch.adapter, sc.iface)
		mut vs := verifiers[sc_dest] or { sim.VerifySet{} }
		// `verify:` ONLY — the ECU under test's messages, never our own.
		//
		// A candump log carries no direction, so a recording made while we were transmitting
		// replays our TX frames as if received. Checking a message the simulation itself sends
		// then reports false failures — worse when loopback puts the same frame in twice and
		// one counter value is checked as though it arrived twice. What the bench is asking
		// about is the other side's protection, and that is exactly what `verify:` describes.
		vs.merge_into(sim.verifiers_for(live, [], sc.verify)) // conflicts already reported at start

		verifiers[sc_dest] = vs
		mut known := dbc_ifaces[sc_dest] or { []string{} }
		if sc.iface !in known {
			known << sc.iface
		}
		dbc_ifaces[sc_dest] = known
		alias[sc.iface] = sc_dest
		alias[sc_dest] = sc_dest
		for c in app.chans {
			if c.iface == sc.iface {
				alias[c.name] = sc_dest
			}
		}
	}
	// A single simulated bus is unambiguous, so an unrecognised label (an MF4's `mf4:bus0`)
	// resolves to it rather than going unchecked. With several, a label we cannot place is left
	// alone — guessing which bus a frame came from would attach verdicts to the wrong sender.
	// An imported label is deliberately namespaced (`mf4:`) so it can never match a project
	// interface by accident: BusChannel is the file's numbering, not this project's.
	only := if verifiers.len == 1 { verifiers.keys()[0] } else { '' }
	// For an MF4 the fallback needs a stronger question: `verifiers` counts buses that HAVE
	// simulation or verify: entries, not buses the project has. A project with three CAN buses
	// where only one is simulated would otherwise apply that one's rules to every `mf4:busN` —
	// and the distinct labels are the file telling us the recording spans several buses. So the
	// import may only fall back when the PROJECT itself has a single CAN bus to fall back to.
	// COUNTED BY DESTINATION, like the verifier map above it. Two spellings of one wire counted
	// as two buses, so a project with `vector:1` and `vector:ch1` looked multi-bus to the
	// single-bus fallback and an imported one-bus recording was verified against nothing.
	mut can_buses := map[string]bool{}
	for c in app.chans {
		if !c.doip {
			can_buses[transport.destination_key_for(c.adapter, c.iface)] = true
		}
	}
	// BOTH sides must be unambiguous. A one-bus project importing a TWO-bus recording is still a
	// guess: routing every mf4:busN through one stateful VerifySet interleaves counters from
	// different source buses, which is a fabricated verdict either way it lands. The recording's
	// own distinct labels are the file saying it spans several buses — believe it.
	mut rec_buses := map[string]bool{}
	for e in entries {
		rec_buses[e.iface] = true
	}
	mf4_only := if can_buses.len == 1 && rec_buses.len == 1 { only } else { '' }
	first_row := if entries.len > trace_cap { entries.len - trace_cap } else { 0 }
	app.mu.lock()
	app.reset_trace_locked()
	// Claim the view HERE, inside the same locked region that reset it, and PAUSE the capture:
	// a label alone let live frames keep filling the ring under the file's rows — trimming them
	// away within seconds on a busy bus while the chip still named the file — and let gcount sum
	// file and live counts into one meaningless total. Paused, the ring holds exactly the file;
	// 'resume live' (or Start) hands the view back.
	app.viewing_rec = os.base(path)
	app.paused = true
	// A TRIMMED import keeps the FILE's frame numbers. Only the last trace_cap entries are
	// pushed (first_row below — one computation, used for both the skip and this), and without
	// this the idx column labelled source frame 598000 as 0 — a number that matches nothing in
	// the file the toast just named, and that changes if the same file is reopened after more
	// rows were captured. Advancing seq AND base together keeps the positional invariant
	// (trace[i].seq == trace_base + i) intact; run_base stays at the reset point, so
	// idx = seq - run_base = the entry's index in the file.
	app.trace_seq += u64(first_row)
	app.trace_base += u64(first_row)
	// Only the LAST trace_cap rows can survive the ring, so only those are built. A 600k-frame
	// capture otherwise paid for 600k DBC name lookups — each a linear scan of every message in
	// every loaded database — and 600k payload clones, to display two thousand rows. Measured on
	// one: 376 s of CPU with the UI frozen throughout.
	//
	// Verification still runs over EVERY frame: an E2E counter/CRC verdict depends on the frames
	// before it, so skipping any would invent verdicts for the ones shown. Likewise the grouped
	// view's totals, which exist precisely to outlive trimming.
	for i, e in entries {
		f := e.frame
		mut viol := ''
		if !f.rtr {
			// An imported MF4 label NEVER goes through the alias table. `mf4:` makes an accidental
			// match unlikely, but a project channel may be named anything at all — including
			// `mf4:bus1` — and a convention is not a guarantee. Structurally: these labels are
			// not in this project's namespace, so the only resolution they may take is the
			// single-bus fallback, where there is nothing to get wrong.
			ifc := if from_mf4 { mf4_only } else { alias[e.iface] or { only } }
			if mut vs := verifiers[ifc] {
				// THE RAW INTERFACE for the databases. dbs_by_iface is keyed by what the
				// channel is called, and `ifc` is now a destination key — so looking the DBCs
				// up by it found none, and a verifier could no longer adopt a name or a layout
				// from the database. The map remembers one raw spelling per destination.
				mut scope := []candb.Database{}
				for raw in dbc_ifaces[ifc] or { [ifc] } {
					scope << app.dbs_for(raw)
				}
				if k := vs.resolve(scope, f.id, f.extended) {
					if mut ver := vs.by_key[k] {
						viol = ver.check(f.data).str()
						vs.by_key[k] = ver
					}
				}
				verifiers[ifc] = vs
			}
		}
		// REP, not BUS: these frames were never on this bench's wire. A candump log carries no
		// origin at all, so we cannot say whether a given line was the recorder's tester, its
		// simulation or the ECU — and claiming one would be a guess dressed as a fact.
		app.gcount[gkey_frame(org_rep, e.iface, f)]++
		if i < first_row {
			continue // trimmed before it could ever be drawn
		}
		name := app.lookup_name(f.id, f.extended)
		app.push_row_locked(TraceRow{
			t_ms:   (e.t_s - t0) * 1000.0
			ch:     e.iface
			origin: org_rep
			id:     f.id
			ext:    f.extended
			fd:     f.fd
			brs:    f.brs
			esi:    f.esi
			rtr:    f.rtr
			name:   name
			data:   f.data.clone()
			e2e:    viol
		})
	}
	app.mu.unlock()
	shown := entries.len - first_row
	if first_row > 0 {
		app.notify('loaded ${entries.len} frames from ${os.base(path)} — showing the last ${shown}')
	} else {
		app.notify('loaded ${entries.len} frames from ${os.base(path)}')
	}
}

// `gen` is the measurement run this loop belongs to. Without it, a Stop→Start inside the 200 ms
// receive timeout leaves the OLD loop running beside the new one on the same channel index: both
// see every frame, the first claims our emission for that index, and the second's copy is then
// classified as the device under test's — logged, recorded and verified as external traffic.
// replay_group plays ONE recording onto every channel configured to replay from it — on one
// clock, which is the whole point.
//
// A worker per channel would give each its own stopwatch, started whenever its thread happened
// to run, and decoding a large `.mf4` takes seconds: the skew between buses would be seconds
// too. The ECU under test gateways between these buses and polices the timing across them, so
// that skew is not a detail — it is the measurement. modules/player/multibus.v builds one
// time-sorted stream from all of them; this feeds it to one player and dispatches per channel.
//
// Channels replaying DIFFERENT files get their own group and their own clock, because timestamps
// from two recordings are not comparable — nothing would be synchronised by pretending they are.
fn replay_group(app &App, source string, cis []int, gen u64, token u64) {
	mut a := unsafe { app }
	a.mu.lock()
	mut chans := []Chan{}
	for ci in cis {
		if ci < a.chans.len {
			chans << a.chans[ci]
		}
	}
	a.mu.unlock()
	label := chans.map(it.name).join(', ')
	// The panel's window into this group, registered AT ENTRY — a large .mf4 decodes for
	// seconds, and a panel that says "no replay running" while one is starting states a
	// falsehood at the exact moment the operator is watching for it. Keyed by the spawn token
	// (the identity ReplayState already uses); the defer directly below removes it on EVERY
	// exit, including the decode-failure and readiness-timeout returns.
	mut ctl := &ReplayCtl{
		src:       os.base(source)
		buses_lbl: label
		loading:   true
		// clamped like new_player_over clamps its speed: a `speed: 0` in the file otherwise
		// becomes a dead 0x button and a "restored on Stop/Start" promise that is false —
		// Start restores the coerced 1.0, not the 0 (self-review of the Scan work)
		cfg_speed: if chans.len > 0 && chans[0].replay_speed > 0 {
			chans[0].replay_speed
		} else {
			1.0
		}
	}
	a.mu.lock()
	a.replay_ctls[token] = ctl
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.replay_ctls.delete(token)
		// the seek latch is keyed by the same token; a drag interrupted by Stop otherwise
		// leaves its entry behind for the session (tokens never recur, so it is dead weight)
		a.replay_seek.delete(token)
		a.mu.unlock()
	}

	// FIRST, before anything that can return. `live` was set by the caller before this worker
	// existed, so every exit has to clear it — and each round of review found another early
	// return that did not: a decode failure, then a readiness timeout. Installing the cleanup at
	// the top makes the question "did I remember?" impossible to get wrong, rather than one more
	// path to audit. Leaving it set meant the source could never restart within the run, even
	// once the operator fixed whatever was wrong.
	defer {
		a.mu.lock()
		// The WIRE goes back first, and outside the state check below. A replacement worker for
		// this same recording has already replaced replay_state's token by the time it is
		// waiting on us, so releasing the wire only when that token still matched meant the
		// predecessor never let go and the replacement waited out its whole timeout. What we
		// hold is decided by the claim we made, not by who owns the source now.
		for ch in chans {
			k := transport.destination_key(ch.iface)
			if o := a.replay_owner[k] {
				if o.token == token {
					a.replay_owner.delete(k)
				}
			}
		}
		st := a.replay_state[source] or { ReplayState{} }
		if st.gen == gen && st.live && st.token == token {
			a.replay_state[source] = ReplayState{
				gen:   gen
				live:  false
				token: token
			}
		}
		a.mu.unlock()
	}

	// WAIT for the in-process consumers. A simulated ECU or a diagnostic responder on a replay
	// bus subscribes to the software bus from its own thread; until it has, the broadcast reaches
	// nobody and a frame sent at timestamp zero is not delayed, it is gone.
	//
	// REFUSED on timeout, not carried on with. Treating the deadline as success is the same
	// mistake the reader gate used to make: the run then looks healthy while the opening
	// stimulus -- often the request the whole experiment is about -- was dropped before anything
	// could hear it. A consumer this slow is a bench that is not ready.
	mut subs_in := false
	mut subs_bad := false
	for waited_sub := 0; waited_sub < 2000; waited_sub += 20 {
		a.mu.lock()
		mut all_in := true
		for ch in chans {
			if a.consumers_failed[transport.destination_key(ch.iface)] > 0 {
				subs_bad = true
			}
		}
		for ch in chans {
			// The BUS, not the spelling. `inproc` and `inproc:CAN` are one software bus, so a
			// gate that compared the raw strings found nothing expected and nothing ready, let
			// itself through immediately, and put the opening frame on a bus whose simulated
			// ECU had not subscribed — the exact failure the gate was added to prevent, walked
			// past by the same substitution this file has now made twice.
			k := transport.destination_key(ch.iface)
			if a.consumers_ready[k] < a.consumers_want[k] {
				all_in = false
				break
			}
		}
		stopped_sub := !a.running || a.run_gen != gen
		a.mu.unlock()
		if stopped_sub {
			return
		}
		if subs_bad {
			a.notify('replay ${label}: a simulated node on this bus could not open it — not starting')
			return
		}
		if all_in {
			subs_in = true
			break
		}
		time.sleep(20 * time.millisecond)
	}
	if !subs_in {
		a.notify('replay ${label}: simulated nodes on this bus never attached — not starting')
		return
	}

	// WAIT for the readers. rx_loop sets `running` only once its transport is actually open, and
	// start() has merely SPAWNED them — so with a small recording, or a slow open, the first
	// frames could go out before any monitor was attached. Nothing would then claim their
	// echoes and they would come back filed as the device under test's traffic, which is the one
	// thing the origin column exists to get right. Bounded, because a bus that never opens must
	// not wedge the player forever; the send simply proceeds and its echo goes unclaimed.
	mut waited := 0
	for waited < 5000 {
		a.mu.lock()
		mut ready := true
		for ci in cis {
			if ci >= a.chans.len || !a.chans[ci].enabled {
				continue
			}
			// IS THIS WIRE BEING READ, by anybody. One reader serves a destination now, so a row
			// that shares a wire with the row holding the monitor never sets its own `running`
			// — and waiting for it would time out on a bus that is perfectly well watched.
			if !a.dest_is_read_locked(a.chans[ci].iface) {
				ready = false
				break
			}
		}
		stopped := !a.running || a.run_gen != gen
		a.mu.unlock()
		if stopped {
			return
		}
		if ready {
			break
		}
		time.sleep(20 * time.millisecond)
		waited += 20
	}
	// Falling through used to mean "transmit anyway", which is the wrong half of the trade: the
	// frames go out unheard, their echoes are unclaimed, and the trace files them as the device
	// under test's traffic. A bus that will not open is a bench that is not ready.
	mut not_up := []string{}
	a.mu.lock()
	for ci in cis {
		if ci < a.chans.len && a.chans[ci].enabled && !a.dest_is_read_locked(a.chans[ci].iface) {
			not_up << a.chans[ci].name
		}
	}
	a.mu.unlock()
	if not_up.len > 0 {
		a.notify('replay ${label}: ${not_up.join(', ')} never came up — not starting')
		return
	}

	// Decoded ONCE for the whole group, however many channels read from it.
	all, buses := load_recording_for_replay(source) or {
		a.notify('replay ${label}: ${err}')
		return
	}
	mut specs := []player.BusSpec{}
	for ch in chans {
		src_label := resolve_replay_bus(buses, ch) or {
			// The WHOLE group, not just this channel: the others would otherwise transmit a
			// partial plan, which is the same incomplete cross-bus picture as a destination that
			// failed to open — convincing, and missing a wire.
			a.notify('replay ${label}: ${ch.name}: ${err} — not starting')
			return
		}
		db := replay_db(a, ch)
		// JUDGED ACROSS THE GROUP, below. Per channel, this refused the ordinary shape of a
		// gateway recording: the SUT transmits on one of the mapped buses and is absent from the
		// other databases, which is not a mistake. The CLI has always judged it that way, so the
		// two front ends disagreed about the same project.
		specs << player.BusSpec{
			src:                 src_label
			dst:                 ch.iface
			db:                  db
			exclude:             ch.replay_exclude.clone()
			replay_unattributed: true
		}
	}
	if specs.len == 0 {
		return
	}
	// One verdict for the whole group, from the rule both front ends share.
	mut all_ex := []string{}
	mut all_dbs := []candb.Database{}
	for sp in specs {
		all_dbs << sp.db
		for n in sp.exclude {
			all_ex << n
		}
	}
	if all_ex.len > 0 {
		nowhere := player.unknown_everywhere(all_dbs, all_ex)
		if nowhere.len > 0 {
			a.notify('replay ${label}: no mapped database declares ${nowhere.join(', ')} — not starting')
			return
		}
	}
	// PER BUS as well, because the check above is deliberately group-wide and that hides
	// something worth knowing: an exclusion whose name this bus's own database does not declare
	// subtracts nothing HERE, however well it works on a sibling. Said, not refused — a node
	// that transmits on one bus of a gateway recording and not another is the ordinary shape,
	// and refusing it would reject exactly the configuration the group-wide rule exists to
	// allow. The operator gets the fact and decides; silence would let a bus nobody subtracted
	// anything from look identical to one that worked.
	for i, sp in specs {
		if sp.exclude.len == 0 {
			continue
		}
		silent := player.check_nodes(sp.db, sp.exclude)
		if silent.len > 0 {
			nm := if i < chans.len { chans[i].name } else { sp.dst }
			a.notify('replay ${nm}: ${silent.join(', ')} not declared by this channel\'s database — nothing is subtracted on ${sp.dst}')
		}
	}
	for c in player.conflicts(specs) {
		a.notify('replay: ${c}')
		return
	}
	plan := player.build_multi(all, specs)
	mut total := 0
	for b in plan.buses {
		total += b.report.kept
		if b.report.kept == 0 {
			a.notify('replay ${b.dst}: nothing to replay, ${b.report.withheld_excluded} withheld')
		} else {
			a.notify('replay ${b.dst}: ${b.report.kept} frames, ${b.report.withheld_excluded} withheld')
		}
	}
	if total == 0 {
		return
	}

	// One tap per channel: the origin marks these as ours (a recording we are transmitting, not
	// traffic the ECU produced) and the name puts them on the right row.
	mut buses_out := map[string]transport.Bus{}
	mut unopened := []string{}
	for ch in chans {
		if ch.iface in buses_out {
			continue
		}
		if b := app.open_tap_on_gen(ch.iface, org_tx_sim, ch.name, gen) {
			buses_out[ch.iface] = b
		} else {
			unopened << '${ch.name} (${ch.iface})'
		}
	}
	// REFUSED, not carried on with. The frames for a bus that never opened would be dropped by
	// the lookup in the send loop while every other bus transmitted — a rest bus missing one
	// wire entirely, at full speed, with one line in the log to say so. For a gateway under
	// test that is a worse answer than not starting.
	if unopened.len > 0 {
		for _, mut b in buses_out {
			b.close()
		}
		a.notify('replay ${label}: cannot open ${unopened.join(', ')} — not starting (the other buses would run without it)')
		return
	}
	// TAKE THE WIRE, now that everything else is ready and the next thing we do is drive it.
	//
	// LATE on purpose. Claimed at the top of the worker, the reservation covered the readiness
	// gates and the decode as well -- and decoding a million-frame capture takes seconds, so a
	// replacement for a group Stop/Started during its own startup waited on a wire held by a
	// predecessor that was not using it, gave up on a deadline, and left the run silent with
	// nothing to restart it. Held only while it is actually being driven, that window is the
	// send loop's own poll interval.
	//
	// WAITED FOR, not deadlined. The predecessor always releases -- its cleanup is deferred at
	// the top of the function, so every exit runs it -- and the only reasons never to start are
	// the two checked here: the run ended, or a later worker superseded us. A fixed timeout in
	// front of work of unbounded length is a guess about how long that work takes, and this one
	// was wrong for exactly the recordings the feature exists for.
	//
	// ALL destinations or none: two groups each holding what the other wants would wait forever.
	//
	// The list is FIXED, because the enabled set is: a channel cannot leave the group while we
	// wait for its wire. It was re-read every pass while it could, which is one more thing that
	// went away with mid-run toggling.
	mut dests := []string{}
	for ch in chans {
		k := transport.destination_key(ch.iface)
		if k !in dests {
			dests << k
		}
	}
	for {
		a.mu.lock()
		st_claim := a.replay_state[source] or { ReplayState{} }
		if !a.running || a.run_gen != gen || st_claim.token != token {
			a.mu.unlock()
			for _, b in buses_out {
				mut bb := b
				bb.close()
			}
			return
		}
		dests = []string{}
		for ci in cis {
			if ci < a.chans.len && a.chans[ci].enabled {
				k := transport.destination_key(a.chans[ci].iface)
				if k !in dests {
					dests << k
				}
			}
		}
		if dests.len == 0 {
			a.mu.unlock()
			for _, b in buses_out {
				mut bb := b
				bb.close()
			}
			return
		}
		mut free := true
		for k in dests {
			if _ := a.replay_owner[k] {
				free = false
				break
			}
		}
		if free {
			for k in dests {
				a.replay_owner[k] = ReplayOwner{
					src:   source
					token: token
				}
			}
			a.mu.unlock()
			break
		}
		a.mu.unlock()
		time.sleep(20 * time.millisecond)
	}

	defer {
		for _, mut b in buses_out {
			b.close()
		}
	}

	// ONE clock means ONE pacing. Channels sharing a recording cannot play it at different
	// speeds or with different looping — there is a single player — so silently applying the
	// first channel's settings would quietly ignore what the others asked for.
	speed := chans[0].replay_speed
	repeat := chans[0].replay_loop
	for ch in chans {
		if ch.replay_speed != speed || ch.replay_loop != repeat {
			a.notify('replay ${label}: channels sharing ${os.base(source)} disagree on speed/loop — they share one clock, so set them alike')
			return
		}
	}
	mut p := player.new_player_over(plan.entries, speed, repeat, plan.t0_s, plan.end_s)
	mut sw := time.new_stopwatch()
	mut sent := u64(0)
	mut failed := u64(0)
	mut first_err := ''
	mut announced_sent := u64(0)
	mut announced := false
	p.play(0.0)
	a.mu.lock()
	ctl.loading = false
	ctl.dur_s = p.duration_s()
	ctl.state = p.state()
	ctl.speed = p.speed
	ctl.repeat = repeat
	a.mu.unlock()
	for {
		// Re-read per DESTINATION, not just "is any channel still on": disabling one channel of
		// a group left `any` true because a sibling was enabled, and the dispatch below then
		// kept transmitting to the disabled channel's bus. A box unticked in the Buses panel has
		// to silence that wire.
		// The group's destinations were fixed when Start was pressed and cannot change while it
		// runs, so there is nothing to re-read here: the run ends, or every wire it holds keeps
		// playing. Re-reading membership each pass -- and releasing, re-taking and re-silencing
		// wires as boxes moved -- is what mid-run toggling cost, and it is gone with it.
		// ONE lock per tick: the stop check, the panel's commands out, and the previous
		// tick's status in. A separate publish acquisition ran at the RECORDING's frame rate —
		// a dense capture at 4x meant ~20k extra takes of the app-wide mutex per second, each
		// a chance to queue behind the GUI's per-frame ring clone, to feed a panel that
		// repaints ~30 times a second.
		mut now := f64(i64(sw.elapsed())) / 1e6
		a.mu.lock()
		stop := !a.running || a.run_gen != gen
		cmd_state := ctl.want_state
		cmd_speed := ctl.want_speed
		cmd_seek := ctl.want_seek
		ctl.want_state = .stopped
		ctl.want_speed = 0
		ctl.want_seek = -1.0
		ctl.state = p.state()
		ctl.pos_s = p.position_s(now)
		ctl.speed = p.speed
		ctl.loops = p.passes()
		ctl.sent = sent
		ctl.failed = failed
		a.mu.unlock()
		if stop {
			break
		}
		// Re-sampled: the publish above can queue behind the GUI's per-frame ring clone, and
		// transport math anchored to a pre-wait clock re-times every frame of this tick by
		// the wait — mutex jitter injected into the replayed cadence, which on a gateway SUT
		// is the measurement itself. The publish keeps the pre-lock sample; position display
		// off by a lock wait is invisible, an emission time is not.
		now = f64(i64(sw.elapsed())) / 1e6
		// A TARGET state, not a toggle: two clicks inside one tick must not cancel out.
		if cmd_state == .paused && p.state() == .playing {
			p.pause(now)
		} else if cmd_state == .playing && p.state() in [player.State.paused, .finished] {
			if p.state() == .finished {
				announced = false // restarting: the NEXT run-out is fresh news
			}
			p.play(now) // from .finished this restarts at 0 — the panel labels it Restart
		}
		if cmd_speed > 0 {
			// the transport math lives in the module, where its test can reach it — the
			// hand-rolled pause/set/play dance here scaled the position by new/old and
			// dumped the difference onto the wire in one burst (the review's numbers: 2x at
			// 30s of a 60s recording = 30 seconds of traffic in one batch)
			p.set_speed(cmd_speed, now)
		}
		if cmd_seek >= 0 {
			p.seek(cmd_seek, now)
		}
		for e in p.due(now) {
			// BEFORE EVERY SEND. A batch is normally a few frames, but after a stall p.due()
			// returns everything owed at once, and stop was checked before the batch — so a
			// Stop/Start during a long one left the PREDECESSOR dispatching into the new run,
			// frames the trace then files as this measurement's. Reserving the wire holds the
			// replacement back; it does not cancel the worker already inside this loop.
			//
			// Checked per frame rather than per batch of 64: the sampling interval was a guess
			// at how much stale traffic is acceptable, and the answer is none. An uncontended
			// lock costs tens of nanoseconds against a send, and the batch is short whenever
			// the cost would matter.
			a.mu.lock()
			gone := !a.running || a.run_gen != gen
			a.mu.unlock()
			if gone {
				break
			}
			mut bus := buses_out[e.iface] or { continue }
			bus.send(e.frame) or {
				// The tap refuses once the run is over, so a rejection here is usually Stop
				// arriving mid-batch rather than a bus problem. Ask, and leave quietly if so —
				// counting it would report a replay that FAILED when it was simply stopped.
				a.mu.lock()
				over := !a.running || a.run_gen != gen
				a.mu.unlock()
				if over {
					break
				}
				// The waiting for a full transmit queue happens in TapBus.send, beneath the
				// trace record — retrying here re-entered it and painted a failed row per
				// attempt. Anything that reaches this point has genuinely failed.
				failed++
				if first_err == '' {
					first_err = '${e.iface}: ${err.msg()}'
				}
				continue
			}
			sent++
		}
		// A paused OR FINISHED group idles instead of exiting. next_due_ms returns none in
		// both states, and breaking on it killed the worker the moment the panel paused it —
		// and, for a non-looping recording that ran out, deleted the row at the exact moment
		// the operator reaches for "scrub back and watch that again" (seek explicitly revives
		// a finished player to .paused; Resume from .finished restarts at 0). The row now
		// stays until the RUN ends; Stop still lands within the 50ms poll.
		if p.state() in [player.State.paused, .finished] {
			if p.state() == .finished && !announced {
				// The row staying alive must not silence the OUTCOME: it used to arrive when
				// the worker exited on finish, and deferring it to Stop turned a one-shot
				// stimulus whose every send failed into minutes of false quiet for anyone
				// watching the log rather than the panel (self-review of the idle rework).
				announced = true
				announced_sent = sent
				if failed > 0 {
					a.notify('replay ${label}: ${sent} sent, ${failed} FAILED — ${first_err}')
				} else {
					a.notify('replay ${label}: finished (${sent} frames, ${p.passes()} pass(es))')
				}
			}
			time.sleep(50 * time.millisecond)
			continue
		}
		nd := p.next_due_ms() or { break }
		mut wait := nd - f64(i64(sw.elapsed())) / 1e6
		if wait > 50 {
			wait = 50 // so a stopped measurement is noticed promptly
		}
		if wait > 0 {
			time.sleep(i64(wait * 1_000_000) * time.nanosecond)
		}
	}
	// `sent`, not p.sent(): the player counts what it handed over. An FD capture on a classic
	// interface fails every send, and reporting attempts would announce a replay that put
	// nothing on the wire.
	// Two different endings, recorded as two different states. `done` is set only when the
	// recording actually ran out: a group STOPPED early (Stop pressed, or every destination
	// disabled) may legitimately be restarted, while one that finished must not spring back to
	// life because an unrelated channel was ticked on.
	ended := p.finished()
	a.mu.lock()
	st := a.replay_state[source] or { ReplayState{} }
	// Only the owner writes: a replacement worker may already have claimed this source.
	if st.gen == gen && st.token == token {
		a.replay_state[source] = ReplayState{
			gen:   gen
			live:  false
			done:  ended
			token: token
		}
	}
	for ch in chans {
		k := transport.destination_key(ch.iface)
		if o := a.replay_owner[k] {
			if o.token == token {
				a.replay_owner.delete(k)
			}
		}
	}
	a.mu.unlock()
	if announced && ended && sent == announced_sent {
		// the run-out was already announced from the idle loop and nothing moved since —
		// repeating it at Stop would report one replay twice
	} else if failed > 0 {
		a.notify('replay ${label}: ${sent} sent, ${failed} FAILED — ${first_err}')
	} else if ended {
		a.notify('replay ${label}: finished (${sent} frames, ${p.passes()} pass(es))')
	} else {
		// NOT "finished": the recording did not run out, we were told to stop. Calling that
		// finished would let a partially transmitted capture read as a complete one.
		a.notify('replay ${label}: stopped after ${sent} frames (recording not complete)')
	}
}

// spawn_replay_workers starts ONE worker per distinct recording, covering every channel that
// replays from it. Already-running groups are not restarted: `replay_gen` records which run a
// source is playing for, so a second call (a channel enabled mid-run) starts only what is new.
// Caller HOLDS app.mu. It reads and writes the replay state, which a previous run's worker can
// still be touching from its own locked cleanup, so it must be under the lock — but the mutex is
// not reentrant and the mid-run enable path already holds it, so taking it here froze the GUI
// the moment a replay channel was ticked on. The spawns happen after the caller unlocks; the
// workers block on their first lock until then, which is harmless.
fn (mut app App) spawn_replay_workers_locked() []ReplaySpawn {
	// CANONICAL path as the key. Two channels naming one capture through different spellings —
	// an absolute path and a symlink, `./x.mf4` and `x.mf4` — would otherwise form two groups,
	// each decoding the file and running its own clock, which is exactly the skew this grouping
	// exists to remove.
	mut by_src := map[string][]int{}
	for i, c in app.chans {
		if c.replaying() {
			by_src[os.real_path(c.replay_src)] << i
		}
	}
	// ACROSS every group, before starting any of them. player.conflicts() is given one
	// recording's specs, so two channels replaying DIFFERENT files onto one interface never
	// meet inside it — and two recordings on one wire is the id collision that grouping exists
	// to prevent, arriving by another door.
	// SEEDED with the live owners, because a worker that was just disabled still holds its
	// destination: it may be dispatching a batch it already computed, or sitting up to 50 ms in
	// its poll before it notices the toggle. Rebuilding this table from the enabled channels
	// alone would call that wire free and start a second worker onto it. The owner table is the
	// single authority for who has a destination; this loop only adds the not-yet-started.
	mut dst_owner := map[string]string{}
	mut clash := []string{}
	for src, cis in by_src {
		for ci in cis {
			if ci >= app.chans.len {
				continue
			}
			k := transport.destination_key(app.chans[ci].iface)
			if prev := dst_owner[k] {
				if prev != src {
					clash << '${app.chans[ci].iface} (${os.base(prev)} and ${os.base(src)})'
				}
			} else {
				dst_owner[k] = src
			}
		}
	}
	mut to_start := map[string][]int{}
	if clash.len > 0 {
		return [
			ReplaySpawn{
				notes: [
					'two recordings are mapped onto one interface: ${clash.join(', ')} — not starting either',
				]
			},
		]
	}
	for src, cis in by_src {
		st := app.replay_state[src] or { ReplayState{} }
		if st.gen == app.run_gen && st.live {
			continue // already playing in this run; start() is the only caller, so this is belt
		}
		if st.gen == app.run_gen && st.done {
			continue // it finished this run; it does not restart because a sibling was enabled
		}
		app.replay_token++
		app.replay_state[src] = ReplayState{
			gen:   app.run_gen
			live:  true
			token: app.replay_token
		}
		to_start[src] = cis.clone()
	}
	gen := app.run_gen
	mut out := []ReplaySpawn{}
	for src, cis in to_start {
		out << ReplaySpawn{
			source: src
			cis:    cis
			gen:    gen
			token:  (app.replay_state[src] or { ReplayState{} }).token
		}
	}
	return out
}

// ReplaySpawn is one deferred action: a group to start, or names to report. Returned rather than
// performed so the caller can act after releasing app.mu.
struct ReplaySpawn {
	source string
	cis    []int
	gen    u64
	token  u64
	notes  []string // whole messages, emitted verbatim
}

// run_replay_spawns performs what spawn_replay_workers_locked decided. Caller must NOT hold app.mu.
fn (mut app App) run_replay_spawns(items []ReplaySpawn) {
	for it in items {
		for n in it.notes {
			app.notify(n)
		}
		if it.source != '' {
			spawn replay_group(app, it.source, it.cis, it.gen, it.token)
		}
	}
}

// load_recording_for_replay decodes a `.mf4` or candump `.log` once. The bus list is part of
// the decode for BOTH formats: an .mf4 carries its own table, and a .log's is synthesized here
// from the interface names its lines carry — in the loader and nowhere else, so Start's
// resolver and the Configure row's Scan match against ONE list by construction (they briefly
// each derived their own; self-review of the Scan work).
fn load_recording_for_replay(source string) !([]canlog.LogEntry, []mf4.BusInfo) {
	if source.to_lower().ends_with('.mf4') {
		rec := mf4.load_recording(source)!
		if rec.entries.len == 0 {
			return error('${os.base(source)} holds no frames')
		}
		return rec.entries.clone(), rec.buses.clone()
	}
	es := canlog.load_file(source)!
	if es.len == 0 {
		return error('${os.base(source)} holds no frames')
	}
	mut counts := map[string]int{}
	for e in es {
		counts[e.iface]++
	}
	mut ifs := counts.keys()
	ifs.sort()
	mut buses := []mf4.BusInfo{}
	for name in ifs {
		buses << mf4.BusInfo{
			iface:  name
			frames: counts[name]
		}
	}
	return es.clone(), buses
}

// resolve_replay_bus asks modules/player, which owns the rule. The GUI and cmd/restbus each had
// their own copy and had already drifted; which bus a recording means is a fact about the file.
fn resolve_replay_bus(buses []mf4.BusInfo, ch Chan) !string {
	mut names := []player.BusName{}
	mut labels := []string{}
	for b in buses {
		names << player.BusName{
			iface: b.iface
			name:  b.name
		}
		labels << b.iface
	}
	return player.resolve_bus(names, labels, ch.replay_bus) or {
		error('${err} (${os.base(ch.replay_src)})')
	}
}

// replay_db merges the channel's databases. resolve_asset AND real_path: app.dbs_paths is keyed
// on the canonical absolute path, so anything less matches nothing and silently yields an empty
// database — which made every excluded node look undeclared.
fn replay_db(app &App, ch Chan) candb.Database {
	mut a := unsafe { app }
	a.mu.lock()
	db := merge_dbs_from(app.loaded_dbs_for(ch.databases.map(os.real_path(app.resolve_asset(it)))))
	a.mu.unlock()
	return db
}

// ReplayScan is what a Scan of a channel's recording found: its buses, and per bus who talks
// on it through the channel's databases. Display-only — Start does its own load and never
// requires a scan; this exists so `bus:` and the rest-bus exclusions are picked from what the
// file and the DBC actually say instead of typed from memory. `src` names the file the result
// describes: the panel renders it only while the row's source still resolves to that path.
@[heap]
struct ReplayScan {
	src string // resolved path this scan was started for
mut:
	loading bool
	err     string
	buses   []mf4.BusInfo
	census  map[string]player.NodeCensus // by bus label (BusInfo.iface)
}

// scan_replay_source decodes a recording off the UI thread and files the result under mu.
// The census runs the SAME attribution the rest-bus subtraction applies (player.census sits
// beside the Decider), so what the row previews is what Start will do; the bus list comes out
// of the same loader Start uses, for the same reason.
//
// `mine` is the entry this worker was started for, and BOTH write-backs compare pointers
// before touching the map: a slow scan finishing after the row was rescanned — or after the
// map was cleared and repopulated for a different file at the same index — must not overwrite
// the newer result. Same ownership rule as ReplayState.token, same reason.
fn scan_replay_source(app &App, ci int, path string, db candb.Database, mine &ReplayScan) {
	mut a := unsafe { app }
	entries, buses := load_recording_for_replay(path) or {
		a.mu.lock()
		if sc := a.replay_scans[ci] {
			if voidptr(sc) == voidptr(mine) {
				mut m := unsafe { mine }
				m.loading = false
				m.err = err.msg()
			}
		}
		a.mu.unlock()
		return
	}
	mut cens := map[string]player.NodeCensus{}
	for b in buses {
		cens[b.iface] = player.census(player.on_bus(entries, b.iface), db)
	}
	a.mu.lock()
	if sc := a.replay_scans[ci] {
		if voidptr(sc) == voidptr(mine) {
			mut m := unsafe { mine }
			m.loading = false
			m.err = ''
			m.buses = buses.clone()
			m.census = cens.clone()
		}
	}
	a.mu.unlock()
}
