module headless

import os
import time
import sync.stdatomic
import blobly.cyclic
import blobly.transport

const many_buses = 8
const many_gens = 32 // per bus
const many_senders = 8 // per bus

// many_project is many_buses rows, each with many_gens cyclic generators at 10..50 ms
fn many_project() string {
	mut s := 'project:\n  name: many\n  version: 8\nchannels:\n'
	for b in 0 .. many_buses {
		s += '  - name: M${b}\n    type: can\n    interface: inproc:HMANY${b}\n    senders:\n'
		for k in 0 .. many_gens {
			s += '      - name: G${k}\n        id: "0x${0x100 + b * 64 + k:X}"\n        data: "01"\n        trigger: cyclic\n        cycle_ms: ${gen_period(k)}\n'
		}
	}
	return s
}

fn gen_period(k int) int {
	return 10 + 10 * (k % 5)
}

const sender_period = 25

// a few hundred generators and background senders are sent by one loop per wire, each on its own
// period, and the run's stop ends them all within its bound
fn test_hundreds_of_periodic_sources_share_one_loop_per_wire() {
	dir := os.join_path(os.vtmp_dir(), 'headless_wires_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'many.blobnet')
	os.write_file(path, many_project())!
	mut rx := []transport.Bus{}
	for b in 0 .. many_buses {
		rx << transport.open('inproc:HMANY${b}')!
	}
	defer {
		for mut x in rx {
			x.close()
		}
	}
	mut r := start(load(path, Options{})!, path, Options{})!
	mut senders := []&cyclic.Sender{}
	for b in 0 .. many_buses {
		iface := 'inproc:HMANY${b}'
		for k in 0 .. many_senders {
			senders << r.start_cyclic(cyclic.Target{
				iface: iface
				row:   'M${b}'
				open:  fn [iface] () !transport.Bus {
					return transport.open(iface)
				}
			}, cyclic.Spec{
				id:        u32(0x500 + b * 16 + k)
				data:      [u8(2)]
				period_ms: sender_period
			})!
		}
	}
	// one loop and one handle per wire, whatever the count of sources on it
	assert r.wires.len == many_buses
	assert stdatomic.load_i64(&r.spawned) == many_buses
	for mut x in rx {
		for {
			x.recv(0) or { break }
		}
	}
	// each id's frames over a second: how many, the first and the last
	mut count := map[u32]int{}
	mut first := map[u32]i64{}
	mut last := map[u32]i64{}
	t_end := time.ticks() + 1000
	for time.ticks() < t_end {
		mut any := false
		for mut x in rx {
			f := x.recv(0) or { continue }
			any = true
			now := time.ticks()
			if f.id !in first {
				first[f.id] = now
			}
			last[f.id] = now
			count[f.id]++
		}
		if !any {
			time.sleep(time.millisecond)
		}
	}
	// the mean interval of each source against its period
	mut sum_err := 0.0
	mut ids := 0
	for b in 0 .. many_buses {
		for k in 0 .. many_gens + many_senders {
			id, period := if k < many_gens {
				u32(0x100 + b * 64 + k), gen_period(k)
			} else {
				u32(0x500 + b * 16 + k - many_gens), sender_period
			}
			n := count[id]
			assert n >= 1000 / period * 7 / 10, '0x${id:X}: ${n} frames in 1 s at ${period} ms'
			mean := f64(last[id] - first[id]) / f64(n - 1)
			rel := if mean > period { (mean - period) / period } else { (period - mean) / period }
			assert rel < 0.3, '0x${id:X}: a mean interval of ${mean:.1} ms at ${period} ms'
			sum_err += rel
			ids++
		}
	}
	assert sum_err / ids < 0.1, 'a mean period error of ${100 * sum_err / ids:.1}%'
	t0 := time.ticks()
	r.stop()
	assert time.ticks() - t0 < 1000
	assert released()
	assert senders.all(!it.info().running)
	assert r.generators().all(!it.running)
}
