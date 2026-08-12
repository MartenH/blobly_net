// cmd/script — the headless script/test runner. It loads a project, brings the
// same engine the GUI uses up (per-channel buses, simulated ECUs + the native
// UDS server — driver-free on the in-process bus), then runs one or more Lua
// test scripts (modules/script) and reports pass/fail. Exits non-zero if any
// test fails, so it drops straight into CI.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v \
//       --project projects/sim-demo.blobnet tests/diag_basic.lua
//
// -enable-globals is required for the in-process bus (transport/inproc.v).
module main

import os
import time
import candb
import project
import transport
import isotp
import uds
import sim
import doip
import script

// Ctl is the shared run flag the simulation threads poll; set false to stop them.
struct Ctl {
mut:
	running bool = true
}


fn main() {
	mut proj_path := 'projects/sim-demo.blobnet'
	mut scripts := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--project', '-p' {
				i++
				if i < os.args.len {
					proj_path = os.args[i]
				}
			}
			else {
				scripts << a
			}
		}
		i++
	}
	if scripts.len == 0 {
		eprintln('usage: run [--project <file.blobnet>] <script.lua> [more.lua ...]')
		exit(2)
	}

	proj := project.load(proj_path) or {
		eprintln('cannot load project ${proj_path}: ${err}')
		exit(2)
	}
	println('project: ${proj.name}  (${proj_path})')

	// Build per-channel DBC catalogs + bring the simulation up on every enabled
	// channel that hosts simulated ECUs (exactly like the GUI's Start).
	mut ctl := &Ctl{}
	mut seeded_ifaces := []string{} // one set of diagnostic servers per physical bus
	// Entities to announce once the environment is ready — see below.
	mut announcers := []Announcer{}
	mut chans := []script.ChanInfo{}
	for ch in proj.channels {
		if !ch.enabled {
			continue
		}
		db := load_channel_db(ch, os.dir(proj_path))
		nodes := ch.all_nodes()
		chans << script.ChanInfo{
			name: ch.name
			// what a script OPENS with — carries the vendor bitrate
			iface: ch.iface_with_bitrate()
			// what faults are KEYED on — the logical interface, no suffix
			key_iface: ch.iface
			db:        db
			nodes:     nodes // so a fault that cannot take effect can be refused
			carrier:   script.carrier_of(ch)
		}
		// DoIP is a different carrier, not a CAN bus: no frames, no ISO-TP, and the entity is
		// reached by logical address over TCP. Nothing outside modules/doip ever started one,
		// so a `type: doip` channel printed "+ UDS server" while spawning a CAN responder on an
		// interface no CAN transport can open — the project documented an entity that was never
		// listening. Start the real thing here.
		if ch.is_doip() {
			if nodes.len == 0 {
				println('channel ${ch.name} (${ch.iface}): DoIP tester only (no simulated entity)')
				continue
			}
			host, port := ch.doip_endpoint()
			// Validate before serving, exactly as the CAN branch does. Without this a
			// malformed `uds:` block was dropped by uds_nodes() in silence and the built-in
			// default served in its place, so a suite could pass against the stock VIN while
			// believing it had read the configured ECU.
			for w in sim.validate_uds_doip(nodes) {
				eprintln('${ch.name}: ${w}')
			}
			// One decision, shared with the GUI (sim.doip_entity): which node is served, and
			// the single VIN both identity surfaces use. An entity that came up differently
			// depending on which side started it would make a bench result depend on how the
			// tool was launched.
			ent := sim.doip_entity(ch, nodes) or {
				eprintln('${ch.name}: ${err}')
				// ABORT, not continue. Leaving the channel in place let scripts dial the
				// endpoint anyway, and if another DoIP process holds it the suite passes
				// against that one — the wrong-ECU failure the bind check below prevents,
				// reached by skipping the bind entirely.
				eprintln('refusing to run: scripts would dial ${ch.name} and reach whatever else is there')
				exit(1)
			}
			if ent.extra > 0 {
				// One channel is one entity at one logical address, so extra UDS nodes have no
				// address to answer on. Say which one won rather than silently serving it.
				eprintln('${ch.name}: ${ent.extra + 1} UDS nodes on one DoIP entity; serving "${ent.node}" (0x${ch.ecu_addr:04X})')
			}
			mut srv := ent.server
			// Bind HERE, not inside the spawned worker. Reported only to stderr, a failed bind
			// left the run announcing an entity and carrying on — and if the port was held by
			// another DoIP process serving the same built-in defaults, uds.open would connect
			// to THAT and the suite would pass against the wrong ECU.
			mut entity := doip_listen(host, port, ent.cfg, srv) or {
				eprintln('${ch.name}: ${err}')
				eprintln('refusing to run: a suite would connect to whatever else is on ${host}:${port}')
				exit(1)
			}
			spawn doip_serve_loop(mut entity, ctl)
			// NOT announced here. The default sequence is 3 × 500ms and would be finished
			// before the Lua environment exists, so a suite could never observe it — the
			// documented "listen before they announce" was unachievable with the defaults, and
			// the announce fixture was only passing because it announces for four seconds.
			// Collected and fired once the environment is ready, below.
			announcers << Announcer{
				srv:  entity
				name: ch.name
			}
			println('channel ${ch.name} (doip:${host}:${port}): DoIP entity, logical address 0x${ch.ecu_addr:04X}')
			continue
		}
		if nodes.len > 0 {
			// BOTH: the suffixed string opens the transport, the logical one keys faults.
			// Passing only the suffixed form meant sim.apply_injected looked up
			// `pcan:…@250000` while sim.fault() had stored under `pcan:…`, so a scripted
			// fault on vendor hardware reported success and never reached the wire.
			spawn sim_loop(ch.iface_with_bitrate(), ch.iface, db, nodes, ctl)
			// Diagnostics are per BUS and decided ONCE. Skipping outright after the first
			// entry on an interface — rather than emptying the server list — is the difference
			// that matters: the emptied list fell through to the default branch and spawned a
			// SECOND 0x7E0 responder on a wire that already had one.
			if ch.iface in seeded_ifaces {
				println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s)')
			} else {
				seeded_ifaces << ch.iface
				// ENABLED channels only: a disabled entry sharing this interface must not
				// contribute servers, or a test observes an ECU it explicitly switched off.
				mut peers := []project.NodeCfg{}
				for other in proj.channels {
					if other.enabled && other.iface == ch.iface {
						peers << other.all_nodes()
					}
				}
				for w in sim.validate_uds(peers) {
					eprintln('${ch.name}: ${w}')
				}
				mut servers := sim.uds_nodes(peers)
				// Same hazard as the DoIP branch: falling back to the built-in server when
				// every CONFIGURED one was rejected makes a broken project look like a working
				// ECU. Only an absence of `uds:` blocks earns the default.
				mut declared := 0
				for p in peers {
					if _ := p.uds {
						declared++
					}
				}
				if servers.len == 0 && declared > 0 {
					eprintln('${ch.name}: all ${declared} configured UDS node(s) rejected — not starting the default server in their place')
					println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s), NO UDS server (bad uds config)')
					continue
				}
				if servers.len == 0 {
					spawn diag_server_loop(ch.iface_with_bitrate(), ctl)
					println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + UDS server')
				} else {
					for mut u in servers {
						spawn uds_node_loop(ch.iface_with_bitrate(), u.rx, u.tx, u.ext, u.server, ctl)
					}
					println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + ${servers.len} UDS target(s)')
				}
			}
		} else {
			println('channel ${ch.name} (${ch.iface}): monitor only')
		}
	}
	// Let the sims start emitting / the UDS server start polling before scripts run.
	time.sleep(150 * time.millisecond)
	// NOW announce: the entities have been listening since bind, and a suite that starts a
	// doip.listen() in its first lines can actually catch the sequence. A real ECU announces
	// when it comes up; from outside this process that is still what this looks like.
	for mut a in announcers {
		spawn doip_announce(mut a.srv, a.name)
	}

	mut env := script.new_env(chans) or {
		eprintln('script env init failed: ${err}')
		exit(2)
	}

	mut errored := 0
	for s in scripts {
		println('\n=== ${s} ===')
		env.run_file(s) or {
			eprintln('  ERROR running ${s}: ${err}')
			errored++
		}
	}

	ctl.running = false
	passed := env.passed()
	failed := env.failed()
	env.close()

	println('\n${passed} passed, ${failed} failed, ${errored} script error(s)')
	if failed > 0 || errored > 0 {
		exit(1)
	}
}

