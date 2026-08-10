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
		}
		if nodes.len > 0 {
			spawn sim_loop(ch.iface_with_bitrate(), db, nodes, ctl)
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
fn sim_loop(iface string, db candb.Database, nodes []project.NodeCfg, ctl &Ctl) {
	mut bus := transport.open(iface) or { return }
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
		sim.apply_injected(iface, mut engine)
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
