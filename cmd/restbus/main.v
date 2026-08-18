// restbus — replay a recorded bus onto a live one, minus the ECU under test.
//
// The rest bus a SUT hears, sourced from a real capture instead of from generators somebody
// typed. The ECU under test is subtracted, so it remains the only transmitter of its own
// messages rather than arbitrating against a recording of itself.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/restbus/main.v \
//       --source capture.mf4 --bus CAN1 --dbc CAN01.dbc --exclude VCM_C --iface inproc:rest
//
// SEVERAL buses at once — the shape a real bench needs, since the ECU under test sits on all of
// them and gateways between them. Repeat --map <recorded bus>,<interface>,<dbc>:
//
//   restbus --source capture.mf4 --exclude VCM_C \
//       --map CAN1,vcan0,com/CAN01-postfix.dbc \
//       --map CAN2,vcan1,com/CAN02-postfix.dbc
//
// All mapped buses replay from ONE time-sorted stream against ONE clock, so the recording's
// cross-bus ordering survives — the relationship a gateway polices.
//
//   --list                 show the recording's buses and stop
//   --dry-run              do the subtraction and report it, transmit nothing
//   --speed 1.0            playback rate; --loop to repeat
//   --drop-unattributed    withhold messages the DBC defines but does not attribute
//
// The decisions live in modules/player (what to leave out) and modules/mf4 (what a bus is);
// this file is argument parsing, a socket, and a sleep.
module main

import candb
import mf4
import os
import player
import time
import transport

struct Opts {
	source        string
	bus           string
	dbc           string
	iface         string
	exclude       []string
	speed         f64
	loop          bool
	list          bool
	dry_run       bool
	replay_unattr bool
	maps          []string // raw --map values: <recorded bus>,<interface>,<dbc>
}

fn main() {
	o := parse_args() or {
		eprintln('restbus: ${err}')
		eprintln('usage: restbus --source <file.mf4> --bus <name|iface> --dbc <file.dbc> --exclude <NODE> --iface <iface>')
		eprintln('       restbus --source <file.mf4> --list')
		exit(2)
	}
	rec := mf4.load_recording(o.source) or {
		eprintln('restbus: ${o.source}: ${err}')
		exit(1)
	}
	if o.list {
		println('${o.source}: ${rec.entries.len} frames')
		println('${'bus':-14} ${'label':-16} frames')
		for b in rec.buses {
			println('${b.name:-14} ${b.iface:-16} ${b.frames}')
		}
		return
	}
	if o.maps.len > 0 {
		run_multi(o, rec)
		return
	}
	iface := resolve_bus(rec.buses, o.bus) or {
		eprintln('restbus: ${err}')
		for b in rec.buses {
			eprintln('  ${b.iface}${if b.name != '' { ' (${b.name})' } else { ' (unnamed)' }}: ${b.frames} frames')
		}
		exit(1)
	}
	db := candb.load_dbc_file(o.dbc) or {
		eprintln('restbus: ${o.dbc}: ${err}')
		exit(1)
	}
	// A misspelled node subtracts nothing, and the result looks exactly like a working rest bus.
	// Refuse rather than run a test whose premise is silently false.
	missing := player.check_nodes(db, o.exclude)
	if missing.len > 0 {
		eprintln('restbus: ${o.dbc} does not know the node(s): ${missing.join(', ')}')
		eprintln('  it declares: ${db.nodes.join(', ')}')
		exit(1)
	}

	on_bus := player.on_bus(rec.entries, iface)
	if on_bus.len == 0 {
		eprintln('restbus: no frames on ${iface}')
		exit(1)
	}
	kept, rep := player.without_senders(on_bus, db, o.exclude, o.replay_unattr)
	span := on_bus[on_bus.len - 1].t_s - on_bus[0].t_s

	println('source   ${o.source}')
	println('bus      ${o.bus} -> ${iface}: ${on_bus.len} frames over ${span:.2f}s')
	println('database ${os.base(o.dbc)}: ${db.messages.len} messages, ${db.nodes.len} nodes')
	println('exclude  ${o.exclude.join(', ')}: ${rep.withheld_excluded} frames withheld')
	println('replay   ${rep.kept} frames')
	if rep.unattributed > 0 {
		verb := if o.replay_unattr {
			'replayed'
		} else {
			'withheld (${rep.withheld_unattributed} frames)'
		}
		println('  note: ${rep.unattributed} frames on ${rep.unattributed_ids.len} id(s) have no transmitter in the DBC — ${verb}')
		println('        ${hex_ids(rep.unattributed_ids)}')
	}
	if rep.unknown > 0 {
		println('  note: ${rep.unknown} frames on ${rep.unknown_ids.len} id(s) are not in the DBC at all — replayed')
		println('        ${hex_ids(rep.unknown_ids)}')
	}
	fd_n := kept.filter(it.frame.fd).len
	if fd_n > 0 {
		pct := 100.0 * f64(fd_n) / f64(kept.len)
		big := kept.filter(it.frame.data.len > 8).len
		println('  CAN-FD:  ${fd_n} frames (${pct:.1f}%), ${big} with payloads over 8 bytes')
		println('           the destination interface must be CAN-FD capable and up')
	}
	if o.dry_run {
		println('dry run: nothing transmitted')
		return
	}
	if kept.len == 0 {
		eprintln('restbus: nothing left to replay after the subtraction')
		exit(1)
	}

	mut bus := transport.open(o.iface) or {
		eprintln('restbus: open ${o.iface}: ${err}')
		exit(1)
	}
	defer {
		bus.close()
	}
	println('transmitting on ${o.iface} at ${o.speed}x${if o.loop { ', looping' } else { '' }} — ctrl-C to stop')

	// Over the SOURCE bus's span, not the filtered subset's: removing the SUT's frames must not
	// shorten the loop or move its origin.
	mut p := player.new_player_over(kept, o.speed, o.loop, on_bus[0].t_s,
		on_bus[on_bus.len - 1].t_s)
	// A StopWatch, NOT time.ticks(): ticks() is whole milliseconds (and GetTickCount, ~15.6 ms,
	// on Windows) off the wall clock. Quantising to 1 ms would defeat the sleep-until-due
	// scheduling entirely — these recordings repeat frames every 0.18 ms — and a wall clock can
	// step under us mid-run, which on a long --loop means a stall or a flood.
	mut sw := time.new_stopwatch()
	p.play(0.0)
	mut sent := u64(0)
	mut failed := u64(0)
	mut first_err := ''
	mut last_report := 0.0
	for {
		now := f64(i64(sw.elapsed())) / 1e6 // ns -> ms, fractional
		for e in p.due(now) {
			bus.send(e.frame) or {
				failed++
				if first_err == '' {
					first_err = err.msg() // one example beats a bare count on a bench
				}
				continue
			}
			sent++
		}
		if p.finished() {
			break
		}
		// Sleep until the next frame is actually due rather than polling on a chosen tick: a
		// tick quantises every message's recorded period, and these recordings go below 0.2 ms.
		nd := p.next_due_ms() or { break }
		wait := nd - f64(i64(sw.elapsed())) / 1e6
		if wait > 0 {
			time.sleep(i64(wait * 1_000_000) * time.nanosecond)
		}
		el := f64(i64(sw.elapsed())) / 1e6
		if el - last_report >= 1000.0 {
			last_report = el
			eprint('\r  ${sent} sent, ${p.progress(el) * 100:.0f}%  ')
		}
	}
	println('\ndone: ${sent} frames sent${if failed > 0 { ', ${failed} failed' } else { '' }}')
	if failed > 0 {
		eprintln('first failure: ${first_err}')
		exit(1)
	}
}

