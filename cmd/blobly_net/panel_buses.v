module main

import transport
import vgui

// channel state colour + short ASCII label (imgui's default font is ASCII-only):
// grey off (disabled) / red down (attached but the CAN iface is DOWN) / green run / amber idle.
// `shared_reader` says this row's wire is being read by a SIBLING. One reader serves a
// destination, so every alias after the first has running == false while its transmit taps and
// its simulation are perfectly alive — and the panels drew them amber `idle`, reporting that
// part of the experiment had not started when it had.
// read_destinations builds "which wires have a reader" from a SNAPSHOT of the rows, so a panel
// can answer it without touching live state. dest_is_read_locked wants app.mu and the panels do
// not hold it — the frame already cloned `chans` under the lock, and re-reading the live array
// past that snapshot raced the workers publishing into it. My own comment on that helper said it
// required the lock, which made calling it here a contradiction rather than an oversight.
// Returns, per destination: is it read at all, and is the reader's link DOWN. The second half
// matters because a readerless alias carries its own untouched `link_down == false` — so a wire
// the owning row correctly showed as `down` was drawn green and running on every alias of it.
// The link is a property of the interface, not of the row that happened to open it.
struct DestState {
	read bool
	down bool
}

fn read_destinations(rows []Chan) map[string]DestState {
	mut out := map[string]DestState{}
	for c in rows {
		if c.enabled && c.running {
			out[transport.destination_key(c.iface)] = DestState{
				read: true
				down: c.link_down
			}
		}
	}
	return out
}

fn chan_state(c Chan, wire DestState) (u8, u8, u8, string) {
	if !c.enabled {
		return u8(140), u8(140), u8(145), 'off '
	}
	if c.running || wire.read {
		if c.link_down || wire.down {
			return u8(215), u8(90), u8(90), 'down' // iface DOWN — bound but can't tx/rx
		}
		return u8(90), u8(200), u8(120), 'run '
	}
	return u8(220), u8(170), u8(70), 'idle'
}

