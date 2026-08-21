module main

import vgui
import player

// draw_replay is the Replay panel: one row per RUNNING replay group (a recording playing onto
// one or more buses from a single clock), with transport controls. Everything here talks to
// the group's worker through its ReplayCtl under app.mu — commands are picked up on the
// worker's next wake (<= 50ms), and the worker alone touches the Player.
fn draw_replay(mut app App) {
	vis, op := vgui.begin_closable('Replay', app.show_replay)
	app.show_replay = op
	if !vis {
		vgui.end()
		return
	}
	app.mu.lock()
	mut toks := app.replay_ctls.keys()
	app.mu.unlock()
	if toks.len == 0 {
		vgui.text_dim('no replay running')
		vgui.text_dim('a replay is a CHANNEL: set a bus to mode "replay" in Configure and give it a')
		vgui.text_dim('recording (source/speed/loop) — press Start and it plays here. See docs/simulation.md.')
		if !app.running {
			vgui.text_dim('(the app is stopped — replay channels play while a measurement runs)')
		}
		vgui.end()
		return
	}
	toks.sort()
	for tok in toks {
		// snapshot the status under the lock; render from the copy
		app.mu.lock()
		mut c := app.replay_ctls[tok] or {
			app.mu.unlock()
			continue
		}
		src := c.src
		buses := c.buses.join(', ')
		dur := c.dur_s
		pos := c.pos_s
		st := c.state
		speed := c.speed
		repeat := c.repeat
		loops := c.loops
		sent := c.sent
		failed := c.failed
		app.mu.unlock()

		vgui.separator_text('${src}  ->  ${buses}')
		frac := if dur > 0 { f32(pos / dur) } else { f32(0) }
		vgui.progress(frac, '${pos:.1f} / ${dur:.1f} s${if repeat {
			'  (loop ${loops + 1})'
		} else {
			''
		}}')
		// seek: drag anywhere in the recording; the jump fires ONCE, on release — per-pixel
		// seeks would queue a flood of jumps the worker applies 50ms apart
		mut seek_v := f32(pos)
		vgui.set_next_item_width(300 * app.ui_scale)
		vgui.slider_f('##seek${tok}', mut &seek_v, 0, f32(dur), '%.1f s')
		if vgui.is_item_deactivated_after_edit() {
			app.mu.lock()
			if mut cc := app.replay_ctls[tok] {
				cc.want_seek = f64(seek_v)
			}
			app.mu.unlock()
		}
		vgui.same_line()
		play_lbl := if st == .paused { 'Resume##${tok}' } else { 'Pause##${tok}' }
		if st in [player.State.playing, player.State.paused] {
			if vgui.small_button(play_lbl) {
				app.mu.lock()
				if mut cc := app.replay_ctls[tok] {
					cc.want_toggle = true
				}
				app.mu.unlock()
			}
		}
		vgui.same_line()
		vgui.text_dim('${st}  ·  ${sent} sent${if failed > 0 {
			'  ·  ${failed} FAILED'
		} else {
			''
		}}')
		// speed: the recorded cadence scaled; the change lands on the worker's next wake with
		// the position preserved
		vgui.text_dim('speed:')
		for sp in [f64(0.25), 0.5, 1.0, 2.0, 4.0] {
			vgui.same_line()
			lbl := if sp == speed { '[${sp:.2}x]##sp${tok}' } else { '${sp:.2}x##sp${tok}' }
			if vgui.small_button(lbl) {
				app.mu.lock()
				if mut cc := app.replay_ctls[tok] {
					cc.want_speed = sp
				}
				app.mu.unlock()
			}
		}
	}
	vgui.end()
}
