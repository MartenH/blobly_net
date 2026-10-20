// headless — a project brought up WITHOUT the GUI: the per-channel databases, the simulated
// ECUs and their UDS servers, the cyclic generators and the DoIP entities a `.blobnet` describes,
// running until stopped. `cmd/script` is one caller (argv, then Lua over it); a Python binding is
// the next. It is the headless twin of the GUI's Start (`cmd/blobly_net/run.v`), which keeps its
// own bring-up because it owns rows, readers and a trace; what the two share is in `project` and
// `sim` and must stay there — the rules are called through the same functions on both sides.
//
// Every refusal is an error from `start`, never an exit, and a refusal reached after some loops
// were spawned stops them first: a library caller gets a Run or nothing.
module headless

import os
import time
import blobly.candb
import blobly.project
import blobly.transport
import blobly.isotp
import blobly.uds
import blobly.sim
import blobly.sysview
import blobly.doip
import blobly.testports
import sync.stdatomic

// Options is what a caller decides about a run.
pub struct Options {
pub:
	// host the DoIP entities on the ports the project states, rather than moving them onto ports
	// this process can bind (#411) — the headless runner's --project-ports
	project_ports bool
	// progress and warnings: what the runner printed on stdout and stderr. Called from the run's
	// worker threads as well as from `start` — a sink must take that — and never after `stop`
	// has returned, which waits for every loop that could call them.
	out fn (string) = fn (s string) {
		println(s)
	}
	err fn (string) = fn (s string) {
		eprintln(s)
	}
}

// Channel is one enabled row of the project with its databases loaded — what a script OPENS with
// is `cfg.iface_with_bitrate()`, what faults are KEYED on `cfg.iface`, the nodes a fault may
// name `cfg.all_nodes()`: answered by the row, not copied beside it.
pub struct Channel {
pub:
	cfg project.Channel
	db  candb.Database
}

// Ctl is the shared run flag the simulation threads poll; set false to stop them.
struct Ctl {
mut:
	running bool = true
}

// Run is a project brought up; `stop` ends it.
@[heap]
pub struct Run {
mut:
	ctl &Ctl
	// the loops spawned and the loops that have exited — every one counted on its way out, so
	// stop's bounded wait knows whether every wire has said its piece (#213); the serve loop
	// spawns the UDP loop from its own thread, so both counts are atomic
	spawned    i64
	loops_done i64
	err        fn (string) @[required]
pub:
	path string
	// the project as the run uses it: the DoIP rows moved onto this process's ports
	proj project.Project
pub mut:
	// the enabled rows, in project order; filled by start, read after
	chans []Channel
}

// load reads the project a run starts from, its notes said — the pre-v4 `bus:` migration says
// what it converted, as the database reader's notes are (#97). Apart from `start` so a caller
// can tell a project that cannot be read from a run that was refused.
pub fn load(proj_path string, o Options) !project.Project {
	proj := project.load(proj_path) or { return error('cannot load project ${proj_path}: ${err}') }
	o.out('project: ${proj.name}  (${proj_path})')
	for n in proj.notes {
		o.err('${proj_path}: ${n}')
	}
	return proj
}

// start brings a loaded project up: refused with the first problem, and nothing is left running
// on a refusal.
pub fn start(loaded project.Project, proj_path string, o Options) !&Run {
	mut proj := loaded
	// The run's simulated loopback DoIP entities move off the project's ports (13400 in every
	// demo) onto ports this process can bind, and every row dialing them moves with them, so two
	// runs on one machine do not collide (#411). Held until each entity binds, below.
	// Each host is resolved ONCE, here, and that address is what is probed, matched, written into
	// the moved rows and bound (#416). Kept as the project writes them, entities bind their own
	// spelling, which the listen resolves once.
	mut probes := &testports.Holder{}
	if !o.project_ports {
		hosts := project.resolve_doip_hosts(proj.channels, transport.bind_address)
		band := testports.doip_entities
		moves := project.choose_doip_ports(project.doip_hosting(proj.channels, hosts),
			project.reserved_ports(proj.channels), band.candidates(), mut probes) or {
			return error("cannot host the DoIP entities: ${err} in ${band.base}..${band.last()}; Options.project_ports keeps the project's")
		}
		chs, notes := project.with_doip_ports(proj.channels, moves, hosts)
		proj.channels = chs
		for n in notes {
			o.out(n)
		}
	}

	mut r := &Run{
		ctl:  &Ctl{}
		err:  o.err
		path: proj_path
		proj: proj
	}
	r.bring_up(o, mut probes) or {
		// what was spawned before the refusal, and the candidate ports still held for entities
		// that never bound — the runner's exit closed those; a library caller's next start
		// would find them taken
		probes.release_all()
		r.stop()
		return err
	}
	return r
}