fn draw_buses(mut app App, chans []Chan) {
	// From the SNAPSHOT this frame was given, not from live state: the rows were cloned under
	// app.mu and re-reading past that clone races the workers writing into it.
	read_dests := read_destinations(chans)
	vis, op := vgui.begin_closable('Buses', app.show_buses)
	app.show_buses = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text('${app.proj_name} · ${chans.len} channel(s)')
	// The Buses panel is the runtime VIEW (enable/state); add/remove/edit a bus lives in the
	// Configuration editor (stopped-only).
	if app.running {
		vgui.text_dim('Stop to configure buses')
	} else if vgui.button('Configure...') {
		app.show_config = true
		app.sync_cfg_bufs()
	}
	// group channels by adapter type (in-process / SocketCAN / hardware / UDP / DoIP), each a
	// collapsible group with a count — so a big mixed setup folds into a few headers, and a
	// single-type project is just one group.
	mut order := []string{}
	mut groups := map[string][]int{}
	for i, c in chans {
		k := bus_kind(c.adapter)
		if k !in groups {
			order << k
		}
		groups[k] << i
	}
	for k in order {
		idxs := groups[k]
		if !vgui.tree_node_open('${k}   (${idxs.len})###busgrp_${k}') {
			continue
		}
		for i in idxs {
			c := chans[i]
			new := vgui.checkbox('##en${i}', c.enabled)
			if new != c.enabled {
				app.mu.lock()
				// FIXED AT START for a replay channel. Changing the set mid-run meant a worker
				// had to be spawned, or silenced, or made to hand its wire over, against a
				// group whose clock and membership were fixed when it began -- and every one of
				// those states was a way for two recordings to reach one bus, or for a wire to
				// be driven by somebody who no longer held it. The set is what it was when Start
				// was pressed; changing it is Stop and Start, which costs one click and removes
				// the states entirely.
				// THE SAME CHECK Start makes. Enabling a channel live is another way into a
				// run, and it walked past the rate-conflict validation entirely — so an alias
				// configured for a different bitrate could join a running wire, and the vendor
				// layer never saw the disagreement because bitrate_iface had already picked one.
				// DISABLING can change the mode as much as enabling. With a passive normal row
				// and a listen-only row on one wire, every port opened silent; switching the
				// listen-only row off leaves the normal row's already-open ports silent while
				// the model now says the wire is normal, and its transmits are refused one at a
				// time with nothing to explain it. Only Vector, where the mode reaches hardware.
				if !new && app.running && app.chans[i].adapter == 'vector'
					&& app.chans[i].listen_only {
					mut others_live := false
					off_key := transport.destination_key(app.chans[i].iface)
					for j, other in app.chans {
						if j != i && other.enabled && other.running
							&& transport.destination_key(other.iface) == off_key {
							others_live = true
							break
						}
					}
					if others_live {
						app.mu.unlock()
						app.notify('${app.chans[i].name} set ${app.chans[i].iface} to listen-only and other channels are running on it — Stop before changing the mode of a live wire')
						continue
					}
				}
				if new && app.running && app.chans[i].adapter in ['pcan', 'kvaser', 'vector'] {
					app.chans[i].enabled = true
					clash := app.destination_conflict()
					app.chans[i].enabled = false
					if bad := clash {
						app.mu.unlock()
						app.notify('${bad} — not enabling')
						continue
					}
					// THE MODE OF A WIRE THAT IS ALREADY OPEN. silent_conflict only speaks up
					// when something would transmit; two passive rows disagreeing about the
					// mode say nothing to it, yet the shim still refuses the new ports because
					// the live ones configured the channel the other way — leaving the row
					// ticked with no reader and no explanation. Ask whether this row would
					// change the answer for a destination that is already running.
					wire_key := transport.destination_key(app.chans[i].iface)
					// SILENCE WINS, as bitrate_iface decides it. Taking the first running alias's
					// flag read the wire as normal whenever the normal row happened to be listed
					// first, though every port on it had been opened silent by its sibling — so
					// the guard let through exactly the change it exists to refuse.
					mut live_mode := ?bool(none)
					for j, other in app.chans {
						// PART OF THE RUN, not "owns the reader". Under one reader per wire an
						// alias has running == false while its transmit tap is open and its
						// simulation is going, and skipping it read a silenced wire as having no
						// opinion about its own mode.
						if j == i || !other.enabled {
							continue
						}
						if transport.destination_key(other.iface) != wire_key {
							continue
						}
						if !app.dest_is_read_locked(other.iface) {
							continue
						}
						if m := live_mode {
							live_mode = m || other.listen_only
						} else {
							live_mode = other.listen_only
						}
					}
					if lm := live_mode {
						if lm != app.chans[i].listen_only {
							app.mu.unlock()
							want := if app.chans[i].listen_only { 'listen-only' } else { 'normal' }
							has := if lm { 'listen-only' } else { 'normal' }
							app.notify('${app.chans[i].name} is ${want} but ${app.chans[i].iface} is already running ${has} — one wire, one mode; not enabling')
							continue
						}
					}
				}
				if app.running && app.chans[i].mode == 'replay' && app.chans[i].replay_src != '' {
					app.mu.unlock()
					app.notify('${app.chans[i].name}: replay channels are fixed while running — Stop and Start to change which ones play')
					continue
				}
				app.chans[i].enabled = new
				// enabling a channel mid-run spawns its RX thread; disabling lets it exit.
				// `spawning` is the double-click guard — without one, a second click inside the
				// open window starts a second rx_loop and every frame is logged twice. It is
				// SEPARATE from `running` on purpose: running means "a monitor is reading", and
				// an inproc bus broadcasts only to subscribers already attached, so a frame sent
				// while the socket is still opening cannot echo. Claiming a watcher that early
				// marked healthy traffic as never having reached the wire.
				// `c` is the PRE-toggle snapshot, so c.enabled is still false here and
				// c.monitorable() could never be true — this branch has never run, and a channel
				// re-enabled mid-run silently got no reader at all. Ask about the channel as it
				// is NOW, using the same rule monitorable() applies.
				// AND NOBODY ELSE IS READING THIS WIRE. Enabling an alias of a monitored
				// destination used to open a second port on it, which is the duplicate delivery
				// that one-reader-per-wire exists to prevent, arriving through the toggle
				// instead of through Start.
				// THE READER IS OPTIONAL; THE TRANSMIT SIDE IS NOT. Folding the wire-already-read
				// test into this condition skipped the tap setup below along with it, so an
				// alias enabled beside a monitored sibling could not transmit at all — Quick
				// Send and the diagnostic paths reporting "no open bus" for a channel that was
				// ticked and sitting on a live wire.
				if new && app.running && app.chans[i].monitorable() && !app.chans[i].running
					&& !app.chans[i].spawning {
					if !app.dest_is_read_locked(app.chans[i].iface) {
						app.chans[i].spawning = true
						spawn rx_loop(app, i, app.chans[i].iface, app.run_gen)
					}
					// …and the TRANSMIT side, exactly as start() sets it up. Only the reader was
					// started here, so a channel enabled after Start had no tap: Quick Send and
					// the diagnostic paths reported "no open bus", and with no send_iface yet the
					// Send panel had nothing selected. (Nobody hit it while the branch was
					// unreachable — fixing that exposed the other half.)
					iface := app.chans[i].iface
					name := app.chans[i].name
					if tx_bus_key(name, iface) !in app.tx_buses {
						if b := app.open_tap_on(iface, org_tx, name) {
							app.tx_buses[tx_bus_key(name, iface)] = b
						}
					}
					if tx_bus_key('', iface) !in app.tx_buses {
						if b := app.open_tap(iface, org_tx) {
							app.tx_buses[tx_bus_key('', iface)] = b
						}
					}
					if app.send_iface == '' {
						app.send_iface = iface
					}
				}
				app.mu.unlock()
			}
			vgui.same_line()
			r, g, b, label := chan_state(c, read_dests[transport.destination_key(c.iface)] or {
				DestState{}
			})
			vgui.text_colored(r, g, b, label)
			vgui.same_line()
			vgui.text('${c.name}  ${c.iface}  [${c.mode}]  RX ${c.rx}')
			// system awareness: when a system.toml is loaded, name the ECUs that sit on
			// this bus — the channel row alone doesn't say WHO is on the wire. The system
			// bus is matched by its interface (system [bus.x].interface == the channel's).
			if app.sys_loaded {
				mut bus_name := ''
				for sb in app.sys.buses {
					if sb.iface == c.iface {
						bus_name = sb.name
						break
					}
				}
				if bus_name != '' {
					mut on_bus := []string{}
					for n in app.sys.nodes {
						if bus_name in n.buses {
							on_bus << n.name
						}
					}
					if on_bus.len > 0 {
						// own line, indented: the channel row is narrow and would clip this
						vgui.text_dim('        ${bus_name}: ${on_bus.join(', ')}')
					}
				}
			}
		}
		vgui.tree_pop()
	}
	vgui.end()
}

