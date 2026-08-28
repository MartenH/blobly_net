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
				mut want_iface := ''
				mut want_name := ''
				mut need_named := false
				mut need_anon := false
				// failures found while app.mu is HELD are said after the unlock: notify
				// re-takes the (non-reentrant) mutex, so an inline notify here deadlocks
				// the GUI thread — the trap that kept this path silent when start()'s copy
				// of the tap setup learned to speak
				mut open_errs := []string{}
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
				// time with nothing to explain it. EVERY ADAPTER since #117: the mode reaches the
				// transceiver only on Vector, but transport.open now decides silence for every
				// backend as the bus is handed out, so an already-open tap keeps the answer it was
				// given and the same stale-mode trap applies to a SocketCAN or PCAN wire.
				if !new && app.running && app.chans[i].listen_only {
					off_key := transport.destination_key(app.chans[i].iface)
					mut others_live := false
					mut stays_silent := false
					for j, other in app.chans {
						if j == i || transport.destination_key(other.iface) != off_key {
							continue
						}
						if other.enabled && other.running {
							others_live = true
						}
						// SILENCE WINS, the rule bitrate_iface already applies: another enabled
						// listen-only row keeps this wire quiet after the tick, so there is no
						// mode change here and nothing to refuse. Without this the widened guard
						// rejected a legitimate disable purely on which alias happened to own
						// the reader (codex #164 r2). ENABLED, not running -- an alias holds its
						// transmit tap open whether or not it reads.
						if other.enabled && other.listen_only {
							stays_silent = true
						}
					}
					if others_live && !stays_silent {
						app.mu.unlock()
						app.notify('${app.chans[i].name} set ${app.chans[i].iface} to listen-only and other channels are running on it — Stop before changing the mode of a live wire')
						continue
					}
				}
				// Carried out of the prospective check below so the warning block further down can
				// use it. Empty unless this toggle is a row joining a LIVE run, which is the only
				// case where that check runs and the only one where an alias matters yet.
				mut alias_warns := []string{}
				// Not vendor-only either: destination_conflicts now refuses a listen-only
				// disagreement on any wire, so enabling a normal row onto a silenced software or
				// SocketCAN bus has to be caught here too rather than joining it mute.
				if new && app.running {
					app.chans[i].enabled = true
					// THE WHOLE-PROJECT ANSWER FOR THE ARRANGEMENT THIS TOGGLE WOULD CREATE, kept
					// rather than reduced to its first refusal. Its warnings are the only ones that
					// can name an already-enabled row the driver would not describe — the row this
					// one may be about to share a transceiver with (codex #199 r2).
					prospective := app.destination_check()
					app.chans[i].enabled = false
					if prospective.problems.len > 0 {
						app.mu.unlock()
						app.notify('${prospective.problems[0]} — not enabling')
						continue
					}
					alias_warns = prospective.warnings.clone()
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
					// AND THE PORTS THAT ARE ALREADY OPEN, which no scan of the rows can see. A
					// DISABLED row keeps its transmit taps open deliberately, so it is neither
					// enabled nor read and gets no vote above — right for the project's rule,
					// which #164 settled on enabled rows, and irrelevant to a driver that has
					// never heard of a row. Issue #165: disable the only normal row, enable the
					// listen-only alias, and every check here waved it through to ports the XL
					// driver then refused, leaving the ticked row with no taps at all while the
					// transceiver went on acknowledging through the stale ones.
					// AGAINST THE STRING THAT WILL ACTUALLY BE OPENED. bitrate_iface picks the
					// mode and the rate for the WIRE — silence wins, enabled rows decide — so the
					// row's own fields are not what its taps are about to ask for. Asked with the
					// row enabled, exactly as the rate conflict above is, because that is the
					// state whose consequences are in question.
					app.chans[i].enabled = true
					would_open := app.bitrate_iface(app.chans[i].iface)
					app.chans[i].enabled = false
					// The transport layer answers, rather than this panel comparing modes it
					// would have to parse out of a vendor address for itself: which ports are
					// open is known only to the code that opened them, and reading the address is
					// the interpretation that belongs in modules/. Empty for every backend that
					// does not pin — see modules/transport/pinned.v.
					pin := transport.wire_pin_clash(would_open)
					if pin != '' {
						app.mu.unlock()
						app.notify('${app.chans[i].name} ${pin} — the configuration belongs to the ports open on this channel, not to the rows; Stop and Start to change it')
						continue
					}
				}
				// A ROW WITH A REJECTED EDIT MAY NOT JOIN A RUN, and this path is the only way one
				// can. Start refuses on enabled rows only — a disabled channel is never opened, so
				// its uncommitted field is not a reason to stop the others (#183 r2) — which is
				// exactly what leaves this door open: enabling that row mid-run would put it on
				// the wire at the model's PREVIOUS rate while the editor still shows the value
				// that was refused. The same model/editor mismatch the Start guard exists to
				// prevent, arrived at from the side (codex #183 r3).
				if new {
					if why := app.rejected_edit(i) {
						app.mu.unlock()
						app.notify('${app.chans[i].name}: ${why} — correct it in Configuration ▸ Buses before enabling this channel')
						continue
					}
				}
				if app.running && app.chans[i].mode == 'replay' && app.chans[i].replay_src != '' {
					app.mu.unlock()
					app.notify('${app.chans[i].name}: replay channels are fixed while running — Stop and Start to change which ones play')
					continue
				}
				app.chans[i].enabled = new
				// THE CAPABILITY WARNING BELONGS TO EVERY PATH THAT PUTS A ROW INTO A RUN, not
				// only to Start. A row disabled at Start is correctly skipped by
				// fd_capability_warnings — it states nothing about the run — but enabling it here
				// is the moment it starts stating something, and this path never asked again. It
				// mattered more after #181 r5 stopped reporting a PCAN/Kvaser FD row as a
				// destination CONFLICT: with the conflict gone and the warning never re-run, such
				// a row joined a live run in silence, its classic traffic flowing while replayed
				// FD frames were counted as failed — the misleading partial experiment the
				// warning exists to prevent (codex #181 r6).
				//
				// Warnings only, and after the toggle: nothing here refuses an enable that the
				// checks above allowed.
				//
				// UNDER THE LOCK THROUGHOUT, via log_append_locked. notify() takes app.mu itself,
				// so calling it here would deadlock — and dropping the lock to call it would leave
				// app.chans open to another thread in the middle of a sequence that goes on to
				// read it, which is the unlocked-read-of-a-replaced-array mistake this file has
				// paid for before. fd_capability_warnings is pure, so it is safe to run inside.
				// THE ROW THAT JUST JOINED, not every row in the run. Passing the whole set warned
				// again about every already-enabled PCAN/Kvaser FD channel on each toggle, so
				// unrelated ticking filled the Log with duplicates of a warning already given at
				// Start — and a warning repeated for no reason is one an operator learns to skip
				// past (codex #183 r2). Start still asks about the whole project, because there
				// every row is joining at once.
				if new {
					for w in project.fd_capability_warnings([app.runtime_rows()[i]]) {
						app.log_append_locked(w)
					}
					// AND WHETHER THE ALIAS CHECK COULD SEE THIS ROW (#194). Same argument as the
					// capability warning above, which is why it sits beside it: a row disabled at
					// Start states nothing, and enabling it here is the moment it starts to — so a
					// row whose physical channel the driver would not describe has to be mentioned
					// on this path too, or it is silent for every row that joins a live run
					// (codex #199 r1).
					//
					// FROM THE PROSPECTIVE WHOLE-PROJECT CHECK ABOVE, not a fresh one about this row.
					// Two reasons, and the first is correctness: the unreadable row may be one that
					// is ALREADY enabled and sharing this row's transceiver, which a check scoped to
					// the newcomer cannot see. The second is that the sweep is already paid for — the
					// clash check a few lines up made it — so asking again would be a second XL sweep
					// under app.mu for an answer we hold (codex #199 r2). Empty when the toggle did
					// not go through that branch, which is every case where nothing is running.
					for w in alias_warns {
						app.log_append_locked(w)
					}
				}
				// The wire list is derived from the runtime rows and consulted per SEND, so it has
				// to move with this toggle: a listen-only row enabled here would otherwise open its
				// taps against a table that never learned about it, and a disabled one would leave
				// its mark silencing a normal row enabled onto the same wire afterwards. Before the
				// taps below, and while the lock is held, so no open can read a stale list.
				app.push_listen_only_locked()
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
						// a re-enable after a GAP resets the verdict: nobody watched the
						// wire while this row was off, and the interface may have
						// recovered unseen — a fresh healthy backend reports .unknown and
						// would never overwrite the stale BUS-OFF (codex #143 r3). The
						// reader HANDOFF is different and carries its verdict: there the
						// wire was observed continuously.
						app.chans[i].health = .unknown
						// The CADENCE goes with it, and for the same reason: the wire may
						// have carried traffic all through the gap with nobody counting it,
						// so the old timestamp would report the entire unobserved interval
						// as silence the moment the reader comes back (codex #159 r3).
						app.chans[i].rx_last = 0
						app.chans[i].rx_seen = 0
						// NOT the counts (#213). On a shared wire the transmit taps kept the
						// generation alive through the gap, so its since-open counters
						// survive; zeroed here, the successor seeded its narration from
						// nothing and logged the whole history as new (codex round 1 on
						// #231). Kept, the successor sees the same counts and says nothing;
						// on a wire that WAS reopened it sees them fall and says so.
						app.chans[i].spawning = true
						spawn rx_loop(app, i, app.chans[i].iface, app.run_gen)
					}
					// …and the TRANSMIT side, exactly as start() sets it up. Only the reader was
					// started here, so a channel enabled after Start had no tap: Quick Send and
					// the diagnostic paths reported "no open bus", and with no send_iface yet the
					// Send panel had nothing selected. (Nobody hit it while the branch was
					// unreachable — fixing that exposed the other half.)
					// only RECORD what needs a tap here: a vendor open can block ~2s
					// waiting for a port release (run.v's own lesson), and doing it with
					// app.mu held on the GUI thread froze the UI AND every rx_loop's
					// per-frame lock behind a driver timeout (self-review). The opens run
					// after the unlock; the inserts re-take the lock briefly — a V map is
					// not safe for a concurrent read and write (tx_on_chan's invariant).
					// record WHICH taps are actually missing while the lock is held — a
					// re-enabled row's taps usually still exist (disable does not remove
					// them), and opening unconditionally leaked the discarded winner's
					// port on Vector, unreachable by teardown (codex #143 r1, P1)
					want_iface = app.chans[i].iface
					want_name = app.chans[i].name
					need_named = tx_bus_key(want_name, want_iface) !in app.tx_buses
					need_anon = tx_bus_key('', want_iface) !in app.tx_buses
					if app.send_iface == '' {
						app.send_iface = want_iface
					}
				}
				app.mu.unlock()
				for m in open_errs {
					app.notify(m)
				}
				if want_iface != '' && need_named {
					key := tx_bus_key(want_name, want_iface)
					if mut b := app.open_tap_on(want_iface, org_tx, want_name) {
						app.mu.lock()
						race := key in app.tx_buses
						if !race {
							app.tx_buses[key] = b
						}
						app.mu.unlock()
						if race {
							b.close() // somebody inserted first — the loser must not leak
						}
					} else {
						app.notify('${want_name}: transmit tap failed to open — ${err}')
					}
				}
				if want_iface != '' && need_anon {
					key := tx_bus_key('', want_iface)
					if mut b := app.open_tap(want_iface, org_tx) {
						app.mu.lock()
						race := key in app.tx_buses
						if !race {
							app.tx_buses[key] = b
						}
						app.mu.unlock()
						if race {
							b.close()
						}
					} else {
						app.notify('${want_iface}: shared transmit tap failed to open — ${err}')
					}
				}
			}
			vgui.same_line()
			// The wire's folded state, read once per row: three chips below describe it.
			wire := read_dests[transport.destination_key(c.iface)] or { DestState{} }
			r, g, b, label := chan_state(c, wire)
			vgui.text_colored(r, g, b, label)
			vgui.same_line()
			vgui.text('${c.name}  ${c.iface}  [${c.mode}]  RX ${c.rx}')
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
