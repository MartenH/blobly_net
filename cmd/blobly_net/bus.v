module main

import os
import sync
import project
import transport

// Chan is one project channel's live state (the Buses panel row + Start/Stop target).
struct Chan {
	name         string
	network      string // grouping label (v2)
	adapter      string // transport backend (v2): virtual|vcan|socketcan|udp|pcan|kvaser|doip
	address      string // adapter-specific address (v2)
	iface        string
	mode         string
	typ          string
	bitrate      int
	data_bitrate int
	listen_only  bool
	databases    []string
	manifest     string
	doip         bool
	// Replay configuration, when mode == 'replay'. Held on the channel because the worker needs
	// it after Start, and the project may have been edited since.
	replay_src     string
	replay_bus     string
	replay_exclude []string
	replay_speed   f64 = 1.0
	replay_loop    bool
mut:
	enabled bool
	rx      u64
	// When traffic last reached this wire (the trace's clock, App.since_ms) and whether any ever
	// did. Enough to answer "how long has this bus been silent?" without touching the trace: the
	// ring is capped and filtered, and a wire is silent whether or not its rows are still on
	// screen. `rx_seen` is a HAS-IT-EVER, not a cadence — see stale.v for why no cadence is
	// inferred from these at all.
	//
	// Separate from `rx`, which is the DISPLAYED count and is zeroed by clear_trace() — these
	// are not, deliberately: clearing the view must not make the app forget the wire was ever
	// alive, or a Clear would silently reset the reported silence to nothing. They reset at
	// Start instead, with the measurement they describe.
	rx_last f64
	rx_seen u64
	running  bool
	spawning  bool // rx_loop spawned but its bus not open yet (double-click guard)
	link_down bool // real CAN iface is administratively DOWN (bound but can't tx/rx)
	// The controller's fault ladder, from the backend's own driver (transport.BusHealth) —
	// written by the wire's RX loop on transitions, .unknown where the backend cannot say.
	health transport.BusHealth
}

fn (c Chan) monitorable() bool {
	return c.enabled && c.mode in ['monitor', 'replay'] && !c.doip
}

// replay_blocker names the reason a replay-mode channel will not play — '' when nothing
// blocks it. THE one statement of the disqualifiers: replaying() is defined by it and the
// Replay panel prints it, so a clause added here reaches both — the panel hand-copying the
// clauses is how a ticked row that will not play came back once already (self-review of the
// grouped panel: its copy tested `typ == 'doip'`, narrower than the is_doip() rule behind
// c.doip, and an `interface: doip:<host>` row rendered as playable).
fn (c Chan) replay_blocker() string {
	return replay_blocker(c.doip, c.listen_only, c.replay_src)
}

// The free form exists for the Replay panel's preview, which must judge the MODEL
// (project.Channel: is_doip(), listen_only, replay source) — the runtime rows lag behind
// Configure's checkboxes until apply_edits, and Start folds the model first, so a preview
// read from Chan showed "(one clock)" over a channel Start was about to drop (codex #136
// r1). One rule, two adapters; the clauses live only here.
fn replay_blocker(doip bool, listen_only bool, src string) string {
	if doip {
		return 'DoIP channel — replay does not apply'
	}
	if listen_only {
		// listen_only means NEVER TRANSMIT, which is what the editor promises and what a
		// bench relies on when it is wired to a live vehicle. A replay channel is not an
		// exception: it would be the loudest possible violation of it.
		return "listen-only — will NOT play (never transmit is the editor's promise)"
	}
	if src == '' {
		return 'no recording set'
	}
	return ''
}

// replaying reports a channel that PLAYS a recording onto its bus. Such a channel is also
// monitored — the frames come back like anything else on the wire, and the echo is how the
// trace confirms they were really transmitted rather than merely queued.
fn (c Chan) replaying() bool {
	return c.enabled && c.mode == 'replay' && c.replay_blocker() == ''
}