// run_multi replays several recorded buses at once: one stream, one clock, one open bus per
// destination. See modules/player/multibus.v for why the buses must not each get their own
// player — a gateway ECU polices the timing BETWEEN them.
fn run_multi(o Opts, rec mf4.Recording) {
	mut specs := []player.BusSpec{}
	mut unknown_on := map[string][]string{}
	for m in o.maps {
		parts := m.split(',').map(it.trim_space())
		src := resolve_bus(rec.buses, parts[0]) or {
			eprintln('restbus: --map ${m}: ${err}')
			exit(1)
		}
		db := candb.load_dbc_file(parts[2]) or {
			eprintln('restbus: ${parts[2]}: ${err}')
			exit(1)
		}
		// NOT fatal per bus: the ECU under test need not transmit on every bus it sits on, and
		// vendor databases legitimately declare different node sets. Collected and judged after
		// every mapping is read — a name absent from ONE database says nothing, a name absent
		// from ALL of them is a typo that subtracts nothing anywhere.
		for n in player.check_nodes(db, o.exclude) {
			// The PATH is the identity, not the filename: two mappings may legitimately load
			// `a/CAN01.dbc` and `b/CAN01.dbc`, and collapsing them by basename made a node
			// declared in one but absent from the other look absent everywhere — rejecting a
			// perfectly good multi-bus config.
			unknown_on[n] << os.real_path(parts[2])
		}
		specs << player.BusSpec{
			src:                 src
			dst:                 parts[1]
			db:                  db
			exclude:             o.exclude
			replay_unattributed: o.replay_unattr
		}
	}
	// A node no mapped database has heard of subtracts nothing at all, and the run then replays
	// the ECU under test at itself while looking perfectly healthy.
	// DEDUPED, and compared as a set of databases rather than a count of reports: `--exclude
	// VCM_C,VCM_C` made check_nodes report the name twice per database, so the count exceeded
	// specs.len, the equality never held, and a typo repeated by accident subtracted nothing
	// while passing the check meant to catch it.
	mut nowhere := []string{}
	mut judged := map[string]bool{}
	for n in o.exclude {
		if n in judged {
			continue
		}
		judged[n] = true
		mut dbs := map[string]bool{}
		for d in unknown_on[n] or { []string{} } {
			dbs[d] = true
		}
		if dbs.len > 0 && dbs.len == uniq_dbcs(o.maps) {
			nowhere << n
		}
	}
	if nowhere.len > 0 {
		eprintln('restbus: no mapped database declares the node(s): ${nowhere.join(', ')}')
		exit(1)
	}
	for n, dbcs in unknown_on {
		if n !in nowhere && n in judged {
			shown := dbcs.map(os.base(it))
			eprintln('restbus: note: ${n} is not declared by ${shown.join(', ')} — it transmits nothing there')
		}
	}
	if o.exclude.len == 0 && !o.dry_run {
		eprintln('restbus: warning: --exclude not given, so the ECU under test will be replayed at itself')
	}
	// Refused rather than warned about: either conflict produces a run that looks like it worked.
	clashes := player.conflicts(specs)
	if clashes.len > 0 {
		for c in clashes {
			eprintln('restbus: ${c}')
		}
		exit(1)
	}

	plan := player.build_multi(rec.entries, specs)
	mut name_of := map[string]string{}
	for b in rec.buses {
		name_of[b.iface] = if b.name != '' { b.name } else { b.iface }
	}
	println('source   ${o.source}')
	println('exclude  ${o.exclude.join(', ')}')
	println('bus            interface        recorded  withheld    replay  notes')
	mut total := 0
	for b in plan.buses {
		r := b.report
		mut notes := []string{}
		withheld := r.withheld_excluded + r.withheld_unattributed
		if b.source == 0 {
			notes << 'NO FRAMES — check the mapping'
		} else if r.kept == 0 {
			// Name the actual cause. "belongs to the excluded node" is only true when the
			// exclusion is what emptied it; --drop-unattributed and an empty --exclude reach
			// the same zero by different routes, and a wrong diagnosis sends someone hunting
			// the wrong config.
			mut why := []string{}
			if r.withheld_excluded > 0 {
				why << 'excluded node(s)'
			}
			if r.withheld_unattributed > 0 {
				why << 'unattributed (--drop-unattributed)'
			}
			notes << if why.len > 0 {
				'silent: all frames withheld by ${why.join(' + ')}'
			} else {
				'silent'
			}
		}
		if r.withheld_unattributed > 0 {
			notes << '${r.withheld_unattributed} withheld as unattributed'
		}
		if r.unknown > 0 {
			notes << '${r.unknown} frames on ${r.unknown_ids.len} id(s) not in the DBC'
		}
		if r.unattributed > 0 && r.withheld_unattributed == 0 {
			notes << '${r.unattributed} unattributed, replayed'
		}
		nm := name_of[b.src] or { b.src }
		println('${nm:-14} ${b.dst:-16} ${b.source:9} ${withheld:9} ${r.kept:9}  ${notes.join('; ')}')
		total += r.kept
	}
	span := plan.end_s - plan.t0_s
	println('replay   ${total} frames over ${span:.2f}s across ${plan.buses.len} bus(es)')
	fd_n := plan.entries.filter(it.frame.fd).len
	if fd_n > 0 {
		println('  CAN-FD:  ${fd_n} frames — every destination interface must be FD-capable and up')
	}
	if o.dry_run {
		println('dry run: nothing transmitted')
		return
	}
	if total == 0 {
		eprintln('restbus: nothing left to replay after the subtraction')
		exit(1)
	}

	// One open bus per DESTINATION. Entries were relabelled to their destination by build_multi,
	// so this loop is a map lookup and knows nothing about the mapping.
	mut buses := map[string]transport.Bus{}
	for sp in specs {
		if sp.dst in buses {
			continue
		}
		buses[sp.dst] = transport.open(sp.dst) or {
			eprintln('restbus: open ${sp.dst}: ${err}')
			exit(1)
		}
	}
	defer {
		for _, mut b in buses {
			b.close()
		}
	}
	dsts := specs.map(it.dst).join(', ')
	println('transmitting on ${dsts} at ${o.speed}x${if o.loop { ', looping' } else { '' }} — ctrl-C to stop')

	mut p := player.new_player_over(plan.entries, o.speed, o.loop, plan.t0_s, plan.end_s)
	mut sw := time.new_stopwatch()
	p.play(0.0)
	mut sent := u64(0)
	mut failed := u64(0)
	mut first_err := ''
	mut last_report := 0.0
	for {
		now := f64(i64(sw.elapsed())) / 1e6
		for e in p.due(now) {
			mut bus := buses[e.iface] or { continue }
			bus.send(e.frame) or {
				failed++
				if first_err == '' {
					first_err = '${e.iface}: ${err.msg()}'
				}
				continue
			}
			sent++
		}
		if p.finished() {
			break
		}
		nd := p.next_due_ms() or { break }
		wait := nd - f64(i64(sw.elapsed())) / 1e6
		if wait > 0 {
			time.sleep(i64(wait * 1_000_000) * time.nanosecond)
		}
		el := f64(i64(sw.elapsed())) / 1e6
		if el - last_report >= 1000.0 {
			last_report = el
			eprint('\r  ${sent} sent, ${p.progress(el) * 100:.0f}%  ')
		}
	}
	println('\ndone: ${sent} frames sent${if failed > 0 { ', ${failed} failed' } else { '' }}')
	if failed > 0 {
		eprintln('first failure: ${first_err}')
		exit(1)
	}
}

