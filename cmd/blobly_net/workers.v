module main

import os
import time
import project
import transport
import telem
import isotp
import uds
import flash
import sim
import script
import canlog
import doip
import someip
import net as vnet
import vgui

// doip_watch owns one entity's socket for the life of a run: it binds while the channel and
// its ECU are ticked, and closes when either is not.
//
// It never blocks on accept. accept_and_serve() applies its timeout to ACCEPTING and then
// serves the connection until the peer disconnects or the 60-second idle timeout, so a
// supervisor that also served could not observe a toggle while a tester held the session open —
// the "offline" ECU went on answering. Serving happens in doip_serve(); close() from here
// interrupts it, which is what makes switching an ECU off actually take effect.
fn doip_watch(app &App, pch project.Channel, ent sim.DoipEntity, key string, gen u64) {
	mut a := unsafe { app }
	host, port := pch.doip_endpoint()
	cfg := ent.cfg // built by sim.doip_entity, so the GUI announces exactly as headless does
	mut hst := &sim.DoipHost{
		server: ent.server
	}
	mut srv := &doip.DoipServer(unsafe { nil })
	mut bound := false
	mut warned := false
	// This RUN only. Checked with running, so a supervisor that slept through a Stop/Start pair
	// exits instead of acting on a run that is not its own.
	for a.running && a.run_gen == gen {
		want := a.doip_should_host(pch, key)
		if bound && !want {
			srv.close() // interrupts an in-progress session, not just the accept
			bound = false
			// Let a later failure speak again: cleared only on a successful bind, toggling off
			// and on to retry a held port produced no Log line at all, leaving the channel idle
			// and silent — which is what this PR set out to stop.
			warned = false
			// Generation-checked here TOO. Guarding only the bind-failure path left this one:
			// an old watcher between its close() and this call, while a Stop/Start/re-enable
			// published a replacement, would deregister the NEW run's live listener.
			a.doip_forget_if_current(pch, ent, gen)
			a.notify('${pch.name}: DoIP entity stopped — ${host}:${port} released')
		} else if !want || !bound {
			if want && !bound {
				// Rebuild the announcement from what the server SERVES now: a tester may have
				// written 0xF190 since the last bind, and the startup cfg would advertise the
				// original while the server returned the new one.
				mut cur := cfg
				if v := hst.server.dids[u16(0xF190)] {
					// Rebuild only the VIN. server_cfg() carries identity alone, so using it
					// here silently reset announce_count/interval/to to their defaults — an
					// ECU configured silent would start announcing after a toggle.
					cur = doip.ServerCfg{
						...cfg
						vin: v.bytestr()
					}
				}
				if s := a.doip_bind(cur, host, port, mut hst) {
					srv = s
					bound = true
					warned = false
					// Decide and publish ATOMICALLY. Checking first and publishing after leaves a
					// window: Stop can run between them, snapshot an empty host map, and this
					// socket is then inserted behind it — leaking past Stop and failing the
					// next Start against itself. doip_publish_if_current does both under the
					// same mutex Stop takes.
					if !a.doip_publish_if_current(pch, ent, srv, gen, key) {
						srv.close()
						bound = false
					} else {
						spawn doip_serve(app, mut srv)
						spawn doip_udp_worker(app, mut srv)
						// Power-on announcements, in the background: count × interval is 1.5s
						// by default and Start must not block on it.
						spawn doip_announce_worker(app, mut srv, pch.name)
						// cur.vin, not ent.announce: a tester may have written 0xF190 since
						// Start, and naming the startup VIN here would report an identity the
						// entity neither announces nor serves — the split this PR exists to
						// prevent, in the surface an operator actually reads.
						a.notify('${pch.name}: DoIP entity on ${host}:${port}, logical address 0x${pch.ecu_addr:04X}, VIN ${cur.vin}')
					}
				} else {
					// The generation again — an old supervisor that lost the bind race to a
					// new run would otherwise run this path and deregister the NEW run's live
					// listener, target and channel state. Checked inside the bare `else` so
					// `err` stays in scope.
					if a.running && a.run_gen == gen && !warned {
						// Once, not every tick. And DROP the target: whatever the cause, we are
						// not listening — leaving it selectable would point the panel at
						// whatever else owns that endpoint and report the wrong ECU's answers.
						a.notify('${pch.name}: cannot bind ${host}:${port} — ${err}')
						a.doip_forget_if_current(pch, ent, gen)
						warned = true
					}
				}
			}
			time.sleep(200 * time.millisecond)
			continue
		}
		time.sleep(200 * time.millisecond)
	}
	if bound {
		srv.close()
	}
}

// doip_announce_worker sends the power-on announcements, reporting a failure to the Log rather
// than dropping it — a silent ECU that was supposed to announce is exactly the thing a bench
// would waste an hour on.
fn doip_announce_worker(app &App, mut s doip.DoipServer, name string) {
	mut a := unsafe { app }
	s.announce() or { a.notify('${name}: announce failed: ${err}') }
}

// doip_serve runs one bound entity's TCP side until it is closed.
fn doip_serve(app &App, mut s doip.DoipServer) {
	mut a := unsafe { app }
	for a.running && !s.is_stopping() {
		s.accept_and_serve(200) or { continue } // a timeout is the normal case
	}
}

// doip_udp_worker answers vehicle-identification requests, so Discover finds the entity.
// Exits on is_stopping() as well as app.running, which the next Start REUSES: a worker that had
// not yet observed the brief false would otherwise hot-spin against its own closed sockets.
fn doip_udp_worker(app &App, mut s doip.DoipServer) {
	mut a := unsafe { app }
	for a.running && !s.is_stopping() {
		s.serve_udp_once(200) or { continue }
	}
}

fn doip_worker(app &App, host string) {
	mut a := unsafe { app }
	mut h := host
	mut port := 13400
	if host.contains(':') {
		parts := host.split(':')
		h = parts[0]
		port = parts[1].int()
	}
	info := doip.discover(h, port, 1200) or {
		a.notify('DoIP discover ${host}: ${err}')
		return
	}
	a.mu.lock()
	a.doip_ents << info
	a.mu.unlock()
	a.notify('DoIP: found VIN ${info.vin}')
	vgui.wake()
}

