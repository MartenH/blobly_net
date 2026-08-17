// restbus — replay a recorded bus onto a live one, minus the ECU under test.
//
// The rest bus a SUT hears, sourced from a real capture instead of from generators somebody
// typed. The ECU under test is subtracted, so it remains the only transmitter of its own
// messages rather than arbitrating against a recording of itself.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/restbus/main.v \
//       --source capture.mf4 --bus CAN1 --dbc CAN01.dbc --exclude VCM_C --iface inproc:rest
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
	source      string
	bus         string
	dbc         string
	iface       string
	exclude     []string
	speed       f64
	loop        bool
	list        bool
	dry_run     bool
	replay_unattr bool
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
		verb := if o.replay_unattr { 'replayed' } else { 'withheld (${rep.withheld_unattributed} frames)' }
		println('  note: ${rep.unattributed} frames on ${rep.unattributed_ids.len} id(s) have no transmitter in the DBC — ${verb}')
		println('        ${hex_ids(rep.unattributed_ids)}')
	}
	if rep.unknown > 0 {
		println('  note: ${rep.unknown} frames on ${rep.unknown_ids.len} id(s) are not in the DBC at all — replayed')
		println('        ${hex_ids(rep.unknown_ids)}')
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

	mut p := player.new_player(kept, o.speed, o.loop)
	// A StopWatch, NOT time.ticks(): ticks() is whole milliseconds (and GetTickCount, ~15.6 ms,
	// on Windows) off the wall clock. Quantising to 1 ms would defeat the sleep-until-due
	// scheduling entirely — these recordings repeat frames every 0.18 ms — and a wall clock can
	// step under us mid-run, which on a long --loop means a stall or a flood.
	mut sw := time.new_stopwatch()
	p.play(0.0)
	mut sent := u64(0)
	mut failed := u64(0)
	mut last_report := 0.0
	for {
		now := f64(i64(sw.elapsed())) / 1e6 // ns -> ms, fractional
		for e in p.due(now) {
			bus.send(e.frame) or {
				failed++
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
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--list' { list = true }
			'--dry-run' { dry = true }
			'--loop' { loop = true }
			'--drop-unattributed' { replay_unattr = false }
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
	if !list {
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
	}
}
