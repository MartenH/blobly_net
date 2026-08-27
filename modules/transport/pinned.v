module transport

import sync

// The mode a wire's OPEN PORTS have already fixed — the half of "one wire, one mode" that no
// software table can keep.
//
// listen.v holds the policy this process applies to a wire and asks it per SEND, so nothing goes
// stale: a wire that changes its mind takes the handles already open along with it. That is the
// whole answer on every backend whose silence is ours to grant, and only half of it on Vector,
// where `,silent` reaches the TRANSCEIVER. A channel's output mode and bitrate belong to the
// PORTS open on it, and a port that disagrees with them gets one of two answers, both bad:
// refused outright (vector_shim.h, rc -1004/-1005) — the right answer from down there and far
// too late to be a useful one, since by then the operator has ticked a row that ends up with no
// working taps on a wire that goes on acknowledging through the ports that hold it — or, if the
// port that held initialisation access has since closed while siblings stayed open, ALLOWED, and
// the channel is reconfigured under those siblings, which now run against a mode they did not
// ask for and cannot see. Refusing the transition is the answer to both.
//
// So the configuration the open ports installed is recorded HERE, where a front end can ask
// before it opens anything. Issue #165.
//
// WHAT THE ROW MODEL CANNOT SEE, and why this is not a lookup the GUI could do itself. A
// DISABLED row keeps its transmit taps open on purpose. #164 settled that only ENABLED rows
// decide a wire's policy — right for the policy, and the driver has never heard of a row: the
// port is open, so the configuration is held. Between those two facts sits the sequence in #165,
// where an enable the row model considers harmless produces ports the driver refuses.
//
// ONLY WHERE IT PINS. A stale normal tap on SocketCAN, PCAN or a software bus costs nothing —
// those consult the listen-only table per send — so recording their opens would buy a refusal
// nobody needs. mode_pinned_by_ports names the one backend that does.

// PinnedPort is one live port on a wire — reserved before the driver is asked, held until it
// closes — and the configuration it requires the channel to be in.
struct PinnedPort {
	id  u64
	cfg PinnedConfig
}

// PinnedWire is the ports currently holding one wire.
//
// A LIST, not one configuration and a count, and the reason is rollback. A pin is RESERVED
// before `open_raw` runs (see pinned_open), so a reservation whose open then fails has to be
// undone — and with a single record there is nothing to undo TO: restoring a snapshot taken
// before the reservation would clobber whatever an interleaved open established in the meantime,
// and simply decrementing would leave the failed port's configuration standing as the wire's.
// Per-port records make a rollback the removal of one element, which cannot disturb anybody
// else's.
struct PinnedWire {
mut:
	ports []PinnedPort
}

// PinnedConfig is a configuration: what a wire is set to, or what an address asks it to be.
struct PinnedConfig {
	silent  bool
	bitrate int
	// The PROTOCOL is pinned by the open ports exactly as the mode and the rate are, and it is the
	// one of the three a sibling cannot recover from by agreeing later: the interface version a
	// port was opened with decides the event encoding on its queue, so a port that guessed wrong
	// does not merely disagree — it decodes every frame through the wrong struct. Refused with
	// -1011/-1012 down in the shim; predicted here, so the front end asks before it opens.
	fd           bool
	data_bitrate int
}

struct PinnedModes {
mut:
	mu    sync.Mutex
	wires map[string]PinnedWire
	seq   u64 // hands each reservation an identity, so a rollback removes ITS port and no other
}

// pinned_tbl is THE record of open vendor ports for the process, a global for the same reason
// listen_tbl is one: the side that fills it (every `open`, down every call chain there is) and
// the side that reads it (a panel deciding whether to allow a change) have no pointer between
// them.
__global pinned_tbl = &PinnedModes{}

// mode_pinned_by_ports reports a backend whose open ports fix the transceiver configuration for
// the whole wire until the last of them closes.
//
// NOT BEHIND `$if windows`, for the reason vendor_destination_key states about itself: that the
// XL driver holds a channel's configuration is a fact about the driver, not about the machine
// compiling this. Gated on the platform, the rule could only ever be tested where it is false.
// Nothing false registers on Linux regardless — `open_linux.v` sends `vector:1` to SocketCAN,
// which has no such interface, and a failed open never reaches the wrapper.
fn mode_pinned_by_ports(iface string) bool {
	return iface.trim_space().to_lower().starts_with('vector:')
}

// pinned_wire_key names the wire a pinning address reaches, rate and mode both removed.
//
// wire_key_for, NOT listen.v's wire_key, and the difference decides whether this works at all.
// wire_key asks vendor_iface, which is platform-gated on purpose — on Linux `vector:1` really is
// an ordinary SocketCAN name — so it reduces `vector:1@500000,silent` and `vector:1` to two
// different wires on the machine that runs the tests and to one wire on the machine that holds
// the hardware. A table keyed that way would pass its tests and never fire on a bench.
fn pinned_wire_key(iface string) string {
	return wire_key_for(iface.trim_space().all_before(':').to_lower(), iface)
}