// chan_name_for maps a bus iface back to its channel name (the Trace `ch` column value),
// falling back to the iface if unmatched.
fn (app &App) chan_name_for(iface string) string {
	// CANONICAL on both sides. A tap keys on the canonical address (`inproc` and `inproc:CAN`
	// are one hub), so an exact comparison against the configured string failed for a channel
	// written the short way: its Quick Send, Shell, Flash and dump rows were labelled with the
	// expanded interface, and selecting that channel filtered them straight out again.
	want := transport.canonical_iface(iface)
	for c in app.chans {
		if transport.canonical_iface(c.iface) == want {
			return c.name
		}
	}
	return iface
}

// TapBus wraps a bus we EMIT on, so every frame leaving the app is attributed exactly once,
// wherever it was sent from. Stamping at the transport seam rather than at each call site means
// a new emitter cannot forget: simulated ECUs, the ISO-TP diagnostic servers, the tester's own
// sends and anything added later all pass through here.
struct TapBus {
mut:
	// Serialises note+send for ONE interface across every tapped bus on it. Registration order
	// has to be wire order: the matcher claims oldest-first, so if a thread is descheduled
	// between registering and transmitting, another thread's byte-identical frame can go out
	// first and have its echo credited to the wrong row — and then a failed or unechoed send
	// marks the successful row instead. A bus is serial anyway, so this costs nothing real.
	tx_mu     &sync.Mutex
	inner     transport.Bus
	app       &App
	iface     string
	chan_name string // logical channel, '' = derive from the interface
	origin    string
	// The run this tap belongs to, or 0 for a tap that outlives runs (Quick Send, scripts).
	// Checked INSIDE tx_mu, because checking it outside cannot close the window: the caller
	// passes, is descheduled, Start takes the send mutex, advances the generation and resets the
	// trace, and the frame then lands in a measurement that had already begun. tx_mu is the lock
	// Start drains, so a decision made while holding it is a decision Start cannot overtake.
	guard_gen u64
}

fn (mut t TapBus) send(frame transport.CanFrame) ! {
	// What the WIRE will carry, not what the caller asked for: classic CAN takes 8 bytes and the
	// backends truncate silently, so a 12-byte Quick Send would be recorded whole, never match
	// its own 8-byte echo, and show up as a false RX row plus an unconfirmed TX one.
	wire := transport.wire_frame(t.iface, frame)
	t.tx_mu.lock()
	defer {
		t.tx_mu.unlock()
	}
	if t.guard_gen != 0 {
		mut a := unsafe { t.app }
		a.mu.lock()
		stale := !a.running || a.run_gen != t.guard_gen
		a.mu.unlock()
		if stale {
			return error('run ended')
		}
	}
	// BEFORE the send: a monitor thread can see the frame the instant the driver takes it, and a
	// record added afterwards arrives too late to claim its own echo.
	seq, rec_id, epoch := t.app.note_emit(t.iface, t.chan_name, t.origin, wire)
	// `wire`, not `frame`: on a backend that would carry the extra bytes (inproc, udp) sending
	// the original makes the echo disagree with the record in the other direction.
	// BENEATH THE RECORD, and through the shared helper cmd/restbus also uses.
	//
	// A vendor transmit queue fills as a matter of course on a busy replay. Retrying in the
	// CALLER meant re-entering this function, and each attempt noted an emission and retracted
	// it — painting the trace with failed transmissions for frames that went out perfectly well
	// a millisecond later. The record is made once and the waiting happens under it.
	//
	// Still under tx_mu, so the order frames were recorded in is the order they reach the wire,
	// which is the property this lock exists for.
	//
	// KNOWN LIMITATION: note_emit has already timestamped the row, so a frame that waits for
	// room is recorded up to a fifth of a second before it reaches the bus. ORDER is right and
	// the echo still matches; only the absolute time is early, and only while the wire is
	// saturated. Correcting it means splitting note_emit into a reserve that registers the
	// pending echo and a commit that writes the row once the driver has the frame — a change to
	// the hot path that wants its own change, not a corner of this one.
	// The wait ends when the RUN does. t.guard_gen is the run this tap belongs to; without this
	// the worker sat out its whole retry budget after Stop, with its own taps closing underneath.
	gen_now := t.guard_gen
	app_ref := t.app
	transport.send_waiting_for_room(mut t.inner, wire, 200, fn [gen_now, app_ref] () bool {
		if gen_now == 0 {
			return false
		}
		mut a := unsafe { app_ref }
		a.mu.lock()
		over := !a.running || a.run_gen != gen_now
		a.mu.unlock()
		return over
	}) or {
		t.app.retract_emit(seq, t.origin, epoch)
		// exactly the entry this send wrote, if it wrote one — not a search, and not a guess
		// from the backend
		t.app.unrecord(rec_id)
		return err
	}
}