// bring_up spawns the run's loops; what it spawned before a refusal is the caller's to stop.
fn (mut r Run) bring_up(o Options, mut probes testports.Holder) ! {
	proj := r.proj
	proj_path := r.path
	mut seeded_ifaces := []string{} // one set of diagnostic servers per physical bus
	// Entities to announce once the environment is ready — see below.
	mut announcers := []Announcer{}
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
		o.err('${w}')
	}
	for problem in dest.problems {
		// The summary used to name the two kinds this check had ("one wire, one mode and one
		// rate"). #167 added a third — two application channels assigned to one physical
		// channel — which that phrase does not cover, and each problem already says what it is.
		return error('${problem} — not starting')
	}
	// Through the same call the GUI makes, for the reason the block above exists: one policy, and
	// the two front ends must not each keep their own reading of it. A WARNING, not a refusal —
	// see project.fd_capability_warnings.
	for w in project.fd_capability_warnings(proj.channels) {
		o.err('warning: ${w}')
	}
	// one opener for the whole run, behind a pointer: a closure copies a struct it captures (maps
	// included), and the check and the row databases must share this one
	db_files := &DbFiles{
		err: o.err
	}
	for w in project.arxml_rate_warnings(proj.channels, os.dir(proj_path), fn [db_files] (ref string) ?candb.Database {
		mut f := unsafe { db_files }
		l := f.open(ref) or { return none }
		return l.db
	}) {
		o.err('warning: ${w}')
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
	desc_sys := described_system(proj_path, proj, o)
	for ci, ch in proj.channels {
		if !ch.enabled {
			continue
		}
		db := row_db(mut row_dbs, proj.channels, ci, os.dir(proj_path), db_files)
		nodes := ch.all_nodes()
		r.chans << Channel{
			cfg: ch
			db:  db
		}
		// DoIP is a different carrier, not a CAN bus: no frames, no ISO-TP, and the entity is
		// reached by logical address over TCP. Nothing outside blobly/doip ever started one,
		// so a `type: doip` channel printed "+ UDS server" while spawning a CAN responder on an
		// interface no CAN transport can open — the project documented an entity that was never
		// listening. Start the real thing here.
		if ch.is_someip() {
			// A listener endpoint: no bus to open, no entity to host. Scripts reach it through
			// someip.listen({ from = name }), which binds it for the window it asks for.
			host, port := ch.someip_endpoint()
			grp := if ch.group != '' { ', group ${ch.group}' } else { '' }
			o.out('channel ${ch.name} (someip:${host}:${port}${grp}): SOME/IP listener — someip.listen(1500, { from = "${ch.name}" })')
			continue
		}
		if ch.is_doip() {
			if !ch.hosts_doip_entity() {
				o.out('channel ${ch.name} (${ch.iface}): DoIP tester only (no simulated entity)')
				continue
			}
			host, port := ch.doip_endpoint()
			// Validate before serving, exactly as the CAN branch does. Without this a
			// malformed `uds:` block was dropped by uds_nodes() in silence and the built-in
			// default served in its place, so a suite could pass against the stock VIN while
			// believing it had read the configured ECU.
			for w in sim.validate_uds_doip(nodes) {
				o.err('${ch.name}: ${w}')
			}
			// One decision, shared with the GUI (sim.doip_entity): which node is served, and
			// the single VIN both identity surfaces use. An entity that came up differently
			// depending on which side started it would make a bench result depend on how the
			// tool was launched.
			ent := sim.doip_entity_described(ch, nodes, &desc_sys, can_sims(proj)) or {
				// REFUSE, not continue. Leaving the channel in place let scripts dial the
				// endpoint anyway, and if another DoIP process holds it the suite passes
				// against that one — the wrong-ECU failure the bind check below prevents,
				// reached by skipping the bind entirely.
				return error('${ch.name}: ${err}\nrefusing to run: scripts would dial ${ch.name} and reach whatever else is there')
			}
			for n in ent.notes {
				o.err('${ch.name}: ${n}')
			}
			if ent.extra > 0 {
				// One channel is one entity at one logical address, so extra UDS nodes have no
				// address to answer on. Say which one won rather than silently serving it.
				o.err('${ch.name}: ${ent.extra + 1} UDS nodes on one DoIP entity; serving "${ent.node}" (0x${ch.ecu_addr:04X})')
			}
			mut srv := ent.server
			probes.release(port)
			// Bind HERE, not inside the spawned worker. Reported only to stderr, a failed bind
			// left the run announcing an entity and carrying on — and if the port was held by
			// another DoIP process serving the same built-in defaults, uds.open would connect
			// to THAT and the suite would pass against the wrong ECU.
			mut entity := doip_listen(host, port, ent.cfg, srv) or {
				return error('${ch.name}: ${err}\nrefusing to run: a suite would connect to whatever else is on ${host}:${port}')
			}
			r.counted()
			spawn r.doip_serve_loop(mut entity)
			// NOT announced here. The default sequence is 3 × 500ms and would be finished
			// before the script environment exists, so a suite could never observe it — the
			// documented "listen before they announce" was unachievable with the defaults, and
			// the announce fixture was only passing because it announces for four seconds.
			// Collected and fired once the environment is ready, below.
			announcers << Announcer{
				srv:  entity
				name: ch.name
			}
			o.out('channel ${ch.name} (doip:${host}:${port}): DoIP entity, logical address 0x${ch.ecu_addr:04X}')
			continue
		}
		if nodes.len > 0 {
			// BOTH: the suffixed string opens the transport, the logical one keys faults.
			// Passing only the suffixed form meant sim.apply_injected looked up
			// `pcan:…@250000` while sim.fault() had stored under `pcan:…`, so a scripted
			// fault on vendor hardware reported success and never reached the wire.
			r.counted()
			spawn r.sim_loop(ch.iface_with_bitrate(), ch.iface, ch.name, db, nodes)
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
				o.out('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s)')
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
					o.err('${ch.name}: ${w}')
				}
				mut servers := sim.uds_nodes(peers)
				for n in sim.describe_uds_nodes(&desc_sys, mut servers, peers, owners, ch.iface) {
					o.err('${ch.name}: ${n}')
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
					o.err('${ch.name}: all ${declared} configured UDS node(s) rejected — not starting the default server in their place')
					o.out('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s), NO UDS server (bad uds config)')
					continue
				}
				if servers.len == 0 {
					dflt := sim.describe_default(&desc_sys, ch.name, ch.iface, 0x7E0, 0x7E8)
					for n in dflt.notes {
						o.err(n)
					}
					r.counted()
					spawn r.diag_server_loop(ch.iface_with_bitrate(), dflt.server)
					o.out('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + UDS server')
				} else {
					for mut u in servers {
						r.counted()
						spawn r.uds_node_loop(ch.iface_with_bitrate(), u.rx, u.tx, u.ext,
							u.functional, u.fext, u.server)
					}
					o.out('channel ${ch.name} (${ch.iface}): simulating ${nodes.len} node(s) + ${servers.len} UDS target(s)')
				}
			}
		} else {
			o.out('channel ${ch.name} (${ch.iface}): monitor only')
		}
	}
	probes.release_all()
	// Cyclic generators (`senders:` with trigger: cyclic), sent while the run lasts as the GUI
	// sends them during a measurement, by the GUI's rules: every row's generators (a disabled
	// row's too — its generator may target an enabled channel), sent only where a target row is
	// still in the run or the target is a wire no row configures, with the target rows'
	// databases. Without it a project behaved differently headless.
	for w in project.sender_bus_warnings(proj.channels) {
		o.err(w)
	}
	for w in project.generator_source_warnings(proj.channels) {
		o.err(w)
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
				o.err('${ch.name}: generator "${s.name}": ${sb.note} — not sent')
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
			for row in rows {
				sdb << row_db(mut row_dbs, proj.channels, row, os.dir(proj_path), db_files)
			}
			r.counted()
			spawn r.sender_loop(open_iface, s, sdb, run_t0)
			o.out('channel ${ch.name}: cyclic generator "${s.name}" every ${s.cycle_ms} ms on ${sb.iface}')
		}
	}
	// Let the sims start emitting / the UDS server start polling before scripts run.
	time.sleep(150 * time.millisecond)
	// NOW announce: the entities have been listening since bind, and a suite that starts a
	// doip.listen() in its first lines can actually catch the sequence. A real ECU announces
	// when it comes up; from outside this process that is still what this looks like.
	for mut a in announcers {
		r.counted()
		spawn r.doip_announce(mut a.srv, a.name)
	}
}

