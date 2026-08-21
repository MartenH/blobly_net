module main

import os
import vgui
import player
import mf4
import project

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
	// Prune seek-latch entries whose group is gone — HERE, on the GUI thread, because
	// replay_seek is GUI-thread state (the slider reads and writes it without the lock) and a
	// worker-side delete raced those accesses (codex #135 r1, P1). Tokens never recur, so a
	// surviving entry is only dead weight until this runs, never a phantom seek.
	if app.replay_seek.len > 0 {
		mut dead := []u64{}
		for k, _ in app.replay_seek {
			if k !in toks {
				dead << k
			}
		}
		for k in dead {
			app.replay_seek.delete(k)
		}
	}
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
		// different button.
		if cfg_speed !in replay_speeds {
			speeds << cfg_speed
		}
		for sp in speeds {
			vgui.same_line()
			// The ACTIVE compare is exact too — r4 kept it epsilon on the theory that a trip
			// through the worker frays equality, but the published rate is a pure COPY of what
			// a button (or the config) assigned, never recomputed; with a near-preset rate now
			// holding its own button, the tolerance lit two buttons at once (codex #133 r5).
			active := sp == speed
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

// ReplayGroupView is one recording's stopped-view group, precomputed OFF the frame loop: the
// grouping walks the filesystem (real_path — symlink spellings of one capture must land in
// one group, the spawner's own rule), and that is syscall work the 60Hz draw must not repeat
// (the load_cfg_text lesson). Rebuilt when replay_view_gen moves — rebuild_from_proj and the
// panel's enable tick bump it.
struct ReplayGroupView {
mut:
	// the FIRST member's configured spelling, as the header. The canonical key deliberately
	// merges spellings, so a member whose own spelling differs shows it dimmed on its row —
	// hiding a member's hard-coded absolute path is how it survives a project move unseen.
	src string
	key string // canonical identity (real_path of the frozen resolved source); '' = sourceless
	cis []int
}

fn (mut app App) replay_view_groups() []ReplayGroupView {
	if app.replay_view_built == app.replay_view_gen {
		return app.replay_view
	}
	mut out := []ReplayGroupView{}
	mut idx := map[string]int{}
	for ci in 0 .. app.proj.channels.len {
		ch := app.proj.channels[ci]
		if ch.mode != .replay {
			continue
		}
		src := if r := ch.replay { r.source } else { '' }
		if src == '' {
			out << ReplayGroupView{
				cis: [ci]
			}
			continue
		}
		// the spawner's key, from the SAME frozen resolution the spawner reads
		// (chans[ci].replay_src, resolved at rebuild) — resolving proj afresh here opened a
		// skew where panel and Start keyed one file differently (self-review)
		key := if ci < app.chans.len && app.chans[ci].replay_src != '' {
			os.real_path(app.chans[ci].replay_src)
		} else {
			os.real_path(app.resolve_asset(src))
		}
		gi := idx[key] or { -1 }
		if gi >= 0 {
			out[gi].cis << ci
		} else {
			idx[key] = out.len
			out << ReplayGroupView{
				src: src
				key: key
				cis: [ci]
			}
		}
	}
	app.replay_view = out
	app.replay_view_built = app.replay_view_gen
	return app.replay_view
}

// draw_replay_config lists the project's replay channels while nothing plays — GROUPED BY
// RECORDING under the spawner's own canonical key, with "(one clock)" over the members that
// will actually PLAY (enabled, no blocker): the badge describes the group Start builds, not
// the rows that happen to share a file. Members that will not play say why, from the SAME
// replay_blocker() that defines replaying() — never a hand-copy of its clauses. Where a Scan
// of this recording exists, the pairing is checked through player.resolve_bus (the module
// owns which-bus-does-the-config-mean; an inline match here was copy number four and wrong
// twice over) and duplicate mappings are counted; without one the panel says it cannot know,
// dimly, instead of guessing from sibling counts. Ticks and Browse are PROJECT edits.
fn draw_replay_config(mut app App) {
	groups := app.replay_view_groups()
	if groups.len == 0 {
		vgui.text_dim('no replay channels in this project')
		vgui.text_dim('make one: Configure -> set a bus\'s mode to "replay" — then pick its recording here.')
		vgui.text_dim('See docs/simulation.md ("Replay — playing a recording onto a bus").')
		return
	}
	for g in groups {
		// one existence stat per GROUP per frame (was one per row) — live on purpose, so a
		// capture landing on disk clears the red without waiting for an edit
		exists := g.key != '' && os.exists(g.key)
		if g.src == '' {
			vgui.text_colored(230, 120, 120, 'no recording set')
		} else if !exists {
			vgui.text_colored(230, 120, 120, '${g.src}  (NOT FOUND)')
		} else {
			vgui.text(g.src)
		}
		mut active := []int{}
		for ci in g.cis {
			if ci < app.chans.len && app.chans[ci].replaying() {
				active << ci
			}
		}
		if active.len > 1 {
			vgui.same_line()
			vgui.text_dim('(one clock)')
		}
		// ONE clock means ONE pacing — the group refusal replay_group gives at Start, said
		// here while the disagreement is being configured
		if active.len > 1 {
			r0 := app.proj.channels[active[0]].replay or { project.Replay{} }
			for ci in active[1..] {
				ri := app.proj.channels[ci].replay or { project.Replay{} }
				if ri.speed != r0.speed || ri.repeat != r0.repeat {
					vgui.text_colored(230, 120, 120,
						'   members disagree on speed/loop — they share one clock, so set them alike (Start refuses this)')
					break
				}
			}
		}
		// The file's bus list, when any member's Scan covered THIS recording — the only
		// source of pairing facts the panel accepts. sc.src is the resolved (not canonical)
		// path, so it is canonicalized for the compare; scans are few (explicit clicks,
		// cleared on every edit), which bounds the per-frame cost.
		mut names := []player.BusName{}
		mut labels := []string{}
		mut have_scan := false
		app.mu.lock()
		for ci in g.cis {
			if sc := app.replay_scans[ci] {
				if !sc.loading && sc.err == '' && sc.src != '' && os.real_path(sc.src) == g.key {
					for b in sc.buses {
						names << player.BusName{
							iface: b.iface
							name:  b.name
						}
						labels << b.iface
					}
					have_scan = true
					break
				}
			}
		}
		app.mu.unlock()
		// resolve every ACTIVE member through the module's rule first, so duplicate mappings
		// (Start's other refusal) can be counted before any row renders
		mut resolved := map[int]string{}
		mut pair_err := map[int]string{}
		mut label_uses := map[string]int{}
		if have_scan {
			for ci in active {
				bus := (app.proj.channels[ci].replay or { project.Replay{} }).bus
				lbl := player.resolve_bus(names, labels, bus) or {
					pair_err[ci] = err.msg()
					''
				}
				if lbl != '' {
					resolved[ci] = lbl
					label_uses[lbl]++
				}
			}
		}
		for ci in g.cis {
			ch := app.proj.channels[ci]
			rp0 := ch.replay or { project.Replay{} }
			en := ch.enabled
			blocker := if ci < app.chans.len { app.chans[ci].replay_blocker() } else { '' }
			arrow := if rp0.bus != '' { '<- ${rp0.bus}' } else { '' }
			if app.running {
				// mid-run the set is fixed (topology at Start); show, don't edit
				vgui.text_dim('   ${if en { '[x]' } else { '[ ]' }} ${ch.name}  ${arrow}')
				continue
			}
			vgui.indent_x(14 * app.ui_scale)
			nen := vgui.checkbox('${ch.name}##rpen${ci}', en)
			if nen != en {
				// a PROJECT edit that also moves the runtime row — set_chan_enabled_stopped
				// names the intent (NOT the Buses tick, which is runtime-only and does not
				// survive Save)
				app.set_chan_enabled_stopped(ci, nen)
			}
			if g.src != '' && rp0.source != g.src {
				// the canonical key merged a different spelling into this group — show it,
				// or a hard-coded absolute path hides under the header until a move breaks it
				vgui.same_line()
				vgui.text_dim('(${rp0.source})')
			}
			if blocker != '' && blocker != 'no recording set' {
				// the group header already carries the sourceless case
				vgui.same_line()
				vgui.text_colored(230, 120, 120, blocker)
			} else if e := pair_err[ci] {
				// Start's own refusal (resolve_bus wording), before Start gives it
				vgui.same_line()
				vgui.text_colored(230, 120, 120, '<- ${e}')
			} else if lbl := resolved[ci] {
				vgui.same_line()
				if label_uses[lbl] > 1 {
					vgui.text_colored(230, 120, 120,
						'<- ${lbl} — mapped ${label_uses[lbl]} times, its traffic would be sent twice (Start refuses this)')
				} else if arrow != '' {
					vgui.text(arrow)
				} else {
					vgui.text_dim('<- ${lbl} (the only bus)')
				}
			} else if arrow != '' {
				vgui.same_line()
				vgui.text(arrow)
			} else if en && blocker == '' && g.src != '' {
				// no Scan covers this recording, so the panel cannot know whether an empty
				// bus: resolves (one recorded bus) or is refused (several) — say that, dimly,
				// instead of guessing from sibling counts (the first draft guessed, and was
				// wrong in both directions)
				vgui.same_line()
				vgui.text_dim('<- bus: unset — Scan in Configure to check the pairing')
			}
			vgui.same_line()
			if vgui.small_button('Browse##rpsrc${ci}') {
				app.open_browser('replaysrc:${ci}')
			}
			vgui.indent_x(14 * app.ui_scale)
			vgui.text_dim('   speed ${rp0.speed:.2}x${if rp0.repeat { ' · loop' } else { '' }} — press Start to play (speed/loop: Configure)')
		}
	}
	if !app.running {
		vgui.text_dim('ticks and files are PROJECT edits — Save writes them to the .blobnet')
	}
}
