// probe.v — replay stutter instrumentation. INERT unless BLOBLY_PROBE_LOG names a file.
//
// Diagnostic only, on a branch; nothing here is meant to ship. It answers, from inside the real
// GUI on the real platform, the questions a headless harness cannot:
//   * cadence  — for every replayed frame, actual dispatch time minus scheduled time
//   * hiccups  — a thread that sleeps 1 ms and records how long it actually slept, so ANY
//                stop-the-world pause (GC, a lock convoy, the OS) shows as a gap whatever caused it
//   * lockwait — how long TapBus.send waits for app.mu, per frame
//   * heap     — Boehm's heap size, sampled
// Counters are fixed-size and updated atomically or racily-but-harmlessly: the probe must not add
// allocations or locks to the path it is measuring.
module main

import os
import time
import sync.stdatomic

fn C.GC_get_heap_size() usize
fn C.GC_get_total_bytes() usize

__global (
	probe_active      bool
	probe_out         string
	probe_late        [6]u64 // <1 ms, 1-10, 10-100, 100-1000, >1000 ms
	probe_late_max_us u64
	probe_late_n      u64
	probe_lock_n      u64
	probe_lock_us     u64
	probe_lock_max_ns u64
	probe_hic         [6]u64 // <20 ms, 20-50, 50-200, 200-1000, >1000 ms
	probe_hic_max_ms  u64
	probe_hic_n       u64
	probe_heap_min_mb u64
	probe_heap_max_mb u64
	probe_bytes_start u64
	probe_bytes_end   u64
	probe_run_s       int
)

fn probe_init() {
	probe_out = os.getenv('BLOBLY_PROBE_LOG')
	probe_active = probe_out != ''
	probe_heap_min_mb = u64(1) << 62
}

// probe_note_late records one replayed frame's lateness in milliseconds (negative = early).
fn probe_note_late(ms f64) {
	if !probe_active {
		return
	}
	stdatomic.add_u64(&probe_late_n, 1)
	i := if ms < 1.0 {
		0
	} else if ms < 10.0 {
		1
	} else if ms < 100.0 {
		2
	} else if ms < 1000.0 {
		3
	} else {
		4
	}
	stdatomic.add_u64(&probe_late[i], 1)
	us := if ms > 0 { u64(ms * 1000.0) } else { u64(0) }
	if us > probe_late_max_us {
		probe_late_max_us = us // racy, and a probe can live with a lost max
	}
}

fn probe_lock_begin() i64 {
	if !probe_active {
		return 0
	}
	return time.sys_mono_now()
}

fn probe_lock_end(t0 i64) {
	if t0 == 0 {
		return
	}
	d := u64(time.sys_mono_now() - t0)
	stdatomic.add_u64(&probe_lock_n, 1)
	stdatomic.add_u64(&probe_lock_us, int(d / 1000))
	if d > probe_lock_max_ns {
		probe_lock_max_ns = d
	}
}

// probe_hiccup_loop is the stall detector: it asks for 1 ms and records what it got.
fn probe_hiccup_loop() {
	mut k := 0
	for {
		t := time.sys_mono_now()
		time.sleep(time.millisecond)
		ms := u64((time.sys_mono_now() - t) / 1_000_000)
		i := if ms < 20 {
			0
		} else if ms < 50 {
			1
		} else if ms < 200 {
			2
		} else if ms < 1000 {
			3
		} else {
			4
		}
		probe_hic[i]++
		probe_hic_n++
		if ms > probe_hic_max_ms {
			probe_hic_max_ms = ms
		}
		k++
		if k % 200 == 0 {
			h := u64(C.GC_get_heap_size()) / 1048576
			if h < probe_heap_min_mb {
				probe_heap_min_mb = h
			}
			if h > probe_heap_max_mb {
				probe_heap_max_mb = h
			}
		}
	}
}

fn probe_summary() string {
	mut s := ''
	s += 'replay_frames=${probe_late_n}\n'
	lm := f64(probe_late_max_us) / 1000.0
	s += 'late_lt1ms=${probe_late[0]} late_1_10ms=${probe_late[1]} late_10_100ms=${probe_late[2]} late_100_1000ms=${probe_late[3]} late_gt1000ms=${probe_late[4]} late_max_ms=${lm:.1f}\n'
	avg := if probe_lock_n > 0 { f64(probe_lock_us) / f64(probe_lock_n) } else { 0.0 }
	lkm := f64(probe_lock_max_ns) / 1e6
	lkt := f64(probe_lock_us) / 1000.0
	s += 'lockwait_n=${probe_lock_n} lockwait_avg_us=${avg:.1f} lockwait_max_ms=${lkm:.1f} lockwait_total_ms=${lkt:.0f}\n'
	s += 'hiccup_samples=${probe_hic_n} hic_lt20ms=${probe_hic[0]} hic_20_50=${probe_hic[1]} hic_50_200=${probe_hic[2]} hic_200_1000=${probe_hic[3]} hic_gt1000=${probe_hic[4]} hic_max_ms=${probe_hic_max_ms}\n'
	alloc := f64(probe_bytes_end - probe_bytes_start) / 1048576.0
	rate := if probe_run_s > 0 { alloc / f64(probe_run_s) } else { 0.0 }
	s += 'alloc_mb=${alloc:.0f} alloc_mb_per_s=${rate:.1f}
'
	s += 'heap_min_mb=${probe_heap_min_mb} heap_max_mb=${probe_heap_max_mb}\n'
	return s
}

// probe_driver starts the run once the GUI is up, lets it play for `secs`, then writes the
// summary and leaves. The OS reclaims the rest; a probe does not need a tidy shutdown.
fn probe_driver(app &App, secs int) {
	time.sleep(1500 * time.millisecond)
	mut a := unsafe { app }
	a.start()
	probe_bytes_start = u64(C.GC_get_total_bytes())
	run_s := if secs > 0 { secs } else { 70 }
	probe_run_s = run_s
	time.sleep(run_s * time.second)
	probe_bytes_end = u64(C.GC_get_total_bytes())
	os.write_file(probe_out, probe_summary()) or {}
	exit(0)
}