// stop ends the run: every loop told, and waited for — BOUNDED, because a loop stuck in a
// stalled CANsub write cannot re-check the flag until the write returns, and the transport
// confines a stalled write to its sender on purpose: the run must not inherit its timeout (codex
// round 6 on #231). Loops still running when the bound expires are left to the exit; what they
// would have booked is not reported. Returns once the wires have said their piece, so what a
// responder counted is booked before the caller asks its own handles (#213).
pub fn (mut r Run) stop() {
	r.ctl.running = false
	wait_until := time.ticks() + 2000
	for stdatomic.load_i64(&r.loops_done) < stdatomic.load_i64(&r.spawned)
		&& time.ticks() < wait_until {
		time.sleep(10 * time.millisecond)
	}
	left := stdatomic.load_i64(&r.spawned) - stdatomic.load_i64(&r.loops_done)
	if left > 0 {
		r.err('${left} bus loop(s) still busy at exit; their wires are not reported')
	}
}

// counted is one more loop spawned; done counts it out.
fn (mut r Run) counted() {
	stdatomic.add_i64(&r.spawned, 1)
}

// done counts one bus-holding loop out, on EVERY way out, an open that fails included -- a loop
// that returned before counting itself left the bounded wait waiting for it (codex round 7 on
// #231).
fn (mut r Run) done() {
	stdatomic.add_i64(&r.loops_done, 1)
}