// load_channel_db merges every DBC attached to a channel into one catalog (first
// definition of an id wins) — a GUI-free slice of src/main.v's load_databases.
// load_channel_db delegates to candb.merge_files — see the GUI's merge_dbs. Having one merge
// each is how the same project came to mean two different databases.
fn load_channel_db(ch project.Channel, proj_dir string) candb.Database {
	// Resolved against the PROJECT's directory, exactly as the GUI does. runtests.sh changes to
	// the repository root before running, so a project kept anywhere else had its relative
	// `databases:` entries opened as written — the load failed, the database came back empty,
	// and the simulation transmitted nothing with no error anywhere.
	return candb.merge_files(ch.databases.map(project.resolve_asset(proj_dir, it)))
}

// sim_loop runs the channel's simulated ECUs on a dedicated in-process bus
// instance (driver-free twin of src/main.v's sim_loop, minus the GUI).
fn sim_loop(open_iface string, fault_iface string, db candb.Database, nodes []project.NodeCfg, ctl &Ctl) {
	mut bus := transport.open(open_iface) or { return }
	mut engine := sim.Engine{}
	for n in nodes {
		engine.ecus << build_node(db, n)
	}
	t0 := time.ticks()
	for ctl.running {
		// Re-stamped every pass, so a fault a script injects mid-run takes effect on the next
		// frame rather than at the next rebuild — which for the headless runner never comes.
		// The elapsed time ages timed faults; without it "drop for 500 ms" drops forever.
		// The table owns its own clock, so calling this from every bus loop is safe.
		sim.apply_injected(fault_iface, mut engine)
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

// diag_server_loop answers UDS requests (rx 0x7E0 / tx 0x7E8) over software
// ISO-TP on the channel's bus, until stopped.
// uds_node_loop answers one simulated ECU's diagnostic requests on its own addresses.
fn uds_node_loop(iface string, rx u32, tx u32, ext bool, srv uds.Server, ctl &Ctl) {
	mut ch := isotp.open_software(iface, tx, rx, ext) or { return }
	mut s := srv
	for ctl.running {
		req := ch.recv(50) or { continue }
		resp := s.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

// doip_listen binds one simulated DoIP entity: the same uds.Server the CAN path serves,
// behind a real TCP listener plus the UDP socket that answers discovery. Synchronous, so the
// caller learns about a bind failure before any test runs.
fn doip_listen(host string, port int, cfg doip.ServerCfg, srv uds.Server) !&doip.DoipServer {
	// sim.DoipHost owns the wire policy, so the GUI cannot drift from it.
	mut hst := &sim.DoipHost{
		server: srv
	}
	handler := fn [mut hst] (req []u8) []u8 {
		return hst.handle(req)
	}
	mut s := doip.new_server(cfg, handler)
	hst.entity = s
	s.listen(host, port) or { return error('DoIP listen ${host}:${port} failed: ${err}') }
	return s
}

// Announcer is one bound entity waiting to announce, held until the script environment exists.
struct Announcer {
mut:
	srv  &doip.DoipServer
	name string
}

// doip_announce sends the power-on announcements, reporting a failure rather than dropping it.
fn doip_announce(mut s doip.DoipServer, name string) {
	s.announce() or { eprintln('${name}: announce failed: ${err}') }
}

// doip_serve_loop runs an already-bound entity until Stop.
fn doip_serve_loop(mut s doip.DoipServer, ctl &Ctl) {
	spawn doip_udp_loop(mut s, ctl)
	for ctl.running {
		// A timeout is the normal case (no tester connected), not a failure.
		s.accept_and_serve(200) or { continue }
	}
	s.close()
}

// doip_udp_loop answers vehicle-identification requests, so Discover finds the entity.
fn doip_udp_loop(mut s doip.DoipServer, ctl &Ctl) {
	for ctl.running {
		s.serve_udp_once(200) or { continue }
	}
}

fn diag_server_loop(iface string, ctl &Ctl) {
	// Server side: transmit responses on 0x7E8, receive requests on 0x7E0
	// (the mirror of the tester's tx 0x7E0 / rx 0x7E8).
	mut ch := isotp.open_software(iface, 0x7E8, 0x7E0, false) or { return }
	mut srv := uds.default_server()
	for ctl.running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

// build_node delegates to sim.from_project. This used to be a copy of the GUI's builder
// ("mirror src/main.v"), which is how end-to-end protection reached the GUI and not this
// runner — the one CI and runtests.sh use, so a protected project would have been scored
// against unprotected traffic.
fn build_node(db candb.Database, cfg project.NodeCfg) sim.SimEcu {
	// A protect: entry naming a message or signal that is not there applies nothing, and the
	// run would otherwise score a protected project against unprotected traffic without a word.
	for w in sim.validate_cfg(db, cfg) {
		eprintln('${cfg.name}: ${w}')
	}
	return sim.from_project(db, cfg)
}
