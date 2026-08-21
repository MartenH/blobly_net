module main

import vgui
import player

// replay_speeds is the preset rate row. A project may configure ANY rate ('speed: 3'), so the
// panel appends the configured rate when it is off this list — otherwise one click away from a
// preset there was no control that could ever restore it.
const replay_speeds = [0.25, 0.5, 1.0, 2.0, 4.0]

// draw_replay is the Replay panel: one row per replay group (a recording playing onto one or
// more buses from a single clock), with transport controls. Everything here talks to the
// group's worker through its ReplayCtl under app.mu — commands land on the worker's next wake
// (<= 50ms), and the worker alone touches the Player. Panel changes are TRANSPORT-transient,
// like pausing a video: the project's configured speed is untouched, and a Stop/Start returns
// to it (the row says so when the two differ).
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
		c := app.replay_ctls[tok] or {
			app.mu.unlock()
			continue
		}
		src := c.src
		buses := c.buses_lbl
		loading := c.loading
		dur := c.dur_s
		pos := c.pos_s
		st := c.state
		speed := c.speed
		cfg_speed := c.cfg_speed
		repeat := c.repeat
		loops := c.loops
		sent := c.sent
		failed := c.failed
		app.mu.unlock()

		vgui.separator_text('${src}  ->  ${buses}')
		if loading {
			vgui.text_dim('loading the recording…')
			continue
		}
		loop_txt := if repeat { '  (loop ${loops + 1})' } else { '' }
		frac := if dur > 0 {
			f32(pos / dur)
		} else if st == .finished {
			f32(1)
		} else {
			f32(0)
		}
		vgui.progress(frac, '${pos:.1f} / ${dur:.1f} s${loop_txt}')
		// seek: the DRAGGED value is latched across frames, because ImGui does not write the
		// slider's backing variable on the release frame — a per-frame local re-seeded from
		// the live position made every seek a jump to where playback already was. The latch
		// holds the last value the drag reported; release commits it, once.
		mut seek_v := app.replay_seek[tok] or { f32(pos) }
		vgui.set_next_item_width(300 * app.ui_scale)
		if vgui.slider_f('##seek${tok}', &seek_v, 0, f32(dur), '%.1f s') {
			app.replay_seek[tok] = seek_v
		}
		if vgui.is_item_deactivated_after_edit() {
			target := app.replay_seek[tok] or { seek_v }
			app.mu.lock()
			if mut cc := app.replay_ctls[tok] {
				cc.want_seek = f64(target)
			}
			app.replay_seek.delete(tok)
			app.mu.unlock()
		}
		if st in [player.State.playing, player.State.paused, player.State.finished] {
			vgui.same_line()
			// a TARGET state, not a toggle — two clicks in one worker tick must not cancel
			// out while the label lags the (<=50ms late) published state
			lbl := match st {
				.paused { 'Resume##${tok}' }
				.finished { 'Restart##${tok}' } // play() from .finished starts at 0
				else { 'Pause##${tok}' }
			}

			if vgui.small_button(lbl) {
				target := if st == .playing { player.State.paused } else { player.State.playing }
				app.mu.lock()
				if mut cc := app.replay_ctls[tok] {
					cc.want_state = target
				}
				app.mu.unlock()
			}
		}
		vgui.same_line()
		failed_txt := if failed > 0 { '  ·  ${failed} FAILED' } else { '' }
		vgui.text_dim('${st}  ·  ${sent} sent${failed_txt}')
		vgui.text_dim('speed:')
		// ### ids: the bracket highlight changes the label text, and an id derived from the
		// label would change with it — ### pins each button's identity to rate + token alone
		mut speeds := replay_speeds.clone()
		if !replay_speeds.any((it - cfg_speed) < 0.001 && (cfg_speed - it) < 0.001) {
			speeds << cfg_speed
		}
		for sp in speeds {
			vgui.same_line()
			active := (sp - speed) < 0.001 && (speed - sp) < 0.001
			lbl := if active {
				'[${sp:.2}x]###sp${tok}_${sp:.2}'
			} else {
				'${sp:.2}x###sp${tok}_${sp:.2}'
			}
			if vgui.small_button(lbl) {
				app.mu.lock()
				if mut cc := app.replay_ctls[tok] {
					cc.want_speed = sp
				}
				app.mu.unlock()
			}
		}
		if (cfg_speed - speed) > 0.001 || (speed - cfg_speed) > 0.001 {
			vgui.same_line()
			vgui.text_dim('(configured: ${cfg_speed:.2}x — restored on Stop/Start)')
		}
	}
	vgui.end()
}
