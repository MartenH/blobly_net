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
import endrule

// Histogram edges, beside the counters they describe. Five buckets each: below the first edge,
// between each pair, above the last. The hiccup ladder starts at 20 ms because the detector's
// resolution is the OS scheduler quantum: 1 ms on Windows once the process has asked for it
// (player.raise_timer_resolution, at startup — #300), 15.6 ms when it has not, or when Windows
// 11 drops the request for a minimised window. Below 20 ms is therefore the platform, not a
// stall, on every configuration this runs in; the sample count says what the platform allowed.
const late_edges_ms = [1.0, 10.0, 100.0, 1000.0]!
const hic_edges_ms = [20.0, 50.0, 200.0, 1000.0]!

// probe_heap_every_ms: heap sampled on ELAPSED time, not on a sample count, because the count
// runs at whatever rate the quantum gives.
const probe_heap_every_ms = 200.0

fn C.GC_get_gc_no() u32

__global (
	probe_active        bool
	// The GATE: 1 while counters record, armed by the gate before start(), taken back on a
	// refusal, dropped by the driver at the deadline. An atomic word and not a bool, because
	// the close is Dekker's problem: the driver stores "closed" and then loads the in-flight
	// count while a writer increments the count and then loads the gate — with a plain store
	// the driver's could sit in its store buffer past its load, and both would proceed
	// (codex on #299 round 10). Sequentially consistent atomics on both sides close it.
	probe_gate          u64
	// Where the hiccup sampler's first interval begins: the boundary, set by probe_begin,
	// so a collection during start() — inside the measurement on purpose — is in a bucket
	// even though the sampler was asleep in its idle poll when the gate opened.
	probe_hic_prev_ns   u64
	probe_hic_gprev     u32
	// Emissions counted through note_emit by EVERY emitter, so the lock-wait totals — which
	// are every instrumented acquisition, not the replay's alone — can be read against them.
	probe_emit_n        u64
	probe_groups_failed u64
	// What start() came to, published for the driver's poll on another thread: 0 not yet,
	// 1 the run is up, 2 the project refused. One atomic word, not two plain bools, so the
	// driver's read is ordered after the gate's write (codex on #299 round 11).
	probe_start_state   u64
	probe_out           string
	probe_late          [5]u64 // by late_edges_ms
	probe_late_max_us   u64
	probe_late_n        u64
	probe_late_unscored u64 // a negative lateness: the instrument's defect, never the run's
	probe_lock_n        u64
	probe_lock_us       u64
	probe_lock_max_us   u64
	probe_hic           [5]u64 // by hic_edges_ms
	probe_hic_gc        u64 // gaps of 20 ms or more across which a collection happened
	probe_hic_max_ms    u64
	probe_hic_n         u64
	probe_heap_min_mb   u64
	probe_heap_max_mb   u64
	// The LIVE set: heap minus free, sampled right after a collection, which is when free
	// bytes say what survived. That number is what a pause's LENGTH is proportional to, where
	// the heap size is what its FREQUENCY is. Sampled from 10 s into the measurement, since
	// the measurement opens before Start and the recording is loaded by the run.
	probe_live_min_mb   u64
	probe_live_max_mb   u64
	probe_live_n        u64
	probe_bytes_start   u64
	probe_bytes_end     u64
	// The measured interval: from the boundary to the endpoint, as it actually ran. The
	// requested N seconds is a target for the deadline, never the divisor.
	probe_begin_ns      u64
	probe_run_s         f64
	// Writers that passed the gate and have not finished: a lock waiter that entered before
	// the flag dropped still adds its wait when the lock comes, which can be after any fixed
	// grace. The driver waits for this to reach zero before it reads a counter.
	probe_inflight      u64
	// WHERE the bytes go: allocation attributed to a section of the per-frame path, as the
	// difference in Boehm's total across it. Other threads allocate inside the window too, so
	// a single sample is noise; the MEAN over hundreds of thousands is the section's own
	// cost plus the others' rate times the section's duration, which for microsecond
	// sections is negligible. Indexed by ProbeSec.
	probe_sec_n         [8]u64
	probe_sec_sum       [8]u64
)

// ProbeSec names a section of the per-frame path. The enum is the index into the two arrays
// above and the name in the summary, so a section cannot be added to one and not the other.
enum ProbeSec {
	send
	emit
	inner
	after
	rx_handle
	rx_recv
	tick
	render
}

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

fn live_mb() u64 {
	u := gc_heap_usage()
	return u64(u.heap_size - u.free_bytes) / 1048576
}