// uniq_dbcs counts the DISTINCT databases across the mappings — the same file may legitimately
// be mapped to several buses, and counting mappings instead would make "unknown everywhere"
// unreachable.
fn uniq_dbcs(maps []string) int {
	mut seen := map[string]bool{}
	for m in maps {
		parts := m.split(',')
		if parts.len == 3 {
			seen[os.real_path(parts[2].trim_space())] = true
		}
	}
	return seen.len
}

// resolve_bus accepts either the recording's own name for a bus ('CAN1') or the label its frames
// carry ('mf4:group25'). The name is what a person knows; the label is the identity. Ambiguity is
// refused rather than resolved by picking one — acquisition names are free text and not unique.
fn resolve_bus(buses []mf4.BusInfo, want string) !string {
	if want == '' {
		return error('no --bus given')
	}
	for b in buses {
		if b.iface == want {
			return b.iface
		}
	}
	hits := buses.filter(it.name == want)
	if hits.len == 1 {
		return hits[0].iface
	}
	if hits.len > 1 {
		return error('"${want}" names ${hits.len} buses in this recording: ${hits.map(it.iface).join(', ')} — use the label instead')
	}
	return error('no bus called "${want}" in this recording')
}

fn hex_ids(ids []u32) string {
	mut s := []string{}
	for i, id in ids {
		if i == 12 {
			s << '… (${ids.len - 12} more)'
			break
		}
		s << '0x${id:X}'
	}
	return s.join(' ')
}