// pinned_open_config is the configuration this ADDRESS asks the driver for, or none where the
// backend does not carry one.
//
// Parsed by the backend's own parser rather than by a second reading of `,silent` here.
// parse_vector_spec accepts `,listen_only` and `,listenonly` too, and applies the bitrate
// default and range; a private spelling rule in this file would disagree with the one that
// actually opens the port, which is the class of drift vector_names.v exists to prevent.
fn pinned_open_config(iface string) ?PinnedConfig {
	if !mode_pinned_by_ports(iface) {
		return none
	}
	i := iface.trim_space()
	s := parse_vector_spec(i.all_after_first(':')) or { return none }
	return PinnedConfig{
		silent:       s.silent
		bitrate:      s.bitrate
		fd:           s.fd
		data_bitrate: s.data_bitrate
	}
}

// wire_pinned_config reports the configuration that ports already open on this wire have fixed,
// or none when nothing is open on it or the backend does not pin.
//
// It answers for the WIRE and says nothing about which row opened it — the whole point is that
// the port outlives the row's part in the run.
fn wire_pinned_config(iface string) ?PinnedConfig {
	if !mode_pinned_by_ports(iface) {
		return none
	}
	k := pinned_wire_key(iface)
	pinned_tbl.mu.lock()
	w := pinned_tbl.wires[k] or { PinnedWire{} }
	pinned_tbl.mu.unlock()
	if w.ports.len == 0 {
		return none
	}
	// THE LATEST, not the first, and the difference is not a preference: an open that RETURNED is
	// one whose configuration the channel now has. Either it matched what was already installed,
	// and this changes nothing — or it installed it, which happens more readily than "the first
	// port pins it forever" suggests. Initialisation access belongs to a PORT: when the port
	// holding it closes while siblings stay open, XL releases that access, the shim marks its
	// record stale (vector_shim.h, ct_vec_cfg_unref) and the next port to win access reconfigures
	// the channel outright and re-notes it. Keeping the first answer would describe a
	// configuration no longer installed. What wire_pin_clash does with a wire whose ports
	// DISAGREE is stricter still — see there.
	return w.ports.last().cfg
}

// wire_pin_clash reports how opening THIS ADDRESS would contradict the configuration the ports
// already open on its wire have fixed, and '' when it would not — including when nothing is open
// on the wire and when the backend does not pin at all.
//
// AN ADDRESS, not a row, and the caller must pass the string it is actually about to open. The
// GUI chooses a rate and a mode for a whole WIRE rather than taking them from the row being
// ticked (bitrate_iface: silence wins, and enabled rows decide), so a check against the row's own
// fields would refuse an enable that was going to open at the pinned rate anyway — and wave
// through one that was not.
//
// A SENTENCE rather than the two flags, because a caller cannot phrase it without reading a
// vendor address for itself, and reading vendor addresses is the thing this module exists to do
// once. It is a fragment: the caller says who, and what to do about it.
pub fn wire_pin_clash(iface string) string {
	want := pinned_open_config(iface) or { return '' }
	k := pinned_wire_key(iface)
	pinned_tbl.mu.lock()
	held := pinned_tbl.wires[k] or { PinnedWire{} }.ports.clone()
	pinned_tbl.mu.unlock()
	// EVERY PORT, not just the newest. They normally all agree — the driver is what makes them —
	// but a channel reconfigured under its siblings (see wire_pinned_config) leaves ports on it
	// that do not, and a new port cannot satisfy both. Asking all of them refuses that state
	// instead of picking a half of it to answer from.
	for p in held {
		if want.silent != p.cfg.silent {
			w := if want.silent { 'listen-only' } else { 'normal' }
			h := if p.cfg.silent { 'listen-only' } else { 'normal' }
			return 'is ${w} and ports are still open on ${iface.all_before('@')} in ${h} mode'
		}
		if want.bitrate != p.cfg.bitrate {
			return 'asks ${want.bitrate} and ports are still open on ${iface.all_before('@')} at ${p.cfg.bitrate}'
		}
		// BEFORE THE DATA RATE, because the two say different things: one is "this wire is not
		// running the protocol you asked for", the other "it is, at another speed", and an
		// operator fixes them in different places.
		if want.fd != p.cfg.fd {
			w := if want.fd { 'CAN-FD' } else { 'classic CAN' }
			h := if p.cfg.fd { 'CAN-FD' } else { 'classic CAN' }
			return 'is ${w} and ports are still open on ${iface.all_before('@')} as ${h}'
		}
		if want.fd && want.data_bitrate != p.cfg.data_bitrate {
			return 'asks a ${want.data_bitrate} bit/s data phase and ports are still open on ${iface.all_before('@')} at ${p.cfg.data_bitrate}'
		}
	}
	return ''
}

