module main

import time
import vgui
import blobly.nm
import blobly.project
import blobly.sysview
import blobly.transport
import gaterule

// Network Management (View ▸ Network Management): who reports in on each wire's NM cluster and
// who keeps the network awake. The reading is blobly/nm; this file decides which wires have
// one, feeds the trackers and draws them.
//
// THE CONFIGURATION is per wire and comes from one rule (nm.configure): the system model, else
// the wire's ARXML NM-PDU frames, else a row's own `nm:`. It is published at Start for the run
// and, while stopped, followed by the open panel once a second, so a system.toml loaded in the
// System panel shows its declared nodes before anything has been heard.
//
// THE TRACKERS are fed by rx_loop under app.mu with host time — what the bus brought us, and
// our own frames once, off their first echo, so a replayed recording reads as live traffic — and
// read by the panel under the same lock, as a View built there. An imported recording gets
// trackers of its own, per recorded bus, on the recording's clock; the panel shows them, as at
// the recording's end, while it is on screen.

const nm_strip_cols = 120 // half-second columns over the 60 s window
const nm_refresh_ms = 1000.0
const nm_strip_w = f32(240) // the timeline's width, unscaled px

// nm_configs is every CAN wire's NM configuration, from `sys` and the rows and databases on
// each wire. GUI thread (it reads app.chans and app.dbs, which only that thread replaces).
fn (app &App) nm_configs(sys &sysview.System) map[string]nm.Config {
	mut rows := map[string][]project.Channel{}
	mut iface_of := map[string]string{}
	for c in app.chans {
		if c.eth() {
			continue
		}
		dk := transport.destination_key_for(c.adapter, c.iface)
		pc := if c.proj_idx >= 0 && c.proj_idx < app.proj.channels.len {
			app.proj.channels[c.proj_idx]
		} else {
			project.Channel{
				name: c.name
			}
		}
		rows[dk] << pc
		if dk !in iface_of {
			iface_of[dk] = c.iface
		}
	}
	mut out := map[string]nm.Config{}
	for dk, rs in rows {
		if cfg := nm.configure(sys, rs, app.dbs_for_dest(iface_of[dk])) {
			out[dk] = cfg
		}
	}
	return out
}

// nm_publish_locked installs `cfgs`: a wire whose configuration is unchanged keeps its tracker,
// any other starts a new one, a wire with none has none. `fresh` starts every tracker over (a
// Start). Caller holds app.mu.
fn (mut app App) nm_publish_locked(cfgs map[string]nm.Config, fresh bool) {
	mut trk := map[string]&nm.Tracker{}
	for dk, cfg in cfgs {
		if !fresh {
			if old := app.nm_trk[dk] {
				if old.cfg.key() == cfg.key() {
					trk[dk] = old
					continue
				}
			}
		}
		t := &nm.Tracker{
			cfg: cfg
		}
		trk[dk] = t
	}
	app.nm_cfg = cfgs.clone()
	app.nm_trk = trk.clone()
}

// nm_follow re-reads the configuration while stopped — at most once a second unless `force`:
// what the next Start will read, and the declared nodes of a model loaded since. GUI thread.
fn (mut app App) nm_follow(force bool) {
	if app.running {
		return
	}
	now := f64(time.sys_mono_now()) / 1_000_000.0
	if !force && app.nm_cfg_at > 0 && now - app.nm_cfg_at < nm_refresh_ms {
		return
	}
	app.nm_cfg_at = now
	app.diag_sys_refresh()
	empty := sysview.System{}
	sys := if app.diag_sys_ok { &app.diag_sys } else { &empty }
	cfgs := app.nm_configs(sys)
	app.mu.lock()
	app.nm_publish_locked(cfgs, false)
	app.mu.unlock()
}

