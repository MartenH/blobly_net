module main

import telem
import vgui

const lane_palette = [
	[u8(66), 135, 245],
	[u8(76), 175, 80],
	[u8(245), 166, 35],
	[u8(233), 80, 80],
	[u8(155), 100, 210],
	[u8(0), 172, 193],
	[u8(233), 110, 170],
	[u8(140), 160, 60],
]

fn draw_tchart(mut app App, trecs []TRec) {
	vis, op := vgui.begin_closable('Trace Chart', app.show_tchart)
	app.show_tchart = op
	if !vis {
		vgui.end()
		return
	}
	// Capture control: Record arms the target's ring (op_arm), Stop freezes it (op_stop),
	// Dump reads the frozen buffer out over ISO-TP into the swimlane. Snapshot the worker-
	// shared state under the mutex (trace_dump_worker writes it from its thread).
	app.mu.lock()
	busy := app.trace_busy
	recording := app.trace_recording
	status := app.trace_status
	freeze := app.trace_freeze
	app.mu.unlock()
	if busy {
		vgui.text_dim('dumping…')
	} else if app.running {
		if recording {
			if vgui.button('Stop##trace') {
				app.send_trace_cmd(telem.op_stop)
				app.set_trace_state(false, 'recording stopped (frozen)')
			}
		} else {
			if vgui.button('Record##trace') {
				if app.send_trace_cmd(telem.op_arm) {
					app.set_trace_state(true, 'recording…')
				}
			}
		}
		vgui.same_line()
		if vgui.button('Dump##trace') {
			spawn trace_dump_worker(app, app.trace_core_mask())
		}
		vgui.same_line()
		vgui.text_dim('Record arms · Stop freezes · Dump reads out (all cores)')
	} else {
		vgui.text_dim('Start a channel, then Record / Dump')
	}
	// A missing manifest does NOT mean a missing endpoint: send_trace_cmd/trace_dump_worker
	// use TraceFrames.or_defaults(), so a default-configured target answers without one. Keep
	// the controls live and say what the manifest WOULD add (names) — a hint, not a gate
	// (codex #65).
	if !app.has_manifest {
		vgui.text_dim('no trace manifest attached — using the default ids; records decode without handler/thread names')
	}
	if status != '' {
		vgui.text_dim(status)
	}
	if freeze != '' { // the target's own report: capturing / frozen-by-trigger / frozen-by-stop
		vgui.text_dim('target: ${freeze}')
	}
	labels, bars, links, span := build_swimlane(app, trecs)
	vgui.text('${trecs.len} records · ${labels.len} lanes · idle lane = derived (gap between thread runs)')
	vgui.text_dim('drag = pan · scroll = zoom · double-click = fit · A/B keys or drag markers (snap to edges; Alt = free) · hover a bar + M = measure it')
	if bars.len > 0 {
		// re-seat the A/B markers into view whenever a new dump (different span) loads.
		if app.cursor_span != f64(span) {
			app.cursor_span = f64(span)
			app.cursor_a = f64(span) * 0.25
			app.cursor_b = f64(span) * 0.75
		}
		vgui.swimlane('##swim', labels, bars, links, span, &app.cursor_a, &app.cursor_b)
		d := if app.cursor_b > app.cursor_a {
			app.cursor_b - app.cursor_a
		} else {
			app.cursor_a - app.cursor_b
		}
		vgui.text('A ${app.cursor_a:.0f} us    B ${app.cursor_b:.0f} us    Δ ${d:.0f} us (${d / 1000:.3f} ms)')
		vgui.same_line()
		if vgui.button('Reset markers') { // re-seat A/B to 1/4 and 3/4 of the view
			app.cursor_a = f64(span) * 0.25
			app.cursor_b = f64(span) * 0.75
		}
	} else {
		vgui.text_dim('press Dump to capture (handler bars + thread/idle lanes appear here)')
	}
	vgui.end()
}

// A real thread interval, for the idle complement below.
struct Span {
	s u64
	e u64
}