// notify_gen logs `msg` iff `gen` is still the LIVE, RUNNING measurement — the gate every
// WORKER-side failure notify must pass, with the check and the append in ONE take of app.mu:
// a check that unlocks before the append can straddle a Stop/Start and log a stale worker's
// failure into the replacement run, and after a plain Stop run_gen is unchanged, so `running`
// matters too — an obsolete worker must not narrate a run that is over (codex #141 r2).
fn notify_gen(app &App, gen u64, msg string) {
	mut a := unsafe { app }
	a.mu.lock()
	live := a.running && a.run_gen == gen
	if live {
		a.log_append_locked(msg)
	}
	a.mu.unlock()
	if live {
		vgui.wake()
	}
}

// sim_loop runs a channel's simulated ECUs on its bus: emit cyclic frames + answer
// request/response rules. Driver-free on inproc:, real on vcan0/can0.
fn sim_loop(app &App, sc SimCfg, gen u64) {
	a := unsafe { app }
	mut bus := app.open_tap_on(sc.iface, org_tx_sim, sc.pch.name) or {
		eprintln('sim ${sc.iface}: ${err}')
		// consumer_failed only counts, and the count is read only by the replay gate — on a
		// non-replay run a dead sim was discoverable only by the absence of its traffic.
		// Gen-gated like every worker notify: a stale sim's late failure is not this run's.
		notify_gen(app, gen, '${sc.pch.name}: simulation could not open ${sc.iface} — ${err}')
		consumer_failed(a, sc.iface, gen)
		return
	}
	consumer_attached(a, sc.iface, gen)
	mut engine := sim.Engine{}
	// Alive counters for the whole run, not just across one rebuild: an ECU switched OFF leaves
	// the engine, so state kept only in the previous engine is lost and switching it back on
	// restarts its counter at zero — a backward jump a checking receiver rejects.
	mut counters := map[string]int{}
	mut local_gen := u64(0) // rebuild when a.sim_gen changes (ECU enable/disable)
	mut built := false
	t0 := time.ticks()
	for a.running {
		// A CHANNEL THAT HAS LEFT THE RUN takes its simulation with it. rx_loop disables a
		// channel whose adapter failed, and this loop only watched `a.running` — so a simulated
		// ECU went on transmitting into a port that had gone, discarding every failure.
		a.mu.lock()
		// BY NAME AND WIRE. A hand-edited project can carry the same channel name on two buses,
		// and matching on the name alone let an unrelated enabled row keep this simulation alive
		// after its own channel was switched off — transmitting onto a bus nobody had asked for.
		mut still_on := false
		sim_dest := transport.destination_key(sc.iface)
		for c in a.chans {
			if c.enabled && c.name == sc.pch.name && transport.destination_key(c.iface) == sim_dest {
				still_on = true
				break
			}
		}
		a.mu.unlock()
		if !still_on {
			// PARKED, not finished. Leaving outright stopped the transmission — which was the
			// point, since rx_loop takes a dead destination's rows out of the run — but nothing
			// respawns a simulation: start() is its only spawner, so a channel disabled and
			// re-enabled during a run came back with a reader, taps and no simulated ECUs at all
			// until the whole run was restarted.
			//
			// Parking has to keep READING, though. The tap stays subscribed, so a loop that only
			// slept would move the traffic into the socket and the 8192-frame inproc queue rather
			// than drop it: on re-enable the ECU would answer requests put to it while it was
			// switched off, seconds late, and a queue allowed to fill drops frames for everyone
			// sharing the wire. Read and discard. recv's own 5 ms timeout paces an idle bus, so
			// the drain ends on the first empty read and the sleep only bounds the retry rate.
			for _ in 0 .. 1024 {
				bus.recv(5) or { break }
			}
			time.sleep(20 * time.millisecond)
			continue
		}
		if !built || a.sim_gen != local_gen {
			built = true
			local_gen = a.sim_gen
			a.mu.lock()
			mut enabled := map[string]bool{}
			for k, v in a.sim_enabled {
				enabled[k] = v
			}
			a.mu.unlock()
			engine.save_counters(mut counters) // fold the outgoing engine's counts in first
			engine = sim.Engine{}
			for n in sc.nodes {
				if enabled[sim_key(sc.pch, n.name)] or { true } {
					engine.ecus << build_node(sc.db, n)
				}
			}
			engine.restore_counters(counters)
		}
		// ONE fault source, the module's table — the same one Lua writes through sim.fault().
		// The panel used to write a map on App that only the panel read, so a script launched
		// from the Script panel reported success and changed nothing on the bus.
		sim.apply_injected(sc.iface, mut engine)
		now_ms := f64(time.ticks() - t0)
		for f in engine.due_frames(now_ms) {
			bus.send(f) or {}
		}
		if frame := bus.recv(5) {
			for resp in engine.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
	bus.close()
}

// gen_loop fires cyclic senders at their cycle_ms while the measurement runs.
fn gen_loop(app &App) {
	mut a := unsafe { app }
	mut last := map[int]i64{}
	for a.running {
		now := time.ticks()
		mut fire := []int{}
		a.mu.lock()
		for i, sr in a.senders {
			if sr.sender.trigger == 'cyclic' && sr.sender.cycle_ms > 0 {
				// NOT ONTO A WIRE THAT HAS LEFT THE RUN — but "has no reader" is not that.
				// A generator may legitimately target a bus nobody monitors: an `off` channel,
				// or a target-only wire, both of which start() opens a transmit tap for on
				// purpose. Requiring a reader silenced every one of them, which is a supported
				// arrangement rather than a failure.
				//
				// What rx_loop actually does to a dead destination is DISABLE its rows. So the
				// question is whether this target's rows exist and have all left the run — not
				// whether anybody is listening to it.
				tgt := sr.target()
				if tgt != '' && a.dest_left_the_run_locked(tgt) {
					continue
				}
				lf := last[i] or { i64(0) }
				if now - lf >= i64(sr.sender.cycle_ms) {
					last[i] = now
					fire << i
				}
			}
		}
		a.mu.unlock()
		for i in fire {
			a.fire_index(i)
		}
		// Resolve emissions whose echo never came. Expiry is otherwise driven only by the next
		// emission or the next received frame, so on a bus that falls silent — a disconnected
		// bench, the very case the mark is for — the last rows stayed unresolved forever.
		a.mu.lock()
		a.expire_pending_locked(a.since_ms())
		a.mu.unlock()
		time.sleep(8 * time.millisecond)
	}
}

// diag_server_loop runs the native UDS server (mirror of the tester: rx 0x7E0, tx 0x7E8)
// so the Diagnostics panel + Lua scripts work driver-free against simulated channels.
// uds_node_loop answers one simulated ECU's diagnostic requests on its own addresses.
// consumer_attached reports one in-process consumer as attached to its bus -- or as having
// given up, which counts the same here: the gate exists so replay does not transmit into a bus
// nobody is subscribed to yet, and a consumer that will never attach must not hold it shut.
// Exactly once per spawned consumer, or the gate waits for an arrival that cannot come.
fn consumer_attached(app &App, iface string, gen u64) {
	mut a := unsafe { app }
	k := transport.destination_key(iface)
	a.mu.lock()
	if a.run_gen == gen {
		a.consumers_ready[k]++ // a LEFTOVER from the previous run counts towards nothing
	}
	a.mu.unlock()
}

// consumer_failed records one in-process consumer that could not attach at all. Separate from
// consumer_attached because the gate must not open on it: a simulated ECU that never subscribed
// is missing from the experiment, and a replay that starts anyway produces a recording of the
// wrong bench while looking like an ordinary run.
fn consumer_failed(app &App, iface string, gen u64) {
	mut a := unsafe { app }
	k := transport.destination_key(iface)
	a.mu.lock()
	if a.run_gen == gen {
		a.consumers_failed[k]++
	}
	a.mu.unlock()
}

// consumer_expected records one consumer about to be spawned. Under the lock, because a
// consumer of the PREVIOUS run can still be attaching while this one starts: V's maps are not
// safe against concurrent mutation, and locking only the reader's side protects nothing.
fn consumer_expected(mut app App, iface string, gen u64) {
	k := transport.destination_key(iface)
	app.mu.lock()
	if app.run_gen == gen {
		app.consumers_want[k]++
	}
	app.mu.unlock()
}

fn uds_node_loop(app &App, pch project.Channel, iface string, name string, rx u32, tx u32, ext bool, srv uds.Server, gen u64) {
	a := unsafe { app }
	mut s := srv
	key := sim_key(pch, name)
	mut ch := &isotp.SoftChannel(unsafe { nil })
	mut open := false
	mut reported := false
	mut open_err_said := false
	defer {
		if open {
			ch.close()
		}
	}
	for a.running {
		a.mu.lock()
		on := a.sim_enabled[key] or { true }
		a.mu.unlock()
		if !on {
			if !reported {
				reported = true
				consumer_attached(a, iface, gen) // switched off: nothing will subscribe, do not wait for it
			}
			// CLOSE it, do not merely stop answering. Two things go wrong otherwise, and the
			// previous two attempts each fixed one: leaving recv running answers a First Frame
			// with Flow Control, so the "offline" ECU is still visible on the wire; and merely
			// skipping recv leaves requests queued on the open channel, which are answered
			// late once the ECU comes back. A closed channel does neither.
			if open {
				ch.close()
				open = false
			}
			time.sleep(50 * time.millisecond)
			continue
		}
		if !open {
			// on a TAPPED bus: an ISO-TP response is several CAN frames, and a simulated ECU
			// answering diagnostics must be attributed like any other thing we transmit.
			// pch: this node's OWN channel — two entries can share one interface, and the
			// simulated ECUs of the second must not be attributed to the first.
			tapped := a.open_tap_on(iface, org_tx_sim, pch.name) or {
				if !open_err_said {
					open_err_said = true
					// once PER FAILURE EPISODE, not per 200ms retry: the retry is the
					// recovery, the silence was the bug — a UDS node that never came up
					// said nothing, forever. The flag resets on success below, so a later
					// outage of this long-lived worker speaks again.
					notify_gen(app, gen,
						'${pch.name}: UDS node could not open ${iface} — ${err} (retrying)')
				}
				time.sleep(200 * time.millisecond)
				continue
			}
			ch = isotp.on_bus(tapped, a.bitrate_iface(iface), tx, rx, ext) or {
				if !open_err_said {
					open_err_said = true
					notify_gen(app, gen,
						'${pch.name}: UDS node could not bind ISO-TP on ${iface} — ${err} (retrying)')
				}
				time.sleep(200 * time.millisecond)
				continue
			}
			open = true
			open_err_said = false // this episode ended in recovery; the next one may speak
			if !reported {
				reported = true
				consumer_attached(a, iface, gen)
			}
		}
		req := ch.recv(50) or { continue }
		resp := s.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
}

fn diag_server_loop(app &App, iface string, chan_name string, gen u64) {
	a := unsafe { app }
	// its OWN channel: two channels can share a wire, and resolving the name from the interface
	// picks whichever is listed first — so a default server created for the second one had every
	// response attributed to its neighbour
	tapped := a.open_tap_on(iface, org_tx_sim, chan_name) or {
		notify_gen(app, gen, '${chan_name}: UDS server could not open ${iface} — ${err}')
		consumer_failed(a, iface, gen)
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), diag_rx_id, diag_tx_id, false) or {
		notify_gen(app, gen,
			'${chan_name}: UDS server could not bind ISO-TP on ${iface} — ${err}')
		consumer_failed(a, iface, gen)
		return
	}
	consumer_attached(a, iface, gen)
	mut srv := uds.default_server()
	for a.running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

// health_msg words a fault-ladder transition for the Log. BUS-OFF carries the diagnosis
// hints: it is the state a bench actually hits, and the naked word helps nobody at 2am.
fn health_msg(iface string, from transport.BusHealth, to transport.BusHealth) string {
	base := '${iface}: bus ${transport.health_name(to)}'
	return match to {
		.bus_off {
			'${base} — the controller LEFT the bus; nothing transmits until it recovers (shorted/unterminated wire, or a bitrate every other node rejects?)'
		}
		.error_passive {
			'${base} — error counters over 128: this node no longer signals errors actively'
		}
		.warning {
			'${base} — error counters climbing (over the warning limit)'
		}
		.ok {
			if from != .unknown {
				'${base} — recovered'
			} else {
				base
			}
		}
		.unknown {
			// reachable only if a future caller drops the != .unknown gate — say something
			// legible rather than a trailing-space fragment
			'${iface}: bus state changed'
		}
	}
}

fn rx_loop(app &App, ci int, iface string, gen u64) {
	mut bus := app.open_transport(iface) or {
		eprintln('rx ${iface}: ${err}')
		mut a := unsafe { app }
		a.mu.lock()
		// Same generation guard as the teardown below: opening can fail slowly, so a PREVIOUS
		// run's failure can land after the new loop has opened and published readiness. Clearing
		// the flag then would leave the current run with a monitor nobody counts — every emission
		// after it recorded as having no watcher, and its echo read as the ECU's.
		mut say := false
		if a.run_gen == gen {
			a.chans[ci].running = false
			a.chans[ci].spawning = false // release the guard, or it can never be re-enabled
			// Append UNDER THE SAME take of the lock as the flags: a check that unlocks
			// first can straddle a Stop/Start and narrate the replacement run (codex #141
			// r2 — the exact gap the guard exists for, one layer up). And say it at all,
			// not only eprintln: on the Windows GUI-subsystem exe stderr goes nowhere, and
			// two PCAN channels failing to open looked exactly like a healthy silent bus,
			// with the replay's "never came up" as the only audible symptom (maintainer's
			// bench, 2026-08-21). Worded for the WIRE: this loop is the destination's one
			// reader, so an aliased row shows no failure of its own yet is equally
			// unwatched. `running` is not required here: this failure belongs to the run
			// that spawned this loop, which run_gen just proved is still current.
			a.log_append_locked('${iface}: open failed — ${err} — nothing is monitoring this wire')
			say = true
		}
		a.mu.unlock()
		if say {
			vgui.wake()
		}
		return
	}
	mut a := unsafe { app }
	a.mu.lock()
	// Only for the run we belong to. Opening a bus takes time, so a loop from the PREVIOUS run
	// can arrive here after a restart — and since the teardown below is generation-guarded, the
	// flag it set would stay true with nobody reading: note_emit would then count a watcher that
	// does not exist and mark healthy traffic as never having reached the wire.
	if a.run_gen != gen {
		a.mu.unlock()
		bus.close()
		return
	}
	// The bus is open: from here a frame we emit can actually come back to us, which is what
	// `running` promises to note_emit's "is anyone watching?" check.
	a.chans[ci].running = true
	a.chans[ci].spawning = false
	a.dbc_readers++ // this loop reads app.dbs lock-free (lookup_name per frame)
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.dbc_readers--
		a.mu.unlock()
	}
	chname := a.chans[ci].name
	// Built from the SAME `protect:` entries the simulation stamps with, so a project describes
	// each protected message once and both directions follow it. A separate "check this on
	// receive" declaration would let the two drift, and the drift would read as an ECU fault.
	// EVERY SimCfg on this interface, not the first. Two channel entries may share a bus — the
	// diagnostics setup already handles that — and stopping at the first meant later entries'
	// protected messages were never checked, or were checked against the wrong layout.
	mut verifiers := sim.VerifySet{}
	// BY DESTINATION. Two rows spelling one wire differently (`vector:1`, `vector:ch1`) each
	// observe the same traffic, and comparing the strings meant each port checked only its own
	// row's protected messages — so a frame arriving on the wire was verified against half the
	// project, and the missing half read as an ECU that had stopped stamping.
	want_dest := transport.destination_key(iface)
	for sc in a.sims {
		if transport.destination_key(sc.iface) != want_dest {
			continue
		}
		for w in verifiers.merge_into(sim.verifiers_for(sc.db, sc.nodes, sc.verify)) {
			a.notify('${iface}: ${w}')
		}
	}
	// the TraceRsp id is config-static (the manifest is only mutated while stopped, so it can't
	// change under a running RX loop) — resolve it once, not per frame in the hot path.
	rsp_id := a.manifest.frames.or_defaults().rsp
	// the controller's fault ladder, polled ~1/s and reported on TRANSITIONS only — the
	// local last-state means no unlocked read of shared state, and the write is generation
	// -guarded like every other flag this loop owns
	mut last_health := transport.BusHealth.unknown
	mut next_health := i64(0)
	for a.running && a.run_gen == gen && a.chans[ci].enabled {
		if time.ticks() >= next_health {
			next_health = time.ticks() + 1000
			h := bus.health()
			if h != .unknown && h != last_health {
				a.mu.lock()
				// running AND generation, notify_gen's own rule: a health event landing in
				// the teardown after Stop must neither narrate a finished run nor seed a
				// stale verdict for the next one (self-review)
				if a.running && a.run_gen == gen && ci < a.chans.len {
					a.chans[ci].health = h
					a.log_append_locked(health_msg(iface, last_health, h))
				}
				a.mu.unlock()
				vgui.wake()
				last_health = h
			}
		}
		// track the real link state so a bound-but-DOWN iface shows "down" (red), not "run",
		// and flips to green the moment the user brings it up (ip link set … up).
		down := !iface_link_up(a.chans[ci].adapter, a.chans[ci].address)
		if down != a.chans[ci].link_down {
			a.mu.lock()
			a.chans[ci].link_down = down
			a.mu.unlock()
			vgui.wake()
		}
		f := bus.recv(200) or {
			// A TIMEOUT IS THE NORMAL ANSWER; anything else is the adapter in trouble, and
			// continuing repeated the failing call as fast as it could return — a core spun on
			// an unplugged VN while the panel still showed the channel running.
			if err.msg().contains('timeout') {
				continue
			}
			a.notify('${iface}: receive failed — ${err}')
			// DISABLED, not merely broken out of. The teardown below respawns rx_loop whenever
			// the channel is still enabled, so breaking alone reopened the failed adapter and
			// repeated the failure — the same spin, one open slower. A channel whose adapter has
			// gone stops being part of the run until somebody says otherwise.
			a.mu.lock()
			if a.run_gen == gen && ci < a.chans.len {
				// EVERY ALIAS ON THIS WIRE. Disabling only the reader-owning row let the
				// teardown hand the reader to a sibling, which opens the same failed adapter and
				// fails the same way — a relay race around a port that has gone.
				dead := transport.destination_key(a.chans[ci].iface)
				for cj, other in a.chans {
					if transport.destination_key(other.iface) == dead {
						a.chans[cj].enabled = false
					}
				}
				// Same rule as every other writer of chans[].enabled: republish the wire list
				// before releasing the lock, or a row retired here keeps silencing a wire that
				// something else is enabled onto later.
				a.push_listen_only_locked()
			}
			a.mu.unlock()
			break
		}
		// A blocked recv can be woken by the previous run's echo after Start has already reset
		// the ring: this loop would then find no record and file that frame as the CURRENT
		// run's bus traffic — into the trace, the recording and the verifier.
		if a.run_gen != gen {
			break
		}
		t_ms := a.since_ms()
		// Is this the echo of something WE just put on the wire? Every backend delivers our own
		// sends to the monitor's separate bus instance (transport.test_inproc_cross_delivery
		// pins it), so without this the tester and our simulated ECUs arrive here looking
		// exactly like the device under test. Claiming the echo CONFIRMS the row written at
		// emit instead of adding a second one, and keeps our own frames out of both the
		// recording and the E2E verifier — whose per-message counter would otherwise see one
		// message twice and report a jump the ECU never made.
		a.mu.lock()
		// AGAIN under the lock. The check after recv can pass and then this thread be
		// descheduled while Start resets the ring and advances the generation — the stale loop
		// would resume here and claim or record its old frame against the new run.
		if a.run_gen != gen {
			a.mu.unlock()
			break
		}
		claimed := a.claim_echo_locked(ci, transport.canonical_iface(iface), f, t_ms)
		ours := claimed != none
		// The recording follows the WIRE, so its order is observation order — the only order
		// that is actually true. Our own frame is written HERE, when it comes back, under the
		// channel of the row it confirmed: recording at emit instead let a fast responder's
		// answer reach the file before the request, because the simulation and the monitor are
		// different threads on different sockets and neither waits for the other.
		if a.recording {
			if c := claimed {
				// FIRST claim only. Two channels may share a wire, and each monitor claims its
				// own copy of the same emission — writing on every claim put the frame in the
				// file twice, so a replay would transmit it twice.
				//
				// The channel comes from the emission itself (the tag it was noted with), not
				// from the interface: an emission made while the trace was paused has no row to
				// read it from, and deriving it from the interface picks whichever channel is
				// listed first.
				if c.first && !c.done {
					ch_own := if c.tag != '' { c.tag } else { a.chan_name_for(iface) }
					a.rec_append_locked(canlog.LogEntry{
						t_s:   a.since_s()
						iface: ch_own
						frame: f
					})
				}
			}
		}
		a.mu.unlock()
		name := a.lookup_name(f.id, f.extended)
		// Verify protection on the way in. Done here, on the RX thread that already owns the
		// frame, because the check is stateful — it needs the previous counter for this id —
		// and a stateful check spread across draw calls would depend on what the user scrolled.
		mut viol := ''
		// Not our own echo (see above), and not remote frames: an RTR request carries NO payload, so the missing bytes read as
		// zero and a request on a protected id was labelled !CRC — or, repeated, !CNT stalled.
		// A verdict about bytes that were never sent says nothing about the sender.
		if !f.rtr && !ours {
			if k := verifiers.resolve(a.dbs_for_dest(iface), f.id, f.extended) {
				if mut ver := verifiers.by_key[k] {
					v := ver.check(f.data)
					verifiers.by_key[k] = ver
					viol = v.str()
				}
			}
		}
		a.mu.lock()
		// The run again: this iteration released the lock after claiming, and a Stop→Start in
		// that gap resets the ring and moves the generation — publishing here would put the old
		// run's frame into the new run's trace, recording and verifier.
		if a.run_gen != gen {
			a.mu.unlock()
			break
		}
		if !a.paused && !ours {
			a.push_row_locked(TraceRow{
				t_ms:   t_ms
				ch:     chname
				origin: org_rx
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
			a.gcount[gkey_frame(org_rx, chname, f)]++
			// The capture dump now arrives as an ISO-TP block on 0x7E5 (not raw per-record
			// frames): trace_dump_worker reassembles + decodes it on demand. The raw ISO-TP
			// frames still show in the trace table above.
		}
		// A TraceRsp (per core) reports the capture state + freeze CAUSE — the only way to tell a
		// trigger-frozen dump from a manual stop. Update it even while the table is paused: the
		// freeze status is independent of the row capture, and it's what you watch during a pause.
		if f.id == rsp_id && f.data.len >= 8 {
			a.trace_freeze = trace_rsp_status(telem.decode_trace_rsp(f.data))
		}
		if a.recording && !ours {
			a.rec_append_locked(canlog.LogEntry{
				t_s:   a.since_s()
				iface: chname
				frame: f
			})
		}
		// Our own echo is not received traffic. The trace has not called it RX since the origin
		// column landed — it is the TX/TX-S row that was already written at emit — so counting it
		// here left the header claiming hundreds of RX frames above a table with no RX row in it
		// (#105). What this counts now is what the bus brought us: everything nobody here sent.
		if !ours {
			a.chans[ci].rx++
			a.rx++
		}
		a.mu.unlock()
		now := time.ticks()
		if now - a.last_wake >= a.wake_ms {
			a.last_wake = now
			vgui.wake()
		}
	}
	bus.close()
	a.mu.lock()
	// Only if this run is still the current one. A loop that exited because the generation moved
	// on would otherwise clear a flag the NEW loop just set, and every emission after that would
	// see no watcher: its echo classified as the device under test's, recorded twice and fed to
	// the verifier, while the monitor was in fact running the whole time.
	if a.run_gen == gen {
		a.chans[ci].running = false
		a.chans[ci].spawning = false
		// Re-enabled while we were on our way out? The toggle saw `running` still true and
		// skipped spawning a replacement, so without this the channel is left with no reader at
		// all. We are the ones who know this loop is finished, so we start the next one.
		// HANDED ON. This loop held the only reader for its wire, so when its own row is
		// switched off the siblings still enabled on that wire are left with nothing watching
		// them — silent, and looking healthy. Whoever is still here takes it.
		if !a.chans[ci].monitorable() && a.running {
			want := transport.destination_key(iface)
			for cj, other in a.chans {
				if cj == ci || !other.monitorable() || other.running || other.spawning {
					continue
				}
				if transport.destination_key(other.iface) == want {
					// the WIRE's verdict survives the handoff: a socket opened after the
					// controller entered bus-off sees only future transitions, so a
					// successor starting at .unknown painted the still-dead wire green
					// (codex #143 r1). The outgoing reader is the one that knows.
					a.chans[cj].health = a.chans[ci].health
					a.chans[cj].spawning = true
					spawn rx_loop(app, cj, other.iface, gen)
					break
				}
			}
		}
		if a.chans[ci].monitorable() && a.running {
			a.chans[ci].spawning = true
			spawn rx_loop(app, ci, iface, gen)
		}
		// Whatever we emitted while this loop was the observer can no longer be answered by it.
		// Its records stay claimable (an echo may already be queued in the socket) but earn no
		// verdict: the watcher was removed, so silence proves nothing.
		//
		// Inside the generation guard: a stale loop exiting after a restart would otherwise
		// strip the CURRENT run's records for the same channel index — whose monitor is alive
		// and watching — and a genuinely missing frame would then retire without a mark.
		a.taps.drop_monitor(ci)
	}
	a.mu.unlock()
}

fn diag_worker(app &App, kind string, did u16, want_key string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.diag_busy {
		a.mu.unlock()
		return
	}
	a.diag_busy = true
	a.mu.unlock()
	targets := a.diag_targets()
	// Resolve by the identity captured AT CLICK TIME, passed in rather than read here: the
	// combo stays enabled while a request is busy, so a worker that read the live field could
	// address whichever ECU the user selected after clicking. Falling back to another entry
	// when the chosen one has gone would do the same thing more quietly.
	key := want_key
	mut t := DiagTarget{}
	mut found := false
	for cand in targets {
		if cand.key == key || (key == '' && !found) {
			t = cand
			found = true
			if cand.key == key {
				break
			}
		}
	}
	if !found {
		a.diag_push('target "${key}" is no longer available')
		a.diag_done()
		return
	}
	iface := if t.iface != '' { t.iface } else { a.diag_iface() }
	// The transport follows the TARGET, not the panel. Opening ISO-TP for a DoIP entry would
	// try to open `doip:127.0.0.1:13400` as a CAN interface, which on Linux falls through to
	// SocketCAN and fails — the panel would report the entity unreachable while it was serving.
	mut ch := if t.carrier.doip {
		isotp.Channel(doip.open_doip(t.carrier.host, t.carrier.port, t.carrier.tester,
			t.carrier.ecu) or {
			a.diag_push('doip ${t.carrier.host}:${t.carrier.port}: ${err}')
			a.diag_done()
			return
		})
	} else {
		isotp.Channel(isotp.on_bus(a.open_tap_on(iface, org_tx, t.chan) or {
			a.diag_push('open ${iface}: ${err}')
			a.mu.lock()
			a.diag_busy = false
			a.mu.unlock()
			vgui.wake()
			return
		}, a.bitrate_iface(iface), t.rx, t.tx, t.ext) or {
			a.diag_push('open ${iface}: ${err}')
			a.mu.lock()
			a.diag_busy = false
			a.mu.unlock()
			vgui.wake()
			return
		})
	}
	// Close it when this request is done. A DoIP entity serves ONE connection at a time and
	// stays inside it until the peer disconnects, so a leaked connection from the first button
	// press blocked every later one until the server's 60-second idle timeout.
	defer {
		ch.close()
	}
	mut c := uds.new_client(ch)
	match kind {
		'session' {
			c.diagnostic_session(0x03) or {
				a.diag_push('session: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('session 0x03 OK')
		}
		'vin' {
			r := c.read_data_by_identifier(0xF190) or {
				a.diag_push('VIN: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('VIN = ${r.bytestr()}')
		}
		'tp' {
			c.tester_present() or {
				a.diag_push('tester present: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('tester present OK')
		}
		'did' {
			r := c.read_data_by_identifier(did) or {
				a.diag_push('DID ${did:04X}: ${err}')
				a.diag_done()
				return
			}
			a.diag_push('DID ${did:04X} = ${hex(r)}  "${printable(r)}"')
		}
		else {}
	}

	a.diag_done()
}

// trace_dump_worker performs one capture read-out: it freezes the target's ring(s) and dumps
// the selected cores, reassembling each per-core ISO-TP block on 0x7E5 (sending flow control
// on 0x7E6) and decoding the records into app.trecs for the swimlane. Mirrors diag_worker: a
// single-flight busy flag, a short-lived spawn, a blocking transfer, results under mu + wake.
fn trace_dump_worker(app &App, core_mask u16) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.trace_busy {
		a.mu.unlock()
		return
	}
	a.trace_busy = true
	a.mu.unlock()
	iface := a.trace_iface()
	if iface == '' {
		a.set_trace_status('dump: no running channel')
		a.trace_done()
		return
	}
	// the trace frame ids are config-driven on the target — read them from the loaded manifest
	// (or_defaults fills the trace_demo wire when the manifest omits the `# trace frames` block).
	f := a.manifest.frames.or_defaults()
	// the host is the ISO-TP receiver: it sends flow control on dump_fc and receives the dump
	// data on record (open before commanding, so the socket buffers the target's first frame).
	// ISO-TP addressing must match the frame width — a 29-bit trace id would otherwise be masked
	// to 11 bits by SocketCAN and the target would never answer.
	tapped := a.open_tap(iface, org_tx) or {
		a.set_trace_status('dump: open ${iface}: ${err}')
		a.trace_done()
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), f.dump_fc, f.record, trace_ext(f.record)) or {
		a.set_trace_status('dump: open ${iface}: ${err}')
		a.trace_done()
		return
	}
	defer {
		ch.close()
	}
	cmd_ext := trace_ext(f.cmd)
	// Freeze each selected core's capture RING (op_stop) so it can be read out — the target
	// refuses to dump a buffer that's still being written. This stops recording, NOT the
	// core: handlers keep running. Then dump (op_dump).
	a.tx_on(iface, transport.CanFrame{
		id:       f.cmd
		extended: cmd_ext
		data:     telem.encode_trace_cmd(telem.op_stop, telem.filter_all, core_mask)
	})
	a.tx_on(iface, transport.CanFrame{
		id:       f.cmd
		extended: cmd_ext
		data:     telem.encode_trace_cmd(telem.op_dump, telem.filter_all, core_mask)
	})
	// a dump streams SELF-DESCRIBING blocks: one or more per selected core (multi-block:
	// deep rings ride many ~payload-sized blocks; the header's more-flag marks continuation,
	// so end-of-stream lives in the format, not in transport heuristics).
	ncores := mask_popcount(core_mask)
	mut recs := []TRec{}
	mut got := 0
	mut last_seen := 0 // cores whose final block has arrived
	mut recv_err := ''
	// Cross-core correlation (emb REQ-TRACE-011), keyed by core: how tight the measured clock
	// offset was. A core absent here is drawn on its OWN clock — the status has to say so,
	// because an uncorrelated lane looks exactly like a correlated one.
	mut skew_bounds := map[int]u16{}
	for _ in 0 .. 256 {
		if last_seen >= ncores {
			break
		}
		// Reassembly can fail transiently (a lost/reordered frame -> the SN check errors out
		// cleanly). The target's ring stays FROZEN after a dump, so re-issuing op_dump simply
		// re-streams the same block — retry a couple of times and SURFACE the error text
		// (it names the cause: SN gap vs wrong PCI vs timeout) instead of swallowing it.
		mut block := []u8{}
		mut have := false
		for attempt in 0 .. 3 {
			block = ch.recv(1000) or {
				recv_err = err.msg()
				if attempt < 2 {
					// a stale stream (a previous timed-out dump still trickling CFs) makes the
					// next recv join mid-stream ('unexpected PCI 0x2x') — drain until the bus is
					// quiet on the record id, then re-issue the dump (the frozen ring re-streams).
					ch.drain_quiet(150)
					a.tx_on(iface, transport.CanFrame{
						id:       f.cmd
						extended: cmd_ext
						data:     telem.encode_trace_cmd(telem.op_dump, telem.filter_all, core_mask)
					})
				}
				continue
			}
			have = true
			break
		}
		if !have {
			break // no more blocks (or the transfer kept failing — recv_err says why)
		}
		got++
		// Decoding lives in the engine (telem.decode_block), not here: the epoch re-anchor and the
		// cross-core clock offset decide what a dump MEANS, so the Trace Chart and the headless
		// cmd/trace_dump must not each interpret them. It is also where those rules are tested.
		b := telem.decode_block(block)
		if !b.more {
			last_seen++ // this core's final block
		}
		if b.skew_known {
			skew_bounds[b.core] = b.skew_bound_us
		}
		for br in b.records {
			recs << TRec{
				ch:     0
				core:   b.core
				abs_us: br.abs_us
				rec:    br.rec
			}
		}
	}
	a.mu.lock()
	a.trecs = synthesize_idle(recs)
	a.rev++
	a.trace_recording = false // the dump froze the buffer; Record re-arms for a new window
	// Say plainly whether the cores share a timeline. With >1 core and no measured offset the
	// lanes are each on their own clock, and reading across them is meaningless — never let that
	// pass silently, it renders identically to a correlated dump.
	sync_note := if ncores < 2 {
		''
	} else if skew_bounds.len == 0 {
		' · ⚠ cores NOT time-correlated (each on its own clock)'
	} else {
		mut worst := u16(0)
		for _, b in skew_bounds {
			if b > worst {
				worst = b
			}
		}
		' · ${skew_bounds.len}/${ncores - 1} satellite core(s) time-corrected (±${worst} µs)'
	}
	a.trace_status = if last_seen < ncores && recv_err != '' {
		'dumped ${got} block(s), ${last_seen}/${ncores} cores complete · ${recs.len} records${sync_note} · last error: ${recv_err}'
	} else {
		'dumped ${got} block(s) from ${ncores} core(s) · ${recs.len} records${sync_note}'
	}
	a.mu.unlock()
	a.trace_done()
}

// shell_worker sends one command line and collects the response. Mirrors diag/trace workers:
// a single-flight busy flag, a short-lived spawn, a blocking ISO-TP recv, results under mu +
// wake. The shell ids come from the manifest's `# shell frames` section (or loom2v defaults).
fn shell_worker(app &App, line string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.shell_busy {
		a.mu.unlock()
		return
	}
	a.shell_busy = true
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.shell_busy = false
		a.mu.unlock()
		vgui.wake()
	}
	a.shell_append('> ' + line)
	iface := a.trace_iface()
	if iface == '' {
		a.shell_append('(no running channel)')
		return
	}
	if line.len > 8 {
		a.shell_append('(line too long — the target takes one 8-byte frame per command)')
		return
	}
	sh := a.manifest.shell.or_defaults()
	// the host is the ISO-TP receiver: flow control out on `fc`, the response in on `out`
	// (opened before the command is sent, so the socket buffers the target's first frame).
	tapped := a.open_tap(iface, org_tx) or {
		a.shell_append('(open ${iface}: ${err})')
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), sh.fc, sh.out, trace_ext(sh.out)) or {
		a.shell_append('(open ${iface}: ${err})')
		return
	}
	defer {
		ch.close()
	}
	if !a.tx_on(iface, transport.CanFrame{
		id:       sh.input
		extended: trace_ext(sh.input)
		data:     line.bytes()
	}) {
		a.shell_append('(send failed on ${iface})')
		return
	}
	rsp := ch.recv(1500) or {
		a.shell_append('(no response: ${err})')
		return
	}
	a.shell_append(rsp.bytestr().trim_right('\n'))
}

// flash_worker runs the whole download session off-thread (the trace-dump
// pattern): open a dedicated ISO-TP channel to the BOOT ids and drive
// flash.program. The target must already be in its boot manager — the
// panel's "enter boot" button gets it there (the app's shell `boot` command;
// no reply, the reset is the ack).
fn flash_worker(app &App, path string, base u32, req_id u32, rsp_id u32, ver u32) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.flash_busy {
		a.mu.unlock()
		return
	}
	a.flash_busy = true
	a.flash_done = 0
	a.flash_total = 0
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.flash_busy = false
		a.mu.unlock()
		vgui.wake()
	}
	iface := a.trace_iface()
	if iface == '' {
		a.flash_append('(no running channel)')
		return
	}
	image := os.read_bytes(path) or {
		a.flash_append('(read ${path}: ${err})')
		return
	}
	a.flash_append('> ${os.file_name(path)} -> ${iface} @0x${base.hex()}')
	tapped := a.open_tap(iface, org_tx) or {
		a.flash_append('(open ${iface}: ${err})')
		return
	}
	mut ch := isotp.on_bus(tapped, a.bitrate_iface(iface), req_id, rsp_id, trace_ext(rsp_id)) or {
		a.flash_append('(open ${iface}: ${err})')
		return
	}
	defer {
		ch.close()
	}
	mut sink := GuiFlashSink{
		app: a
	}
	// 0x29 tester seed: $BLOBLY_FLASH_SEED or the dev seed — same as cmd/flash, so
	// the panel authenticates against a secured boot instead of skipping 0x29.
	seed := flash.tester_seed(os.getenv('BLOBLY_FLASH_SEED')) or {
		a.flash_append('(BLOBLY_FLASH_SEED: ${err})')
		return
	}
	flash.program(mut ch, image, flash.Opts{ base: base, sw_version: ver, auth_seed: seed }, mut
		sink) or {
		a.flash_append('FAILED: ${err}')
		a.flash_append('(a cut transfer is safe: the boot refuses the torn image — fix and re-run)')
		return
	}
}

fn script_worker(app &App, path string) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.script_busy {
		a.dbc_readers-- // release the spawn-side reservation: we never read
		a.mu.unlock()
		return
	}
	a.script_busy = true
	a.script_log = []
	a.mu.unlock()
	// the reader slot was reserved by the SPAWNING thread (TOCTOU: this
	// worker may not schedule before an edit) — this side only releases it
	defer {
		a.mu.lock()
		a.dbc_readers--
		a.mu.unlock()
	}
	mut chans := []script.ChanInfo{}
	for ch in a.chans {
		// Disabled channels are NOT scriptable. The headless runner skips them when building
		// its channel list, so leaving them here meant the same script could reach an ECU the
		// project had explicitly switched off from the GUI, and report "unknown channel" for
		// it headlessly. For a DoIP channel that means dialing a TCP endpoint the user turned
		// off — and connecting to whatever else is listening there.
		if !ch.enabled {
			continue
		}
		// A DoIP channel we are SUPPOSED to host but could not is not scriptable either. The
		// bind failed because something else owns that endpoint, so uds.open() would dial that
		// process and a GUI script would pass against the wrong ECU — the failure the
		// synchronous bind exists to prevent, reached through the scripting side instead.
		if ch.doip && a.doip_host_failed(ch.name, ch.iface) {
			continue
		}
		mut sim_nodes := []project.NodeCfg{}
		for sc in a.sims {
			if sc.iface == ch.iface {
				sim_nodes << sc.nodes
			}
		}
		// The carrier comes from the PROJECT channel: the runtime Chan above carries a `doip`
		// flag but not the logical addresses, and a DoIP open needs both. Matched by name, the
		// same key the rest of the config editor uses.
		mut pch := project.Channel{}
		for c in a.proj.channels {
			if c.name == ch.name {
				pch = c
				break
			}
		}
		chans << script.ChanInfo{
			name:      ch.name
			iface:     a.bitrate_iface(ch.iface) // pcan/kvaser: @<bitrate> so scripts open right
			key_iface: ch.iface // faults key on the LOGICAL interface, not the opened string
			// This channel's OWN merged database. Handing every channel the first one meant a
			// real message on any other DBC was rejected as unknown, or a coincidentally named
			// message was accepted with the wrong signal metadata.
			db:      merge_dbs(ch.databases)
			nodes:   sim_nodes // so a fault that cannot take effect can be refused
			carrier: script.carrier_of(pch)
		}
	}
	mut env := script.new_env(chans) or {
		a.script_push('env init: ${err}')
		a.script_done()
		return
	}
	// A script IS the tester. Left on the default opener it would be the one emitter the trace
	// could not account for, and its frames would come back labelled as the device under test's.
	env.opener = fn [a] (iface string, chan_name string) !transport.Bus {
		// open_tap_on, not open_tap: the script picked a CHANNEL, and two channels can share one
		// interface — resolving it back from the interface would attribute the second's traffic
		// to the first.
		return a.open_tap_on(iface, org_tx, chan_name)
	}
	env.run_file(path) or { a.script_push('error: ${err}') }
	a.script_push('${env.passed()}/${env.total()} passed, ${env.failed()} failed')
	env.close()
	a.script_done()
}

// shell_worker_eth sends one command line as a SOME/IP REQUEST and renders
// the correlated response — the client half of the emb P3 RPC design
// (modules/someip RpcClient: one in flight, deadline, drain). The local
// socket binds the manifest peer\'s PORT: the board\'s static source filter
// accepts only its configured peer endpoint, and the WSL->LAN NAT path
// preserves a bound source port (the emb#158 bench recipe). Single-flight
// via the same shell_busy latch as the CAN worker.
fn shell_worker_eth(app &App, line string, target string, sip telem.SomeipIdent, method u16) {
	mut a := unsafe { app }
	a.mu.lock()
	if a.shell_busy {
		a.mu.unlock()
		return
	}
	a.shell_busy = true
	a.mu.unlock()
	defer {
		a.mu.lock()
		a.shell_busy = false
		a.mu.unlock()
		vgui.wake()
	}
	a.shell_append('> ' + line)
	if target == '' {
		a.shell_append('(enter the board ip first)')
		return
	}
	peer_port := sip.peer.all_after_last(':').int()
	bind_port := if peer_port > 0 { peer_port } else { 30491 }
	mut sock := vnet.listen_udp(':${bind_port}') or {
		a.shell_append('(bind :${bind_port}: ${err} — the board only answers its configured peer endpoint)')
		return
	}
	defer {
		sock.close() or {}
	}
	sock.set_read_timeout(100 * time.millisecond)
	addrs := vnet.resolve_addrs('${target}:${sip.port}', .ip, .udp) or {
		a.shell_append('(resolve ${target}: ${err})')
		return
	}
	a.mu.lock()
	last_session := a.eth_shell_session
	a.mu.unlock()
	mut cli := someip.RpcClient{
		service:    sip.service
		method:     method
		iface:      sip.version
		client_id:  0x0E01
		timeout_us: 1_500_000
		session:    last_session
	}
	sw := time.new_stopwatch()
	req := cli.send(line.bytes(), 0) or {
		a.shell_append('(client busy)')
		return
	}
	a.mu.lock()
	a.eth_shell_session = cli.session // burn it NOW: even a timeout never reuses it
	a.mu.unlock()
	sock.write_to(addrs[0], req) or {
		a.shell_append('(send: ${err})')
		return
	}
	mut buf := []u8{len: 65536} // one FULL UDP datagram: a truncated read would
	// fail the header-length check and read as a timeout, not as truncation
	want_src := addrs[0].str()
	for cli.state == .waiting {
		n, raddr := sock.read(mut buf) or {
			cli.poll(u64(sw.elapsed().microseconds()))
			continue
		}
		// only the dialed board may answer — on a shared bench another node
		// could otherwise forge matching correlation fields
		if raddr.str() == want_src {
			cli.on_datagram(buf[..n])
		}
		cli.poll(u64(sw.elapsed().microseconds()))
	}
	if cli.state == .done {
		a.shell_append(cli.result.payload.bytestr())
		return
	}
	if cli.result.timed_out {
		a.shell_append('(no response — board off, wrong ip, or the peer port is not ours after NAT)')
	} else {
		match cli.result.rc {
			0x03 { a.shell_append('(error: unknown method on the target)') }
			0x20 { a.shell_append("(denied — this build's mutate gate is closed)") }
			else { a.shell_append('(error rc 0x${cli.result.rc.hex()})') }
		}
	}
}