// nm_note_locked feeds a frame of `wire` to its tracker, if the wire has an NM reading.
// Caller holds app.mu.
fn (mut app App) nm_note_locked(wire string, f transport.CanFrame, t_ms f64) {
	if app.nm_trk.len == 0 || f.rtr {
		return
	}
	mut t := app.nm_trk[wire] or { return }
	t.note(f.id, f.extended, f.data, t_ms)
}

// nm_import_note_locked feeds an imported frame of recorded bus `label`, placed on the wire
// `gate` names, to that bus's own tracker. Caller holds app.mu.
fn (mut app App) nm_import_note_locked(label string, gate string, f transport.CanFrame, t_ms f64) {
	if app.nm_cfg.len == 0 || f.rtr {
		return
	}
	mut t := app.nm_rec[label] or {
		cfg := app.nm_cfg[gaterule.placement(gate)] or { return }
		n := &nm.Tracker{
			cfg: cfg
		}
		app.nm_rec[label] = n
		n
	}
	t.note(f.id, f.extended, f.data, t_ms)
	if t_ms > app.nm_rec_end {
		app.nm_rec_end = t_ms
	}
}

// NmSection is one wire's reading, as the panel draws it.
struct NmSection {
	title string
	view  nm.View
}

// nm_sections is what the panel shows: the imported recording's buses while it is on screen,
// else the live wires, each read at its own clock's now. Takes app.mu.
fn (mut app App) nm_sections() ([]NmSection, string) {
	mut out := []NmSection{}
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if app.viewing_rec != '' && app.nm_rec.len > 0 {
		mut labels := app.nm_rec.keys()
		labels.sort()
		for l in labels {
			t := app.nm_rec[l] or { continue }
			out << NmSection{
				title: 'recorded bus ${l}'
				view:  t.view(app.nm_rec_end, nm_strip_cols)
			}
		}
		return out, 'from ${app.viewing_rec}, as at its last frame'
	}
	now := app.since_ms()
	mut wires := app.nm_trk.keys()
	wires.sort()
	for w in wires {
		t := app.nm_trk[w] or { continue }
		mut names := []string{}
		for c in app.chans {
			if !c.eth() && transport.destination_key_for(c.adapter, c.iface) == w && c.name !in names {
				names << c.name
			}
		}
		out << NmSection{
			title: '${names.join(' / ')}  (${w})'
			view:  t.view(now, nm_strip_cols)
		}
	}
	note := if app.running {
		''
	} else {
		'stopped — the last run, or what the next Start will read'
	}
	return out, note
}

fn nm_ago(ms f64) string {
	return if ms < 10_000 { '${ms / 1000.0:.1f} s ago' } else { '${ms / 1000.0:.0f} s ago' }
}

fn nm_cell_color(p nm.Phase) u32 {
	return match p {
		.requesting { vgui.rgba(80, 190, 100, 255) }
		.ready { vgui.rgba(140, 140, 140, 255) }
		.silent { u32(0) }
	}
}