// synthesize_idle appends DERIVED idle bars (THREAD id 0) covering the gaps where no real thread
// ran — per core, bounded by that core's captured window. The wire carries only real events (the
// exec-hook targets emit nothing when nothing runs), so idle is the complement, computed here in
// the viewer where it can be seen and measured. Cores that already stream REAL idle records (the
// multicore host path) are left alone. Long gaps chunk at the u16 cpu_us ceiling.
fn synthesize_idle(recs []TRec) []TRec {
	mut out := recs.clone()
	mut cores := []int{}
	for tr in recs {
		if tr.core !in cores {
			cores << tr.core
		}
	}
	for core in cores {
		mut spans := []Span{}
		mut lo := u64(0)
		mut hi := u64(0)
		mut first := true
		mut has_real_idle := false
		for tr in recs {
			if tr.core != core {
				continue
			}
			s0 := tr.abs_us
			e0 := s0 + u64(tr.rec.cpu_us)
			if first || s0 < lo {
				lo = s0
			}
			if first || e0 > hi {
				hi = e0
			}
			first = false
			if tr.rec.kind() == telem.kind_thread {
				if tr.rec.id() == 0 {
					has_real_idle = true
				} else {
					spans << Span{s0, e0}
				}
			}
		}
		if first || has_real_idle || spans.len == 0 {
			continue // nothing captured, or the target already reports idle itself
		}
		spans.sort(a.s < b.s)
		// Gaps below ~20 us are context-switch/kernel/hook overhead between back-to-back slices —
		// a READY thread is usually waiting through them, so painting them "idle" lies at high
		// zoom (idle can't run while someone is ready). Only real gaps become idle bars.
		min_gap := u64(20)
		mut cur := lo
		for sp in spans {
			if sp.s > cur && sp.s - cur >= min_gap {
				out << idle_recs(core, cur, sp.s - cur)
			}
			if sp.e > cur {
				cur = sp.e
			}
		}
		if hi > cur && hi - cur >= min_gap {
			out << idle_recs(core, cur, hi - cur)
		}
	}
	return out
}

// idle_recs emits one derived idle interval as TRec(s), chunked so each fits Record's u16 cpu_us.
fn idle_recs(core int, start u64, dur u64) []TRec {
	mut out := []TRec{}
	mut s0 := start
	mut left := dur
	for left > 0 {
		chunk := if left > 0xFFFF { u64(0xFFFF) } else { left }
		out << TRec{
			ch:     0
			core:   core
			abs_us: s0
			rec:    telem.Record{
				entity_id: u16(telem.kind_thread) << 14 // THREAD id 0 = idle
				info:      telem.reason_block           // idle can't be "preempted" — no hatch
				cpu_us:    u16(chunk)
			}
		}
		s0 += chunk
		left -= chunk
	}
	return out
}

// build_swimlane turns decoded records into swimlane lanes + bars. A dumped stream mixes entity
// kinds, each an interval [start, start+cpu): FB (handler) runs, THREAD runs, and ISR runs each
// get a duration bar on their own lane; CONTROL records (block headers / epochs) are framing and
// were stripped by the dump worker. Lanes are grouped FB → threads → interrupts, by core.
// handler_core / thread_core resolve the core of a manifest id (-1 = unknown / no manifest).
fn handler_core(app &App, id u16) int {
	if h := app.manifest.lookup(id) {
		return h.core
	}
	return -1
}

// fb_label prefixes the handler name with its core (c0/c1…) so a lane shows which
// core it belongs to.
fn fb_label(app &App, id u16) string {
	c := handler_core(app, id)
	base := app.manifest.label(id)
	return if c >= 0 { 'c${c}  ${base}' } else { base }
}

// split_lane_key splits a '<core>:<id>' thread/isr lane key back into its parts.
fn split_lane_key(k string) (int, u16) {
	parts := k.split(':')
	if parts.len != 2 {
		return 0, 0
	}
	return parts[0].int(), u16(parts[1].int())
}

// thread_core_label labels a THREAD lane, prefixed with its (block) core. id 0 is idle (no
// manifest row); a real thread resolves its name from the manifest, else "thread N".
fn thread_core_label(app &App, core int, id u16) string {
	base := if id == 0 { 'idle' } else { app.manifest.thread_label(core, id) }
	if id != 0 {
		if t := app.manifest.by_tid[telem.tkey(core, id)] {
			if t.prio >= 0 {
				return 'c${core}  ${base} p${t.prio}'
			}
		}
	}
	return 'c${core}  ${base}'
}

