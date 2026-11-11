module main

import blobly.nm
import blobly.sim
import blobly.transport
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
		// id by project row, not interface or name: two channels on one interface — or two rows
		// sharing a name too — collapsed into a single imgui id, so expanding one expanded the
		// other. Same substitution as sim_key, name and interface in it too so a deleted row's
		// open state does not pass to the row that takes its index. The label names the row
		// where its name is shared.
		hdr_bus := if sc.who != sc.pch.name { '${sc.iface}  ${sc.who}' } else { sc.iface }
		if !vgui.tree_node('${hdr_bus}   (${sc.nodes.len})###simbus_${sc.proj_idx}|${sc.pch.name}|${sc.iface}') {
			continue
		}
		// the nodes announcing on the wire's NM cluster, as the run (or the next Start) reads it:
		// on an announced frame only a drop takes effect
		mut wire_nm := ?nm.Config(none)
		app.mu.lock()
		if c := app.nm_cfg[transport.destination_key_for(sc.pch.adapter, sc.iface)] {
			wire_nm = c
		}
		app.mu.unlock()
		anns, _ := nm.announcements(wire_nm, sc.nodes)
		for node in sc.nodes {
			// sim_key, not '<iface>:<node>': the panel writes what the CAN loop and the DoIP
			// supervisor read, so all three move together or a tick lands on a key nobody
			// consults. Channel identity is in the key because two channels can share an
			// interface string and a node name — and the row INDEX, because two rows may share
			// both (#575).
			key := sim_key(sc.proj_idx, sc.pch, node.name)
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
				nprot := sim.protections(sc.db, node)
				for m in sc.db.messages_from(node.name) {
					cur := sim.injected_fault(sc.iface, node.name, m.name)
					lbl := match cur.kind {
						.none_ { 'normal' }
						.drop { 'DROP' }
						.bad_crc { 'BAD CRC' }
						.freeze_ctr { 'FROZEN CTR' }
						.out_of_range { 'OUT OF RANGE' }
					}

					// only what takes effect on THIS message, by the rule a script's arm keeps:
					// a fault that changes no bit on the wire would read as active and do nothing
					offer := sim.fault_offer(node, m, nprot[m.name] or { []sim.E2e{} }, anns)
					kind_of := offer.kinds
					oor_sig := offer.oor_signal
					kinds := kind_of.map(match it {
						.none_ { 'normal' }
						.drop { 'drop' }
						.bad_crc { 'bad crc' }
						.freeze_ctr { 'freeze counter' }
						.out_of_range { 'out of range (${oor_sig})' }
					})
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
