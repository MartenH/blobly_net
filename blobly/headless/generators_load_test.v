module headless

import os
import time
import strings

// generators_load_test.v — a few hundred cyclic generators on thirteen in-process buses, the mix
// of cycles a rest bus has (#689's): every slot of every generator's cycle is sent or counted as
// left out, and the run allocates next to nothing per frame — garbage per frame is what stopped
// every sending loop at once for a collection. How many are left out is the host's scheduling as
// much as the code's (the unit suite runs a test per core), so that is bounded loosely.

// load_mix is each cycle (ms) and how many of the generators have it.
const load_mix = [[10, 12], [20, 22], [50, 29], [100, 78], [1000, 119]]

const load_buses = 13

// load_project writes the project: every message 8 bytes of four static signals, the generators
// dealt round the buses. It answers the project's path and each generator's cycle, by name.
fn load_project() !(string, map[string]int) {
	dir := os.join_path(os.vtmp_dir(), 'headless_gen_load_${os.getpid()}')
	os.mkdir_all(dir)!
	mut cycles := []int{}
	for m in load_mix {
		for _ in 0 .. m[1] {
			cycles << m[0]
		}
	}
	mut d := strings.new_builder(32768)
	d.writeln('VERSION ""\n\nNS_ :\n\nBS_:\n\nBU_: Node Receiver\n')
	for i in 0 .. cycles.len {
		d.writeln('BO_ ${0x100 + i} Msg${i:03d}: 8 Node')
		for k in 0 .. 4 {
			d.writeln(' SG_ S${i:03d}_${k} : ${16 * k}|16@1+ (1,0) [0|65535] "" Receiver')
		}
		d.writeln('')
	}
	dbc := os.join_path(dir, 'load.dbc')
	os.write_file(dbc, d.str())!
	mut by_name := map[string]int{}
	mut p := strings.new_builder(65536)
	p.writeln('project:\n  name: generator load\n  version: 8\n\nbuses:')
	for b in 0 .. load_buses {
		p.writeln('  - name: BUS${b:02d}\n    adapter: virtual\n    address: hgenload${b:02d}\n    protocol: can\n    bitrate: 500000\n    databases: [${dbc}]\n    senders:')
		for i := b; i < cycles.len; i += load_buses {
			by_name['Msg${i:03d}'] = cycles[i]
			p.writeln('      - name: Msg${i:03d}\n        message: Msg${i:03d}\n        trigger: cyclic\n        cycle_ms: ${cycles[i]}\n        signals:')
			for k in 0 .. 4 {
				p.writeln('          - { name: S${i:03d}_${k}, value: ${k} }')
			}
		}
	}
	path := os.join_path(dir, 'load.blobnet')
	os.write_file(path, p.str())!
	return path, by_name
}

// Tally is every generator's sent and skipped, by name.
struct Tally {
	sent    map[string]i64
	skipped map[string]i64
}

fn tally(mut r Run) Tally {
	mut sent := map[string]i64{}
	mut skipped := map[string]i64{}
	for g in r.generators() {
		sent[g.name] = g.sent
		skipped[g.name] = g.skipped
	}
	return Tally{sent, skipped}
}

fn test_a_few_hundred_generators_send_every_slot() {
	path, cycle_of := load_project()!
	defer {
		os.rmdir_all(os.dir(path)) or {}
	}
	mut r := start(load(path, Options{})!, path, Options{})!
	defer {
		r.stop()
	}
	time.sleep(500 * time.millisecond)
	a := tally(mut r)
	t0 := time.sys_mono_now()
	before := u64(gc_heap_usage().total_bytes)
	time.sleep(2 * time.second)
	after := u64(gc_heap_usage().total_bytes)
	t1 := time.sys_mono_now()
	b := tally(mut r)
	window_ms := f64(t1 - t0) / 1_000_000.0
	mut slots := 0.0
	mut sent := i64(0)
	mut skipped := i64(0)
	mut off := []string{}
	for name, cycle in cycle_of {
		want := window_ms / f64(cycle)
		ds := b.sent[name] - a.sent[name]
		dk := b.skipped[name] - a.skipped[name]
		slots += want
		sent += ds
		skipped += dk
		// a slot at either edge of the window, and the slots a send late at its end covered,
		// which the next send counts: a loop held up for a fifth of the window at its end
		if f64(ds + dk) < want * 0.8 - 3 || f64(ds + dk) > want * 1.1 + 2 {
			off << '${name} (${cycle} ms): ${ds} sent + ${dk} skipped for ${want:.1f} slots'
		}
	}
	per := if sent > 0 { f64(after - before) / f64(sent) } else { 0.0 }
	println('${cycle_of.len} generators on ${load_buses} buses, ${window_ms:.0f} ms: ${sent} sent, ${skipped} skipped of ${slots:.0f} slots; ${per:.0f} bytes allocated per frame')
	assert off.len == 0, 'sent + skipped is not every slot of the cycle: ${off}'
	assert f64(sent) > slots * 0.5, '${sent} of ${slots:.0f} slots sent'
	assert per < 128, 'the run allocates ${per:.0f} bytes per frame it sends'
}