fn parse_args() !Opts {
	mut source := ''
	mut bus := ''
	mut dbc := ''
	mut iface := ''
	mut exclude := []string{}
	mut speed := 1.0
	mut loop := false
	mut list := false
	mut dry := false
	mut replay_unattr := true
	mut maps := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--list' {
				list = true
			}
			'--dry-run' {
				dry = true
			}
			'--loop' {
				loop = true
			}
			'--drop-unattributed' {
				replay_unattr = false
			}
			else {
				if i + 1 >= os.args.len {
					return error('${a} needs a value')
				}
				v := os.args[i + 1]
				match a {
					'--source' { source = v }
					'--bus' { bus = v }
					'--dbc' { dbc = v }
					'--iface' { iface = v }
					'--exclude' { exclude << v.split(',').map(it.trim_space()).filter(it != '') }
					'--speed' { speed = v.f64() }
					'--map' { maps << v }
					else { return error('unknown argument ${a}') }
				}

				i++
			}
		}

		i++
	}
	if source == '' {
		return error('--source is required')
	}
	if !list && maps.len > 0 {
		if bus != '' || dbc != '' || iface != '' {
			return error('--map cannot be combined with --bus/--dbc/--iface; give one --map per bus')
		}
		for m in maps {
			if m.split(',').len != 3 {
				return error('--map takes <recorded bus>,<interface>,<dbc> — got "${m}"')
			}
		}
	}
	if !list && maps.len == 0 {
		if bus == '' {
			return error('--bus is required (or --list to see them)')
		}
		if dbc == '' {
			return error('--dbc is required: the subtraction needs a database to name senders')
		}
		if !dry && iface == '' {
			return error('--iface is required (or --dry-run)')
		}
		if exclude.len == 0 && !dry {
			eprintln('restbus: warning: --exclude not given, so the ECU under test will be replayed at itself')
		}
	}
	if speed <= 0 {
		return error('--speed must be > 0')
	}
	return Opts{
		source:        source
		bus:           bus
		dbc:           dbc
		iface:         iface
		exclude:       exclude
		speed:         speed
		loop:          loop
		list:          list
		dry_run:       dry
		replay_unattr: replay_unattr
		maps:          maps
	}
}