// bus_kind maps a channel adapter to a friendly type-group label for the Buses panel.
fn bus_kind(adapter string) string {
	return match adapter {
		'virtual' { 'Virtual (in-process)' }
		'vcan' { 'Virtual CAN (vcan)' }
		'socketcan' { 'SocketCAN' }
		'pcan' { 'PCAN (hardware)' }
		'kvaser' { 'Kvaser (hardware)' }
		'udp' { 'UDP software bus' }
		'doip' { 'DoIP (Ethernet)' }
		'' { 'Other' }
		else { adapter }
	}
}

// draw_network shows the bus topology: each channel (bus) and everything attached to it —
// the tester's own functions (Monitor / Send / Diagnostics), simulated ECUs, and generators
// grouped by the bus they actually transmit on. The simulation-setup analog.
fn draw_network(mut app App, chans []Chan) {
	// From the SNAPSHOT this frame was given, not from live state: the rows were cloned under
	// app.mu and re-reading past that clone races the workers writing into it.
	read_dests := read_destinations(chans)
	vis, op := vgui.begin_closable('Network', app.show_network)
	app.show_network = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text_dim('each bus and what is attached to it')
	if chans.len == 0 {
		vgui.text_dim('no channels in this project')
		vgui.end()
		return
	}
	for ci, c in chans {
		r, g, b, st := chan_state(c, read_dests[transport.destination_key(c.iface)] or {
			DestState{}
		})
		vgui.text_colored(r, g, b, '*')
		vgui.same_line()
		if vgui.tree_node_open('${c.name}   ${c.iface}   [${c.mode}]   ${st.trim_space()}   RX ${c.rx}###net${ci}') {
			mut any := false
			// tester functions this tool runs on the bus
			mut tf := []string{}
			if c.monitorable() {
				tf << 'Monitor'
			}
			if app.send_iface == c.iface {
				tf << 'Send'
			}
			for sc in app.sims {
				if sc.iface == c.iface {
					tf << 'Diagnostics (UDS 0x7E0->0x7E8)'
					break
				}
			}
			if tf.len > 0 {
				vgui.text('    Tester:  ${tf.join('  ·  ')}')
				any = true
			}
			// simulated ECUs on this bus
			for sc in app.sims {
				if sc.iface != c.iface {
					continue
				}
				for n in sc.nodes {
					vgui.text('    ECU:     ${n.name}')
					any = true
				}
			}
			// generators that transmit on this bus (after Part-1 routing they group correctly)
			for sr in app.senders {
				if sr.target() != c.iface {
					continue
				}
				s := sr.sender
				desc := if s.message != '' { s.message } else { 'id 0x${s.id:X}' }
				trig := match s.trigger {
					'cyclic' { 'cyclic ${s.cycle_ms}ms' }
					'key' { 'key ${s.key}' }
					else { 'manual' }
				}

				vgui.text('    Gen:     ${s.name}  (${desc}, ${trig})')
				any = true
			}
			if c.mode == 'replay' {
				vgui.text('    Replay:  playing recording')
				any = true
			}
			if !any {
				vgui.text_dim('    (nothing attached)')
			}
			vgui.tree_pop()
		}
	}
	vgui.end()
}