fn build_swimlane(app &App, trecs []TRec) ([]string, []vgui.Bar, []vgui.Link, f32) {
	if trecs.len == 0 {
		return []string{}, []vgui.Bar{}, []vgui.Link{}, f32(1)
	}
	// distinct lanes, first-seen. FB handler ids are globally unique; THREAD and ISR lanes are
	// keyed by (block core, id) — via TRec.core from the block header — so each core's idle (id 0,
	// shared across cores) and per-core ISR vectors get their own lane rather than merging.
	// lanes are laid out in a STABLE order (not first-seen-in-capture, which shuffles every
	// dump): handlers by manifest id, threads by RTOS priority (p0 at the top — the hierarchy
	// preemption is read against), unknown-prio threads after, by id.
	mut hids := []u16{}
	mut sh := map[u16]bool{}
	mut tkeys := []string{} // '<core>:<id>' for THREAD (incl. idle id 0)
	mut tseen := map[string]bool{}
	mut ikeys := []string{} // '<core>:<id>' for ISR
	mut iseen := map[string]bool{}
	for tr in trecs {
		r := tr.rec
		if r.kind() == telem.kind_fb {
			if r.id() !in sh {
				sh[r.id()] = true
				hids << r.id()
			}
		} else if r.kind() == telem.kind_thread {
			k := '${tr.core}:${r.id()}'
			if k !in tseen {
				tseen[k] = true
				tkeys << k
			}
		} else if r.kind() == telem.kind_isr {
			k := '${tr.core}:${r.id()}'
			if k !in iseen {
				iseen[k] = true
				ikeys << k
			}
		}
	}
	hids.sort()
	tkeys.sort_with_compare(fn [app] (a &string, b &string) int {
		acore, aid := split_lane_key(a)
		bcore, bid := split_lane_key(b)
		ap := if t := app.manifest.by_tid[telem.tkey(acore, aid)] { t.prio } else { -1 }
		bp := if t := app.manifest.by_tid[telem.tkey(bcore, bid)] { t.prio } else { -1 }
		// known priorities first (ascending: p0 on top), then unknowns by id
		if ap >= 0 && bp >= 0 {
			if ap != bp {
				return if ap < bp { -1 } else { 1 }
			}
			return if aid < bid {
				-1
			} else {
				if aid > bid { 1 } else { 0 }
			}
		}
		if ap >= 0 {
			return -1
		}
		if bp >= 0 {
			return 1
		}
		return if aid < bid {
			-1
		} else {
			if aid > bid { 1 } else { 0 }
		}
	})
	ikeys.sort()
	// lay lanes out grouped by core: FB (handler) lanes first (by core), then a separator + thread
	// lanes (by core; real threads before idle within a core), then a separator + ISR lanes. So
	// each core's fb / thread / interrupt traces are visually grouped and split.
	mut lane_of := map[string]int{}
	mut labels := []string{}
	for core in 0 .. 16 {
		for id in hids {
			if handler_core(app, id) == core && 'h${id}' !in lane_of {
				lane_of['h${id}'] = labels.len
				labels << fb_label(app, id)
			}
		}
	}
	for id in hids { // unknown-core handlers (no manifest) last
		if 'h${id}' !in lane_of {
			lane_of['h${id}'] = labels.len
			labels << fb_label(app, id)
		}
	}
	if tkeys.len > 0 {
		labels << '──  threads  ──' // separator lane (no bars)
		for pass in 0 .. 2 { // pass 0 = real threads, pass 1 = idle (id 0) — idle at each core's foot
			for core in 0 .. 16 {
				for k in tkeys {
					kc, kid := split_lane_key(k)
					idle := kid == 0
					if kc == core && ((pass == 0 && !idle) || (pass == 1 && idle))
						&& 't${k}' !in lane_of {
						lane_of['t${k}'] = labels.len
						labels << thread_core_label(app, kc, kid)
					}
				}
			}
		}
		for k in tkeys { // cores outside 0..16 (garbage/unexpected header) — never drop a lane
			if 't${k}' !in lane_of {
				kc, kid := split_lane_key(k)
				lane_of['t${k}'] = labels.len
				labels << thread_core_label(app, kc, kid)
			}
		}
	}
	if ikeys.len > 0 {
		labels << '──  interrupts  ──' // separator lane (no bars)
		for core in 0 .. 16 {
			for k in ikeys {
				kc, kid := split_lane_key(k)
				if kc == core && 'i${k}' !in lane_of {
					lane_of['i${k}'] = labels.len
					labels << 'c${kc}  isr ${kid}'
				}
			}
		}
		for k in ikeys { // cores outside 0..16 — same catch-all as threads
			if 'i${k}' !in lane_of {
				kc, kid := split_lane_key(k)
				lane_of['i${k}'] = labels.len
				labels << 'c${kc}  isr ${kid}'
			}
		}
	}
	// time span over every interval record (abs_us folds epoch re-anchors; every kind has width).
	// Work in u64 and subtract tmin BEFORE the f32 cast: absolute µs can exceed f32's 24-bit
	// precision (~16.7 s) on a long capture, but the relative offsets are small and f32-exact.
	mut tmin := u64(0xffff_ffff_ffff_ffff)
	mut tmax := u64(0)
	for tr in trecs {
		s := tr.abs_us
		e := s + u64(tr.rec.cpu_us)
		if s < tmin {
			tmin = s
		}
		if e > tmax {
			tmax = e
		}
	}
	// TIME-BASE RECONSTRUCTION. A thread record's cpu_us is ISR-SUBTRACTED duration, but bar
	// positions are wall time — drawn as [start, start+cpu] a slice ends BEFORE reality and
	// overlaps ISR bars. Re-add the overlapping ISR durations to get the wall extent, then chop
	// the slice around the ISR spans: what remains is where the thread's code actually ran.
	// FB bars clip to these chunks (an FB record's duration IS wall — the Loom hook brackets by
	// clock), so neither a thread nor its FB can ever overlap an ISR again.
	mut isr_spans := map[int][]Span{}
	for tr in trecs {
		if tr.rec.kind() == telem.kind_isr {
			isr_spans[tr.core] << Span{tr.abs_us, tr.abs_us + u64(tr.rec.cpu_us)}
		}
	}
	for c, _ in isr_spans {
		isr_spans[c].sort(a.s < b.s)
	}
	mut tsl_key := []string{} // '<core>:<tid>' per thread slice
	mut tsl_core := []int{}
	mut tsl_id := []u16{}
	mut tsl_s := []u64{} // wall start
	mut tsl_e := []u64{} // wall END (ISR-extended)
	mut tsl_pre := []bool{} // ended by preemption
	mut tsl_chunks := [][]Span{} // run chunks: [s..e] minus ISR spans
	for tr in trecs {
		if tr.rec.kind() != telem.kind_thread || tr.rec.id() == 0 {
			continue
		}
		s0 := tr.abs_us
		mut e0 := s0 + u64(tr.rec.cpu_us)
		spans := isr_spans[tr.core] or { []Span{} }
		for isp in spans {
			if isp.s >= s0 && isp.s < e0 {
				e0 += isp.e - isp.s // an ISR inside the slice: the wall end moves right
			}
		}
		mut chunks := []Span{}
		mut cur := s0
		for isp in spans {
			if isp.e <= cur || isp.s >= e0 {
				continue
			}
			if isp.s > cur {
				chunks << Span{cur, isp.s}
			}
			if isp.e > cur {
				cur = isp.e
			}
		}
		if e0 > cur {
			chunks << Span{cur, e0}
		}
		tsl_key << '${tr.core}:${tr.rec.id()}'
		tsl_core << tr.core
		tsl_id << tr.rec.id()
		tsl_s << s0
		tsl_e << e0
		tsl_pre << (tr.rec.reason() == telem.reason_preempt)
		tsl_chunks << chunks
	}
	mut tslices := map[string][]Span{}
	for i, k in tsl_key {
		for ch in tsl_chunks[i] {
			tslices[k] << ch
		}
	}
	mut tid_of := map[string]u16{}
	for t in app.manifest.threads {
		tid_of[t.name] = t.id
	}
	if tmin > tmax { // no interval records — nothing to draw
		return labels, []vgui.Bar{}, []vgui.Link{}, f32(1)
	}
	span := if tmax > tmin { f32(tmax - tmin) } else { f32(1) }
	mut bars := []vgui.Bar{cap: trecs.len}
	for tr in trecs {
		r := tr.rec
		mut key := ''
		if r.kind() == telem.kind_fb {
			key = 'h${r.id()}'
		} else if r.kind() == telem.kind_thread {
			if r.id() != 0 {
				continue // real thread slices are drawn from the reconstructed chunks below
			}
			key = 't${tr.core}:${r.id()}'
		} else if r.kind() == telem.kind_isr {
			key = 'i${tr.core}:${r.id()}'
		} else {
			continue // CONTROL framing — no bar
		}
		li := lane_of[key]
		// colour by (block) core so cores are visually distinct.
		c := lane_palette[tr.core % lane_palette.len]
		// FB warn = overran/saturated (a deadline concept — belongs to the handler). The preempt
		// hatch is THREAD-ONLY: preemption happens to threads, never to functions — the FB lane
		// shows execution chunks and the thread lane below carries the scheduling story.
		warn := if r.kind() == telem.kind_fb
			&& (r.flags() & (telem.flag_overran | telem.flag_saturated)) != 0 {
			1
		} else {
			0
		}
		preempted := if r.kind() == telem.kind_thread && r.reason() == telem.reason_preempt {
			1
		} else {
			0
		}
		if r.kind() == telem.kind_fb {
			s0 := tr.abs_us
			e0 := s0 + u64(r.cpu_us)
			mut hrow_thread := ''
			if h := app.manifest.by_id[r.id()] {
				hrow_thread = h.thread
			}
			tid := tid_of[hrow_thread] or { u16(0) }
			if tid != 0 {
				spans := tslices['${tr.core}:${tid}'] or { []Span{} }
				mut chunks := []Span{}
				for sp in spans {
					cs := if sp.s > s0 { sp.s } else { s0 }
					ce := if sp.e < e0 { sp.e } else { e0 }
					if ce > cs {
						chunks << Span{cs, ce}
					}
				}
				if chunks.len > 0 {
					for ck in chunks {
						bars << vgui.Bar{
							t0:        f32(ck.s - tmin)
							dur:       f32(ck.e - ck.s)
							lane:      li
							color:     vgui.rgba(c[0], c[1], c[2], 235)
							warn:      warn
							preempted: 0 // functions don't get preempted — threads do (see the thread lane)
						}
					}
					continue
				}
			}
		}
		bars << vgui.Bar{
			t0:        f32(tr.abs_us - tmin) // relative µs (f32-exact even for long captures)
			dur:       f32(r.cpu_us)
			lane:      li
			color:     vgui.rgba(c[0], c[1], c[2], 235)
			warn:      warn
			preempted: preempted
		}
	}
	// thread execution chunks (ISR-chopped, wall-consistent), the torn edge on the LAST chunk of
	// a preempted slice, and a thin dim READY bar from the cut to the thread's next slice — the
	// whole preempted wait is visible, not just the cut instant.
	for i, k in tsl_key {
		li := lane_of['t${k}']
		c := lane_palette[tsl_core[i] % lane_palette.len]
		nch := tsl_chunks[i].len
		for j, ch in tsl_chunks[i] {
			bars << vgui.Bar{
				t0:        f32(ch.s - tmin)
				dur:       f32(ch.e - ch.s)
				lane:      li
				color:     vgui.rgba(c[0], c[1], c[2], 235)
				preempted: if tsl_pre[i] && j == nch - 1 { 1 } else { 0 }
			}
		}
		if tsl_pre[i] {
			// ready-but-waiting: until this thread's next slice starts
			mut nxt := u64(0)
			for j2, k2 in tsl_key {
				if k2 == k && tsl_s[j2] > tsl_e[i] && (nxt == 0 || tsl_s[j2] < nxt) {
					nxt = tsl_s[j2]
				}
			}
			if nxt > tsl_e[i] {
				bars << vgui.Bar{
					t0:    f32(tsl_e[i] - tmin)
					dur:   f32(nxt - tsl_e[i])
					lane:  li
					color: vgui.rgba(c[0], c[1], c[2], 90)
					style: 1
				}
			}
		}
	}
	// preemption cut-links: victim -> the thread whose slice starts at the (wall) cut.
	mut links := []vgui.Link{}
	for i, k in tsl_key {
		if !tsl_pre[i] {
			continue
		}
		cut := tsl_e[i]
		mut best_dt := u64(200)
		mut best_key := ''
		for j2, k2 in tsl_key {
			if k2 == k || tsl_core[j2] != tsl_core[i] {
				continue
			}
			dt := if tsl_s[j2] >= cut { tsl_s[j2] - cut } else { cut - tsl_s[j2] }
			if dt < best_dt {
				best_dt = dt
				best_key = k2
			}
		}
		if best_key != '' {
			links << vgui.Link{
				x:         f32(cut - tmin)
				lane_from: lane_of['t${k}']
				lane_to:   lane_of['t${best_key}']
			}
		}
	}
	return labels, bars, links, span
}