// sim_loop runs the channel's simulated ECUs on a dedicated bus handle.
fn (mut r Run) sim_loop(open_iface string, fault_iface string, chan_name string, db candb.Database, nodes []project.NodeCfg) {
	defer {
		r.done()
	}
	mut bus := transport.open(open_iface) or { return }
	mut engine := sim.Engine{}
	for n in nodes {
		engine.ecus << build_node(db, n, r.err)
	}
	t0 := time.ticks()
	for r.ctl.running {
		// Re-stamped every pass, so a fault a script injects mid-run takes effect on the next
		// frame rather than at the next rebuild — which for the headless runner never comes.
		// The elapsed time ages timed faults; without it "drop for 500 ms" drops forever.
		// The table owns its own clock, so calling this from every bus loop is safe.
		sim.apply_injected(fault_iface, mut engine)
		now_ms := f64(time.ticks() - t0)
		sim.transmit(mut engine, mut bus, now_ms, fault_iface, chan_name)
		if frame := bus.recv(5) {
			for resp in engine.on_frame(frame) {
				bus.send(resp) or {}
			}
		}
	}
	// CLOSED FIRST: a shared handle's close books the last gap its cursor lost, and a closed
	// handle still answers with the wire's totals (codex round 12 on #231).
	bus.close()
	r.report_diag('${open_iface} (sim)', bus.diagnostics())
}

