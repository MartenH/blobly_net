module main

import transport
import project
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
mut:
	read bool
	down bool
	// worst fault-ladder verdict of any row on this wire — health is a property of the
	// INTERFACE like `down` is (the reader-owning row is the only one whose rx_loop writes
	// it, and every alias must show it or a bus-off wire draws green on its other rows —
	// the exact defect `down` was added here to fix, repeated; self-review)
	health transport.BusHealth
	// When traffic last reached this WIRE, and whether any ever did — folded here for the same
	// reason health is. Only the reader-owning alias records them, so read row-by-row every
	// other alias of one wire looks fine while the wire it names is dead.
	rx_last f64
	rx_seen u64
	// What the backend counts beyond frames and the ladder (#213) — a property of the WIRE
	// (the hub reports every handle's ring gap, not the polled one's), written by the one
	// reader-owning row, shown on every alias for the reason health is.
	diag transport.BusDiagnostics
	// When the retained sample was taken -- ordering among retired rows, see below.
	diag_at i64
}

fn read_destinations(rows []Chan) map[string]DestState {
	mut out := map[string]DestState{}
	for c in rows {
		if c.enabled && c.running {
			mut st := out[transport.destination_key(c.iface)] or { DestState{} }
			st.read = true
			st.down = st.down || c.link_down
			if transport.health_rank(c.health) > transport.health_rank(st.health) {
				st.health = c.health
			}
			// The alias that has actually been reading is the one that knows. Not summed:
			// one reader per destination, so exactly one row carries these — and adding two
			// rows' counts together would invent a cadence neither of them saw.
			if c.rx_seen > st.rx_seen {
				st.rx_last = c.rx_last
				st.rx_seen = c.rx_seen
			}
			// One writer per wire (its RX loop), so this is a copy, not a sum.
			if !c.diag.is_empty() {
				st.diag = c.diag
			}
			out[transport.destination_key(c.iface)] = st
		}
	}
	// COUNTS OUTLIVE THE READER. A row retired by Stop or by a fatal receive keeps its last
	// sample on purpose -- it is what the wire knew at its death -- and a fold over running
	// rows only made the chip vanish at exactly that moment (codex round 2 on #231). A live
	// reader's value wins; a retired row's stands in only where no live row has one.
	for c in rows {
		if c.enabled && c.running {
			continue
		}
		// A retired row that never sampled has nothing to say; one that sampled ZERO does --
		// a reopened wire that counted nothing is newer than an older alias's counts, and
		// skipping empties resurrected those (codex round 6). Presence is the timestamp.
		if c.diag_at == 0 {
			continue
		}
		key := transport.destination_key(c.iface)
		mut st := out[key] or { DestState{} }
		// `read`, not an empty value: a LIVE reader reporting zero is a reopened wire that has
		// counted nothing yet, and the retired sample must not paint over it (codex round 3).
		// Among retired rows the NEWEST sample wins: after an A -> B -> A handoff, B's row
		// still holds the value it was handed at the first handoff (codex round 4).
		if !st.read && c.diag_at > st.diag_at {
			st.diag = c.diag
			st.diag_at = c.diag_at
			out[key] = st
		}
	}
	return out
}

// worst_wire_health folds every running wire down to the one verdict worth interrupting the
// operator with, and names the bus it came from. Built on read_destinations, the same fold the
// Buses panel colours its rows from — a second walk over `chans` here is how the toolbar and
// the panel would end up disagreeing about which wire is in trouble.
//
// `.unknown` deliberately cannot win: it ranks BELOW ok (transport.health_rank), because
// "cannot say" is not a fault and a chip that fires on it would be permanent on backends whose
// driver reports no ladder at all.
// health_chip_color and health_short are the ONE mapping of the fault ladder to how it looks:
// the Buses row and the toolbar chip both read them, so a wire cannot be amber in one place and
// red in the other. Anything at or below `ok` is never drawn by either caller — both test the
// rank first — so the fallthrough colour is only a defensive neutral.
fn health_chip_color(h transport.BusHealth) (u8, u8, u8) {
	if h == .bus_off {
		return u8(230), u8(70), u8(70)
	}
	if h == .error_passive {
		return u8(230), u8(140), u8(60)
	}
	if h == .warning {
		return u8(220), u8(190), u8(70)
	}
	return u8(200), u8(200), u8(200)
}

// health_short is the 4-character form the Buses table column has room for; the toolbar uses
// transport.health_name, which spells it out.
fn health_short(h transport.BusHealth) string {
	if h == .bus_off {
		return 'BOFF'
	}
	if h == .error_passive {
		return 'errP'
	}
	if h == .warning {
		return 'warn'
	}
	return ''
}