fn (mut t TapBus) recv(timeout_ms int) !transport.CanFrame {
	return t.inner.recv(timeout_ms)
}

// health passes the inner backend's fault ladder through — the tap wraps for attribution,
// not for transport, so the controller state is whatever the wire's driver says.
fn (mut t TapBus) health() transport.BusHealth {
	return t.inner.health()
}

fn (mut t TapBus) close() {
	t.inner.close()
}

// open_tap opens a bus whose sends are attributed to `origin`.
// `chan_name` names the LOGICAL channel emitting, for the case where two channel entries share one
// physical interface: deriving it from the interface always picks the first, so the second
// channel's simulated nodes would show up attributed to its neighbour. '' = derive (the tester
// paths — generators, diagnostics, shell, flash, scripts — are not per-channel).
fn (app &App) open_tap_on(iface string, origin string, chan_name string) !transport.Bus {
	return app.open_tap_on_gen(iface, origin, chan_name, 0)
}

// open_tap_on_gen is open_tap_on for a tap that must not outlive its run: every send through it
// is checked against `gen` while the send mutex is held. Used by replay, whose worker can be
// inside a long catch-up batch when the run it belongs to ends.
fn (app &App) open_tap_on_gen(iface string, origin string, chan_name string, gen u64) !transport.Bus {
	// The bitrate suffix is an OPEN-time detail of the VENDOR backends, not part of a bus's
	// identity: chan_name_for and the pending records both key on the logical name, so a caller
	// that already carries `pcan:…@250000` (the script engine's ChanInfo does) would otherwise
	// label its rows with the physical open string and split them from every other row on the
	// same bus. Only there: nothing else uses `@` as syntax, and `inproc:bench@A` is a bus NAME
	// — stripping it universally sent every emitter to a different hub than the monitor.
	// Identity is the CANONICAL address: `inproc` and `inproc:CAN` are one hub, and keying them
	// separately means a frame reaches the monitor but cannot claim its own record. The physical
	// open still takes the caller's spelling.
	logical := transport.canonical_iface(if transport.vendor_iface(iface) {
		iface.all_before('@')
	} else {
		iface
	})
	// The caller's string AS GIVEN when it already carries a vendor bitrate. Stripping it and
	// re-deriving from the current channels loses the rate whenever those no longer describe it
	// — a script that outlives Stop and a project switch still holds the interface it captured,
	// and a 250k bus would then be opened at the default.
	phys := if iface.contains('@') { iface } else { app.bitrate_iface(iface) }
	inner := transport.open(phys)!
	return &TapBus{
		tx_mu:     app.tx_mutex(logical)
		inner:     inner
		app:       unsafe { app }
		iface:     logical
		chan_name: chan_name
		origin:    origin
		guard_gen: gen
	}
}

fn (app &App) open_tap(iface string, origin string) !transport.Bus {
	return app.open_tap_on(iface, origin, '')
}

// tx_mutex returns the send lock for an interface, creating it on first use. One per interface:
// every tapped bus on the same wire shares it, so note+send stay in order relative to each other
// without coupling unrelated buses.
fn (app &App) tx_mutex(iface string) &sync.Mutex {
	mut a := unsafe { app }
	// KEYED ON THE DESTINATION, not on the spelling. This lock serialises the record-then-send
	// pair in TapBus, so two spellings of one wire taking two different locks lets one thread
	// record A, pause, and the other queue B first — the trace then says A went out before B
	// while the bus carried B, and each frame can claim the other's echo. `vector:1` and
	// `vector:ch1` are one transceiver; canonical_iface does not know that and
	// destination_key does.
	key := transport.destination_key(iface)
	// tx_map_mu, NOT app.mu — see the field comment: a caller may already hold app.mu here.
	a.tx_map_mu.lock()
	defer {
		a.tx_map_mu.unlock()
	}
	if m := a.tx_mutexes[key] {
		return m
	}
	m := &sync.Mutex{}
	m.init()
	a.tx_mutexes[key] = m
	return m
}