// sender_loop sends one cyclic generator's frame every `cycle_ms` until stopped — the headless
// counterpart of the GUI's gen_loop, building the frame with the same sim.sender_message_frame.
// The send index counts DELIVERED frames only, as the GUI's does, so a counter source never
// skips a value a refused send did not put on the wire.
fn (mut r Run) sender_loop(iface string, s project.Sender, dbs []candb.Database, run_t0 u64) {
	defer {
		r.done()
	}
	mut bus := transport.open(iface) or {
		r.err('generator "${s.name}": cannot open ${iface}: ${err}')
		return
	}
	mut n := 0
	mut next := time.ticks()
	for r.ctl.running {
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
				r.err('generator "${s.name}": message "${s.message}" not in the channel databases — not sent')
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
	r.report_diag('${iface} (generator ${s.name})', bus.diagnostics())
}

// uds_node_loop answers one simulated ECU's diagnostic requests on its own addresses.
fn (mut r Run) uds_node_loop(iface string, rx u32, tx u32, ext bool, fid u32, fext bool, srv uds.Server) {
	defer {
		r.done()
	}
	ctl := r.ctl
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
			r.err('${iface}: uds node 0x${rx:X} cannot listen on functional id 0x${fid:X}: ${err} — physical requests only')
		}
	}
	mut s := srv
	for r.ctl.running {
		s.serve_step(mut link, 50) or { time.sleep(50 * time.millisecond) }
	}
	fdiags := link.close()
	r.report_diag('${iface} (uds node)', ch.diagnostics()) // after the close: see sim_loop
	for d in fdiags {
		r.report_diag('${iface} (uds node 0x${rx:X}, functional 0x${fid:X} queue)', transport.BusDiagnostics{
			dropped: d.queue_dropped
		})
		if wd := d.wire {
			r.report_diag('${iface} (functional listener)', wd)
		}
	}
}