fn draw_nm(mut app App) {
	vgui.set_next_window(200, 120, 1240, 560)
	vis, op := vgui.begin_closable('Network Management', app.show_nm)
	app.show_nm = op
	if !vis {
		vgui.end()
		return
	}
	app.nm_follow(false)
	sc := app.prefs.ui_scale
	sections, note := app.nm_sections()
	if note != '' {
		vgui.text_dim(note)
	}
	if sections.len == 0 {
		vgui.text_dim_wrapped("No wire has an NM configuration. One comes from the system.toml (a bus with `nm = { peers = [lo, hi], timeout_ms }`, on the channel named after it), from an ARXML whose cluster carries NM-PDU frames, or from the channel's own `nm: { lo: 0x500, hi: 0x53F, timeout_ms: 300 }` in the project. Nothing guesses that a frame is NM.")
		vgui.end()
		return
	}
	for si, s in sections {
		v := s.view
		vgui.separator_text(s.title)
		vgui.text_dim('NM ids 0x${v.cfg.lo:X}..0x${v.cfg.hi:X}${if v.cfg.ext {
			' (29-bit)'
		} else {
			''
		}}, timeout ${v.cfg.timeout_ms} ms — from ${v.cfg.origin}')
		// the header: the state, who keeps it awake, who woke it, how long since the last frame
		match v.state {
			.awake { vgui.text_colored(80, 190, 100, 'awake') }
			.releasing { vgui.text_colored(220, 180, 60, 'releasing') }
			.asleep { vgui.text_colored(150, 150, 150, 'asleep') }
		}
		vgui.same_line()
		mut parts := []string{}
		if v.keepers.len > 0 {
			parts << 'kept awake by: ${v.keepers.join(', ')}'
		}
		if v.woke != '' {
			how := if v.woke_active { ' (active wake-up)' } else { '' }
			parts << 'woken by ${v.woke}${how} ${nm_ago(v.woke_ago)}'
		}
		if v.repeaters.len > 0 {
			parts << 'repeat requested by: ${v.repeaters.join(', ')}'
		}
		parts << if v.heard { 'last NM frame ${nm_ago(v.last_ago)}' } else { 'no NM frame yet' }
		vgui.text(parts.join('   ·   '))
		if v.malformed > 0 {
			vgui.text_colored(220, 120, 80, '${v.malformed} malformed NM frame(s); last: ${v.last_error}')
		}
		if v.dropped > 0 {
			vgui.text_colored(220, 120, 80, '${v.dropped} frame(s) from reporters past ${nm.max_nodes} not tracked')
		}
		if v.rows.len == 0 {
			vgui.text_dim('nothing declared on this cluster, and nothing heard')
			continue
		}
		if vgui.table_begin_flat('##nm${si}', 8) {
			vgui.table_setup_col('node', 130 * sc)
			vgui.table_setup_col('NM id', 60 * sc)
			vgui.table_setup_col('last heard', 80 * sc)
			vgui.table_setup_col('cadence', 140 * sc)
			vgui.table_setup_col('frames', 55 * sc)
			vgui.table_setup_col('bits', 260 * sc)
			vgui.table_setup_col('PN', 70 * sc)
			vgui.table_setup_col('last 60 s', nm_strip_w * sc)
			vgui.table_headers()
			for r in v.rows {
				vgui.table_row()
				vgui.table_set_col(0)
				if r.missing {
					vgui.text(r.name)
					vgui.same_line()
					vgui.text_colored(220, 120, 80, 'missing')
				} else if r.unknown {
					vgui.text(r.name)
					vgui.same_line()
					vgui.text_colored(220, 180, 60, 'unknown')
				} else {
					vgui.text(r.name)
				}
				vgui.table_set_col(1)
				if r.has_id {
					vgui.text('0x${r.id:X}')
				}
				vgui.table_set_col(2)
				if r.missing {
					vgui.text_dim('never')
				} else if r.stale {
					vgui.text_dim(nm_ago(r.ago_ms))
				} else {
					vgui.text(nm_ago(r.ago_ms))
				}
				vgui.table_set_col(3)
				if r.mean_ms > 0 {
					vgui.text('${r.mean_ms:.0} ms (last ${r.last_iv_ms:.0})')
				}
				vgui.table_set_col(4)
				if !r.missing {
					vgui.text('${r.count}')
				}
				vgui.table_set_col(5)
				if !r.missing {
					if r.stale {
						vgui.text_dim(r.bits.join(', '))
					} else {
						vgui.text(r.bits.join(', '))
					}
				}
				vgui.table_set_col(6)
				if r.has_pn {
					vgui.text('0x${r.pn:X}')
				}
				vgui.table_set_col(7)
				vgui.cells(r.timeline.map(nm_cell_color(it)), nm_strip_w * sc, 12 * sc)
				vgui.set_item_tooltip('the last 60 s, oldest left: green while it requests the network, grey while ready to sleep, empty while silent (past the ${v.cfg.timeout_ms} ms timeout)')
			}
			vgui.table_end()
		}
	}
	vgui.end()
}
