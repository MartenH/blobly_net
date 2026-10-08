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
import sysview
import doip
import script
import testports
import sync.stdatomic

// loops_done counts the bus-holding loops that have exited, so the runner's bounded wait at the
// end knows whether every wire has said its piece (#213).
__global (
	loops_done i64
)

// Ctl is the shared run flag the simulation threads poll; set false to stop them.
struct Ctl {
mut:
	running bool = true
}

fn main() {
	mut proj_path := 'projects/sim-demo.blobnet'
	mut explicit := '' // --project as given, distinct from the default above
	mut project_ports := false // --project-ports: host DoIP entities on the ports the project states
	mut scripts := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--project', '-p' {
				i++
				if i < os.args.len {
					explicit = os.args[i]
					proj_path = explicit
				}
			}
			'--project-ports' {
				project_ports = true
			}
			else {
				scripts << a
			}
		}

		i++
	}
	if scripts.len == 0 {
		eprintln('usage: run [--project <file.blobnet>] [--project-ports] <script.lua> [more.lua ...]')
		exit(2)
	}

	// A test that needs a particular project says so in its own head; script.agree decides what
	// that means here, and refuses a run it cannot make true rather than producing failures that
	// read as broken features (#115). See modules/script/project_decl.v.
	mut decls := []script.Decl{}
	for s in scripts {
		if d := script.declaration_of(s) {
			decls << d
		}
	}
	chosen := script.agree(decls, explicit) or {
		eprintln('cannot decide which project to run: ${err}')
		exit(2)
	}
	if chosen != '' {
		proj_path = chosen
	}

	// The pre-v4 `bus:` migration says what it converted; stderr here, as the database reader's
	// notes are (#97).
	mut proj := project.load(proj_path) or {
		eprintln('cannot load project ${proj_path}: ${err}')
		exit(2)
	}
	println('project: ${proj.name}  (${proj_path})')
	for n in proj.notes {
		eprintln('${proj_path}: ${n}')
	}
	// The run's simulated loopback DoIP entities move off the project's ports (13400 in every
	// demo) onto ports this process can bind, and every row dialing them moves with them, so two
	// runs on one machine do not collide (#411). Held until each entity binds, below.
	// Each host is resolved ONCE, here, and that address is what is probed, matched, written into
	// the moved rows and bound (#416). Kept as the project writes them, entities bind their own
	// spelling, which the listen resolves once.
	mut probes := &testports.Holder{}
	if !project_ports {
		hosts := project.resolve_doip_hosts(proj.channels, transport.bind_address)
		band := testports.doip_entities
		moves := project.choose_doip_ports(project.doip_hosting(proj.channels, hosts),
			project.reserved_ports(proj.channels), band.candidates(), mut probes) or {
			eprintln('cannot host the DoIP entities: ${err} in ${band.base}..${band.last()}; --project-ports keeps the project\'s')
			exit(1)
		}
		chs, notes := project.with_doip_ports(proj.channels, moves, hosts)
		proj.channels = chs
		for n in notes {
			println(n)
		}
	}

	// Build per-channel DBC catalogs + bring the simulation up on every enabled
	// channel that hosts simulated ECUs (exactly like the GUI's Start).
	mut ctl := &Ctl{}
	mut seeded_ifaces := []string{} // one set of diagnostic servers per physical bus
	// Entities to announce once the environment is ready — see below.
	mut announcers := []Announcer{}
	mut chans := []script.ChanInfo{}
	// THE WHOLE PROJECT, before anything is spawned. Per row, this missed the case that matters:
	// a normal row hosting simulated nodes beside a listen-only alias of the SAME wire, where
	// the silenced row never opens a bus here and the simulation therefore drove a channel the
	// project had asked to keep quiet. And the runner had no rate check at all, so two aliases
	// disagreeing about the bitrate configured the hardware from whichever spawned first.
	dest := project.check_destinations(proj.channels)
	// SAID BEFORE THE REFUSALS, so it is not lost when one of them exits. A row the driver would
	// not describe is a gap in the alias check rather than a fault, and the headless runner had no
	// way to mention it at all (codex #199 r1).
	for w in dest.warnings {
		eprintln('${w}')
	}
	for problem in dest.problems {
		// The summary used to name the two kinds this check had ("one wire, one mode and one
		// rate"). #167 added a third — two application channels assigned to one physical
		// channel — which that phrase does not cover, and each problem already says what it is.
		eprintln('${problem} — not starting')
		exit(1)
	}
	// Through the same call the GUI makes, for the reason the block above exists: one policy, and
	// the two front ends must not each keep their own reading of it. A WARNING, not a refusal —
	// see project.fd_capability_warnings.
	// Every loop that holds a wire -- simulated ECUs and diagnostic responders -- joined at the
	// end so what their wires counted is booked and printed before the summary rather than
	// racing the exit (#213, codex round 4 on #231).
	mut sims := []thread{}
	for w in project.fd_capability_warnings(proj.channels) {
		eprintln('warning: ${w}')
	}
	// NOT someip_endpoint_warnings HERE. That warning is about rows this front end BINDS, and
	// the headless runner binds none: a SOME/IP row is a declaration a suite may listen on by
	// name, one window at a time, and the claim registry refuses a second. Emitting it here told
	// a suite that uses one row — or neither — to go and change a configuration that is correct
	// for the way it runs. The GUI, which does start every row, still warns.
	// Which wires may transmit, through the same call the GUI makes. The runner honoured
	// listen-only nowhere before #117: `bus.send` from a script reached the wire whatever the
	// project said, and a simulated node on a silenced row transmitted at its own cadence.
	project.apply_listen_only(proj.channels)
	// every row's databases loaded once, by ROW: the channel loop and the generators below both
	// ask, and a row a generator targets need not be one the loop loaded
	mut row_dbs := map[int]candb.Database{}
	run_t0 := time.sys_mono_now() // the ONE epoch every generator's time-based source runs from
	// the description the simulated diagnostic servers answer by (sim.describe): the system.toml
	// the GUI's Diagnostics panel would read for this project
	desc_sys := described_system(proj_path, proj)
	for ci, ch in proj.channels {
		if !ch.enabled {
			continue
		}
		db := row_db(mut row_dbs, proj.channels, ci, os.dir(proj_path))
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
		if ch.is_someip() {
			// A listener endpoint: no bus to open, no entity to host. Scripts reach it through
			// someip.listen({ from = name }), which binds it for the window it asks for.
			host, port := ch.someip_endpoint()
			grp := if ch.group != '' { ', group ${ch.group}' } else { '' }
			println('channel ${ch.name} (someip:${host}:${port}${grp}): SOME/IP listener — someip.listen(1500, { from = "${ch.name}" })')
			continue
		}
		if ch.is_doip() {
			if !ch.hosts_doip_entity() {
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
			ent := sim.doip_entity_described(ch, nodes, &desc_sys) or {
				eprintln('${ch.name}: ${err}')
				// ABORT, not continue. Leaving the channel in place let scripts dial the
				// endpoint anyway, and if another DoIP process holds it the suite passes
				// against that one — the wrong-ECU failure the bind check below prevents,
				// reached by skipping the bind entirely.
				eprintln('refusing to run: scripts would dial ${ch.name} and reach whatever else is there')
				exit(1)
			}
			for n in ent.notes {
				eprintln('${ch.name}: ${n}')
			}
			if ent.extra > 0 {
				// One channel is one entity at one logical address, so extra UDS nodes have no
				// address to answer on. Say which one won rather than silently serving it.
				eprintln('${ch.name}: ${ent.extra + 1} UDS nodes on one DoIP entity; serving "${ent.node}" (0x${ch.ecu_addr:04X})')
			}
			mut srv := ent.server
			probes.release(port)
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
			sims << spawn sim_loop(ch.iface_with_bitrate(), ch.iface, ch.name, db, nodes, ctl)
			// Diagnostics are per BUS and decided ONCE. Skipping outright after the first
			// entry on an interface — rather than emptying the server list — is the difference
			// that matters: the emptied list fell through to the default branch and spawned a
			// SECOND 0x7E0 responder on a wire that already had one.
			// BY DESTINATION, as the GUI does. Two spellings of one wire each seeded their own
			// diagnostics, so a headless run got two built-in responders answering 0x7E0/0x7E8
			// at once — a bus with two ECUs claiming one identity, in the runner that is
			// supposed to be the reproducible one.
			ch_dest := transport.destination_key_for(ch.adapter, ch.iface)
			if ch_dest in seeded_ifaces {
				println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s)')
			} else {
				seeded_ifaces << ch_dest
				// ENABLED channels only: a disabled entry sharing this interface must not
				// contribute servers, or a test observes an ECU it explicitly switched off.
				mut peers := []project.NodeCfg{}
				mut owners := []string{} // each peer's channel, by position
				for other in proj.channels {
					if other.enabled
						&& transport.destination_key_for(other.adapter, other.iface) == ch_dest {
						for n in other.all_nodes() {
							peers << n
							owners << other.name
						}
					}
				}
				for w in sim.validate_uds(peers) {
					eprintln('${ch.name}: ${w}')
				}
				mut servers := sim.uds_nodes(peers)
				for n in sim.describe_uds_nodes(&desc_sys, mut servers, peers, owners, ch.iface) {
					eprintln('${ch.name}: ${n}')
				}
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
					dflt := sim.describe_default(&desc_sys, ch.name, ch.iface, 0x7E0, 0x7E8)
					for n in dflt.notes {
						eprintln(n)
					}
					sims << spawn diag_server_loop(ch.iface_with_bitrate(), dflt.server, ctl)
					println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + UDS server')
				} else {
					for mut u in servers {
						sims << spawn uds_node_loop(ch.iface_with_bitrate(), u.rx, u.tx, u.ext,
							u.functional, u.fext, u.server, ctl)
					}
					println('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + ${servers.len} UDS target(s)')
				}
			}
		} else {
			println('channel ${ch.name} (${ch.iface}): monitor only')
		}
	}
	probes.release_all()
	// Cyclic generators (`senders:` with trigger: cyclic), sent while the run lasts as the GUI
	// sends them during a measurement, by the GUI's rules: every row's generators (a disabled
	// row's too — its generator may target an enabled channel), sent only where a target row is
	// still in the run or the target is a wire no row configures, with the target rows'
	// databases. Without it a project behaved differently headless.
	for w in project.sender_bus_warnings(proj.channels) {
		eprintln(w)
	}
	for w in project.generator_source_warnings(proj.channels) {
		eprintln(w)
	}
	for ci, ch in proj.channels {
		if ch.is_doip() || ch.is_someip() {
			continue
		}
		for s in ch.senders {
			if s.trigger != 'cyclic' || s.cycle_ms <= 0 {
				continue
			}
			sb := project.resolve_sender_bus(s.bus, ch, proj.channels)
			if sb.iface == '' {
				eprintln('${ch.name}: generator "${s.name}": ${sb.note} — not sent')
				continue
			}
			rows := project.sender_target_rows(sb, ci, proj.channels)
			enabled := rows.filter(proj.channels[it].enabled)
			if rows.len > 0 && enabled.len == 0 {
				continue // every row on its target has left the run: nothing is sent there
			}
			open_iface := if enabled.len > 0 {
				proj.channels[enabled[0]].iface_with_bitrate()
			} else {
				sb.iface
			}
			mut sdb := []candb.Database{}
			for r in rows {
				sdb << row_db(mut row_dbs, proj.channels, r, os.dir(proj_path))
			}
			sims << spawn sender_loop(open_iface, s, sdb, run_t0, ctl)
			println('channel ${ch.name}: cyclic generator "${s.name}" every ${s.cycle_ms} ms on ${sb.iface}')
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
	// Joined BEFORE the script's buses are asked: a responder that fell behind books its gap
	// at its close, into the wire, where the script's own handle then reads it. BOUNDED: a
	// loop stuck in a stalled CANsub write cannot re-check ctl.running until the write returns,
	// and the transport confines a stalled write to its sender on purpose -- the runner must
	// not inherit its timeout (codex round 6 on #231). Loops still running when the bound
	// expires are left to the exit; what they would have booked is not reported.
	wait_until := time.ticks() + 2000
	for stdatomic.load_i64(&loops_done) < i64(sims.len) && time.ticks() < wait_until {
		time.sleep(10 * time.millisecond)
	}
	if stdatomic.load_i64(&loops_done) < i64(sims.len) {
		eprintln('${sims.len - int(stdatomic.load_i64(&loops_done))} bus loop(s) still busy at exit; their wires are not reported')
	}
	// And what the script's own buses and connections counted (#213). EACH HANDLE REPORTS
	// ITSELF, here and in the loops above at their close: on a shared wire every handle answers
	// with the wire's totals, reconciled for every subscriber at the asking; on a backend that
	// fans out natively each handle counts what it consumed. A separate reporting handle was
	// tried and was wrong both ways -- it had to drain to see anything on the one kind and
	// was itself a dropping subscriber on the other (codex rounds 8-11 on #231).
	for name, d in env.close_reporting() {
		eprintln('${name}: ${d.str()}')
	}
	passed := env.passed()
	failed := env.failed()

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
	db, notes := candb.merge_files_report(ch.databases.map(project.resolve_asset(proj_dir, it)))
	// what could not be opened, and what the ARXML reader had to skip: on stderr, because a
	// refused database otherwise surfaces as failing tests with no line saying why
	for n in notes {
		eprintln('${ch.name}: ${n}')
	}
	return db
}

// sim_loop runs the channel's simulated ECUs on a dedicated in-process bus
// instance (driver-free twin of src/main.v's sim_loop, minus the GUI).
fn sim_loop(open_iface string, fault_iface string, chan_name string, db candb.Database, nodes []project.NodeCfg, ctl &Ctl) {
	// Counted done on EVERY way out, an open that fails included -- a loop that returned
	// before counting itself left the runner's bounded wait waiting for it (codex round 7 on
	// #231).
	defer {
		stdatomic.add_i64(&loops_done, 1)
	}
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
		sim.publish_live(fault_iface, chan_name, &engine) // what a described server's live DIDs read
		if frame := bus.recv(5) {
			for resp in engine.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
	// CLOSED FIRST: a shared handle's close books the last gap its cursor lost, and a closed
	// handle still answers with the wire's totals (codex round 12 on #231).
	bus.close()
	report_diag('${open_iface} (sim)', bus.diagnostics())
}

// row_db is row `i`'s databases, loaded (and its reader notes printed) once.
fn row_db(mut cache map[int]candb.Database, chs []project.Channel, i int, proj_dir string) candb.Database {
	if db := cache[i] {
		return db
	}
	db := load_channel_db(chs[i], proj_dir)
	cache[i] = db
	return db
}

// sender_loop sends one cyclic generator's frame every `cycle_ms` until stopped — the headless
// counterpart of the GUI's gen_loop, building the frame with the same sim.sender_message_frame.
// The send index counts DELIVERED frames only, as the GUI's does, so a counter source never
// skips a value a refused send did not put on the wire.
fn sender_loop(iface string, s project.Sender, dbs []candb.Database, run_t0 u64, ctl &Ctl) {
	defer {
		stdatomic.add_i64(&loops_done, 1)
	}
	mut bus := transport.open(iface) or {
		eprintln('generator "${s.name}": cannot open ${iface}: ${err}')
		return
	}
	mut n := 0
	mut next := time.ticks()
	for ctl.running {
		now := time.ticks()
		if now < next {
			time.sleep(time.Duration(i64(if next - now > 20 { 20 } else { next - now }) * time.millisecond))
			continue
		}
		next += s.cycle_ms
		if next < now {
			next = now + s.cycle_ms // a stall does not become a burst of catch-up frames
		}
		el := f64(time.sys_mono_now() - run_t0) / 1_000_000_000.0
		frame := if s.message != '' {
			sim.sender_message_frame(s, dbs, n, el) or {
				eprintln('generator "${s.name}": message "${s.message}" not in the channel databases — not sent')
				break
			}
		} else {
			transport.CanFrame{
				id:       s.id
				extended: s.ext
				data:     s.data.clone()
			}
		}
		bus.send(frame) or { continue }
		n++
	}
	bus.close()
	report_diag('${iface} (generator ${s.name})', bus.diagnostics())
}

// diag_server_loop answers UDS requests (rx 0x7E0 / tx 0x7E8) over software
// ISO-TP on the channel's bus, until stopped.
// uds_node_loop answers one simulated ECU's diagnostic requests on its own addresses.
fn uds_node_loop(iface string, rx u32, tx u32, ext bool, fid u32, fext bool, srv uds.Server, ctl &Ctl) {
	// Counted done on EVERY way out, an open that fails included -- a loop that returned
	// before counting itself left the runner's bounded wait waiting for it (codex round 7 on
	// #231).
	defer {
		stdatomic.add_i64(&loops_done, 1)
	}
	mut ch := isotp.open_software(iface, tx, rx, ext) or { return }
	// a run worker: Stop abandons an answer still being segmented (#347)
	ch.stop_requested = fn [ctl] () bool {
		return !ctl.running
	}
	mut link := uds.NodeLink{
		phys: ch
	}
	if fid != 0 {
		// one functional listener per wire, shared by every node answering on it. Failing to
		// open it costs the broadcasts, not the ECU: physical requests are still served.
		if f := uds.functional_join(iface, fid, fext, fn [iface] () !transport.Bus {
			return transport.open(iface)!
		})
		{
			link.func << f
		} else {
			eprintln('${iface}: uds node 0x${rx:X} cannot listen on functional id 0x${fid:X}: ${err} — physical requests only')
		}
	}
	mut s := srv
	for ctl.running {
		s.serve_step(mut link, 50) or { time.sleep(50 * time.millisecond) }
	}
	fdiags := link.close()
	report_diag('${iface} (uds node)', ch.diagnostics()) // after the close: see sim_loop
	for d in fdiags {
		report_diag('${iface} (uds node 0x${rx:X}, functional 0x${fid:X} queue)', transport.BusDiagnostics{
			dropped: d.queue_dropped
		})
		if wd := d.wire {
			report_diag('${iface} (functional listener)', wd)
		}
	}
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

fn diag_server_loop(iface string, server uds.Server, ctl &Ctl) {
	// Counted done on EVERY way out, an open that fails included -- a loop that returned
	// before counting itself left the runner's bounded wait waiting for it (codex round 7 on
	// #231).
	defer {
		stdatomic.add_i64(&loops_done, 1)
	}
	// Server side: transmit responses on 0x7E8, receive requests on 0x7E0
	// (the mirror of the tester's tx 0x7E0 / rx 0x7E8).
	mut ch := isotp.open_software(iface, 0x7E8, 0x7E0, false) or { return }
	ch.stop_requested = fn [ctl] () bool {
		return !ctl.running
	}
	mut srv := server
	for ctl.running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
	report_diag('${iface} (uds server)', ch.diagnostics()) // after the close: see sim_loop
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

// described_system is the system.toml sysview.find_system finds for the project, loaded; an empty
// model, which describes nothing, when there is none.
fn described_system(proj_path string, proj project.Project) sysview.System {
	mut refs := []string{}
	for c in proj.channels {
		refs << c.databases
	}
	path := sysview.find_system(proj_path, refs) or { return sysview.System{} }
	sys := sysview.load(path) or {
		eprintln('${path} could not be read (${err}); simulated servers answer from the project')
		return sysview.System{}
	}
	println('described: ${path}')
	return sys
}

// report_diag prints what one handle counted that no frame carried, if anything (#213).
fn report_diag(what string, d transport.BusDiagnostics) {
	if !d.is_empty() {
		eprintln('${what}: ${d.str()}')
	}
}
