// loadtest — headless data-plane benchmark for many concurrent buses. NO GUI: it
// measures the transport + decode path so we can see where 20+ buses land before
// the GUI's bounded-repaint ceiling muddies the picture.
//
// Model (mirrors the app's per-bus threads): each bus gets a producer thread that
// sends frames and a consumer thread that recv()s + (optionally) DBC-decodes them.
// The in-proc bus drops on a full subscriber queue, so sent-vs-received shows the
// sustainable rate and where the bottleneck is (transport vs decode).
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/loadtest/loadtest.v \
//       [buses=20] [rate_per_bus=0(max)] [secs=5] [decode=1]
module main

import os
import time
import runtime
import transport
import candb

struct CStat {
	recvd   u64
	decoded u64
}

// producer floods (rate<=0) or paces (rate>0) frames onto `iface` until deadline.
fn producer(iface string, rate int, deadline i64) u64 {
	mut bus := transport.open(iface) or { return 0 }
	defer {
		bus.close()
	}
	// IDs that exist in dbc/cantester.dbc so the consumer's decode does real work.
	ids := [u32(0x100), 0x300, 0x301, 0x200]
	mut sent := u64(0)
	start := time.ticks()
	for time.ticks() < deadline {
		// elapsed-target pacing (accurate over time, unlike per-frame sleep): only
		// send while behind rate*elapsed; otherwise nap briefly. rate<=0 = flat out.
		if rate > 0 {
			target := u64(f64(rate) * f64(time.ticks() - start) / 1000.0)
			if sent >= target {
				time.sleep(200 * time.microsecond)
				continue
			}
		}
		mut data := [u8(sent), u8(sent >> 8), 0x10, 0x20, 0x30, 0x40, 0x50, 0x60]
		bus.send(transport.CanFrame{ id: ids[sent % u64(ids.len)], data: data }) or {}
		sent++
	}
	return sent
}

// consumer recv-loops, decoding each frame against the DBC when do_decode.
fn consumer(iface string, db candb.Database, do_decode bool, deadline i64) CStat {
	mut bus := transport.open(iface) or { return CStat{} }
	defer {
		bus.close()
	}
	mut recvd := u64(0)
	mut decoded := u64(0)
	for time.ticks() < deadline {
		f := bus.recv(100) or { continue }
		recvd++
		if do_decode {
			if m := db.lookup_frame(f.id, f.extended) {
				for s in m.active_signals(f.data) {
					_ := s.physical(f.data)
					decoded++
				}
			}
		}
	}
	return CStat{recvd, decoded}
}

fn rss_kb() int {
	txt := os.read_file('/proc/self/status') or { return 0 }
	for line in txt.split_into_lines() {
		if line.starts_with('VmRSS:') {
			return line.all_after('VmRSS:').trim_space().all_before(' ').int()
		}
	}
	return 0
}

// cpu_secs returns process CPU time (utime+stime) in seconds, for cores-used calc.
fn cpu_secs() f64 {
	txt := os.read_file('/proc/self/stat') or { return 0 }
	// fields after the (comm) paren: utime=14, stime=15 (1-based on the whole line)
	rest := txt.all_after_last(')').trim_space()
	f := rest.split(' ')
	if f.len < 13 {
		return 0
	}
	hz := f64(100) // typical CLK_TCK
	return (f[11].f64() + f[12].f64()) / hz // utime + stime
}

fn main() {
	buses := if os.args.len > 1 { os.args[1].int() } else { 20 }
	rate := if os.args.len > 2 { os.args[2].int() } else { 0 } // per bus; 0 = max
	secs := if os.args.len > 3 { os.args[3].int() } else { 5 }
	decode := if os.args.len > 4 { os.args[4].int() != 0 } else { true }

	db := candb.load_dbc_file('dbc/cantester.dbc') or {
		eprintln('cannot load DBC: ${err}')
		exit(1)
	}
	rmode := if rate > 0 { '${rate}/bus' } else { 'max' }
	println('loadtest: ${buses} buses, rate ${rmode}, ${secs}s, decode=${decode}')

	deadline := time.ticks() + i64(secs) * 1000
	// Start consumers first + let them attach, so producers don't broadcast into the void.
	mut cons := []thread CStat{}
	for i in 0 .. buses {
		cons << spawn consumer('inproc:LBUS${i}', db, decode, deadline)
	}
	time.sleep(50 * time.millisecond)
	mut prods := []thread u64{}
	for i in 0 .. buses {
		prods << spawn producer('inproc:LBUS${i}', rate, deadline)
	}

	cpu0 := cpu_secs()
	t0 := time.ticks()
	mut sent := u64(0)
	for p in prods {
		sent += p.wait()
	}
	mut recvd := u64(0)
	mut decoded := u64(0)
	for c in cons {
		s := c.wait()
		recvd += s.recvd
		decoded += s.decoded
	}
	wall := f64(time.ticks() - t0) / 1000.0
	cpu := cpu_secs() - cpu0
	rss := rss_kb()

	dropped := if sent > recvd { sent - recvd } else { 0 }
	drop_pct := if sent > 0 { f64(dropped) / f64(sent) * 100 } else { 0 }
	println('--- results (${wall:.2f}s wall) ---')
	println('sent     : ${sent}  (${u64(f64(sent) / wall):12} /s aggregate)')
	println('received : ${recvd}  (${u64(f64(recvd) / wall):12} /s aggregate, ${u64(f64(recvd) / wall / buses)} /s/bus)')
	if decode {
		println('decoded  : ${decoded} signals (${u64(f64(decoded) / wall):12} /s)')
	}
	println('dropped  : ${dropped} (${drop_pct:.1f}% — overflow when consumer < producer)')
	println('CPU      : ${cpu:.2f} cpu-s → ${cpu / wall:.1f} cores busy (of ${runtime.nr_cpus()})')
	println('RSS      : ${rss / 1024} MB')
}
