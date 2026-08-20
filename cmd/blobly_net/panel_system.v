module main

import os
import sysview
import vgui

// load_system loads a blobly_emb system.toml into the read-only System view.
// restbus_from_system configures the REST BUS for one ECU under test: every OTHER node that
// shares a bus with it becomes a simulated ECU on the matching channel. This is the single-ECU
// bench workflow — you develop one ECU, and the rest of its buses have to be alive or it faults.
// The system model already knows who sits on which bus, and system.toml node names are the DBC
// transmitter (BU_) names, so the simulator can derive each node's frames straight from the DBC.
// Writes into the PROJECT (channel.simulate) so it survives a rebuild and can be saved.
// Returns (simulated nodes, channels touched).
fn (mut app App) restbus_from_system(sut string) (int, int) {
	mut nodes := 0
	mut chans_hit := 0
	mut sut_dropped := 0 // rich `nodes:` entries removed because they configured the SUT itself
	mut chans_disabled := 0 // matching channels skipped because the project has them disabled
	// the system buses the ECU under test sits on
	mut sut_buses := []string{}
	for n in app.sys.nodes {
		if n.name == sut {
			sut_buses = n.buses.clone()
			break
		}
	}
	for sb in app.sys.buses {
		if sb.name !in sut_buses {
			continue
		}
		mut others := []string{}
		for n in app.sys.nodes {
			if n.name != sut && sb.name in n.buses {
				others << n.name
			}
		}
		if others.len == 0 {
			continue
		}
		for ci, ch in app.proj.channels {
			if ch.iface != sb.iface {
				continue
			}
			// A disabled channel gets no SimCfg from rebuild_from_proj, so writing its
			// simulate list and counting it as configured reports success for something
			// that will not run (codex #65 r4).
			if !ch.enabled {
				// Skipping is right — rebuild_from_proj makes no SimCfg for a disabled channel —
				// but skipping SILENTLY made a partial setup report success and an all-disabled
				// one claim no interface matched (codex #65 r5). Count it and say so.
				chans_disabled++
				continue
			}
			// all_nodes() merges the rich `nodes:` configs with the `simulate:` shorthand, so
			// replacing `simulate` does NOT stop a SUT that is also explicitly configured —
			// the ECU under test would be simulated against itself, two talkers on one bus.
			// Drop its config here and say so, rather than silently leaving it live.
			before := app.proj.channels[ci].nodes.len
			app.proj.channels[ci].nodes = app.proj.channels[ci].nodes.filter(it.name != sut)
			sut_dropped += before - app.proj.channels[ci].nodes.len
			app.proj.channels[ci].simulate = others.clone()
			chans_hit++
			nodes += others.len
		}
	}
	if chans_hit > 0 {
		// Generators are edited live in app.senders/gen_bufs and only reach app.proj through
		// this sync; rebuilding without it recreates them from the stale project model and
		// silently drops unsaved edits, while still marking the project dirty. Both other
		// rebuild_from_proj call sites sync first — this one did not (codex #65 r5).
		app.sync_senders_into_proj()
		app.rebuild_from_proj()
		app.dirty = true
	}
	if sut_dropped > 0 {
		app.notify('restbus: dropped ${sut_dropped} configured simulation entr(ies) for ${sut} — it is the ECU under test, not a simulated node')
	}
	if chans_disabled > 0 {
		app.notify('restbus: ${chans_disabled} matching channel(s) are DISABLED and were skipped — enable them in Configure, or the rest bus stays silent')
	}
	return nodes, chans_hit
}

fn (mut app App) load_system(path string) {
	if path.trim_space() == '' {
		app.notify('no system.toml path — type one or use Browse')
		return
	}
	if sy := sysview.load(path) {
		app.sys = sy
		app.sys_loaded = true
		app.sys_path_buf = mkbuf(path, path.len + 64)
		app.notify('system: ${sy.nodes.len} node(s), ${sy.buses.len} bus(es), ${sy.signals.len} cross-node signal(s)')
	} else {
		app.notify('system load failed: ${err}')
	}
}

// ---- System viewer (docs/dbc_editor.md roadmap: viewer, NOT an editor) -----
// Renders a blobly_emb system.toml — the things text is bad at seeing: the
// per-bus communication matrix (P producer / C consumer / W undeclared
// writer), node identities, and the id allocation with collisions. Read-only
// by design: system/ecu TOML is hand-written and comment-rich, and its
// validation brain (ecucheck/syscheck) lives in blobly_emb.