// monitors_locked lists the rx_loops actually reading this interface — the sockets an echo could
// arrive at. The SAME predicate that decides which channels get an rx_loop —
// `enabled` alone counts an `off` channel a generator may target, whose sends nothing could ever
// confirm. A `replay` channel DOES get one: it plays onto its own bus and hears its own echo,
// which is how the trace confirms the recording reached the wire rather than merely being queued.
// Caller holds app.mu.
fn (app &App) monitors_locked(iface string) []int {
	mut out := []int{}
	// THE WIRE, like tx_mutex above and like wiretap's own matching — not canonical_iface, which
	// does not know that `vector:1` and `vector:ch1` are one transceiver, and which keeps a
	// bitrate suffix that only one side of this comparison carries. start() gives a wire ONE
	// reader, so a mismatch here does not merely pick the wrong row: it finds NO row, and the
	// emission is noted with an empty `allowed` set. That still lets the echo be claimed, so the
	// duplicate disappears and the bug looks fixed — while expire() can never call the emission
	// missed, and the recording takes the nobody-is-watching path and writes the frame at emit as
	// well as at echo (codex #174 r2).
	want := transport.wire_key(iface)
	for i, c in app.chans {
		if transport.wire_key(c.iface) == want && c.monitorable() && c.running {
			out << i
		}
	}
	return out
}

// tx sends a frame on the default TX bus (send_iface) and records it as a TX trace row.
fn (mut app App) tx(f transport.CanFrame) bool {
	return app.tx_on(app.send_iface, f)
}

// tx_bus_key identifies a tester bus by the CHANNEL that owns it as well as its interface: two
// channels can share one wire, and a tap opened without the name attributes every frame to
// whichever channel happens to be listed first.
fn tx_bus_key(chan_name string, iface string) string {
	// project.compose_key is injective — see its comment for why a plain 'a|b' is not, and
	// modules/project/key_test.v for the property under inputs that contain the separator.
	return project.compose_key(chan_name, iface)
}

// tx_on sends a frame on the bus `iface` (a channel iface) and records it as a TX row on
// that bus. Generators use this to fire on their own target bus rather than a single
// global send bus; `chan_name` is the owning channel, '' where the caller has no particular one.
fn (mut app App) tx_on(iface string, f transport.CanFrame) bool {
	return app.tx_on_chan('', iface, f)
}

fn (mut app App) tx_on_chan(chan_name string, iface string, f transport.CanFrame) bool {
	// The LOOKUP is under app.mu; the send is not. Enabling a channel mid-run inserts into
	// tx_buses while a cyclic generator may be reading it from gen_loop, and a V map is not safe
	// for a concurrent read and write — this used to be safe only because every insertion
	// happened at Start, before any worker existed. The Bus reference is taken and the lock
	// released before sending: b.send takes the interface's send lock and then app.mu inside
	// note_emit, so holding app.mu across it would deadlock.
	app.mu.lock()
	mut b := app.tx_buses[tx_bus_key(chan_name, iface)] or {
		// fall back to the anonymous tap for this wire — a Quick Send or a diagnostic path has
		// no owning channel, and a generator whose channel was renamed mid-run still transmits
		app.tx_buses[tx_bus_key('', iface)] or {
			app.mu.unlock()
			app.notify('TX failed: no open bus for ${iface}')
			return false
		}
	}
	app.mu.unlock()
	// The row, the recording and the pending echo are the tap's job (open_tap), so they happen
	// for every emitter rather than only for the ones that remember to log.
	b.send(f) or {
		app.notify('TX failed: ${err}')
		return false
	}
	// The count is the tap's job (note_emit), like the row and the recording — a generator that
	// bypasses tx_on still transmits, and used to be invisible here.
	return true
}

