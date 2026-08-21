module main

import os
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
		// STOPPED (or nothing playing): the panel is the configuration surface — which
		// recordings will play on Start, each with the file and a play-on-Start tick. Both
		// write into app.proj with `dirty` set, so Save persists them into the .blobnet:
		// these are project edits made from the panel, not runtime toggles.
		draw_replay_config(mut app)
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
		// EXACT match, not epsilon: the append's job is to make the configured rate reachable,
		// and a tolerance hid any rate within 0.001 of a preset — 1.0005 could be left but
		// never restored. Config rates are parsed f64 literals; if it differs at all, it is a
		// different button. (The ACTIVE highlight below stays epsilon-based: the running speed
		// travels through the worker and equality there is the fragile kind.)
		if cfg_speed !in replay_speeds {
			speeds << cfg_speed
		}
		for sp in speeds {
			vgui.same_line()
			active := (sp - speed) < 0.001 && (speed - sp) < 0.001
			// the ID carries the RAW rate — a configured 1.004 beside the 1.0 preset rounded
			// to the same ':.2' and the two buttons collided; the display may round, the
			// identity may not. The appended configured rate also DISPLAYS at full precision,
			// or the row shows two '1.00x' buttons nobody can tell apart.
			shown := if sp in replay_speeds { '${sp:.2}x' } else { '${sp}x' }
			lbl := if active {
				'[${shown}]###sp${tok}_${sp}'
			} else {
				'${shown}###sp${tok}_${sp}'
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

// draw_replay_config lists the project's replay channels for editing while nothing plays:
// a play-on-Start checkbox (the channel's `enabled` — the same flag the Buses panel ticks,
// written to chans AND proj exactly as its stopped tick does) and the recording, with a
// Browse into the file picker. All of it is model state: Save writes the .blobnet.
fn draw_replay_config(mut app App) {
	mut have := false
	for ci in 0 .. app.proj.channels.len {
		if app.proj.channels[ci].mode != .replay {
			continue
		}
		have = true
		ch := app.proj.channels[ci]
		src := if r := ch.replay { r.source } else { '' }
		en := ch.enabled
		if app.running {
			// mid-run the set is fixed (topology at Start); show, don't edit
			vgui.text_dim('${if en { '[x]' } else { '[ ]' }} ${ch.name}  ${src}')
			continue
		}
		nen := vgui.checkbox('${ch.name}##rpen${ci}', en)
		if nen != en {
			// the Buses panel's stopped-tick, verbatim in spirit: the runtime row AND the
			// model move together, and dirty makes Save carry it to the file
			app.mu.lock()
			if ci < app.chans.len {
				app.chans[ci].enabled = nen
			}
			app.proj.channels[ci].enabled = nen
			app.mu.unlock()
			app.dirty = true
		}
		vgui.same_line()
		if src == '' {
			vgui.text_colored(230, 120, 120, 'no recording set')
		} else if !os.exists(app.resolve_asset(src)) {
			vgui.text_colored(230, 120, 120, '${src}  (NOT FOUND)')
		} else {
			vgui.text(src)
		}
		vgui.same_line()
		if vgui.small_button('Browse##rpsrc${ci}') {
			app.open_browser('replaysrc:${ci}')
		}
		spd := if r := ch.replay { r.speed } else { 1.0 }
		lp := if r := ch.replay { r.repeat } else { false }
		vgui.text_dim('   speed ${spd:.2}x${if lp { ' · loop' } else { '' }} — press Start to play (speed/loop: Configure)')
	}
	if !have {
		vgui.text_dim('no replay channels in this project')
		vgui.text_dim('make one: Configure -> set a bus\'s mode to "replay" — then pick its recording here.')
		vgui.text_dim('See docs/simulation.md ("Replay — playing a recording onto a bus").')
	} else if !app.running {
		vgui.text_dim('ticks and files are PROJECT edits — Save writes them to the .blobnet')
	}
}
