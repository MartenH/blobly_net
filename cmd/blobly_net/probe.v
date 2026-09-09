// probe.v — replay stutter instrumentation. INERT unless BLOBLY_PROBE_LOG names a file.
//
// A diagnostic dev hook in the shape of VGUI_FRAMES. It answers, from inside the real GUI on the
// real platform, the questions a headless harness cannot:
//   * cadence  — for every replayed frame, dispatch time minus the player's due time for it
//   * hiccups  — a thread that asks for 1 ms and records what it got, so ANY stop-the-world
//                pause (GC, a lock convoy, the OS) shows as a gap whatever caused it — and,
//                beside each gap, whether Boehm's collection counter moved across it
//   * lockwait — how long TapBus.send waits for app.mu, per frame
//   * heap     — Boehm's heap size, sampled; and bytes ALLOCATED over the run, which is the
//                number that decides how often the collector runs
// Counters are fixed-size and updated atomically or racily-but-harmlessly: the probe must not add
// allocations or locks to the path it is measuring. Its two hot-path touches are a bool test each.
//
// THE RUN IS STARTED BY main.v's AUTOSTART GATE, on the GUI thread, after the GL context has
// settled — BLOBLY_PROBE_LOG implies BLOBLY_AUTOSTART. The first version started it from this
// thread after a wall-clock sleep, which is exactly the trigger that gate exists to avoid: a
// Boehm collection from a worker thread inside the settle window faults in GC_mark_from
// (see the comment at the gate). A GC instrument must not reproduce the crash it observes past.
module main

import os
import time
import sync.stdatomic

// Histogram edges, beside the counters they describe. Five buckets each: below the first edge,
// between each pair, above the last. The hiccup ladder starts at 20 ms because the detector's
// resolution is the OS scheduler quantum — on Windows Sleep(1) returns after ~16 ms unless
// somebody has called timeBeginPeriod, and nothing in this app does — so a gap below that is
// the platform, not a stall, and the sample count is what the platform allowed.
const late_edges_ms = [1.0, 10.0, 100.0, 1000.0]!
const hic_edges_ms = [20.0, 50.0, 200.0, 1000.0]!

// probe_heap_every_ms: heap sampled on ELAPSED time, not on a sample count, because the count
// runs at whatever rate the quantum gives.
const probe_heap_every_ms = 200.0

fn C.GC_get_gc_no() u32

__global (
	probe_active        bool
	probe_measuring     bool // the run is up: counters record from here, not from process start
	probe_start_refused bool // the autostart gate called start() and the project refused it
	probe_out           string
	probe_late          [5]u64 // by late_edges_ms
	probe_late_max_us   u64
	probe_late_n        u64
	probe_late_unscored u64 // released across a loop wrap: the schedule had moved on
	probe_lock_n        u64
	probe_lock_us       u64
	probe_lock_max_us   u64
	probe_hic           [5]u64 // by hic_edges_ms
	probe_hic_gc        u64 // gaps of 20 ms or more across which a collection happened
	probe_hic_max_ms    u64
	probe_hic_n         u64
	probe_heap_min_mb   u64
	probe_heap_max_mb   u64
	probe_bytes_start   u64
	probe_bytes_end     u64
	probe_run_s         int
)

fn bucket(x f64, edges [4]f64) int {
	for i in 0 .. 4 {
		if x < edges[i] {
			return i
		}
	}
	return 4
}

fn heap_mb() u64 {
	return u64(gc_heap_usage().heap_size) / 1048576
}

// gc_count is Boehm's collection counter, or 0 where there is no Boehm to ask — inside the
// comptime guard so a `-gc none` build links, which a bare C declaration would not.
fn gc_count() u32 {
	$if gcboehm ? {
		return C.GC_get_gc_no()
	}
	return 0
}

fn probe_init() {
	probe_out = os.getenv('BLOBLY_PROBE_LOG')
	probe_active = probe_out != ''
}

// probe_begin marks the measurement boundary: the run is up. Everything sampled before it —
// window creation, the GL context, font loading, the settle frames — is startup, and a
// slow one would otherwise read as replay stalls and a pre-run heap in the summary. The heap
// extremes start from one real sample here rather than a sentinel. CALLED BY THE GATE that
// starts the run, on the same thread, BEFORE start(): start() spawns the replay workers
// inside itself, so any boundary drawn after it — a driver polling `running`, or the gate
// after the call returned — could miss the first frames they score. Every counter is gated
// on the flag this sets (codex on #299, rounds 1 to 3).
fn probe_begin() {
	h := heap_mb()
	probe_heap_min_mb = h
	probe_heap_max_mb = h
	probe_bytes_start = u64(gc_heap_usage().total_bytes)
	probe_measuring = true
}