// diag_server_loop answers UDS requests (rx 0x7E0 / tx 0x7E8) over software ISO-TP on the
// channel's bus, until stopped.
fn (mut r Run) diag_server_loop(iface string, server uds.Server) {
	defer {
		r.done()
	}
	ctl := r.ctl
	// Server side: transmit responses on 0x7E8, receive requests on 0x7E0
	// (the mirror of the tester's tx 0x7E0 / rx 0x7E8).
	mut ch := isotp.open_software(iface, 0x7E8, 0x7E0, false) or { return }
	ch.stop_requested = fn [ctl] () bool {
		return !ctl.running
	}
	mut srv := server
	for r.ctl.running {
		req := ch.recv(50) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
	r.report_diag('${iface} (uds server)', ch.diagnostics()) // after the close: see sim_loop
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
	hst.bind_functional(mut s)
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
// Counted like a bus loop: the sequence is sliced on the entity's `stopping`, which its close
// sets, so a stop ends it within ~50 ms and no sink is called after stop has returned.
fn (mut r Run) doip_announce(mut s doip.DoipServer, name string) {
	defer {
		r.done()
	}
	s.announce() or { r.err('${name}: announce failed: ${err}') }
}

// doip_serve_loop runs an already-bound entity until stop, then closes it — counted, so a stop
// has the port free when it returns and the next start on the same endpoint can bind it.
fn (mut r Run) doip_serve_loop(mut s doip.DoipServer) {
	defer {
		r.done()
	}
	r.counted()
	spawn r.doip_udp_loop(mut s)
	for r.ctl.running {
		// A timeout is the normal case (no tester connected), not a failure.
		s.accept_and_serve(200) or { continue }
	}
	s.close()
}

// doip_udp_loop answers vehicle-identification requests, so Discover finds the entity.
fn (mut r Run) doip_udp_loop(mut s doip.DoipServer) {
	defer {
		r.done()
	}
	for r.ctl.running {
		s.serve_udp_once(200) or { continue }
	}
}

// build_node delegates to sim.from_project. This used to be a copy of the GUI's builder
// ("mirror src/main.v"), which is how end-to-end protection reached the GUI and not this
// runner — the one CI and runtests.sh use, so a protected project would have been scored
// against unprotected traffic.
fn build_node(db candb.Database, cfg project.NodeCfg, err_out fn (string)) sim.SimEcu {
	// A protect: entry naming a message or signal that is not there applies nothing, and the
	// run would otherwise score a protected project against unprotected traffic without a word.
	for w in sim.validate_cfg(db, cfg) {
		err_out('${cfg.name}: ${w}')
	}
	return sim.from_project(db, cfg)
}

// can_sims is every node the project simulates on an enabled CAN channel: the frames a described
// DoIP entity's live DIDs read.
fn can_sims(proj project.Project) []project.NodeCfg {
	mut out := []project.NodeCfg{}
	for c in proj.channels {
		if c.enabled && !c.is_eth() {
			out << c.all_nodes()
		}
	}
	return out
}

// described_system is the system.toml sysview.find_system finds for the project, loaded; an empty
// model, which describes nothing, when there is none.
fn described_system(proj_path string, proj project.Project, o Options) sysview.System {
	mut refs := []string{}
	for c in proj.channels {
		refs << c.databases
	}
	path := sysview.find_system(proj_path, refs) or { return sysview.System{} }
	sys := sysview.load(path) or {
		o.err('${path} could not be read (${err}); simulated servers answer from the project')
		return sysview.System{}
	}
	o.out('described: ${path}')
	return sys
}

// report_diag prints what one handle counted that no frame carried, if anything (#213).
fn (r &Run) report_diag(what string, d transport.BusDiagnostics) {
	if !d.is_empty() {
		r.err('${what}: ${d.str()}')
	}
}

// row_db is row `i`'s databases, loaded (and its reader notes printed) once.
fn row_db(mut cache map[int]candb.Database, chs []project.Channel, i int, proj_dir string, files &DbFiles) candb.Database {
	if db := cache[i] {
		return db
	}
	db := load_channel_db(chs[i], proj_dir, files)
	cache[i] = db
	return db
}

// load_channel_db merges every DBC attached to a channel into one catalog (first definition of
// an id wins) through candb.merge_files — see the GUI's merge_dbs. Having one merge each is how
// the same project came to mean two different databases.
fn load_channel_db(ch project.Channel, proj_dir string, files &DbFiles) candb.Database {
	// Resolved against the PROJECT's directory, exactly as the GUI does. runtests.sh changes to
	// the repository root before running, so a project kept anywhere else had its relative
	// `databases:` entries opened as written — the load failed, the database came back empty,
	// and the simulation transmitted nothing with no error anywhere.
	db, notes := candb.merge_files_report_with(ch.databases.map(project.resolve_asset(proj_dir, it)),
		fn [files] (ref string) !candb.Loaded {
			mut f := unsafe { files }
			return f.open(ref)
		})
	// what could not be opened, and what the ARXML reader had to skip: on stderr, because a
	// refused database otherwise surfaces as failing tests with no line saying why
	for n in notes {
		files.err('${ch.name}: ${n}')
	}
	return db
}

// DbFiles opens the run's databases: each reference once and each ARXML FILE once, however
// many of its clusters rows name (a system description is hundreds of MB to read and hash), and
// the SAME parse for every question asked of it — the rate check before the run and the row
// databases the run uses, so a file replaced between the two cannot make them disagree.
struct DbFiles {
	err fn (string) @[required]
mut:
	refs         map[string]candb.Loaded // by canonical reference
	failed       map[string]string
	arxml        map[string]candb.Arxml // by real path
	arxml_failed map[string]string      // by real path: a broken file is read once, not per cluster
}

fn (mut f DbFiles) open(ref string) !candb.Loaded {
	key := candb.canonical_database_ref(ref)
	if why := f.failed[key] {
		return error(why)
	}
	if l := f.refs[key] {
		return l
	}
	l := f.open_new(ref) or {
		f.failed[key] = err.msg()
		return err
	}
	f.refs[key] = l
	return l
}

fn (mut f DbFiles) open_new(ref string) !candb.Loaded {
	file, cluster := candb.split_database_ref(ref)
	if !candb.is_arxml_path(file) {
		return candb.open_database(ref)
	}
	k := os.real_path(file)
	if why := f.arxml_failed[k] {
		return error(why)
	}
	if k !in f.arxml {
		f.arxml[k] = candb.load_arxml_file(file) or {
			f.arxml_failed[k] = err.msg()
			return err
		}
	}
	return f.arxml[k].loaded(cluster, os.base(file))
}
