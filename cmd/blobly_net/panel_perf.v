// panel_perf.v — the Performance panel: how long each frame's work took, and what the garbage
// collector was doing, over the last few seconds. For a stutter: a spike with a collection line
// through it is the collector; a spike without one is something else on the GUI thread.
module main

import time
import vgui
import perfrule

const perf_window_s = 20.0
const perf_spike_ms = f32(33)
const perf_cap = 4096 // samples: a 20 s window at up to ~200 frames/s

// PerfView is the panel's state. GUI thread only. Sampled only while the panel is open.
struct PerfView {
mut:
	on      bool // sampling: the panel was open last frame
	sampler perfrule.Sampler
	// plot buffers kept across frames, so drawing the panel allocates nothing per frame and
	// does not feed the collector it is watching
	xs    []f32
	work  []f32
	heap  []f32
	since []f32
	alloc []f32
	gcx   []f32
}

// perf_step records the frame that began at begin_ns. Called once per frame, after it ends.
fn (mut app App) perf_step(begin_ns u64) {
	if !app.show_perf {
		app.perf.on = false
		return
	}
	if !app.perf.on {
		// a fresh ring: the collection count across a closed stretch is not one frame's
		app.perf.sampler = perfrule.new_sampler(perf_cap)
		app.perf.on = true
	}
	u := gc_heap_usage()
	app.perf.sampler.step(perfrule.Reading{
		begin_ns:    begin_ns
		end_ns:      time.sys_mono_now()
		gc_no:       u64(gc_count())
		alloc_total: u64(u.total_bytes)
		heap:        u64(u.heap_size)
		free:        u64(u.free_bytes)
		since_gc:    u64(u.bytes_since_gc)
	})
}

fn draw_perf(mut app App) {
	vgui.set_next_window(220, 120, 1000, 640)
	vis, op := vgui.begin_closable('Performance', app.show_perf)
	app.show_perf = op
	if !vis {
		vgui.end()
		return
	}
	mut p := &app.perf
	n := p.sampler.len()
	if n == 0 {
		vgui.text_dim('collecting…')
		vgui.end()
		return
	}
	last := p.sampler.at(n - 1)
	now := last.t_s
	sm := p.sampler.summary(now - perf_window_s, perf_spike_ms)
	vgui.text('heap ${last.heap_mb:.1} MB    live after last GC ${p.sampler.live_after_gc_mb:.1} MB')
	vgui.text('allocated since GC ${last.since_mb:.1} MB    ${last.alloc_mb_s:.1} MB/s    GCs ${p.sampler.gcs}')
	worst_why := if sm.worst_gc { ', a GC frame' } else { '' }
	vgui.text('last ${perf_window_s:.0} s: ${sm.frames} frames, worst ${sm.worst_ms:.1} ms${worst_why}')
	vgui.text('${sm.spikes} over ${perf_spike_ms:.0} ms, ${sm.gc_spikes} of them GC frames; ${sm.gcs} GCs')
	vgui.text_dim('frame = the GUI thread\'s work, idle wait excluded; a vertical line = a GC completed in that frame')
	p.xs.clear()
	p.work.clear()
	p.heap.clear()
	p.since.clear()
	p.alloc.clear()
	p.gcx.clear()
	// the y ranges, from what is in the window: a spike sets the scale, and leaves it when it
	// scrolls out
	mut top_ms := perf_spike_ms * 1.2
	mut top_mb := f32(1)
	mut top_rate := f32(1)
	for i in 0 .. n {
		s := p.sampler.at(i)
		if now - s.t_s > perf_window_s {
			continue
		}
		x := f32(s.t_s - now)
		p.xs << x
		p.work << s.work_ms
		p.heap << s.heap_mb
		p.since << s.since_mb
		p.alloc << s.alloc_mb_s
		if s.gc {
			p.gcx << x
		}
		top_ms = f32_max(top_ms, s.work_ms)
		top_mb = f32_max(top_mb, f32_max(s.heap_mb, s.since_mb))
		top_rate = f32_max(top_rate, s.alloc_mb_s)
	}
	// the plot moves every frame, so frames keep coming without input
	vgui.keep_busy()
	if vgui.plot_begin_lim('frame (ms)##perf_frame', 200, -perf_window_s, 0, f64(top_ms) * 1.1,
		0) {
		vgui.plot_line('frame ms', p.xs, p.work)
		vgui.plot_vlines('GC', p.gcx)
		vgui.plot_end()
	}
	if vgui.plot_begin_lim('memory##perf_mem', 200, -perf_window_s, 0, f64(top_mb) * 1.1,
		f64(top_rate) * 1.1) {
		// series i takes axis i's colour, so the right axis's one series goes second
		vgui.plot_line_axis('heap MB', p.xs, p.heap, 0)
		vgui.plot_line_axis('alloc MB/s', p.xs, p.alloc, 1)
		vgui.plot_line_axis('since GC MB', p.xs, p.since, 0)
		vgui.plot_vlines('GC', p.gcx)
		vgui.plot_end()
	}
	vgui.end()
}