// pinned_open reserves this address's pin BEFORE the backend opens, then hands back a bus that
// holds it — or, if the open fails, rolls the reservation back as though it never happened.
//
// THE RESERVATION COMES FIRST, and that ordering is the whole point of this function existing
// instead of a wrapper applied to an already-open bus. A vendor open ACTIVATES and CONFIGURES
// the channel before it returns; recording afterwards leaves a window in which the port is live
// on the wire and the table says the wire is free. It is not a theoretical window: rx_loop opens
// its monitor without holding app.mu (and says why — opening a bus takes time), so the GUI
// thread can run the enable guard inside it, read a free wire, and admit the conflicting alias
// this whole change exists to refuse. Codex #166 r1.
//
// The cost is the opposite window, which is the safe one: between the reservation and a FAILED
// open the wire reads as pinned to a configuration nothing installed, so a concurrent check
// refuses for as long as the vendor open takes. A refusal that resolves itself, against a wire
// nobody could have used anyway.
//
// NOT UNDER THE LOCK, unlike shared_open, and for the reason that one gives for the opposite
// choice: it must serialise because a second caller would otherwise join an entry with no bus in
// it. Here every caller gets its own port and its own record, so there is nothing to join —
// holding the mutex across a ~1s vendor open would only stall the front end's guard against
// every unrelated wire.
fn pinned_open(iface string, make fn (string) !Bus) !Bus {
	cfg := pinned_open_config(iface) or { return make(iface)! }
	k := pinned_wire_key(iface)
	pinned_tbl.mu.lock()
	pinned_tbl.seq++
	id := pinned_tbl.seq
	mut w := pinned_tbl.wires[k] or { PinnedWire{} }
	w.ports << PinnedPort{
		id:  id
		cfg: cfg
	}
	pinned_tbl.wires[k] = w
	pinned_tbl.mu.unlock()
	b := make(iface) or {
		pinned_release(k, id)
		return err
	}
	return &PinnedBus{
		inner: b
		key:   k
		id:    id
	}
}

// pinned_release drops one port's hold, by the identity it was given. By id, not by position or
// by configuration: ports come and go from a wire in any order, and two of them on one wire are
// routinely identical.
fn pinned_release(key string, id u64) {
	pinned_tbl.mu.lock()
	mut w := pinned_tbl.wires[key] or {
		pinned_tbl.mu.unlock()
		return
	}
	for i, p in w.ports {
		if p.id == id {
			w.ports.delete(i)
			break
		}
	}
	if w.ports.len == 0 {
		pinned_tbl.wires.delete(key)
	} else {
		pinned_tbl.wires[key] = w
	}
	pinned_tbl.mu.unlock()
}

// PinnedBus is a bus that holds a wire's configuration for as long as it is open. It adds no
// behaviour of its own — the whole of it is the bookkeeping in close().
struct PinnedBus {
	key string
	id  u64
mut:
	inner  Bus
	closed bool
}

fn (mut p PinnedBus) send(frame CanFrame) ! {
	return p.inner.send(frame)
}

fn (mut p PinnedBus) recv(timeout_ms int) !CanFrame {
	return p.inner.recv(timeout_ms)
}

fn (mut p PinnedBus) health() BusHealth {
	return p.inner.health()
}

// close releases THIS port's hold. Idempotent, for the reason SharedHandle.close is: the app
// closes a bus twice on at least one race path, and a second decrement would report a wire as
// free while ports are still open on it — which is the failure this file exists to prevent,
// arrived at from the other side.
fn (mut p PinnedBus) reconcile_silence(want bool) ! {
	p.inner.reconcile_silence(want)!
}

fn (mut p PinnedBus) close() {
	// THE DRIVER FIRST, the record after. Released the other way round there is a window in
	// which the wire reads as free while its XL port is still live, and an open let through in
	// that window is one the driver refuses — the exact outcome #165 is about, produced by the
	// code meant to prevent it. This order errs the safe way instead: for the length of a
	// vendor close the wire reads as still pinned, which costs at worst a refusal a moment
	// early.
	p.inner.close()
	// UNDER THE LOCK, not beside it. `closed` is what makes this idempotent, and the app closes
	// a bus twice on at least one race path; tested outside the mutex, two threads can both read
	// false and release twice — and the second release would take a LATER port's record, since
	// ids are handed out per reservation and this one's is already gone.
	pinned_tbl.mu.lock()
	if p.closed {
		pinned_tbl.mu.unlock()
		return
	}
	p.closed = true
	pinned_tbl.mu.unlock()
	pinned_release(p.key, p.id)
}