fn worst_wire_health(chans []Chan) (transport.BusHealth, string) {
	dests := read_destinations(chans)
	mut worst := transport.BusHealth.ok
	mut name := ''
	for c in chans {
		// A RUNNING alias, or the name is a lie. Folding is by destination, so a disabled row
		// shares its key with the enabled one that supplied the verdict — and if the disabled
		// row comes first, the toolbar blames a channel the operator can see is switched off.
		if !c.enabled || !c.running {
			continue
		}
		st := dests[transport.destination_key(c.iface)] or { continue }
		if transport.health_rank(st.health) > transport.health_rank(worst) {
			worst = st.health
			name = c.name
		}
	}
	return worst, name
}

fn chan_state(c Chan, wire DestState) (u8, u8, u8, string) {
	if !c.enabled {
		return u8(140), u8(140), u8(145), 'off '
	}
	if c.running || wire.read {
		if c.link_down || wire.down {
			return u8(215), u8(90), u8(90), 'down' // iface DOWN — bound but can't tx/rx
		}
		// the controller's own fault ladder outranks "running": a bus-off channel IS still
		// running its reader — that is how it will notice the recovery — but nothing
		// transmits, and painting it green was the lie the bench kept believing. Read from
		// the WIRE's folded verdict, not the row's own field: only the reader-owning row is
		// ever written, and its aliases must not draw green on a bus-off wire
		// Colour and label from the ONE mapping of the ladder (health_chip_color /
		// health_short), which the toolbar chip reads too: this row and that chip describe the
		// same wire, and two tables of colours is how they would come to describe it
		// differently.
		if transport.health_rank(wire.health) > transport.health_rank(transport.BusHealth.ok) {
			hr, hg, hb := health_chip_color(wire.health)
			return hr, hg, hb, health_short(wire.health)
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
				// TOPOLOGY IS FIXED AT START; WORKLOAD STAYS LIVE (#120). This tick decides
				// which buses a measurement OPENS, and changing that under a running one meant
				// spawning readers against ports other threads hold and handing wires between
				// owners. The handler this replaces was 142 lines when #120 proposed removing
				// it and 340 by the time it was removed — every mid-run defect (#114, #143,
				// #159, #164, #165, #167, #199) had added another guard to the same path, which
				// is the argument stated as a measurement.
				//
				// What is still live is the actual job of a bus tester: simulated ECUs on and
				// off, fault injection, Quick Send, generators, pause, trace filters. Those
				// mutate data the workers read; they do not create or destroy the workers. And
				// the one honest reason to reach for this tick mid-run — silencing a noisy bus
				// — is a trace filter, not a topology change.
				//
				// Changing topology is Stop, tick, Start. The Replay panel's own tick already
				// worked this way (`mid-run the set is fixed (topology at Start)`); this is the
				// same rule reaching the panel that decides which buses open at all.
				//
				// It REFUSES rather than hiding the control, which is where it parts company with
				// that panel: vgui has no tooltip and no disabled scope, so a row rendered as text
				// while running is a refusal with nowhere to say why — and this is the primary
				// control of the measurement view, not a line inside a replay group. The checkbox
				// stays where it is, keeps showing the truth, and snaps back with the reason.
				//
				// A REFUSAL DOES NOT LEAVE THE ROW. Every earlier refusal on this path ended in
				// `continue`, which jumps past the same_line() and the whole rest of the row — the
				// state label, the interface, RX, the load strip, the chips — so the bus rendered
				// as a lone checkbox for that frame. That was survivable while a refusal meant a
				// rare misconfiguration; refusing while running is now the ROUTINE outcome of
				// clicking the tick, and vgui idles at ~0.5 s a frame, so it would be a visible
				// half-second of a row with its live state blanked. The reason is carried out
				// instead, and the row draws either way.
				mut refusal := ''
				app.mu.lock()
				if app.running {
					refusal = '${c.name}: buses are fixed while running — Stop to change which ones the measurement opens'
				}
				// A ROW WITH A REJECTED EDIT IS NOT ENABLED, the same refusal Start makes: the
				// value the channel would open with is one the editor no longer shows anywhere
				// (codex #183 r3).
				if refusal == '' && new {
					if why := app.rejected_edit(i) {
						refusal = '${app.chans[i].name}: ${why} — correct it in Configuration ▸ Buses before enabling this channel'
					}
				}
				if refusal == '' {
					app.chans[i].enabled = new
					// THE TICK IS A PROJECT EDIT, like the Replay panel's
					// set_chan_enabled_stopped already is. It used to move only the runtime
					// copy: Configure went on showing the row ticked, and Save wrote it
					// enabled — two owners of one bit, synchronised in one direction (#245).
					if i < app.proj.channels.len {
						app.proj.channels[i].enabled = new
						app.dirty = true
					}
					// THE CAPABILITY WARNING BELONGS TO EVERY PATH THAT PUTS A ROW INTO A RUN,
					// not only to Start: a row ticked on here is in the next run, and the
					// warning is about what its wire can carry. log_append_locked, not notify:
					// notify takes app.mu and it is not reentrant.
					if new {
						for w in project.fd_capability_warnings([app.runtime_rows()[i]]) {
							app.log_append_locked(w)
						}
					}
					// The listen-only / framing table is derived from the enabled rows and read
					// per send, so it is republished by every writer of this bit — including a
					// Lua script's bus that outlived the last Stop.
					app.push_listen_only_locked()
				}
				app.mu.unlock()
				if refusal != '' {
					app.notify(refusal)
				}
			}
			vgui.same_line()
			// The wire's folded state, read once per row: three chips below describe it.
			wire := read_dests[transport.destination_key(c.iface)] or { DestState{} }
			r, g, b, label := chan_state(c, wire)
			vgui.text_colored(r, g, b, label)
			vgui.same_line()
			vgui.text('${c.name}  ${c.iface}  [${c.mode}]  RX ${c.rx}')
			// BUS LOAD, the gauge every CAN tool shows: the last sixty seconds as a strip and
			// this second as a number. Bits on the wire over the wire's rate
			// (transport.busload), worst-case stuffing, ours and theirs alike.
			// The number as soon as one interval has closed; the strip once there are two points
			// to draw a line between (codex #263 r4).
			if c.running && !c.doip && c.load_hist.len >= 1 {
				if c.load_hist.len >= 2 {
					vgui.same_line()
					vgui.sparkline('##load${c.iface}', c.load_hist, 100, 90 * app.prefs.ui_scale, 16 * app.prefs.ui_scale)
					vgui.set_item_tooltip('bus load, about the last ${c.load_hist.len} s — bit-times of DECODED frames on ${c.iface} over ${if c.load_nominal > 0 { c.load_nominal } else if c.bitrate > 0 { c.bitrate } else { project.default_bitrate }} bit/s, worst-case stuffing. Error frames, retransmissions and overrun drops are not in it — see the fault ladder')
				}
				vgui.same_line()
				vgui.text_dim('load ${c.load_pct:.0f}%')
			}
			// Silence, per wire, next to the row it belongs to. The ladder colour to the left
			// cannot carry this: a listening channel whose cable is pulled reports a perfectly
			// healthy bus, because CAN has no link detection and an unplugged wire is
			// indistinguishable from an idle one (#156).
			qms := app.silent_ms(wire)
			if qms > 0 {
				// DIM, and worded as an observation. Whether silence is a fault depends on what
				// the wire was supposed to carry, which nothing here knows — see stale.v.
				vgui.same_line()
				vgui.text_dim('last RX ${qms / 1000:.0f}s')
			}
			// AND WHAT THE BACKEND COUNTED that is neither a frame nor a rung (#213): dropped,
			// controller-error and undecodable records. DIM, like `last RX`, because it is a
			// fact and not a judgement: whether a dropped record matters depends on what the wire
			// was carrying, which nothing here knows — the controller's ladder stays the one
			// coloured verdict. The sentence is the tooltip; the Log has each change.
			if !wire.diag.is_empty() {
				vgui.same_line()
				vgui.text_dim(wire.diag.short())
				vgui.set_item_tooltip('${c.iface}: ${wire.diag.str()}. Counts since this wire opened; the Log has each change.')
			}
			// AND WHETHER THE TRANSCEIVER AGREED. Listen-only has two halves: this process refusing
			// to transmit, and the CONTROLLER refusing to acknowledge. The second can be declined by
			// the driver, and on a wire that is only ever RECEIVED from there is no other way for an
			// operator to learn it — a passive listener never calls send, so the error has no path
			// out (codex round 3 on #219). COLOURED, unlike `last RX`, because this one IS a
			// judgement: the row says listen-only and the wire is acknowledging anyway.
			if f := transport.wire_silence_fault(c.iface) {
				// WHICH DIRECTION FAILED, because they are opposite faults and one label described
				// both as the first (codex round 4 on #219). A refused SILENCE is a wire that keeps
				// acknowledging on a bus it was told to observe; a refused NORMAL is a wire that
				// cannot transmit at all, which is not "still acknowledging" — it is the reverse.
				vgui.same_line()
				if f.want {
					vgui.text_colored(u8(240), u8(150), u8(60), 'NOT SILENT')
					vgui.set_item_tooltip('${c.iface}: ${f.why}. This row is marked listen-only, but the transceiver is still acknowledging every frame it sees — on a bus with one other node that is the difference between its frames succeeding and it going error-passive. Retried on every receive.')
				} else {
					vgui.text_colored(u8(240), u8(150), u8(60), 'STILL SILENT')
					vgui.set_item_tooltip('${c.iface}: ${f.why}. This row is transmit-enabled, but the transceiver will not leave listen-only — so nothing sent on this wire reaches the bus, however much this app reports as sent. Retried on every receive.')
				}
			}
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