// probe_note_late records one replayed frame's lateness in playback-clock ms. The player never
// releases a frame early, so a negative value means the schedule moved under it: a batch that
// straddles a loop wrap carries pass N's tail beside pass N+1's head, and by the time this runs
// the player's base is the new pass's. Those frames are counted, not scored — scoring them
// against the new base would file the ones a stall delayed as on-time.
fn probe_note_late(ms f64) {
	if !probe_measuring {
		return
	}
	if ms < -1.0 {
		stdatomic.add_u64(&probe_late_unscored, 1)
		return
	}
	stdatomic.add_u64(&probe_late_n, 1)
	stdatomic.add_u64(&probe_late[bucket(ms, late_edges_ms)], 1)
	us := if ms > 0 { u64(ms * 1000.0) } else { u64(0) }
	if us > probe_late_max_us {
		probe_late_max_us = us // racy, and a probe can live with a lost max
	}
}

fn probe_lock_begin() i64 {
	if !probe_measuring {
		return 0
	}
	return time.sys_mono_now()
}

fn probe_lock_end(t0 i64) {
	if t0 == 0 {
		return
	}
	us := u64(time.sys_mono_now() - t0) / 1000
	stdatomic.add_u64(&probe_lock_n, 1)
	stdatomic.add_u64(&probe_lock_us, int(us))
	if us > probe_lock_max_us {
		probe_lock_max_us = us
	}
}

// probe_hiccup_loop is the stall detector: it asks for 1 ms and records what it got.
fn probe_hiccup_loop() {
	mut last_heap := time.sys_mono_now()
	for {
		if !probe_measuring {
			time.sleep(20 * time.millisecond)
			continue
		}
		g0 := gc_count()
		t := time.sys_mono_now()
		time.sleep(time.millisecond)
		now := time.sys_mono_now()
		ms := f64(now - t) / 1e6
		b := bucket(ms, hic_edges_ms)
		probe_hic[b]++
		probe_hic_n++
		if b > 0 && gc_count() != g0 {
			probe_hic_gc++
		}
		if u64(ms) > probe_hic_max_ms {
			probe_hic_max_ms = u64(ms)
		}
		if f64(now - last_heap) / 1e6 >= probe_heap_every_ms {
			last_heap = now
			h := heap_mb()
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
	late_max := f64(probe_late_max_us) / 1000.0
	lock_avg := if probe_lock_n > 0 { f64(probe_lock_us) / f64(probe_lock_n) } else { 0.0 }
	lock_max := f64(probe_lock_max_us) / 1000.0
	lock_total := f64(probe_lock_us) / 1000.0
	alloc := f64(probe_bytes_end - probe_bytes_start) / 1048576.0
	rate := if probe_run_s > 0 { alloc / f64(probe_run_s) } else { 0.0 }
	mut s := ''
	s += 'replay_frames=${probe_late_n} late_unscored_wrap=${probe_late_unscored}\n'
	s += 'late_lt1ms=${probe_late[0]} late_1_10ms=${probe_late[1]} late_10_100ms=${probe_late[2]} late_100_1000ms=${probe_late[3]} late_gt1000ms=${probe_late[4]} late_max_ms=${late_max:.1f}\n'
	s += 'lockwait_n=${probe_lock_n} lockwait_avg_us=${lock_avg:.1f} lockwait_max_ms=${lock_max:.1f} lockwait_total_ms=${lock_total:.0f}\n'
	s += 'hiccup_samples=${probe_hic_n} hic_lt20ms=${probe_hic[0]} hic_20_50=${probe_hic[1]} hic_50_200=${probe_hic[2]} hic_200_1000=${probe_hic[3]} hic_gt1000=${probe_hic[4]} hic_max_ms=${probe_hic_max_ms} hic_with_gc=${probe_hic_gc}\n'
	s += 'alloc_mb=${alloc:.0f} alloc_mb_per_s=${rate:.1f}\n'
	s += 'heap_min_mb=${probe_heap_min_mb} heap_max_mb=${probe_heap_max_mb}\n'
	return s
}

// probe_driver waits for the gate to open the measurement, lets the run play for `secs`, then
// writes the summary and leaves. The OS reclaims the rest; a probe does not need a tidy shutdown.
// A summary that cannot be written goes to stderr and the exit status says so — a 70 s run that
// exits 0 with no file would read as a run that never happened.
fn probe_driver(secs int) {
	// Bounded: the gate fires after its settle frames, which a cold GL start can stretch to
	// seconds but not to a minute; and a refused Start is reported by the gate itself. An
	// unattended probe that waits forever on either is a run nobody can account for.
	deadline := time.sys_mono_now() + 60 * u64(time.second)
	for {
		if probe_measuring {
			break
		}
		if probe_start_refused {
			eprintln('probe: the project refused to start; nothing to measure')
			exit(2)
		}
		if time.sys_mono_now() > deadline {
			eprintln('probe: the run did not start within 60 s; nothing to measure')
			exit(2)
		}
		time.sleep(20 * time.millisecond)
	}
	run_s := if secs > 0 { secs } else { 70 }
	probe_run_s = run_s
	time.sleep(run_s * time.second)
	probe_bytes_end = u64(gc_heap_usage().total_bytes)
	summary := probe_summary()
	os.write_file(probe_out, summary) or {
		eprintln('probe: cannot write ${probe_out}: ${err}')
		eprintln(summary)
		exit(1)
	}
	exit(0)
}