// gc_count is Boehm's collection counter, or 0 where there is no Boehm to ask — inside the
// comptime guard so a `-gc none` build links, which a bare C declaration would not.
fn gc_count() u32 {
	$if gcboehm ? {
		return C.GC_get_gc_no()
	}
	return 0
}

// alloc_total is Boehm's monotonic allocation counter, or 0 without Boehm.
fn alloc_total() u64 {
	return u64(gc_heap_usage().total_bytes)
}

// probe_alloc_mark opens an attribution window; probe_alloc_note closes it onto a section.
// probe_alloc_mark opens an attribution window. It only READS the gate: a mark is not always
// followed by its note — an RX timeout and a paused replay both `continue` past theirs — so
// a mark that counted itself in-flight left the driver waiting forever (codex on #300).
// The note is the writer, and it admits and leaves around its own write.
fn probe_alloc_mark() u64 {
	if !probe_active || stdatomic.load_u64(&probe_gate) == 0 {
		return 0
	}
	return alloc_total()
}

fn probe_alloc_note(sec ProbeSec, b0 u64) {
	if b0 == 0 {
		return
	}
	if !probe_admit() {
		return
	}
	mut d := alloc_total() - b0
	// The atomic add takes an int: a window that spans more than 2 GiB of allocation (a
	// recording loaded from the menu inside one render frame) would otherwise go in as a
	// negative and wrap the total.
	if d > u64(max_int) {
		d = u64(max_int)
	}
	stdatomic.add_u64(&probe_sec_n[int(sec)], 1)
	stdatomic.add_u64(&probe_sec_sum[int(sec)], int(d))
	probe_leave()
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
	probe_bytes_start = alloc_total()
	probe_begin_ns = time.sys_mono_now()
	probe_hic_prev_ns = probe_begin_ns
	probe_hic_gprev = gc_count()
	stdatomic.store_u64(&probe_gate, 1)
}

// probe_admit is how every counter writer enters: counted in-flight FIRST, then the
// measurement asked whether it is open. Asked first and counted second, a writer that read
// the flag just before the driver dropped it was invisible to the driver's wait and wrote
// after the summary had been read (codex on #299 round 7). Now the driver drops the flag and
// waits for zero, and a writer counted before the drop is waited for, one counted after it
// sees the flag down and leaves; there is no order of the two in which a write escapes.
fn probe_admit() bool {
	// A plain bool first: with no probe configured this is the hot path's whole cost, and an
	// atomic pair per lock take on every send is not "inert" (codex on #299 round 8).
	if !probe_active {
		return false
	}
	stdatomic.add_u64(&probe_inflight, 1)
	if stdatomic.load_u64(&probe_gate) == 1 {
		return true
	}
	stdatomic.sub_u64(&probe_inflight, 1)
	return false
}

// probe_note_emit counts one emission through note_emit, whoever emitted it.
fn probe_note_emit() {
	if !probe_admit() {
		return
	}
	stdatomic.add_u64(&probe_emit_n, 1)
	probe_leave()
}

// probe_group_failed records a replay group that ended without running.
fn probe_group_failed() {
	if !probe_active {
		return
	}
	stdatomic.add_u64(&probe_groups_failed, 1)
}

fn probe_leave() {
	stdatomic.sub_u64(&probe_inflight, 1)
}