// available_adapters is the adapter-picker list for THIS platform — only backends that
// actually work here (SocketCAN/vcan are Linux; PCAN/Kvaser are Windows). `current` is always
// included so a project authored on another OS still shows (and can keep) its adapter.
fn available_adapters(current string) []string {
	mut list := $if windows {
		// `vector` belongs here for the same reason pcan and kvaser do. Without it the only
		// route to a Vector channel was Discover, which lists application channels whose
		// hardware is present — so a bench could not be configured with the adapter unplugged,
		// or before it had been assigned in Vector Hardware Manager, which is exactly when
		// somebody sits down to write the project.
		['virtual', 'udp', 'pcan', 'kvaser', 'vector', 'doip']
	} $else {
		['virtual', 'vcan', 'socketcan', 'udp', 'doip']
	}
	if current !in list {
		list << current
	}
	return list
}

// adapter_tip is the tooltip text explaining an adapter (shown via the "(?)" help marker).
fn adapter_tip(a string) string {
	return match a {
		'virtual' { 'In-process software bus (driver-free). The address is a bus NAME you invent (CAN1, CAN2…); buses with the same name are the same wire. Runs anywhere, no drivers.' }
		'vcan' { 'Linux virtual CAN (SocketCAN). The address is a kernel interface like vcan0. Create them with scripts/setup_vcan.sh, then Discover to list them.' }
		'socketcan' { 'Real Linux CAN hardware (SocketCAN). The address is an interface like can0. Bring it up with: ip link set can0 up type can bitrate 500000.' }
		'udp' { 'Cross-platform UDP-multicast software bus. The address is group:port (e.g. 239.0.0.1:5000). Lets separate processes/hosts share a virtual wire.' }
		'pcan' { 'PEAK PCAN hardware (Windows). The address is a channel like PCAN_USBBUS1. Discovery needs the PEAK driver on Windows.' }
		'kvaser' { 'Kvaser hardware (Windows). The address is a channel index (0, 1…). Discovery needs the Kvaser driver on Windows.' }
		'doip' { 'Diagnostics over Ethernet (ISO 13400) — NOT a CAN bus. The address is host:port (default 127.0.0.1:13400); set the tester/ECU logical addresses below.' }
		else { '' }
	}
}

// CanIface is one CAN interface found on the machine (Linux /sys/class/net).
struct CanIface {
	name    string
	is_vcan bool
	desc    string // e.g. "PCAN-USB Pro FD [1-1] · down" (real) or "virtual CAN" (vcan)
}

// read_can_ifaces enumerates the machine's CAN interfaces with a human description: for
// real hardware, the USB product name + bus path + link state (so the two channels of a
// dual PCAN read as "can0 … PCAN-USB Pro FD [1-1]" / "can1 …"). Linux-only (/sys); [] else.
fn read_can_ifaces() []CanIface {
	mut out := []CanIface{}
	names := os.ls('/sys/class/net') or { return out }
	for name in names {
		typ := os.read_file('/sys/class/net/${name}/type') or { continue }
		if typ.trim_space() != '280' { // ARPHRD_CAN
			continue
		}
		is_vcan := name.starts_with('vcan')
		mut desc := 'virtual CAN'
		if !is_vcan {
			base := '/sys/class/net/${name}'
			product := (os.read_file('${base}/device/../product') or { '' }).trim_space()
			state := (os.read_file('${base}/operstate') or { '' }).trim_space()
			busnum := (os.read_file('${base}/device/../busnum') or { '' }).trim_space()
			devpath := (os.read_file('${base}/device/../devpath') or { '' }).trim_space()
			mut parts := [if product != '' { product } else { 'CAN' }]
			if busnum != '' && devpath != '' {
				parts << '[${busnum}-${devpath}]'
			}
			if state != '' {
				parts << '· ${state}'
			}
			desc = parts.join(' ')
		}
		out << CanIface{
			name:    name
			is_vcan: is_vcan
			desc:    desc
		}
	}
	out.sort(a.name < b.name)
	return out
}

// DiscoveredIface is one transport the Discover dialog offers to add as a bus.
struct DiscoveredIface {
	adapter string
	address string
	desc    string
	added   bool // already present in the project
}

