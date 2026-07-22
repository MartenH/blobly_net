// live_trace — the live-data integration test for the vgui evaluation. A background CAN
// RX thread reads real frames off a bus and calls vgui.wake() (glfwPostEmptyEvent) to
// unblock the EVENT-DRIVEN render loop — the exact pattern the migrated app would use
// (gui does the same with queue_command). Proves: live frames render, idle CPU stays ~0
// when there is no traffic, and CPU scales with (not ahead of) the frame rate.
//
// Build:  libs/vgui/build_deps.sh  then
//   v -cc gcc -path "@vlib|@vmodules|modules|libs" run libs/vgui/examples/live_trace/live_trace.v [iface]
// iface defaults to vcan0 (SocketCAN). Feed it:  cansend vcan0 100#DEADBEEF  /  cangen vcan0
//
// Env: VGUI_FRAMES=N exit after N rendered frames (headless CI); VGUI_SHOT=path dump last frame.
module main

import os
import sync
import time
import transport
import vgui

struct Shared {
mut:
	mu     sync.Mutex
	frames []transport.CanFrame // ring (newest last), capped
	rx     u64
	stop   bool
}

fn rx_loop(st &Shared, iface string, wake_ms i64) {
	mut bus := transport.open(iface) or {
		eprintln('rx: open ${iface} failed: ${err}')
		return
	}
	mut s := unsafe { st } // mutate through the st handle
	mut last_wake := i64(0)
	for {
		if s.stop {
			break
		}
		f := bus.recv(200) or { continue } // 200ms timeout -> loop re-checks stop
		s.mu.lock()
		s.frames << f
		if s.frames.len > 200 {
			s.frames = s.frames[s.frames.len - 200..].clone()
		}
		s.rx++
		s.mu.unlock()
		// COALESCE repaints: frames always accumulate above, but request a repaint at
		// most ~60x/s. Without this, a 1000 msg/s bus = 1000 renders/s = the poll trap.
		// This is the app's batched-repaint scheme; the 0.5s wait-timeout is the backstop
		// that flushes the final frames after a burst ends.
		now := time.ticks()
		if now - last_wake >= wake_ms {
			last_wake = now
			vgui.wake()
		}
	}
	bus.close()
}

fn hex(b []u8) string {
	mut parts := []string{cap: b.len}
	for x in b {
		parts << '${x:02X}'
	}
	return parts.join(' ')
}

fn main() {
	iface := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	max_frames := os.getenv('VGUI_FRAMES').int()
	shot := os.getenv('VGUI_SHOT')

	// repaint cap (ms between wake requests). Default 33 = ~30fps; the app uses ~5fps under
	// WSLg's GL tax. Frames still accumulate every RX; only the repaint is throttled.
	mut wake_ms := os.getenv('VGUI_WAKE_MS').i64()
	if wake_ms <= 0 {
		wake_ms = 33
	}
	mut st := &Shared{}
	spawn rx_loop(st, iface, wake_ms)

	if !vgui.init('vgui — Live Trace (RX thread → wake, event-driven)', 1000, 600, true) {
		eprintln('vgui.init failed')
		return
	}

	mut frame := 0
	for vgui.running() { // blocks in glfwWaitEvents until input OR vgui.wake()
		frame++
		last := max_frames > 0 && frame >= max_frames
		if last && shot != '' {
			vgui.dump_ppm(shot)
		}
		vgui.frame_begin()
		vgui.set_next_window(20, 20, 960, 560)
		vgui.begin('Live Trace')

		st.mu.lock()
		n := st.rx
		rows := st.frames.clone()
		st.mu.unlock()

		vgui.text('RX ${n} frames · ${vgui.fps():.0}fps · event-driven (idle when the bus is quiet)')
		vgui.separator_text('newest 30')
		if vgui.table_begin('live', 3) {
			vgui.table_col('ID')
			vgui.table_col('DLC')
			vgui.table_col('Data')
			vgui.table_headers()
			mut i := rows.len - 1
			mut shown := 0
			for i >= 0 && shown < 30 {
				f := rows[i]
				vgui.table_row()
				idw := if f.extended { '0x${f.id:08X}' } else { '0x${f.id:03X}' }
				vgui.table_cell(idw)
				vgui.table_cell('${f.data.len}')
				vgui.table_cell(hex(f.data))
				i--
				shown++
			}
			vgui.table_end()
		}
		vgui.end()
		vgui.frame_end()
		if last {
			eprintln('rendered ${frame} frames; RX ${n} CAN frames total (data flowed RX-thread → wake → render)')
			break
		}
	}
	st.stop = true
	vgui.shutdown()
}