// probe_note_late records one replayed frame's lateness in playback-clock ms against the
// schedule the player released it on — a per-entry due time, so a batch that crossed one or
// several loop wraps scores exactly. The player never releases early; a negative value is
// counted as a defect of the instrument, not scored.
fn probe_note_late(ms f64) {
	if !probe_admit() {
		return
	}
	defer {
		probe_leave()
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
	if !probe_admit() {
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
	probe_leave()
}

// close_final_hiccup_interval records the stretch from where the sampler's last COMPLETE
// interval ended to the endpoint. Called by the driver AFTER the gate is down and every admitted
// writer has left, so it is the only thread touching these counters.
//
// The DECISION is endrule's (extracted after six repairs in one review, #302); this applies it
// to the counters and the bucket table, which is all that has to live in the main package.
fn close_final_hiccup_interval(closed_ns u64, closed_gc u32, closed_live u64) {
	c := endrule.final_interval(probe_hic_prev_ns, closed_ns, probe_begin_ns, probe_hic_gprev,
		closed_gc)
	if !c.record {
		return
	}
	b := bucket(c.ms, hic_edges_ms)
	probe_hic[b]++
	probe_hic_n++
	// b > 0 because a collection inside a sub-20ms interval is not what the attribution is for:
	// the question `hic_with_gc` answers is how many of the SLOW intervals had one.
	if b > 0 && c.collected {
		probe_hic_gc++
	}
	if c.sample_live {
		if probe_live_n == 0 || closed_live < probe_live_min_mb {
			probe_live_min_mb = closed_live
		}
		if closed_live > probe_live_max_mb {
			probe_live_max_mb = closed_live
		}
		probe_live_n++
	}
	if u64(c.ms) > probe_hic_max_ms {
		probe_hic_max_ms = u64(c.ms)
	}
}

// probe_hiccup_loop is the stall detector: it asks for 1 ms and records what it got.
// The interval is WAKE TO WAKE, and the collection counter is read at each wake: a gap
// measured only across the sleep left the loop's own work between two sleeps — the counter
// updates, the heap sample — outside every window, and a collection landing there was in no
// bucket and in no `hic_with_gc` (codex on #299 round 5). Now every instant of the
// measurement is inside exactly one interval.
fn probe_hiccup_loop() {
	mut last_heap := time.sys_mono_now()
	mut prev := u64(0)
	mut gprev := u32(0)
	for {
		if stdatomic.load_u64(&probe_gate) == 0 {
			prev = 0
			time.sleep(5 * time.millisecond)
			continue
		}
		if prev == 0 {
			// From the BOUNDARY, not from this wake: the gate opened while this thread was
			// in its idle poll, and start() ran meanwhile — inside the measurement, so a
			// collection there belongs in a bucket (codex on #299 round 10).
			prev = probe_hic_prev_ns
			gprev = probe_hic_gprev
			last_heap = prev
		}
		time.sleep(time.millisecond)
		if !probe_admit() {
			// The measurement closed during the sleep. This interval is NOT dropped — the part
			// of it inside the run is closed by the driver at the endpoint, from what this loop
			// published above; see close_final_hiccup_interval.
			prev = 0
			continue
		}
		now := time.sys_mono_now()
		gnow := gc_count()
		// ADMITTED IS NOT THE SAME AS IN-RUN. This thread passed the gate while it was open and
		// may then have been descheduled past the endpoint: the interval it is holding runs off
		// the end of the measurement, and bucketing it reports an arbitrary scheduling delay
		// AFTER the run as an in-run stall — in the histogram whose whole job is to find stalls
		// (codex round 1 on #302). Its `gnow` is equally post-close, so a collection outside the
		// measurement would be attributed to an interval inside it (round 2).
		//
		// So it does not bucket, and does not publish. The in-run part of exactly this interval
		// is closed by the driver at the endpoint (close_final_hiccup_interval), from the
		// boundary the last COMPLETE sample published — which covers it once, and only the part
		// that was measured. Clamping a sample to a published close was the first answer and
		// needed a second word for the endpoint; this needs none.
		if stdatomic.load_u64(&probe_gate) == 0 {
			probe_leave()
			continue
		}
		ms := f64(now - prev) / 1e6
		b := bucket(ms, hic_edges_ms)
		probe_hic[b]++
		probe_hic_n++
		if b > 0 && gnow != gprev {
			probe_hic_gc++
		}
		if gnow != gprev && now - probe_begin_ns > 10 * u64(time.second) {
			l := live_mb()
			if probe_live_n == 0 || l < probe_live_min_mb {
				probe_live_min_mb = l
			}
			if l > probe_live_max_mb {
				probe_live_max_mb = l
			}
			probe_live_n++
		}
		prev = now
		gprev = gnow
		// PUBLISHED, so the endpoint interval can be closed by the driver after this thread has
		// stopped (#302). It cannot be closed HERE: the branch that would do it runs with the
		// gate already down, outside probe_inflight, and writing a bucket there is the very race
		// round 5 closed — probe_summary() reading counters a sampler is still changing.
		probe_hic_prev_ns = now
		probe_hic_gprev = gnow
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
		// Admitted through the LAST write of the sample: left earlier, the driver could read
		// the summary while the maximum and the heap extremes were still being written
		// (codex on #299 round 8).
		probe_leave()
	}
}

fn probe_summary() string {
	late_max := f64(probe_late_max_us) / 1000.0
	lock_avg := if probe_lock_n > 0 { f64(probe_lock_us) / f64(probe_lock_n) } else { 0.0 }
	lock_max := f64(probe_lock_max_us) / 1000.0
	lock_total := f64(probe_lock_us) / 1000.0
	alloc := f64(probe_bytes_end - probe_bytes_start) / 1048576.0
	rate := if probe_run_s > 0 { alloc / probe_run_s } else { 0.0 }
	mut s := ''
	s += 'replay_frames=${probe_late_n} late_negative=${probe_late_unscored}\n'
	s += 'late_lt1ms=${probe_late[0]} late_1_10ms=${probe_late[1]} late_10_100ms=${probe_late[2]} late_100_1000ms=${probe_late[3]} late_gt1000ms=${probe_late[4]} late_max_ms=${late_max:.1f}\n'
	// lockwait covers EVERY instrumented acquisition — every emitter's sends, not the replay's
	// alone — so the emit count is printed beside it; on a project whose only emitter is
	// the replay, emit_n equals replay_frames and lockwait_n is five per frame.
	s += 'lockwait_n=${probe_lock_n} lockwait_avg_us=${lock_avg:.1f} lockwait_max_ms=${lock_max:.1f} lockwait_total_ms=${lock_total:.0f} emit_n=${probe_emit_n} (all emitters)\n'
	s += 'hiccup_samples=${probe_hic_n} hic_lt20ms=${probe_hic[0]} hic_20_50=${probe_hic[1]} hic_50_200=${probe_hic[2]} hic_200_1000=${probe_hic[3]} hic_gt1000=${probe_hic[4]} hic_max_ms=${probe_hic_max_ms} hic_with_gc=${probe_hic_gc}\n'
	s += 'measured_s=${probe_run_s:.2f} alloc_mb=${alloc:.0f} alloc_mb_per_s=${rate:.1f}\n'
	s += 'heap_min_mb=${probe_heap_min_mb} heap_max_mb=${probe_heap_max_mb} live_after_gc_min_mb=${probe_live_min_mb} live_after_gc_max_mb=${probe_live_max_mb} collections_sampled=${probe_live_n}\n'
	for sec in [ProbeSec.send, .emit, .inner, .after, .rx_handle, .rx_recv, .tick, .render] {
		i := int(sec)
		if probe_sec_n[i] == 0 {
			continue
		}
		mean := f64(probe_sec_sum[i]) / f64(probe_sec_n[i])
		mbs := if probe_run_s > 0 {
			f64(probe_sec_sum[i]) / 1048576.0 / probe_run_s
		} else {
			0.0
		}
		s += 'sec_${sec}: n=${probe_sec_n[i]} mean_bytes=${mean:.0f} mb_per_s=${mbs:.1f}\n'
	}
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
		st := stdatomic.load_u64(&probe_start_state)
		if st == 1 {
			break
		}
		if st == 2 {
			eprintln('probe: the project refused to start; nothing to measure')
			exit(2)
		}
		if time.sys_mono_now() > deadline {
			eprintln('probe: the run did not start within 60 s; nothing to measure')
			exit(2)
		}
		time.sleep(20 * time.millisecond)
	}
	want_s := if secs > 0 { secs } else { 70 }
	// The deadline is N seconds after the BOUNDARY, not after this thread noticed the run:
	// start() had already run under the measurement for as long as it took, and a rate
	// divided by N over an interval of N plus that is not comparable between projects
	// (codex on #299 round 6). And the divisor is the interval as measured.
	end_ns := probe_begin_ns + u64(want_s) * u64(time.second)
	for time.sys_mono_now() < end_ns {
		time.sleep(20 * time.millisecond)
	}
	// Sampling STOPS before the summary is read: with the flag still up, the workers and
	// the hiccup thread went on changing the counters while probe_summary() read them, so
	// its fields described different intervals and a histogram need not sum to its total
	// (round 5). Then every writer that passed the gate is waited for — a lock waiter that
	// entered before the flag dropped adds its wait when the lock comes, which a fixed grace
	// cannot bound (round 6) — and only then is anything read.
	// THE ENDPOINT IS READ IMMEDIATELY BEFORE THE GATE CLOSES, and that ORDER IS A DECISION, not
	// an oversight. A clock read and a store cannot be made atomic, so one of two errors is
	// unavoidable if the driver is preempted between them, and they are not the same size:
	//
	//   read AFTER the store  -> the delay lands INSIDE the final hiccup interval, and a
	//                            scheduling stall that happened after the run is reported as a
	//                            stall during it. A false entry in the histogram whose entire
	//                            job is to find stalls.
	//   read BEFORE the store -> a handful of events admitted in that window are counted after
	//                            the declared endpoint. A rate off by a rounding error.
	//
	// The second is the one to take. This was ordered the other way for one round (codex round 2
	// on #302, correctly describing the admission window) and round 3 found the larger error it
	// created; corrupting the primary output to tidy a rounding error is the wrong trade, and
	// further rounds on the sub-millisecond fuzziness of an endpoint that cannot be atomic will
	// be answered with this comment.
	// THE ENDPOINT: the collection count, the live set and the clock, then the gate — four
	// adjacent reads, no loop and no cross-validation. What #302 asked for is the interval the
	// sampler cannot record and the collection counter across it; the live set comes with the
	// collection because counting one without sampling it makes the summary disagree with itself
	// (codex round 3).
	//
	// TWO IMPERFECTIONS ARE ACCEPTED HERE, DELIBERATELY, and they are written down rather than
	// chased — seven review rounds on this seam produced thirteen findings, every fix creating
	// the next, which is the shape this guide names for stopping (#315 carries the analysis):
	//
	//   * a clock read and a store are not atomic. Preempted between them, a few events are
	//     counted past the declared endpoint — a rate off by a rounding error. The other order
	//     puts a post-run scheduling delay INSIDE the final hiccup interval, a false entry in the
	//     histogram whose whole job is finding stalls, which is the worse error of the two.
	//   * a collection completing during these four reads splits them, and the attribution for
	//     the final interval can be off by one collection. Validating against a second read moves
	//     the split rather than closing it, as rounds 5-7 each demonstrated in turn.
	//
	// Both are bounded by one scheduling quantum at the very end of a run, in a dev instrument
	// whose output is a one-page summary. Neither was better before this PR: the interval was not
	// recorded at all.
	closed_gc := gc_count()
	closed_live := live_mb()
	closed_ns := time.sys_mono_now()
	stdatomic.store_u64(&probe_gate, 0)
	for stdatomic.load_u64(&probe_inflight) > 0 {
		time.sleep(time.millisecond)
	}
	// THE INTERVAL THAT CROSSES THE ENDPOINT BELONGS TO THE MEASUREMENT (#302). A
	// stop-the-world beginning inside the run and ending after it is exactly the stall this
	// probe exists to record, and it is most likely at the end, where a large run has the most
	// to collect. The sampler could only see it by waking to a closed gate, where it may not
	// write — so the interval is closed here instead, between the inflight drain and the first
	// read, where this thread is the only one left. Bucketed to the ENDPOINT, not to now: the
	// part after it was not measured.
	close_final_hiccup_interval(closed_ns, closed_gc, closed_live)
	probe_bytes_end = alloc_total()
	// AFTER THE DRAIN, as before this PR. Tying it to closed_ns instead was scope I added in
	// round 3 answering a finding of my own making, and it dragged the allocation total in after
	// it (round 4), then the ordering of the two (rounds 6-7). The divisor and the histogram do
	// describe slightly different intervals — the drain sits between them — which is a real
	// inconsistency, and an OLD one that #302 did not ask about. Filed as #315 with the analysis
	// rather than fixed by a PR that has already changed its mind three times about it.
	probe_run_s = f64(time.sys_mono_now() - probe_begin_ns) / 1e9
	// A run that replayed NOTHING is not a measurement, whatever start() said: a replay
	// worker refuses after start() has returned — a reader that never came up, a recording
	// that would not decode, a plan that kept no frames — and its refusal reaches the Log,
	// not this thread. Zero frames scored is that outcome, and it exits as one (codex on
	// #299 round 7).
	if probe_late_n == 0 {
		eprintln('probe: the run replayed no frames in ${probe_run_s:.1f} s; nothing to measure (see the Log)')
		exit(3)
	}
	// And a replay GROUP that failed after start() — its recording would not decode, no
	// reader came up, its plan kept nothing — while another played: a summary of the
	// survivors is not the measurement that was asked for (round 10).
	// LOADED, not read: the workers add to it with stdatomic.add_u64, and a plain read of a
	// word another thread is adding to is not defined to see either value (codex round 12 on
	// #299). The inflight drain above has already happened, so this is not a race in practice —
	// it is the one counter in this function still spelled as if it could be.
	groups_failed := stdatomic.load_u64(&probe_groups_failed)
	if groups_failed > 0 {
		eprintln('probe: ${groups_failed} replay group(s) failed to run; the summary would describe the rest (see the Log)')
		exit(3)
	}
	summary := probe_summary()
	os.write_file(probe_out, summary) or {
		eprintln('probe: cannot write ${probe_out}: ${err}')
		eprintln(summary)
		exit(1)
	}
	exit(0)
}