fn draw_system(mut app App) {
	vis, op := vgui.begin_closable('System', app.show_sys)
	app.show_sys = op
	if !vis {
		vgui.end()
		return
	}
	sc := app.ui_scale
	if app.sys_path_buf.len == 0 {
		// smart default: the project's own dir usually holds the system.toml (a .blobnet lives
		// next to it), so Load works out of the box instead of starting on an empty box.
		mut def := ''
		if app.proj_path != '' {
			cand := os.join_path(os.dir(app.proj_path), 'system.toml')
			if os.is_file(cand) {
				def = cand
			}
		}
		app.sys_path_buf = mkbuf(def, 512)
	}
	vgui.set_next_item_width(340 * sc)
	vgui.input_text('system.toml', mut app.sys_path_buf)
	vgui.same_line()
	if vgui.small_button('Browse…##sys') {
		app.open_browser('system')
	}
	vgui.same_line()
	if vgui.small_button('Load##sys') {
		app.load_system(vgui.buf_str(app.sys_path_buf))
	}
	if !app.sys_loaded {
		vgui.text_dim('pick a blobly_emb system.toml — Browse…, or type a path (e.g. examples/system_full/system.toml)')
		vgui.end()
		return
	}

	// nodes + identities
	// load-time problems (unreadable DBCs etc.) must stay visible
	for e in app.sys.errs {
		vgui.text_colored(205, 60, 60, e)
	}
	vgui.text_dim('showing: ${app.sys.path}')
	// Nodes as a compact master-detail: a small selectable list (left) + the selected
	// ECU's detail (right). Replaces the wide 6-column table that dominated the panel.
	// default/reset the selection: re-default whenever the selected node is absent — after
	// loading a different system the old name would linger and leave the detail pane blank.
	mut sel_valid := false
	for n in app.sys.nodes {
		if n.name == app.sel_ecu {
			sel_valid = true
			break
		}
	}
	if !sel_valid {
		app.sel_ecu = if app.sys.nodes.len > 0 { app.sys.nodes[0].name } else { '' }
	}
	vgui.separator_text('nodes')
	// BOTH panes get the SAME fixed height: a child_fill detail pane would eat all remaining
	// vertical space, and ImGui advances the parent past the taller same-line child — pushing
	// the 'buses & id allocation' tree below the visible region (codex #65).
	ecu_h := 160 * sc
	vgui.child_wh('##ecu_list', 130 * sc, ecu_h)
	for n in app.sys.nodes {
		lbl := if n.ecu_err != '' { '${n.name}  (!)' } else { n.name }
		if vgui.selectable('${lbl}##ecusel_${n.name}', n.name == app.sel_ecu) {
			app.sel_ecu = n.name
		}
	}
	vgui.child_end()
	vgui.same_line()
	vgui.child_wh('##ecu_detail', 0, ecu_h) // w=0 = remaining width, same height as the list
	if app.sel_ecu == '' {
		vgui.text_dim('select an ECU on the left')
	} else {
		mut si := -1
		for j, n in app.sys.nodes {
			if n.name == app.sel_ecu {
				si = j
				break
			}
		}
		if si >= 0 {
			en := app.sys.nodes[si]
			vgui.text(en.name)
			if en.ecu_err != '' {
				vgui.text_colored(205, 60, 60, 'UNREADABLE: ${en.ecu_err}')
			}
			vgui.text_dim('ecu   ${en.ecu}')
			vgui.text_dim('buses ${en.buses.join(', ')}    NM ${if en.nm != 0 {
				'0x' + en.nm.hex()
			} else {
				'-'
			}}    ${if en.trace != 0 { 'trace' } else { 'no-trace' }}')
			if en.diag_req != 0 {
				vgui.text_dim('diag  0x${en.diag_req.hex()} / 0x${en.diag_rsp.hex()}')
			}
			// the single-ECU bench action: make everything else on this ECU's buses come alive.
			// It runs rebuild_from_proj(), which clears app.chans/dbs/sims while rx, sim and
			// generator workers iterate them lock-free — safe only when stopped AND drained.
			// stop() clears app.running BEFORE those workers exit, so !running alone leaves a
			// window where the rebuild frees what a live worker is reading (codex #65 r4). Use
			// the same gate the DBC editor uses.
			app.mu.lock()
			rb_readers := app.dbc_readers
			app.mu.unlock()
			if app.running || rb_readers > 0 {
				vgui.text_dim('Simulate the rest — stop to configure (workers drain briefly after Stop)')
			} else if vgui.small_button('Simulate the rest##restbus') {
				n, c := app.restbus_from_system(en.name)
				if c > 0 {
					app.notify('restbus for ${en.name}: simulating ${n} node(s) on ${c} channel(s) — enable/disable them in the Simulation panel')
				} else {
					app.notify('restbus: no channel matches ${en.name}\'s buses (check the project\'s interfaces)')
				}
			}
			vgui.same_line()
			vgui.text_dim('← treat as ECU under test; simulate the other nodes on its buses')
			vgui.separator_text('produces (${en.writes.len})')
			for s in en.writes {
				vgui.text('  ${s}')
			}
			vgui.separator_text('consumes (${en.reads.len})')
			for s in en.reads {
				vgui.text('  ${s}')
			}
		}
	}
	vgui.child_end()

	// buses matrix + id allocation: useful but long, so fold it (closed by default) —
	// keeps the panel focused on the nodes/ECU detail above.
	if vgui.tree_node('buses & id allocation###sysbusid') {
		for b in app.sys.buses {
			vgui.separator_text('bus ${b.name} (${b.iface}${if b.fd { ', FD' } else { '' }}${if b.bitrate > 0 {
				', ${b.bitrate / 1000} kbit'
			} else {
				''
			}})')

			// the communication matrix: signals x nodes, node columns chunked
			// well under Dear ImGui's hard 64-column table limit
			chunk := 32
			mut n0 := 0
			// a nodeless (partially authored) system still shows its signals:
			// the first pass always renders (with zero node columns), and the
			// explicit break below ends the zero-node case
			for {
				n1 := if n0 + chunk < app.sys.nodes.len { n0 + chunk } else { app.sys.nodes.len }
				if vgui.table_begin('##sysmx_${b.name}_${n0}', 3 + (n1 - n0)) {
					vgui.table_setup_col('signal', 140 * sc)
					vgui.table_setup_col('frame', 130 * sc)
					vgui.table_setup_col('cycle', 50 * sc)
					for ni in n0 .. n1 {
						vgui.table_setup_col(app.sys.nodes[ni].name, 70 * sc)
					}
					vgui.table_headers()
					for sg in app.sys.signals {
						if sg.bus != b.name {
							continue
						}
						vgui.table_row()
						vgui.table_cell(sg.name)
						vgui.table_cell(sg.frame)
						vgui.table_cell(if sg.cycle_ms > 0 { '${sg.cycle_ms}ms' } else { '-' })
						for ni in n0 .. n1 {
							cell := app.sys.matrix_cell(sg, app.sys.nodes[ni])
							vgui.table_next_col()
							if cell == 'W' {
								vgui.text_colored(205, 60, 60, 'W?') // undeclared writer
							} else if cell == 'P' {
								vgui.text_colored(120, 190, 120, 'P')
							} else if cell == 'C' {
								vgui.text_colored(86, 156, 214, 'C')
							} else {
								vgui.text_dim('')
							}
						}
					}
					vgui.table_end()
				}
				if n1 >= app.sys.nodes.len {
					break
				}
				n0 = n1
			}

			// id allocation with collisions (kind-aware: an ext twin of a
			// colliding std id is not itself flagged)
			ncols := app.sys.collision_count(b.name)
			if ncols > 0 {
				vgui.text_colored(205, 60, 60, '${ncols} id collision(s) on ${b.name}')
			}
			if vgui.table_begin('##sysid_${b.name}', 3) {
				vgui.table_setup_col('id', 90 * sc)
				vgui.table_setup_col('kind', 80 * sc)
				vgui.table_setup_col('owner', 160 * sc)
				vgui.table_headers()
				for a in app.sys.id_allocation(b.name) {
					vgui.table_row()
					idtxt := if a.ext { '0x${a.id.hex()}x' } else { '0x${a.id.hex()}' }
					if app.sys.is_collision(b.name, a.id, a.ext) {
						vgui.table_next_col()
						vgui.text_colored(205, 60, 60, '${idtxt} !')
					} else {
						vgui.table_cell(idtxt)
					}
					vgui.table_cell(a.kind)
					vgui.table_cell(a.owner)
				}
				vgui.table_end()
			}
		}
		vgui.tree_pop()
	}
	vgui.end()
}
