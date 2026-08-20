module main

import sim
import vgui

// draw_sim lists the in-process simulation workload: each channel's simulated ECUs,
// expandable to their signal generators + request/response rules.
fn draw_sim(mut app App) {
	vis, op := vgui.begin_closable('Simulation', app.show_sim)
	app.show_sim = op
	if !vis {
		vgui.end()
		return
	}
	if app.sims.len == 0 {
		vgui.text_dim('no simulated ECUs in this project')
		vgui.end()
		return
	}
	vgui.text_dim('tick to enable/disable an ECU live')
	for sc in app.sims {
		// each bus is a collapsible group, collapsed by default (### keeps the id stable if the
		// label changes)
		// id by channel, not interface: two channels on one interface collapsed into a single
		// imgui id, so expanding one expanded the other. Same substitution as sim_key.
		if !vgui.tree_node('${sc.iface}   (${sc.nodes.len})###simbus_${sc.pch.name}|${sc.iface}') {
			continue
		}
		for node in sc.nodes {
			// sim_key, not '<iface>:<node>': the panel writes what the CAN loop and the DoIP
			// supervisor read, so all three move together or a tick lands on a key nobody
			// consults. Channel identity is in the key because two channels can share an
			// interface string and a node name.
			key := sim_key(sc.pch, node.name)
			en := app.sim_enabled[key] or { true }
			nen := vgui.checkbox('##simen_${key}', en)
			if nen != en {
				app.mu.lock()
				app.sim_enabled[key] = nen
				app.sim_gen++
				app.mu.unlock()
			}
			vgui.same_line()
			// A shorthand node (project `simulate:`, e.g. from "Simulate the rest") carries NO
			// explicit config by design — build_node derives its frames from the DBC by
			// transmitter name. Printing "0 sig / 0 resp" for it reads as "this ECU sends
			// nothing", which is wrong and alarming; say where its behaviour comes from.
			// Protection is worth its own word in the header. It is invisible on the wire until
			// the ECU rejects a frame, so "is this node protected?" must be answerable without
			// opening the project file.
			// ASCII only: fonts are loaded without expanded glyph ranges, and the fallback
			// ProggyClean is ASCII-only, so a shield or an arrow renders as a missing-glyph box.
			prot := if node.protect.len > 0 { '  [P${node.protect.len}]' } else { '' }
			diag := if node.uds != none { '  [UDS]' } else { '' }
			// Protection is orthogonal to BEHAVIOUR, in the label exactly as in from_project: a
			// protect-only node still transmits its DBC-derived frames, so calling it
			// "0 sig / 0 resp" recreates the "this ECU sends nothing" reading the line above
			// exists to avoid. The protection count is appended to whichever label applies.
			hdr := if node.signals.len == 0 && node.responses.len == 0 {
				'${node.name}  (frames derived from the DBC)${prot}${diag}###${key}'
			} else {
				'${node.name}  (${node.signals.len} sig / ${node.responses.len} resp)${prot}${diag}###${key}'
			}
			if vgui.tree_node(hdr) {
				for g in node.signals {
					vgui.text('    ${g.signal}: ${g.typ}')
				}
				for r in node.responses {
					vgui.text('    ${r.request} -> ${r.response}')
				}
				// Protection that matches nothing is applied nowhere while the count above still
				// claims it is on. Say so here, next to the claim.
				if u := node.uds {
					mut what := 'rx 0x${u.rx:X} / tx 0x${u.tx:X}'
					if u.dids.len > 0 {
						what += ', ${u.dids.len} DID(s)'
					}
					if u.dtcs.len > 0 {
						what += ', ${u.dtcs.len} DTC(s)'
					}
					vgui.text('    [UDS] ${what}')
				}
				for w in sim.validate_cfg(sc.db, node) {
					vgui.text_dim('    ! ${w}')
				}
				// Fault injection, per message. Only messages the DBC says this node sends,
				// because a fault on a frame it never transmits does nothing and reads as a
				// broken feature rather than a misconfiguration.
				for m in sc.db.messages_from(node.name) {
					cur := sim.injected_fault(sc.iface, node.name, m.name)
					lbl := match cur.kind {
						.none_ { 'normal' }
						.drop { 'DROP' }
						.bad_crc { 'BAD CRC' }
						.freeze_ctr { 'FROZEN CTR' }
						.out_of_range { 'OUT OF RANGE' }
					}

					// Only offer what can take effect on THIS message. bad_crc without a
					// configured checksum changes no bits, and out_of_range needs a signal with
					// an illegal value — offering either would show a fault the bus never sees.
					has_crc := node.protect.any(it.message == m.name && it.crc != '')
					has_ctr := node.protect.any(it.message == m.name && it.counter != '')
					mut oor_sig := ''
					mut mprot := sim.E2e{}
					for pr in node.protect {
						if pr.message == m.name {
							mprot = sim.E2e{
								counter: pr.counter
								crc:     pr.crc
								profile: pr.profile
							}
						}
					}
					for sg in m.signals {
						if sim.can_force_out_of_range(m, sg.name, mprot) {
							oor_sig = sg.name
							break
						}
					}
					mut kinds := ['normal', 'drop']
					mut kind_of := [sim.FaultKind.none_, .drop]
					// Independently: a counter-only entry can be frozen but has no checksum to
					// corrupt, and a crc-only entry the reverse. Gating both on the checksum
					// offered one fault that changes nothing and hid one that works.
					if has_crc {
						kinds << 'bad crc'
						kind_of << .bad_crc
					}
					if has_ctr {
						kinds << 'freeze counter'
						kind_of << .freeze_ctr
					}
					if oor_sig != '' {
						kinds << 'out of range (${oor_sig})'
						kind_of << .out_of_range
					}
					mut sel := 0
					for ki, kk in kind_of {
						if kk == cur.kind {
							sel = ki
							break
						}
					}
					vgui.text('    ${m.name}: ${lbl}')
					vgui.same_line()
					nsel := vgui.combo('##fault_${sc.iface}_${node.name}_${m.name}', kinds, sel)
					if nsel != sel && nsel < kind_of.len {
						sim.inject(sc.iface, node.name, m.name, sim.Fault{
							kind:   kind_of[nsel]
							signal: if kind_of[nsel] == .out_of_range { oor_sig } else { '' }
						})
					}
				}
				for pr in node.protect {
					mut what := []string{}
					if pr.counter != '' {
						what << 'counter ${pr.counter}'
					}
					if pr.crc != '' {
						what << '${pr.profile} -> ${pr.crc}'
					}
					if id := pr.data_id {
						what << 'id 0x${id:02X}' // shown even when 0: an explicit zero id is
						// not the same as none, and telling them apart is the whole point when
						// you are staring at a checksum mismatch
					}
					vgui.text('    [P] ${pr.message}: ${what.join(', ')}')
				}
				vgui.tree_pop()
			}
		}
		vgui.tree_pop()
	}
	vgui.end()
}