// iface_desc renders a short description for a transport-discovered interface (used for the
// vendor/virtual entries that don't come with the rich /sys hardware label).
fn iface_desc(f transport.Iface) string {
	mut d := match f.kind {
		'vcan' {
			'virtual CAN'
		}
		'udp' {
			'software bus'
		}
		'inproc' {
			'in-process simulation'
		}
		'can' {
			if f.name != '' && f.name != f.iface { f.name } else { 'CAN' }
		}
		else {
			f.kind
		}
	}

	if f.bitrate > 0 {
		d += ' · ${f.bitrate}'
	}
	return d
}

// discover_all builds the Discover list, marking entries already in the project. Two sources
// are merged and de-duplicated by (adapter,address):
//   1. Linux /sys CAN interfaces — finds interfaces that are DOWN (which `ip -json`, and thus
//      transport.list_interfaces on Linux, omits) and enriches them with the USB product /
//      bus path / link state. Empty off Linux.
//   2. transport.list_interfaces() — the platform-gated enumerator that adds Windows vendor
//      hardware (PCAN/Kvaser via their DLLs) plus the driver-free software buses (UDP/SIM).
fn (app &App) discover_all() []DiscoveredIface {
	mut out := []DiscoveredIface{}
	mut seen := map[string]bool{}
	for ci in read_can_ifaces() {
		adapter := if ci.is_vcan { 'vcan' } else { 'socketcan' }
		seen[project.compose_iface(adapter, ci.name)] = true
		out << DiscoveredIface{
			adapter: adapter
			address: ci.name
			desc:    ci.desc
			added:   app.iface_added(adapter, ci.name)
		}
	}
	for f in transport.list_interfaces() or { transport.virtual_ifaces() } {
		adapter, address := project.decompose_iface(f.iface)
		key := project.compose_iface(adapter, address)
		if key in seen {
			continue
		}
		seen[key] = true
		out << DiscoveredIface{
			adapter: adapter
			address: address
			desc:    iface_desc(f)
			added:   app.iface_added(adapter, address)
		}
	}
	return out
}

// iface_link_up reports whether a real CAN interface (socketcan/vcan) is administratively
// UP (IFF_UP in /sys/class/net/<if>/flags). Software backends (inproc/udp/doip) have no
// kernel interface and are always usable → true. An unreadable flags file → assume up
// (don't cry wolf on a platform without /sys).
fn iface_link_up(adapter string, address string) bool {
	if adapter != 'socketcan' && adapter != 'vcan' {
		return true
	}
	raw := os.read_file('/sys/class/net/${address}/flags') or { return true }
	mut t := raw.trim_space()
	if t.starts_with('0x') || t.starts_with('0X') {
		t = t[2..]
	}
	mut v := u64(0)
	for c in t {
		d := if c >= `0` && c <= `9` {
			u64(c - `0`)
		} else if c >= `a` && c <= `f` {
			u64(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			u64(c - `A`) + 10
		} else {
			continue
		}
		v = v * 16 + d
	}
	return (v & 0x1) != 0 // IFF_UP
}

// iface_added reports whether the project already has a bus on this adapter+address.
fn (app &App) iface_added(adapter string, address string) bool {
	target := project.compose_iface(adapter, address)
	for c in app.proj.channels {
		if c.iface == target {
			return true
		}
	}
	return false
}

// adapter_hint is the grey placeholder shown next to a bus's address field.
fn adapter_hint(a string) string {
	return match a {
		'virtual' { 'CAN1 — in-process bus name (driver-free sim)' }
		'vcan' { 'vcan0 — Linux virtual CAN' }
		'socketcan' { 'can0 — real Linux CAN hardware' }
		'udp' { '239.0.0.1:5000 — group:port software bus' }
		'pcan' { 'PCAN_USBBUS1 — PEAK channel' }
		'kvaser' { '0 — Kvaser channel index' }
		'vector' { '1 — Vector application channel (see Vector Hardware Manager)' }
		'doip' { '127.0.0.1:13400 — host:port' }
		else { '' }
	}
}
