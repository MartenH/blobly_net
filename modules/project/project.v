// project — Blobly Net project / configuration files (`.yml`).
//
// A project is the single source of truth for the bus setup: which channels
// (buses) exist and how each is configured — interface, bitrate/timing, the
// operating mode (off/monitor/replay), associated DBC databases, and (for
// replay) the recording to play. The GUI loads one at startup and Start/Stop
// attaches the enabled channels accordingly.
//
// Pure V (vlib `yaml`), GUI-free and independently testable. For `vcan0` the
// bitrate/timing fields are nominal; for a real `can0` they map to
// `ip link set can0 type can bitrate … sample-point …`.
module project

import transport
import os
import yaml
import doip

// schema_version is the current project-file format version. Bump it when the `.yml`
// schema changes incompatibly. Files carry `version:`; Save writes schema_version,
// and the loader flags a file whose version is NEWER than the app understands
// (is_supported / version_note) so opening a future-format file isn't silent.
pub const schema_version = 2

// Mode is a channel's operating mode within a measurement.
pub enum Mode {
	off     // configured but not attached
	monitor // RX only — observe live traffic (today's default)
	replay  // play a recording onto the bus / into the trace
}

// Timing is advanced manual CAN bit timing (0 = derive from bitrate).
pub struct Timing {
pub:
	brp   int
	tseg1 int
	tseg2 int
	sjw   int = 1
}

// Replay configures a channel in replay mode.
pub struct Replay {
pub:
	source string // .log or .mf4 recording
	// WHICH recorded bus feeds this channel. A multi-bus `.mf4` holds several, and their names
	// are the recording's, not this project's — so nothing can infer the pairing. Either the
	// name the file gives a bus ('CAN1') or the label its frames carry ('mf4:group25'); empty
	// means the recording holds exactly one bus and there is nothing to choose.
	bus string
	// Nodes whose messages are NOT replayed: the ECU under test, so it stays the only
	// transmitter of its own frames instead of arbitrating against a recording of itself.
	// Resolved through the channel's databases by DBC sender.
	exclude []string
	speed   f64 = 1.0
	repeat  bool // yaml key `loop`
}

// GenCfg configures one signal's value generator for a simulated ECU. `typ`
// selects the kind; only the relevant params are used (see modules/sim Gen).
pub struct GenCfg {
pub mut:
	signal    string
	typ       string = 'const' // const | sine | sawtooth | counter | stepmod
	value     f64 // const
	offset    f64 // sine bias
	amplitude f64 // sine amplitude
	freq      f64 // sine angular freq (rad/s·t)
	phase     f64 // sine phase
	min       f64 // sawtooth
	max       f64 // sawtooth
	period    f64 // sawtooth / stepmod period (s)
	start     f64 // counter start
	step      f64 = 1.0 // counter increment
	modulo    f64 // counter wrap
	count     f64 // stepmod step count
	base      f64 // stepmod base
}

// ResponseCfg configures a request→response rule for a simulated ECU.
pub struct ResponseCfg {
pub mut:
	request  u32
	response u32
	byte     int
	add      u8 = 1
}

// NodeCfg is a configured simulated ECU: its name (must match a DBC transmitter),
// per-signal generators, and response rules. With no signals/responses it falls
// back to the built-in defaults for that node.
pub struct NodeCfg {
pub mut:
	name      string
	signals   []GenCfg
	responses []ResponseCfg
	protect   []ProtectCfg
	uds       ?UdsCfg
}

// UdsCfg is a diagnostic server attached to ONE simulated ECU: its own ISO-TP addresses and
// its own content.
//
// Without this there is a single server per channel on 0x7E0/0x7E8 serving built-in data, so
// every simulated ECU answers as the same target and a tester cannot tell them apart — which
// defeats the point of simulating several. Addresses are named from the TESTER's point of
// view, the way a diagnostic database describes them: `rx` is where the ECU listens for
// requests, `tx` is where it answers.
pub struct UdsCfg {
pub mut:
	// Fields whose written value was not a clean number. Kept so validation can name the typo:
	// a stripped character produces a DIFFERENT VALID id, which no range check can catch.
	malformed []string
	// u64 for the same reason DidCfg.id is u32: the value must survive parsing intact so the
	// range check can see it. Narrowed to a CAN id only once it is known to fit.
	rx   u64 // request id  (tester -> ECU)
	tx   u64 // response id (ECU -> tester)
	dids []DidCfg
	dtcs []DtcCfg
	// u32 for the same reason every other id here is wide: 265 narrowed at the cast becomes 9,
	// and the server then runs a session the project never asked for.
	session u32 = 1
}

// DidCfg is one ReadDataByIdentifier entry. The value is given either as `text` (ASCII, the
// common case for VIN and part numbers) or as `bytes` (hex, e.g. "01 00") — never inferred
// from the string's shape, which would make "0100" ambiguous between four characters and two
// bytes.
pub struct DidCfg {
pub mut:
	// u32, not u16: narrowing at parse time made 0x1F190 silently become 0xF190, which then
	// masquerades as — or overwrites — a different configured DID. Kept wide so validation can
	// see the mistake, and narrowed only once it is known to fit.
	id    u32
	text  string
	bytes []u8
}

// value_len is how many bytes this DID will actually carry on the wire.
pub fn (d DidCfg) value_len() int {
	return if d.bytes.len > 0 { d.bytes.len } else { d.text.len }
}

// DtcCfg is one stored fault: a 24-bit code and its status byte.
pub struct DtcCfg {
pub mut:
	// Both wide, for the same reason DidCfg.id is: narrowing at parse time turns a mistake
	// into a different VALID value — status 265 silently becomes 9, and the server then
	// reports bits the project never asked for. Checked before narrowing, never at the cast.
	code   u32
	status u32 = 0x09 // confirmed + testFailed
}

// ProtectCfg — end-to-end protection for one of the node's messages: an alive counter and/or
// a checksum, named by SIGNAL so their placement and width come from the DBC rather than being
// re-stated (and re-broken) here. A real ECU rejects frames whose counter has not advanced or
// whose checksum does not match, so a rest-bus simulation without this can drive a demo bus
// but not the ECU under test.
pub struct ProtectCfg {
pub mut:
	message string // DBC message name
	// Optional CAN id AND frame format, for a channel-level `verify:` entry whose message name
	// is ambiguous — merged databases can carry one name at two ids, or at one id in both
	// formats, and a bench check bound to the wrong one is worse than no check.
	id       ?u32
	extended ?bool
	// Whether the written id / data_id were clean numbers. A stripped character yields a
	// DIFFERENT VALID value, so no range check can catch it — `0x2G2` became `0x22` and bound
	// to whatever lives there, while saving replaced the typo with the sanitized value. A bad
	// data_id is worse still: it mixes four unintended bytes into every checksum, so valid
	// traffic is reported corrupt.
	id_malformed       bool
	data_id_malformed  bool
	extended_malformed bool
	counter            string // signal carrying the alive counter ('' = none)
	crc                string // signal carrying the checksum ('' = none)
	profile            string = 'crc8_j1850' // crc8_j1850 | crc8_autosar | sum8 | xor8
	// Mixed into the checksum only; never occupies payload. An OPTION rather than a u32 with
	// 0 meaning unset: 0 is a valid Data ID. Carrying presence as a separate bool left three
	// places to remember it and the GUI forgot one, showing an explicit zero id as absent.
	data_id ?u32
}

// SenderSig is one signal value applied when building a Sender's frame: the
// signal `name` (must be a signal of the resolved message) set to `value`
// (physical units; encoded onto the payload via the DBC).
pub struct SenderSig {
pub mut:
	name  string
	value f64
}

// Sender is a declarative "interactive generator" (IG-style): a named,
// user-triggerable frame. The frame is built either from `message` (a DBC
// message name → id/dlc, with `signals` encoded onto a zero payload) or from an
// explicit `id` + raw `data`. `key` is an optional single-character hotkey that
// fires it; `trigger` is manual (button only) | key (button + hotkey) | cyclic
// (auto-sent every `cycle_ms` while the measurement runs). GUI-free config; the
// app resolves the message and encodes signals using the loaded DBC at send time.
pub struct Sender {
pub mut:
	name     string
	key      string // single-character hotkey ('' = none)
	message  string // DBC message name (optional)
	id       u32    // explicit CAN id (used when message is empty / unresolved)
	ext      bool   // 29-bit extended id
	data     []u8   // explicit raw payload (optional; overrides the zero/dlc default)
	signals  []SenderSig
	bus      string // target bus to transmit on (a channel iface); '' = the sender's own channel
	trigger  string = 'manual' // manual | key | cyclic
	cycle_ms int // cyclic period (ms); only used when trigger == cyclic
}

// Channel is one bus the tester attaches to.
//
// Schema v2 introduces `adapter` + `address` (the transport backend and its
// backend-specific address) and an optional `network` grouping label; `iface` is
// the derived internal scheme string that `transport.open()` consumes (composed
// from adapter+address). v1 files (`channels:` with `interface:`/`type:`) still
// load — the parser decomposes `interface` back into adapter+address so the editor
// always has them. See compose_iface / decompose_iface.
// all_digits_of is the "a rate that is nearly a number is not a number" rule, as a predicate.
// V's `.int()` takes a numeric prefix, so `250000garbage` reads as 250000 — the mistake this
// repo has now fixed once per caller. Non-empty and every byte a digit.
pub fn is_all_digits(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if !c.is_digit() {
			return false
		}
	}
	return true
}

// strict_rate reads a bits-per-second scalar from a project file, refusing one that is only
// PARTLY a number.
//
// THE SAME RULE AS EVERY OTHER READER OF A RATE, and the reason it is a function is that the rule
// had to be applied three times before it stopped being got wrong: transport.vendor_bitrate for
// the address, the editor buffer, and now the file itself. `2000000oops` reached the Vector
// backend as 2000000 through V's permissive `.int()`, so the Configuration ▸ File tab and the
// headless runner could run a data phase different from the one the project states — and the
// round-2 fix for the GUI validated only the editor buffer, leaving the file it saves to
// unguarded (codex #181 r3).
//
// REFUSES THE PROJECT rather than defaulting. A malformed rate has no safe reading: 0 means "run
// the data phase at the nominal rate", which is a real configuration and not what the file says,
// so silently choosing it puts a bench on a wire at a speed nobody asked for. The message names
// the field and the value, because this is a hand-edited file and the author can fix it.
fn strict_rate(c yaml.Any, key string) !int {
	v := c.value(key).default_to('').string().trim_space()
	if v == '' {
		return 0
	}
	if !is_all_digits(v) {
		return error('${key}: "${v}" is not a rate — digits only, in bits per second')
	}
	return v.int()
}

// default_bitrate is what an unset nominal rate MEANS, in the one place it is decided.
//
// It was written out as a bare 500000 in three places that have to agree — the struct default,
// the conflict check's `want`, and fd_wanted — and iface_with_bitrate had a FOURTH reading in
// which an unset rate meant "compose no address suffix at all". So a CAN-FD row with no explicit
// bitrate opened classic while the conflict check called the same wire CAN-FD at 500 kbit/s: the
// project refusing a mixture on a wire it was itself opening as the other half of that mixture
// (codex #181 r2). One constant, so a future default cannot move in some of them.
pub const default_bitrate = 500000

pub struct Channel {
pub mut:
	name         string = 'CAN'
	network      string // v2: optional grouping label (buses of one logical network)
	adapter      string = 'vcan'  // v2: virtual | vcan | socketcan | udp | pcan | kvaser | vector | doip
	address      string = 'vcan0' // v2: adapter-specific (CAN1 / vcan0 / can0 / grp:port / host:port)
	typ          string = 'can'   // yaml `type`/`protocol`: can | canfd | doip
	iface        string = 'vcan0' // derived scheme string (composed from adapter+address)
	bitrate      int    = default_bitrate
	fd           bool
	data_bitrate int
	sample_point f64
	timing       Timing
	mode         Mode = .monitor
	listen_only  bool
	enabled      bool = true
	databases    []string
	manifest     string // telemetry handler manifest (CSV) — resolves handler_id -> FB/handler/core
	// Protection to VERIFY on received frames. Independent of `simulation:` on purpose: in a
	// rest-bus setup the ECU under test is the one node NOT simulated, so its protected messages
	// can never be described by a simulated node's `protect:` — and it is precisely that ECU's
	// counter and checksum a bench needs checked.
	verify   []ProtectCfg
	simulate []string  // shorthand: ECU node names to simulate with default behaviour
	nodes    []NodeCfg // fully-configured simulated ECUs (signals + responses)
	senders  []Sender  // interactive generators: triggerable custom frames
	replay   ?Replay
	// DoIP (type: doip) — a diagnostics-over-Ethernet endpoint, NOT a CAN bus.
	// `iface` carries `doip:<host>[:<port>]`; bitrate/timing are meaningless here.
	// The logical addresses identify the tester (source) and ECU (target) per
	// ISO 13400; they replace the CAN diag pair (0x7E0/0x7E8).
	tester_addr u16 = 0x0E80 // our (tester) logical address
	ecu_addr    u16 = 0x1000 // the ECU's logical address
	// Simulated-entity identity (only used when this DoIP channel hosts a node):
	// the VIN + entity-id reported in vehicle announcements / discovery, so a
	// network of simulated entities is distinguishable. Empty = module defaults.
	vin string
	eid []u8
	// Power-on announcement, per ECU. Defaults are ISO 13400's (three, 500ms apart);
	// `announce_count: 0` is a silent ECU — a legitimate thing to simulate, and a fault worth
	// injecting deliberately at a tester that relies on discovery.
	announce_count    int = doip.announce_num_default
	announce_interval int = doip.announce_interval_default
	announce_to       string // '' = derive from the entity's own address
}

// is_doip reports whether this channel is a DoIP (diagnostics-over-Ethernet)
// endpoint rather than a CAN bus. Recognised via `type: doip` or an interface of
// `doip` (bare shorthand) / `doip:<host>[:<port>]`.
pub fn (ch Channel) is_doip() bool {
	t := ch.iface.trim_space()
	return ch.typ == 'doip' || t == 'doip' || t.starts_with('doip:')
}

// doip_endpoint parses `iface` ("doip:host:port" / "doip:host" / "doip") into a
// host + port, defaulting to 127.0.0.1:13400. Only meaningful when is_doip().
pub fn (ch Channel) doip_endpoint() (string, int) {
	// Only an explicit `doip[:host[:port]]` interface carries an endpoint. A
	// `type: doip` channel that omits `interface` inherits the CAN default
	// (`vcan0`), which is NOT a host — fall back to localhost rather than dialing
	// "vcan0:13400".
	trimmed := ch.iface.trim_space()
	if !trimmed.starts_with('doip') {
		return '127.0.0.1', 13400
	}
	rest := if trimmed.starts_with('doip:') { trimmed['doip:'.len..] } else { '' }
	if rest == '' {
		return '127.0.0.1', 13400
	}
	// Bracketed IPv6: `[host]` or `[host]:port`.
	if rest.starts_with('[') {
		if end := rest.index(']') {
			host := rest[1..end]
			after := rest[end + 1..]
			if after == '' {
				return host, 13400 // bare [host]
			}
			if after.starts_with(':') {
				if p := valid_port(after[1..]) {
					return host, p
				}
			}
			// malformed suffix ([host]:badport or [host]junk) → keep the whole
			// string as the host so it fails loudly on connect, matching the
			// non-bracketed path, rather than silently defaulting the port.
			return rest, 13400
		}
		return rest, 13400 // no closing bracket; let the caller's dial/listen surface it
	}
	// Split host:port only on a SINGLE colon whose suffix is a valid port. An
	// unbracketed IPv6 literal (multiple colons) or a typo'd port is kept whole as
	// the host with the default port, so a bad value surfaces as a connect/listen
	// error rather than silently mangling the address or jumping to 13400.
	if rest.count(':') == 1 {
		i := rest.index(':') or { -1 }
		host := rest[..i]
		if p := valid_port(rest[i + 1..]) {
			return if host == '' { '127.0.0.1' } else { host }, p
		}
	}
	return rest, 13400
}

// valid_port parses a TCP/UDP port: all-digits, 1..65535. Returns none otherwise
// (so a non-numeric or out-of-range suffix isn't mistaken for a port).
fn valid_port(s string) ?int {
	t := s.trim_space()
	if t == '' {
		return none
	}
	for c in t {
		if c < `0` || c > `9` {
			return none
		}
	}
	p := t.int()
	if p < 1 || p > 65535 {
		return none
	}
	return p
}

// all_nodes merges the rich `nodes:` configs with the `simulate:` shorthand
// (names not already configured become default-behaviour nodes).
pub fn (ch Channel) all_nodes() []NodeCfg {
	mut out := ch.nodes.clone()
	mut have := map[string]bool{}
	for n in ch.nodes {
		have[n.name] = true
	}
	for name in ch.simulate {
		if name !in have {
			out << NodeCfg{
				name: name
			}
		}
	}
	return out
}

// Project is a parsed project file.
pub struct Project {
pub mut:
	name     string = 'untitled'
	version  int    = 1
	channels []Channel
}

// iface_with_bitrate is the interface string a transport should actually be opened with.
//
// Parsing splits the configured bitrate out of the interface, and the vendor backends default
// to 500 kbit/s when it is absent — so opening the bare `iface` silently ran a PCAN or Kvaser
// channel at the wrong rate and produced no traffic against a bus at any other. The GUI
// re-appended it and the headless runner did not, which is why the same project worked
// interactively and stayed silent under a script.
// nominal_bitrate is the arbitration rate this row will actually be OPENED with — the configured
// one, or the transport default when it is unset.
//
// ONE READING OF AN UNSET RATE, which the address composer below already insisted on and which
// origination_framing then read a second way: comparing a 500000 data phase against a RAW zero made
// the phases look different, so an equal-phase channel originated frames demanding a bit-rate
// switch the wire has no faster phase for (codex #202 r2). Both callers ask this now.
pub fn (c Channel) nominal_bitrate() int {
	return if c.bitrate > 0 { c.bitrate } else { default_bitrate }
}

pub fn (c Channel) iface_with_bitrate() string {
	// The MODE is split off first and put back last, because the two suffixes are not
	// interchangeable: `vector:1,silent@500000` puts the rate inside the mode, and the parser
	// reads the mode as "silent@500000" and refuses the whole channel. Appending blindly to a
	// stored interface that already carried `,silent` did exactly that.
	mut base := c.iface
	mut mode := ''
	if c.adapter == 'vector' && base.contains(',') {
		mode = ',' + base.all_after_last(',')
		base = base.all_before_last(',')
	}
	// THE SAME DEFAULT fd_wanted USES, and it has to be the same one. This block used to be
	// skipped entirely when `bitrate` was 0, so a row with `fd: true` and no nominal rate composed
	// a bare address and opened CLASSIC — while fd_wanted, reading that same 0 as the transport's
	// 500000 default, reported the wire as CAN-FD to every conflict check. The project refused
	// mixtures on a wire it was simultaneously opening as classic. One reading of an unset rate,
	// here, where the address is built (codex #181 r2).
	nominal := c.nominal_bitrate()
	if transport.adapter_configures_bitrate(c.adapter)
		&& (c.bitrate > 0 || (transport.adapter_configures_data_phase(c.adapter) && c.fd)) {
		base = '${base}@${nominal}'
		// THE DATA PHASE TRAVELS WITH THE RATE, on the backends that configure one. `fd` and
		// `data_bitrate` sat in the schema and in the editor and reached no transport at all: the
		// address is everything `open` is given, so a `canfd` Vector row opened CLASSIC and then
		// refused every FD frame at send() — the project saying one thing and the wire doing
		// another, which is the failure this whole function exists to stop.
		//
		// DEFAULTED TO THE ARBITRATION RATE rather than dropped when `data_bitrate` is unset. FD
		// at one rate is a real configuration (64-byte payloads, no bit-rate switch), and it is
		// the honest reading of "this channel is CAN-FD" with nothing said about its data phase.
		// Dropping the flag instead would silently downgrade the row to classic.
		if transport.adapter_configures_data_phase(c.adapter) && c.fd {
			dbr := if c.data_bitrate > 0 { c.data_bitrate } else { nominal }
			base = '${base}/${dbr}'
		}
	}
	// LISTEN-ONLY REACHES THE TRANSCEIVER, on the one backend that can do it. Everywhere else
	// `listen_only` stops the application transmitting and nothing more, so the adapter still
	// acknowledges every frame it sees — which is not what the flag says, and on a live vehicle
	// at the wrong bitrate it is the difference between hearing nothing and emitting error
	// frames. The XL backend takes `,silent`, so a project that asks for listen-only gets it.
	if c.adapter == 'vector' && c.listen_only {
		// THE FLAG WINS over a mode embedded in the address. The address is free text in the
		// editor, so `1,normal` with `listen_only: true` is a configuration that contradicts
		// itself — and it used to resolve toward the transceiver acknowledging, with the
		// application still believing the channel was listening quietly. Of the two readings,
		// only one can disturb a live bus.
		mode = ',silent'
	}
	return base + mode
}

// apply_listen_only publishes which wires refuse to transmit, from the rows AS THEY STAND.
//
// Takes rows rather than a Project for the reason destination_conflicts does, and the GUI's
// comment there says it best: one policy, and the front ends must not each keep their own
// reading of it. The GUI passes its RUNTIME channel set -- a bus enabled or disabled from the
// Buses panel mid-run never touches the file, so a version reading p.channels would publish a
// wire list the run had already moved past. The headless runner passes the file's.
//
// Rebuilt wholesale and swapped in one locked step. A channel unticked, renamed, retargeted or
// removed must not leave a wire silenced behind it.
pub fn apply_listen_only(chs []Channel) {
	mut quiet := []string{}
	for c in chs {
		// ENABLED ROWS DECIDE, the rule bitrate_iface already follows. A row switched off states
		// nothing about the wire -- and destination_conflicts skips disabled rows too, so a
		// disabled listen-only row silencing an enabled sibling would be a contradiction that
		// nothing in the project could even warn about.
		//
		// CAN ONLY, which is what the checkbox is offered for. A `doip:` row addresses a TCP
		// endpoint, not a wire that can be held quiet, and its editor never draws the tick — so
		// a flag left behind by an adapter change would silence an address no CAN bus opens and
		// could not be cleared from the UI that set it.
		if !c.enabled || !c.listen_only || c.is_doip() {
			continue
		}
		quiet << c.iface_with_bitrate()
	}
	// ONE PUBLISH, silence and format together — see transport.WirePolicy. Two swaps were externally
	// observable as two policy versions: a bus a script still holds could send between them, with
	// the new silence state and the PREVIOUS project's format, which is exactly the stale policy the
	// per-send lookup exists to prevent (codex #202 r2).
	//
	// The name stays `apply_listen_only` because every caller means "publish this project's wire
	// policy" and always did; what it publishes has grown.
	transport.replace_wire_policy(quiet, wire_framings(chs))
}

// apply_framing publishes what format each wire carries, so frames this app ORIGINATES on it are
// built the way the project declared (#185).
//
// BESIDE apply_listen_only AND CALLED WITH IT, because they are the same kind of statement — a
// policy on a wire, published where a project is APPLIED and consulted per send — and because a
// caller that remembered one and forgot the other would leave a CAN-FD channel silently building
// classic frames, which is the state this fixes.
//
// ENABLED CAN ROWS ONLY, exactly the rule above: a row switched off states nothing about the wire,
// and a `doip:` row addresses a TCP endpoint rather than a wire that carries a CAN format at all.
pub fn wire_framings(chs []Channel) map[string]transport.Framing {
	mut out := map[string]transport.Framing{}
	mut disputed := map[string]bool{}
	for c in chs {
		if !c.enabled || c.is_doip() {
			continue
		}
		k := transport.wire_key(c.iface_with_bitrate())
		fr := c.origination_framing()
		// AN ADAPTER THAT REFUSES FD MUST NOT BE DECLARED FD. No CAN adapter is one since #217, so
		// this guards whatever comes next rather than a backend that exists today. It rejects rather than
		// truncating it (Kvaser did too until #200), so declaring this wire FD turns the row's
		// traffic into nothing at all — while fd_capability_warnings promises the classic half of
		// such a run is real. Asked through can_carry_fd rather than by naming adapters here, so
		// this follows the backend rather than restating it.
		// The warning says the row cannot do what it asked; it must not also take away what it
		// could still do (codex #202 r2).
		if fr.fd && !c.can_carry_fd() {
			continue
		}
		// ROWS ON ONE WIRE MUST AGREE. destination_conflicts refuses a canfd/can mixture only for
		// VECTOR, because only Vector configures a data phase — so on any other adapter two enabled
		// rows may legitimately name one wire and disagree about the format. This table is per
		// WIRE, so whichever was listed first would decide for both, and the classic row's frames
		// would go out FD. Neither row overrules the other: a disagreement leaves the wire
		// undeclared, which is the format every emitter builds anyway.
		//
		// AND WHAT THAT COSTS, said plainly: the FD row on such a wire goes on originating CLASSIC
		// frames, so a 64-byte generator or simulated response is truncated on SocketCAN. That is
		// not a regression — before this change every emitter built classic on every wire — but it
		// is the one configuration this feature does not reach, and it cannot be reached from here:
		// the table is keyed by WIRE and the disagreement is between ROWS. Two formats on one wire
		// is ordinary CAN-FD traffic and wants a per-frame answer, which is #203.
		if existing := out[k] {
			if existing.fd != fr.fd || existing.brs != fr.brs {
				disputed[k] = true
			}
			continue
		}
		out[k] = transport.Framing{
			fd:  fr.fd
			brs: fr.brs
		}
	}
	for k, _ in disputed {
		out.delete(k)
	}
	// ONLY THE FD DECLARATIONS SURVIVE. Classic entries were carried this far so a second row on the
	// same wire could be compared against them — that comparison is what `disputed` is — but classic
	// is the absence of a declaration rather than a declaration of absence, and returning both would
	// hand the caller two ways to spell one state.
	mut classic := []string{}
	for k, fr in out {
		if !fr.fd {
			classic << k
		}
	}
	for k in classic {
		out.delete(k)
	}
	return out
}

// resolve_asset makes a project-relative path (a DBC, a recording) absolute against the
// project file's own directory.
//
// `dir` is the directory holding the project. A relative path is resolved against it when that
// resolves to something real, and returned unchanged otherwise so a repo-root-relative path
// still works. Without this the headless runner opened `databases:` entries as written, after
// runtests.sh had changed to the repository root — so a project kept anywhere else loaded an
// EMPTY database and the simulation emitted nothing, silently.
pub fn resolve_asset(dir string, path string) string {
	if path == '' || os.is_abs_path(path) {
		return path
	}
	rel := os.join_path(dir, path)
	return if os.exists(rel) { rel } else { path }
}

// is_supported reports whether this app understands the file's format version
// (i.e. it isn't newer than schema_version).
pub fn (p Project) is_supported() bool {
	return p.version <= schema_version
}

// version_note returns a human warning if the file came from a newer app, else ''.
pub fn (p Project) version_note() string {
	if p.version > schema_version {
		return 'file format v${p.version} is newer than this app (v${schema_version}) — some settings may be ignored'
	}
	return ''
}

// parse decodes a project `.yml` document.
pub fn parse(text string) !Project {
	doc := yaml.parse_text(text)!
	mut p := Project{}
	pj := doc.value('project')
	p.name = pj.value('name').default_to('untitled').string()
	p.version = pj.value('version').default_to(i64(schema_version)).int()
	// v2 uses `buses:`; v1 used `channels:`. Accept either (buses wins if both present).
	chs := doc.value_opt('buses') or { doc.value_opt('channels') or { yaml.Any(yaml.Null{}) } }
	if chs !is yaml.Null {
		for c in chs.array() {
			if c is yaml.Null {
				continue
			}
			p.channels << parse_channel(c)!
		}
	}
	return p
}

// load reads and parses a project file.
pub fn load(path string) !Project {
	return parse(os.read_file(path)!)
}

// default_project is the built-in fallback when no project file is available:
// a single vcan0 monitor channel decoding dbc/blobly_net.dbc.
pub fn default_project() Project {
	return Project{
		name:     'default'
		channels: [
			Channel{
				name:      'CAN1'
				iface:     'vcan0'
				databases: ['dbc/blobly_net.dbc']
			},
		]
	}
}

fn parse_channel(c yaml.Any) !Channel {
	mut ch := Channel{
		name:         c.value('name').default_to('CAN').string()
		network:      c.value('network').default_to('').string()
		bitrate:      c.value('bitrate').default_to(i64(default_bitrate)).int()
		fd:           c.value('fd').default_to(false).bool()
		data_bitrate: strict_rate(c, 'data_bitrate')!
		sample_point: c.value('sample_point').default_to(f64(0)).f64()
		mode:         mode_from(c.value('mode').default_to('monitor').string())
		listen_only:  c.value('listen_only').default_to(false).bool()
		enabled:      c.value('enabled').default_to(true).bool()
	}
	// protocol/type: v2 `protocol:` (can|canfd), falling back to v1 `type:` (can|canfd|doip).
	mut proto := c.value('protocol').default_to('').string()
	if proto == '' {
		proto = c.value('type').default_to('can').string()
	}
	// adapter/address: v2 `adapter:`+`address:` compose the iface; v1 `interface:` is
	// decomposed back into adapter+address so the editor always has both.
	if av := c.value_opt('adapter') {
		ch.adapter = av.string()
		ch.address = c.value('address').default_to('').string()
		// A mode written into a v2 ADDRESS is lifted into the flag, exactly as the v1 interface
		// spelling is. Left in the address it becomes a second source for one decision: the port
		// opens silently while the model still calls the channel transmit-capable, so the GUI
		// offers replay, generators and manual sends that VectorBus.send then refuses one frame
		// at a time. listen_only is the single place this is recorded.
		if ch.adapter == 'vector' {
			addr, silent, _ := split_vector_mode(ch.address)
			ch.address = addr
			if silent {
				ch.listen_only = true
			}
		}
		ch.iface = compose_iface(ch.adapter, ch.address)
	} else if iv := c.value_opt('interface') {
		raw := iv.string()
		ch.adapter, ch.address = decompose_iface(raw)
		// A legacy vendor iface embeds the bitrate (`pcan:CH@500000`): lift it into the bitrate
		// field (decompose stripped it from the address) and recompose a clean iface.
		// A legacy Vector iface may carry a mode with or WITHOUT a rate (`vector:1,silent` is
		// as valid as `vector:1@250000,silent`), so the mode is migrated on its own terms
		// rather than as a side effect of finding an `@`. Hanging it off the bitrate branch
		// left `vector:1,silent` opening silently at the hardware while the model believed the
		// channel could transmit — the editor offering sends that VectorBus.send then refuses.
		if ch.adapter == 'vector' && raw.contains(',') {
			// THE SHARED SPLITTER, which also refuses a stacked `1,silent,normal`. This branch
			// had its own copy that read only the final suffix, so that spelling left `,silent`
			// in the address while the flag said transmit-capable — the two halves of one
			// decision disagreeing, in the one path that still had its own rule.
			addr, silent, ok := split_vector_mode(ch.address)
			if ok {
				ch.address = addr
				// ONLY SETS. A v1 file carrying both `interface: vector:1,normal` and
				// `listen_only: true` states the safety flag explicitly, and clearing it from a
				// suffix would open the transceiver on a bench that asked for quiet —
				// iface_with_bitrate already makes the flag win over an embedded mode, and the
				// two must not disagree. The editor is where `,normal` can clear it, because
				// there somebody is choosing rather than a file being migrated.
				if silent {
					ch.listen_only = true
				}
			}
		}

		if transport.adapter_configures_bitrate(ch.adapter) && raw.contains('@') {
			// LAST `@`, then the mode: `vector:1@250000,silent` puts the suffix after the rate,
			// so all_after_last('@') is "250000,silent" and .int() would read 250000 only by
			// luck of parsing. Cut the mode off first and the number is the number.
			// MORE THAN ONE `@` is a contradiction, not a preference for the last one.
			// Taking all_after_last and recomposing a clean interface silently discarded the
			// first rate, so `vector:1@250000@500000` reached the driver as a tidy 500000 and
			// the strict parser downstream — the one this preservation exists to reach — never
			// saw the problem at all.
			// PRESERVED, then parsing CARRIES ON. Returning here skipped every field below —
			// databases, simulated nodes, senders, verification rules, timing, replay — so
			// opening such a project and saving it wrote those away as defaults. Preserving a
			// malformed rate must not cost the rest of the channel.
			mut two_rates := false
			if raw.count('@') > 1 {
				ch.address = raw.all_after('${ch.adapter}:')
				ch.iface = raw
				two_rates = true
			}
			mut tail := if two_rates { '' } else { raw.all_after_last('@') }
			if ch.adapter == 'vector' && tail.contains(',') {
				tail = tail.all_before_last(',')
			}
			// EVERY character, not merely a leading digit: V's `.int()` takes the numeric
			// prefix, so `250000garbage` parsed as 250000, took the success path, and the
			// recomposition dropped the garbage before the transport parser could object. A
			// rate that is nearly a number is not a number.
			// A CAN-FD RATE HAS TWO PHASES, and a v1 `interface:` may carry both — the address
			// form this release documents. Lifted here into `bitrate` + `data_bitrate` + `fd`,
			// because everything below reads those fields and `iface_with_bitrate` recomposes the
			// address from them. Left to the digits-only test, `500000/2000000` was "not a
			// number", so the whole spec was preserved verbatim AND another `@500000` was appended
			// to it — producing `vector:1@500000/2000000@500000`, which the strict parser then
			// refused for having two rates. A legacy project could not use the advertised FD form
			// at all (codex #181 r2).
			mut migrated_fd := false
			if transport.adapter_configures_data_phase(ch.adapter) && !two_rates
				&& tail.count('/') == 1 {
				fd_arb, fd_dat := tail.all_before('/'), tail.all_after('/')
				if is_all_digits(fd_arb) && is_all_digits(fd_dat) {
					arb, dat := fd_arb.int(), fd_dat.int()
					// SANITY ONLY, not the full range check: parse_vector_spec owns the ranges
					// and must stay the thing that refuses a bad one. What matters here is not to
					// migrate a pair that would compose into something worse than it started as —
					// anything this leaves alone falls through to the verbatim branch below and
					// is refused downstream with its evidence intact.
					if arb > 0 && dat > 0 {
						ch.bitrate = arb
						ch.fd = true
						ch.data_bitrate = dat
						ch.iface = compose_iface(ch.adapter, ch.address)
						migrated_fd = true
					}
				}
			}
			mut all_digits := tail.len > 0
			for ch_b in tail {
				if !ch_b.is_digit() {
					all_digits = false
					break
				}
			}
			br := if all_digits && !two_rates { tail.int() } else { 0 }
			if migrated_fd {
				// Already lifted into bitrate + data_bitrate + fd above; the verbatim branch
				// below would otherwise "preserve" a spec that is no longer malformed and undo
				// the migration by putting the two-phase rate back into the address.
			} else if br > 0 {
				ch.bitrate = br
				ch.iface = compose_iface(ch.adapter, ch.address)
			} else {
				// KEPT VERBATIM, for the same reason an unrecognised mode is. `vector:1@oops`
				// reads as 0, which is not a rate anybody asked for — and recomposing a clean
				// interface here would drop the evidence and open at the 500 kbit/s default,
				// putting an adapter on a live bus at a rate the project never named. Left as
				// written, the transport parser refuses it and says so.
				// IN THE ADDRESS, not only in the iface. decompose_iface has already cut
				// the rate off the address, so the next commit_cfg or save recomposes a
				// clean `vector:1` from adapter + address and the evidence is gone — the
				// bus then opens at the 500 kbit/s default this branch exists to prevent.
				// Keeping it where recomposition looks makes the refusal survive a save.
				// THIS ADAPTER'S prefix, not Vector's. The branch covers pcan and kvaser too
				// now, and cutting a hardcoded `vector:` off `pcan:PCAN_USBBUS1@oops` left the
				// prefix in the address — which recomposition then prefixed again, writing
				// `pcan:pcan:…` into the project. Preserving a rejected spec must not corrupt
				// the file it is preserved in.
				if !two_rates {
					ch.address = raw.all_after('${ch.adapter}:')
					ch.iface = raw
				}
			}
		} else if ch.adapter == 'vector' && raw.contains(',') {
			ch.iface = compose_iface(ch.adapter, ch.address)
		} else {
			ch.iface = raw
		}
	} else {
		ch.adapter = 'vcan'
		ch.address = 'vcan0'
		ch.iface = 'vcan0'
	}
	// coherence: a doip adapter (or v1 `type: doip`) is a DoIP endpoint, not a CAN bus.
	if ch.adapter == 'doip' || proto == 'doip' {
		ch.typ = 'doip'
		if ch.adapter != 'doip' {
			// v1 `type: doip` — the interface may already carry `doip:<endpoint>`.
			if ch.iface.starts_with('doip') {
				ch.adapter, ch.address = decompose_iface(ch.iface)
			} else {
				ch.adapter = 'doip'
				ch.address = ''
				ch.iface = 'doip'
			}
		}
	} else {
		ch.typ = proto
		if proto == 'canfd' {
			ch.fd = true
		}
		// AND THE OTHER DIRECTION, for a v1 file that expresses FD only in its ADDRESS. The
		// migration above lifts `interface: vector:1@500000/2000000` into `fd` + `data_bitrate`,
		// but `protocol:`/`type:` is absent from such a file and defaults to `can` — so `typ` was
		// set to 'can' on a channel that opens as CAN-FD. The model then contradicted itself:
		// saving wrote `protocol: can` beside an FD data rate, and the editor lit the CAN toggle
		// on an FD channel. `fd` and `typ` are two spellings of one fact and must not disagree
		// whichever of them the file happened to carry (codex #182 r1).
		if ch.fd && ch.typ == 'can' {
			ch.typ = 'canfd'
		}
	}
	// CHECKED parse. yaml's i64() coerces a malformed scalar to 0, so `announce_count: three`
	// would have turned the ECU deliberately silent, and a bad interval would have fired the
	// whole sequence as a burst — a typo quietly changing behaviour instead of failing.
	if v := c.value_opt('announce_count') {
		ch.announce_count = int(checked_int(v.str(), 'announce_count', 0, 100)!)
	}
	if v := c.value_opt('announce_interval_ms') {
		ch.announce_interval = int(checked_int(v.str(), 'announce_interval_ms', 0, 60000)!)
	}
	ch.announce_to = c.value('announce_to').default_to('').string()
	if v := c.value_opt('tester_address') {
		ch.tester_addr = parse_addr16(v.str()) or { return error('tester_address: ${err.msg()}') }
	}
	if v := c.value_opt('ecu_address') {
		ch.ecu_addr = parse_addr16(v.str()) or { return error('ecu_address: ${err.msg()}') }
	}
	ch.vin = c.value('vin').default_to('').string()
	if ch.vin != '' && ch.vin.len != 17 {
		return error('vin must be exactly 17 characters, got ${ch.vin.len} ("${ch.vin}")')
	}
	if e := c.value_opt('eid') {
		ch.eid = parse_eid(e.str()) or { return error('eid: ${err.msg()}') }
	}
	if dbs := c.value_opt('databases') {
		ch.databases = dbs.array().as_strings()
	}
	if mf := c.value_opt('manifest') {
		ch.manifest = mf.string()
	}
	if sim := c.value_opt('simulate') {
		ch.simulate = sim.array().as_strings()
	}
	if vs := c.value_opt('verify') {
		ch.verify = parse_protect_list(vs)
	}
	// Simulated ECUs. `simulation:` is the preferred key (separates the simulation
	// workload from the bus config visually); `nodes:` is the legacy alias. Both
	// append, so either — or both — work.
	if ns := c.value_opt('simulation') {
		for n in ns.array() {
			ch.nodes << parse_node(n)
		}
	}
	if ns := c.value_opt('nodes') {
		for n in ns.array() {
			ch.nodes << parse_node(n)
		}
	}
	if ss := c.value_opt('senders') {
		for s in ss.array() {
			ch.senders << parse_sender(s)
		}
	}
	if t := c.value_opt('timing') {
		ch.timing = Timing{
			brp:   t.value('brp').int()
			tseg1: t.value('tseg1').int()
			tseg2: t.value('tseg2').int()
			sjw:   t.value('sjw').default_to(i64(1)).int()
		}
	}
	if r := c.value_opt('replay') {
		// value_opt for the two optional keys, like `databases`/`simulate` above: `value()` on a
		// missing key yields a null node, and `.array()` on that produced a one-element list
		// containing the string "null" — an exclusion naming a node no database declares, which
		// the replay worker then correctly refused. An absent key must mean an empty list.
		mut rp := Replay{
			source: r.value('source').string()
			speed:  r.value('speed').default_to(f64(1)).f64()
			repeat: r.value('loop').default_to(false).bool()
		}
		if b := r.value_opt('bus') {
			rp = Replay{
				...rp
				bus: b.string()
			}
		}
		if ex := r.value_opt('exclude') {
			rp = Replay{
				...rp
				exclude: ex.array().as_strings()
			}
		}
		ch.replay = rp
	}
	return ch
}

// parse_node parses one simulated-ECU entry: name + signals[] + responses[].
// parse_protect_list parses a list of protection entries — shared by a node's `protect:` (what
// the simulation STAMPS) and a channel's `verify:` (what it CHECKS on receive), because the two
// describe the same thing from opposite ends of the wire.
fn parse_protect_list(ps yaml.Any) []ProtectCfg {
	mut out := []ProtectCfg{}
	for p in ps.array() {
		// presence, not value: `data_id: 0` is a legitimate id whose four zero bytes must still
		// reach the checksum, so it cannot be distinguished from absent by testing 0
		mut id := ?u32(none)
		mut idbad := false
		if v := p.value_opt('data_id') {
			raw := v.i64()
			idbad = raw < 0 || raw > i64(0xFFFFFFFF) || !hex_id_is_clean(v.str())
			id = clamp_i64_u32(raw) // present, even when 0 — that is a real id
		}
		mut mid := ?u32(none)
		mut mbad := false
		if v := p.value_opt('id') {
			mid = clamp_u32(parse_id_wide(v.str()))
			mbad = !hex_id_is_clean(v.str())
		}
		mut mext := ?bool(none)
		mut extbad := false
		if v := p.value_opt('extended') {
			// `.bool()` coerces anything it does not understand to FALSE, so a typo silently
			// became a standard-frame selector — and where a same-named standard message
			// exists, verification quietly checked the wrong frame while saving replaced the
			// typo with `extended: false`.
			t := v.str().trim_space().to_lower()
			if t in ['true', 'yes', '1'] {
				mext = true
			} else if t in ['false', 'no', '0'] {
				mext = false
			} else {
				extbad = true
			}
		}
		out << ProtectCfg{
			message:            p.value('message').default_to('').string()
			id:                 mid
			extended:           mext
			extended_malformed: extbad
			id_malformed:       mbad
			counter:            p.value('counter').default_to('').string()
			crc:                p.value('crc').default_to('').string()
			profile:            p.value('profile').default_to('crc8_j1850').string()
			data_id:            id
			data_id_malformed:  idbad
		}
	}
	return out
}

fn parse_node(n yaml.Any) NodeCfg {
	mut nm := n.value('name').default_to('').string()
	if nm == '' {
		nm = n.value('node').default_to('').string() // accept `node:` too
	}
	mut node := NodeCfg{
		name: nm
	}
	if sigs := n.value_opt('signals') {
		for s in sigs.array() {
			node.signals << GenCfg{
				signal:    s.value('name').string()
				typ:       s.value('type').default_to('const').string()
				value:     s.value('value').f64()
				offset:    s.value('offset').f64()
				amplitude: s.value('amplitude').f64()
				freq:      s.value('freq').f64()
				phase:     s.value('phase').f64()
				min:       s.value('min').f64()
				max:       s.value('max').f64()
				period:    s.value('period').f64()
				start:     s.value('start').f64()
				step:      s.value('step').default_to(f64(1)).f64()
				modulo:    s.value('modulo').f64()
				count:     s.value('count').f64()
				base:      s.value('base').f64()
			}
		}
	}
	if u := n.value_opt('uds') {
		// PRESENT-but-invalid only. An absent rx/tx reads back as an empty string, which
		// hex_id_is_clean rightly calls unclean — so omitting them was recorded as a malformed
		// identifier. On CAN that was masked (validate_uds reports the missing pair anyway); on
		// a DoIP node, where there are no CAN ids to give, it rejected every valid config.
		mut idfields := map[string]string{}
		if v := u.value_opt('rx') {
			idfields['rx'] = v.str()
		}
		if v := u.value_opt('tx') {
			idfields['tx'] = v.str()
		}
		mut ucfg := UdsCfg{
			rx:        parse_id_wide(u.value('rx').str())
			tx:        parse_id_wide(u.value('tx').str())
			malformed: bad_ids(idfields)
			session:   clamp_i64_u32(u.value('session').default_to(i64(1)).i64())
		}
		if ds := u.value_opt('dids') {
			for d in ds.array() {
				mut dc := DidCfg{
					id:   clamp_u32(parse_id_wide(d.value('id').str()))
					text: d.value('text').default_to('').string()
				}
				if bv := d.value_opt('bytes') {
					dc.bytes = parse_hex_bytes(bv.str())
				}
				if !hex_id_is_clean(d.value('id').str()) {
					ucfg.malformed << 'did ${d.value('id').str()}'
				}
				ucfg.dids << dc
			}
		}
		if ts := u.value_opt('dtcs') {
			for t in ts.array() {
				if !hex_id_is_clean(t.value('code').str()) {
					ucfg.malformed << 'dtc ${t.value('code').str()}'
				}
				ucfg.dtcs << DtcCfg{
					code:   clamp_u32(parse_id_wide(t.value('code').str()))
					status: clamp_i64_u32(t.value('status').default_to(i64(0x09)).i64())
				}
			}
		}
		node.uds = ucfg
	}
	if ps := n.value_opt('protect') {
		node.protect << parse_protect_list(ps)
	}
	if rs := n.value_opt('responses') {
		for r in rs.array() {
			node.responses << ResponseCfg{
				request:  parse_id(r.value('request').str())
				response: parse_id(r.value('response').str())
				byte:     r.value('byte').int()
				add:      u8(r.value('add').default_to(i64(1)).int())
			}
		}
	}
	return node
}

// parse_sender parses one interactive-generator entry: name + key + the frame
// definition (message name or explicit id/data) + signal values + trigger.
fn parse_sender(s yaml.Any) Sender {
	mut snd := Sender{
		name:     s.value('name').default_to('').string()
		key:      s.value('key').default_to('').string()
		message:  s.value('message').default_to('').string()
		ext:      s.value('extended').default_to(false).bool()
		bus:      s.value('bus').default_to('').string()
		trigger:  s.value('trigger').default_to('manual').string().to_lower()
		cycle_ms: s.value('cycle_ms').int()
	}
	if idv := s.value_opt('id') {
		snd.id = parse_id(idv.str())
	}
	if dv := s.value_opt('data') {
		snd.data = parse_hex_bytes(dv.str())
	}
	if sigs := s.value_opt('signals') {
		for sg in sigs.array() {
			snd.signals << SenderSig{
				name:  sg.value('name').string()
				value: sg.value('value').f64()
			}
		}
	}
	return snd
}

// parse_hex_bytes reads a raw CAN payload written as hex bytes, with or without
// separators: "DE AD BE EF", "DEADBEEF" and "de:ad" all give [0xDE,0xAD,…].
// Non-hex characters are skipped; an odd trailing nibble is dropped.
fn parse_hex_bytes(s string) []u8 {
	mut nibbles := []u8{}
	for ch in s.trim_space().trim('"') {
		d := if ch >= `0` && ch <= `9` {
			u8(ch - `0`)
		} else if ch >= `a` && ch <= `f` {
			u8(ch - `a`) + 10
		} else if ch >= `A` && ch <= `F` {
			u8(ch - `A`) + 10
		} else {
			continue
		}
		nibbles << d
	}
	mut out := []u8{}
	for i := 0; i + 1 < nibbles.len; i += 2 {
		out << (nibbles[i] << 4) | nibbles[i + 1]
	}
	return out
}

// parse_addr16 parses a 16-bit DoIP logical address ("0x"-hex or decimal),
// erroring if it isn't a valid integer or exceeds 0xFFFF. The range is checked
// during accumulation (in u64) so an overflowing value (e.g. 0x100000000) can't
// wrap through a narrower type and slip past the guard as 0.
fn parse_addr16(s string) !u16 {
	t := s.trim_space().trim('"')
	mut v := u64(0)
	hex := t.starts_with('0x') || t.starts_with('0X')
	body := if hex { t[2..] } else { t }
	if body == '' {
		return error('"${s}" is not a valid address')
	}
	base := if hex { u64(16) } else { u64(10) }
	for ch in body {
		d := if ch >= `0` && ch <= `9` {
			u64(ch - `0`)
		} else if hex && ch >= `a` && ch <= `f` {
			u64(ch - `a`) + 10
		} else if hex && ch >= `A` && ch <= `F` {
			u64(ch - `A`) + 10
		} else {
			return error('"${s}" is not a valid address')
		}
		v = v * base + d
		if v > 0xFFFF {
			return error('${s} out of range (DoIP logical addresses are 16-bit, max 0xFFFF)')
		}
	}
	return u16(v)
}

// parse_eid parses a DoIP entity id as EXACTLY six strict hex bytes. Separators
// (space / colon / dash) are allowed between bytes; any other character (incl. an
// `0x` prefix) or a length other than 6 bytes is an error — so a mistyped EID
// surfaces at project load instead of being silently mangled by parse_hex_bytes.
fn parse_eid(s string) ![]u8 {
	mut nibbles := []u8{}
	for c in s.trim_space() {
		if c == ` ` || c == `:` || c == `-` {
			continue
		}
		d := if c >= `0` && c <= `9` {
			u8(c - `0`)
		} else if c >= `a` && c <= `f` {
			u8(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			u8(c - `A`) + 10
		} else {
			return error('invalid hex in "${s}"')
		}
		nibbles << d
	}
	if nibbles.len != 12 {
		return error('must be exactly 6 bytes (12 hex digits), got ${nibbles.len} nibbles in "${s}"')
	}
	mut out := []u8{cap: 6}
	for i := 0; i < 12; i += 2 {
		out << (nibbles[i] << 4) | nibbles[i + 1]
	}
	return out
}

// parse_id reads a CAN id written as decimal or `0x`-prefixed hex.
// checked_int parses a plain decimal in [lo, hi], refusing anything else by name. Not i64(),
// which turns a typo into 0 and changes what the ECU does without saying so.
fn checked_int(raw string, field string, lo i64, hi i64) !i64 {
	t := raw.trim_space().trim('"')
	if t == '' {
		return error('${field}: empty')
	}
	for ch in t {
		if ch < `0` || ch > `9` {
			return error('${field}: "${t}" is not a whole number')
		}
	}
	n := t.i64()
	if n < lo || n > hi {
		return error('${field} must be ${lo}..${hi}, got ${n}')
	}
	return n
}

// bad_ids returns the labels of any field whose value is not a clean numeric id.
fn bad_ids(fields map[string]string) []string {
	mut out := []string{}
	for k, v in fields {
		if !hex_id_is_clean(v) {
			out << '${k} ${v}'
		}
	}
	out.sort()
	return out
}

// clamp_i64_u32 narrows a parsed integer without WRAPPING, so an out-of-range value stays out
// of range for validation instead of becoming a different valid one. Every narrowing in the
// uds/protect parse path goes through this or clamp_u32 — session, DTC status and data_id were
// each found separately, which is three times too many for one mistake.
fn clamp_i64_u32(v i64) u32 {
	if v < 0 || v > i64(0xFFFFFFFF) {
		// Both directions saturate to a value the range checks REJECT. Clamping a negative to
		// 0 made it valid: `session: -1` started session 0, and `status: -1` became status 0,
		// which vanishes from every nonzero mask query — then saving wrote the repaired zero
		// and the original mistake was gone.
		return u32(0xFFFFFFFF)
	}
	return u32(v)
}

// clamp_u32 narrows without WRAPPING: an over-wide value stays out of range so validation can
// still see and reject it, instead of becoming a different valid identifier.
fn clamp_u32(v u64) u32 {
	return if v > u64(0xFFFFFFFF) { u32(0xFFFFFFFF) } else { u32(v) }
}

// hex_id_is_clean reports whether every character after the 0x prefix is a hex digit.
// parse_id_wide SKIPS anything else, so "0x7G1" quietly became 0x71 — a valid, unintended id.
pub fn hex_id_is_clean(s string) bool {
	t := s.trim_space().trim('"')
	body := if t.starts_with('0x') || t.starts_with('0X') {
		t[2..]
	} else {
		return t.u64() > 0 || t.trim_space() == '0'
	}
	if body.len == 0 {
		return false
	}
	for ch in body {
		ok := (ch >= `0` && ch <= `9`) || (ch >= `a` && ch <= `f`) || (ch >= `A` && ch <= `F`)
		if !ok {
			return false
		}
	}
	return true
}

// parse_id_wide accumulates in u64 so an over-long identifier is still VISIBLE to validation.
// parse_id itself wraps at 32 bits, which made 0x1000007E0 arrive as a perfectly ordinary
// 0x7E0: the range check passed and the server started on an address nobody configured.
pub fn parse_id_wide(s string) u64 {
	t := s.trim_space().trim('"')
	if t.starts_with('0x') || t.starts_with('0X') {
		mut v := u64(0)
		for ch in t[2..] {
			d := if ch >= `0` && ch <= `9` {
				int(ch - `0`)
			} else if ch >= `a` && ch <= `f` {
				int(ch - `a`) + 10
			} else if ch >= `A` && ch <= `F` {
				int(ch - `A`) + 10
			} else {
				continue
			}
			if v > (u64(0xFFFFFFFFFFFFFFFF) - u64(d)) / 16 {
				return u64(0xFFFFFFFFFFFFFFFF) // saturate rather than wrap: still out of range
			}
			v = v * 16 + u64(d)
		}
		return v
	}
	return t.u64()
}

fn parse_id(s string) u32 {
	t := s.trim_space().trim('"')
	if t.starts_with('0x') || t.starts_with('0X') {
		mut v := u32(0)
		for ch in t[2..] {
			d := if ch >= `0` && ch <= `9` {
				int(ch - `0`)
			} else if ch >= `a` && ch <= `f` {
				int(ch - `a`) + 10
			} else if ch >= `A` && ch <= `F` {
				int(ch - `A`) + 10
			} else {
				continue
			}
			v = v * 16 + u32(d)
		}
		return v
	}
	return u32(t.u64())
}

// adapters is the set of transport backends the editor offers (the `adapter:` value).
// Order = the picker order. `virtual`/`vcan`/`socketcan`/`udp` are cross-platform or
// Linux; `pcan`/`kvaser` are Windows CAN hardware; `doip` is an Ethernet diag endpoint.
pub const adapters = ['virtual', 'vcan', 'socketcan', 'udp', 'pcan', 'kvaser', 'vector', 'cansub',
	'doip']

// WHICH ADAPTERS A PLATFORM MAY OFFER. `adapters` above is every name a project FILE may carry —
// these two are what an editor may put in front of somebody, and they live here, next to the
// registry, rather than in the GUI.
//
// The GUI's own copy is how CANsub shipped unselectable: registered in `adapters`, in
// compose_iface, in decompose_iface and in all three capability predicates, and absent from the
// single hardcoded list a user actually clicks — so the only way to reach the new backend was to
// edit the project file by hand (codex round 1 on #204). The registry test holds the union of
// these two to `adapters`, which is the assertion that would have caught it: a backend cannot be
// added to the engine and left unreachable from the editor.
//
// Split by platform because most backends are: SocketCAN and vcan are Linux kernel interfaces,
// PCAN/Kvaser/Vector are Windows vendor DLLs. CANsub is on BOTH — it is a network device the
// host reaches over USB-Ethernet, so there is no driver to be missing.
pub const windows_adapters = ['virtual', 'udp', 'pcan', 'kvaser', 'vector', 'cansub', 'doip']

pub const linux_adapters = ['virtual', 'vcan', 'socketcan', 'udp', 'cansub', 'doip']

// adapter_silences_transceiver reports whether this app can put the adapter's CONTROLLER into
// listen-only — the half of the promise software cannot keep for itself, because an ACK is
// generated by the controller on every frame it accepts and no amount of not calling send
// suppresses it (transport/listen.v carries that argument in full).
//
// ALL FOUR VENDOR ADAPTERS NOW CAN: Vector through `,silent` on the port, CANsub through
// `listen_only` in the PHY object, and — since this change — PCAN through CAN_SetValue with
// PCAN_LISTEN_ONLY and Kvaser through canSetBusOutputControl(canDRIVER_SILENT). It was Vector and
// CANsub only, which is why this used to be a shorter list than `vendor_adapters`; it is now the
// same list, and it is kept as its own function anyway because the QUESTION is a different one
// from the default below and the two sets have already been apart once.
//
// The software and kernel adapters are not here and never will be: `inproc:`/`udp:` have no
// transceiver at all, and a SocketCAN interface is brought up by `ip link` by whoever chose its
// mode.
pub fn adapter_silences_transceiver(adapter string) bool {
	return match adapter.trim_space().to_lower() {
		'vector', 'cansub', 'pcan', 'kvaser' { true }
		else { false }
	}
}

// adapter_starts_silent reports whether a NEW row on this adapter should begin listen-only.
//
// TRUE FOR HARDWARE THAT MAY ALREADY BE ON A LIVE BUS. A row created in the editor or through
// Discover arrives with the 500 kbit/s default, which nobody has confirmed — and a node joining a
// running vehicle able to acknowledge, at a rate that is a guess, is how a tester disturbs the
// thing it came to observe. Untick it once the rate is known.
//
// THE SAME SET AS `adapter_silences_transceiver`, and that is the rule rather than a coincidence:
// the default is only honest where the transceiver will actually be silenced, and there is no
// vendor adapter where it would be honest and unwanted. PCAN and Kvaser were a stated exception
// while this app could not silence them — a default tick there promised what the transceiver would
// not do — and that reason has now gone, so the exception goes with it. What changes is only what
// a NEWLY CREATED row defaults to; a saved project carries its own answer.
//
// HERE RATHER THAN IN THE GUI, and the reason is the one this file keeps running into: the rule
// lived in two hardcoded `== 'vector'` comparisons in cmd/blobly_net, so exposing CANsub in the
// picker made the manual route the unsafe one while Discover stayed careful, and nothing failed to
// say so (codex round 5 on #204). The registry test holds it against `adapters`, so a hardware
// backend added later cannot quietly default to transmitting.
pub fn adapter_starts_silent(adapter string) bool {
	return adapter_silences_transceiver(adapter)
}

// adapter_change_starts_silent reports whether changing a row's adapter from `was` to `now`
// should re-arm listen-only.
//
// THE DECISION, not just the property, because the property alone was not enough to get it right.
// Written in the GUI as "starts silent now and did not before", a transmit-enabled Vector row
// switched to CANsub kept `listen_only = false`: both answer true, so the condition never fired
// and the new controller opened able to ACK — the default defeated by the one case where BOTH
// adapters need it (codex round 6 on #204). What matters is that the HARDWARE changed, at a rate
// nobody has confirmed for the new one.
pub fn adapter_change_starts_silent(was string, now string) bool {
	return adapter_starts_silent(now) && was.trim_space().to_lower() != now.trim_space().to_lower()
}

// platform_adapters is what THIS build may offer.
pub fn platform_adapters() []string {
	$if windows {
		return windows_adapters
	} $else {
		return linux_adapters
	}
}

// compose_iface builds the internal scheme string `transport.open()` consumes from an
// adapter + its backend-specific address. It is the inverse of decompose_iface.
//   virtual  CAN1            -> inproc:CAN1   (bare `inproc` if address empty)
//   vcan     vcan0           -> vcan0         (raw; SocketCAN backend)
//   socketcan can0           -> can0          (raw; SocketCAN backend)
//   udp      239.0.0.1:5000  -> udp:239.0.0.1:5000  (bare `udp` if empty)
//   pcan     PCAN_USBBUS1    -> pcan:PCAN_USBBUS1
//   kvaser   0               -> kvaser:0
//   vector   1               -> vector:1
//   doip     127.0.0.1:13400 -> doip:127.0.0.1:13400 (bare `doip` if empty)
// split_vector_mode separates a `,silent` style suffix from a Vector address.
//
// Returns the address without it, whether it asked for listen-only, and whether the suffix was
// RECOGNISED at all. An unrecognised one is left on the address so the transport parser refuses
// it: `vector:1,silnt` is plainly a request for silence, and quietly dropping it would open the
// channel able to acknowledge.
//
// Shared, because the same rule has to hold on every path that can produce an address — the
// project loader, the editor's text field, and the migration of a v1 interface. It held on one
// of them for a while, and a `,silent` typed into the editor opened a silent port that the
// model still believed could transmit.
pub fn split_vector_mode(address string) (string, bool, bool) {
	if !address.contains(',') {
		return address, false, true
	}
	body := address.all_before_last(',')
	// ONE suffix. `1,silent,normal` recognised the final `,normal`, returned `1,silent`, and the
	// model then called the channel transmit-capable while the address it kept still said
	// silent — the two halves of one decision disagreeing again, from a spelling nobody should
	// be able to write and have quietly resolved.
	if body.contains(',') {
		return address, false, false
	}
	return match address.all_after_last(',').trim_space().to_lower() {
		'silent', 'listen_only', 'listenonly' { body, true, true }
		'normal' { body, false, true }
		else { address, false, false }
	}
}

pub fn compose_iface(adapter string, address string) string {
	a := address.trim_space()
	return match adapter {
		'virtual' {
			if a == '' {
				'inproc'
			} else {
				'inproc:${a}'
			}
		}
		'udp' {
			if a == '' {
				'udp'
			} else {
				'udp:${a}'
			}
		}
		'pcan' {
			'pcan:${a}'
		}
		'kvaser' {
			'kvaser:${a}'
		}
		'cansub' {
			'cansub:${a}'
		}
		'vector' {
			'vector:${a}'
		}
		'doip' {
			if a == '' {
				'doip'
			} else {
				'doip:${a}'
			}
		}
		// vcan / socketcan / unknown: the address IS the raw interface name.
		else {
			a
		}
	}
}

// decompose_iface splits a scheme string back into (adapter, address) so a v1 file (or
// any raw `iface`) presents in the editor. Inverse of compose_iface. A bare `vcanN` maps
// to the `vcan` adapter; anything else raw is treated as `socketcan` (real `canN`).
pub fn decompose_iface(iface string) (string, string) {
	s := iface.trim_space()
	if s == 'inproc' {
		return 'virtual', ''
	}
	if s.starts_with('inproc:') {
		return 'virtual', s['inproc:'.len..]
	}
	if s == 'udp' {
		return 'udp', ''
	}
	if s.starts_with('udp:') {
		return 'udp', s['udp:'.len..]
	}
	// Vendor backends carry the bitrate in the iface as `@<rate>` (a v1 convention). Strip it
	// from the address so it isn't re-appended at open (`…@500000@250000`) or treated as a
	// distinct bus; the rate is lifted into the bitrate field by parse_channel.
	if s.starts_with('pcan:') {
		return 'pcan', s['pcan:'.len..].all_before('@')
	}
	// `cansub:<id>/<channel>[@<rates>]` — the id AND channel are the address, so only the rate
	// suffix comes off, exactly as it does for the other three.
	//
	// CASE-INSENSITIVELY, unlike the branches around it, because the CANsub DISPATCHER is
	// (`open_windows.v` / `open_linux.v` both match `iface.to_lower()`). `pcan:`, `kvaser:` and
	// `vector:` are case-sensitive in both places and so agree with themselves; cansub was the one
	// that did not, so `CANSUB:E5A16ADF/1@250000` opened as a CANsub at 250k while this classified
	// the row as SocketCAN and never lifted the rate into the model — leaving the editor and every
	// conflict check reasoning about a different bus from the one that opens (codex round 3 on
	// #204).
	if s.to_lower().starts_with('cansub:') {
		return 'cansub', s['cansub:'.len..].all_before('@')
	}
	if s.starts_with('kvaser:') {
		return 'kvaser', s['kvaser:'.len..].all_before('@')
	}
	if s.starts_with('vector:') {
		// The mode suffix (`,silent`) rides along with the address rather than the bitrate, so
		// it is kept here: it is part of how the channel is opened, and dropping it would turn
		// a listen-only bench into one that acknowledges the next time the project is saved.
		body := s['vector:'.len..]
		mode := if body.contains(',') { ',' + body.all_after_last(',') } else { '' }
		return 'vector', body.all_before('@').all_before_last(',') + mode
	}
	if s == 'doip' {
		return 'doip', ''
	}
	if s.starts_with('doip:') {
		return 'doip', s['doip:'.len..]
	}
	if s.starts_with('vcan') {
		return 'vcan', s
	}
	return 'socketcan', s
}

// mode_from maps a string to a Mode (unknown → monitor).
pub fn mode_from(s string) Mode {
	return match s.to_lower() {
		'off' { Mode.off }
		'replay' { Mode.replay }
		else { Mode.monitor }
	}
}

// str renders a Mode for display.
pub fn (m Mode) str() string {
	return match m {
		.off { 'off' }
		.monitor { 'monitor' }
		.replay { 'replay' }
	}
}

// conflict_wire_key groups rows by the wire they reach, for checks that READ a project.
//
// Deliberately not transport.wire_key, which this module's own apply_listen_only uses: that one
// is platform-guarded, because it is naming a bus about to be opened HERE. This is analysis — a
// Linux GUI must resolve `vector:1` and `vector:ch1` to one wire while reading a project
// authored for a Windows bench, which is exactly what destination_key_for exists for.
//
// And the two families need different treatment of `@`: a bitrate suffix on a vendor address, a
// literal part of the name anywhere else, where `inproc:bench@A` is a bus called `bench@A`.
fn conflict_wire_key(c Channel) string {
	if transport.adapter_configures_bitrate(c.adapter) {
		return transport.wire_key_for(c.adapter, c.iface)
	}
	return transport.canonical_iface(c.iface)
}

// destination_conflicts reports configurations that two rows on ONE physical wire cannot both
// have. Empty means nothing to say.
//
// HERE, not in a front end, because both have to reach the same verdict on the same file and
// they did not: the GUI refused these at Start while the headless runner started the simulation
// anyway and discarded the refusals a frame at a time. The rules are about what a project MEANS,
// which is this module's job.
//
// Three of them now. Two come from a wire having one mode and one bitrate:
//   - a wire one row has set listen-only cannot carry another row's traffic — checked on EVERY
//     adapter since #117. It used to be Vector-only, because `,silent` reached only the Vector
//     transceiver and the flag did nothing anywhere else, so two rows disagreeing about it on a
//     PCAN or SocketCAN wire contradicted each other harmlessly. Now the wire itself refuses to
//     transmit, whichever row asked for it, so the disagreement costs the OTHER row its voice —
//     answerable before Start rather than discovered as silence afterwards.
//   - two rows cannot ask for different bitrates on it — vendor adapters only, which are the
//     ones we configure the rate on.
//
// And the third is about a wire being TWO rows without either of them saying so:
//   - two Vector application channels assigned to ONE physical channel (#167). Every check above
//     compares rows that destination_key has already agreed are the same wire; this one is for
//     rows it says are different and the hardware says are not.
//
// (Named vendor_destination_conflicts while both halves were vendor-only.)
// can_carry_fd reports whether this row's backend can put a CAN-FD frame on the wire.
//
// A METHOD ON THE ROW so a front end asks the project about a project row rather than importing
// the transport module to reason about an adapter string itself. The answer still comes from
// transport, which is where "who implemented FD" belongs; this is the seam, not a second copy.
pub fn (c Channel) can_carry_fd() bool {
	return transport.adapter_carries_fd(c.adapter)
}

// Framing is how a frame this app ORIGINATES on a channel should be put on the wire.
//
// A frame carries the format, and until now every frame the app built carried the classic one —
// so a channel configured as CAN-FD, opened as CAN-FD and verified at an 8 Mbit/s data phase could
// still only be exercised by REPLAY, which passes recorded frames through with their own flags
// (#185). Quick Send, the generators, the simulated ECUs and the diagnostics all built classic.
pub struct Framing {
pub:
	fd  bool
	brs bool
}

// origination_framing answers it from the CHANNEL, which is the only party that has declared
// anything.
//
// DECLARED, NOT INFERRED, which is this repo's habit whenever a wire format is at stake. The
// tempting inference is "a DBC message longer than eight bytes must be FD" — but that reads a
// format out of a payload size, and it is wrong in both directions: an 8-byte message on an FD
// wire is a perfectly good FD frame, and a 12-byte one on a classic wire is a mistake worth
// refusing rather than silently promoting. `type: canfd` in the project is the operator saying it.
//
// BRS FOLLOWS A DISTINCT DATA RATE, for the reason vectorcheck's own probe does the same: with
// equal phases there is no faster phase to switch into, and the XL library refuses the flag. So
// `canfd` at 500000/500000 originates 64-byte frames without the bit-rate switch, which is a real
// configuration and the only way to ask for it.
pub fn (c Channel) origination_framing() Framing {
	if !c.fd {
		return Framing{}
	}
	return Framing{
		fd:  true
		brs: c.data_bitrate > 0 && c.data_bitrate != c.nominal_bitrate()
	}
}

// framed returns `f` as this channel would put it on the wire.
//
// A FRAME THAT ALREADY SAYS `fd` KEEPS IT. Replay does not come through here, but the emitters that
// do include ones handling a frame somebody else built, and demoting an FD frame to classic
// silently would be the truncation this whole change exists to stop. Stamping only upward means
// this can add the channel's format and never contradict a caller who has already stated one.
pub fn (c Channel) framed(f transport.CanFrame) transport.CanFrame {
	return c.origination_framing().apply(f)
}

// apply is the stamp itself, on Framing rather than on Channel, because the two front ends reach it
// from different directions: the GUI has the row and the headless runner has only what it passed
// into its sim loop. One function either way, so they cannot drift about what `canfd` means.
pub fn (fr Framing) apply(f transport.CanFrame) transport.CanFrame {
	if f.fd || !fr.fd {
		return f
	}
	return transport.CanFrame{
		...f
		fd:  true
		brs: fr.brs
	}
}

// address_config_error reports why this row's CAN-FD rates could not be opened, or none when they can.
//
// ASKS THE REAL PARSER rather than restating its rules, and asks it about the ADDRESS THIS ROW
// WILL ACTUALLY BE OPENED WITH. An editor enforcing its own copy is a second opinion about the
// same string, and it was one twice over: `commit_cfg` accepted any positive digit string, so a
// 250000 data phase under a 500000 nominal was accepted, persisted, and refused only at Start —
// and the first attempt at this check reached for vendor_split_fd_rate, which enforces the
// ordering and leaves the RANGES to parse_vector_spec, so 9 Mbit/s still slipped through
// (codex #183 r1; the second half was caught by this function's own test).
//
// Composing through iface_with_bitrate is what makes it exact: whatever that produces is what
// `transport.open` is handed, so anything this accepts, the open accepts.
pub fn (c Channel) address_config_error() ?string {
	// CANSUB IS ASKED ABOUT EVERY ROW, FD or not. The other vendor backends hand a nominal rate
	// to a driver that either produces it or says so; the CANsub derives its own bit timing from
	// an 80 MHz clock that must divide EXACTLY, so it is the first adapter here that can refuse a
	// plain CLASSIC rate. 333333 bit/s passed the editor's digits-only check, was saved, and was
	// refused only at Start — which is the exact failure the FD half of this function was written
	// to prevent, recurring one row-type over (codex round 1 on #204). The name says `address`
	// rather than `fd` for the same reason.
	if c.adapter == 'cansub' {
		// THE ADDRESS FIELD CARRIES NO RATE. `iface_with_bitrate()` appends the row's rate fields,
		// so a suffix left in the address is either duplicated (two `@`, refused) or — when the
		// nominal field is unset — passed through untouched, in which case the backend opens at
		// the address's rate while `nominal_bitrate()` and `destination_conflicts()` model the row
		// at the 500 kbit/s default. A rate conflict on that wire then goes unnoticed and the
		// controller runs at a rate the editor never showed (codex round 8 on #204).
		//
		// Refused rather than migrated: moving it silently would change what the row means without
		// the operator seeing it, and the rate fields are right there. v1 files are unaffected —
		// `decompose_iface` lifts their suffix into `bitrate` on load, which is what that code is
		// for.
		if c.address.contains('@') {
			return 'the address field holds a rate (${c.address}) — put the rates in the bitrate fields instead; the address is just the device id and channel'
		}
		// A SAMPLE POINT THE BACKEND CANNOT BE TOLD ABOUT IS REFUSED, not ignored. The CANsub
		// address carries a device, a channel and rates — there is nowhere in it for a sample
		// point, so `cansub_timing_for` is always asked for the 80% default. A project that set
		// 75% for a long bus therefore ran timing it never asked for, silently, and the errors
		// that produces appear under load and nowhere else (codex round 10 on #204).
		//
		// Refused rather than carried, because carrying it means putting it in the address, and
		// the address is the wire's IDENTITY — `destination_key` derives from it, so a sample
		// point in there would split one wire into two for every rule keyed on it. Zero means
		// unset, which is what almost every row has.
		// THE WHOLE VALUE, not its integer part: `int(80.5)` is 80, so a row asking for 80.5%
		// passed this check and then ran at exactly 80% anyway — the same silent substitution one
		// decimal place down (codex round 11 on #204).
		if c.sample_point != 0 && c.sample_point != f64(transport.cansub_default_sample_point) {
			return 'sample point ${c.sample_point}% cannot be configured on a CANsub from here — it solves both phases at ${transport.cansub_default_sample_point}%, so remove the setting or use a different adapter'
		}
		return transport.cansub_address_error(c.iface_with_bitrate())
	}
	// THE SAME RULE FOR PCAN, and for the same reason: its address carries a channel and rates and
	// has nowhere to put a sample point, so a row asking for one that will not be used runs timing
	// it never requested, silently — the failure this repo's own parity table faults Kvaser for.
	//
	// BUT THE ANSWER DEPENDS ON THE MODE, which the first version of this check missed. An FD
	// channel is SOLVED, at the 80% default. A classic channel is LOOKED UP, in a fixed BTR table
	// whose entries do not agree with each other or with 80: 500 kbit/s samples at 87.5%, 1 Mbit/s
	// at 75%. Applying the FD default to a classic row refused the sample point that channel
	// actually has and accepted one it does not (codex round 3 on #217). So each mode is asked
	// about its own timing.
	if c.adapter == 'pcan' && c.sample_point != 0 {
		if c.fd && c.can_carry_fd() {
			if c.sample_point != f64(transport.pcan_default_sample_point) {
				return 'sample point ${c.sample_point}% cannot be configured on a PCAN from here — it solves both phases at ${transport.pcan_default_sample_point}%, so remove the setting or use a different adapter'
			}
		} else if actual := transport.pcan_classic_sample_point(c.nominal_bitrate()) {
			// A rate with no BTR code at all is not this check's business: it is refused when the
			// channel opens, and answering here would report the wrong fault first.
			if c.sample_point != actual {
				return 'sample point ${c.sample_point}% cannot be configured on a classic PCAN from here — ${c.nominal_bitrate()} bit/s uses a fixed BTR code that samples at ${actual}%, so remove the setting or use a different adapter'
			}
		}
	}
	if !c.fd || !c.can_carry_fd() {
		return none
	}
	// PER ADAPTER, because each backend's parser owns its own rates and ranges. Asking
	// Vector's validator about a Kvaser address would answer about the wrong hardware --
	// and answering `none` for every non-Vector adapter, which is what this did while
	// Vector was the only one with a data phase, is how a Kvaser row with an impossible
	// rate got persisted and refused at Start instead of in the editor.
	return match c.adapter {
		'vector' { transport.vector_address_error(c.iface_with_bitrate()) }
		'kvaser' { transport.kvaser_address_error(c.iface_with_bitrate()) }
		'cansub' { transport.cansub_address_error(c.iface_with_bitrate()) }
		'pcan' { transport.pcan_address_error(c.iface_with_bitrate()) }
		else { none }
	}
}

// fd_capability_warnings reports enabled rows configured for CAN-FD on an adapter whose backend
// refuses an FD frame — said ONCE, at Start, before any traffic flows.
//
// WHY A WARNING AND NOT A REFUSAL (issue #170). The failure it describes is quiet in the worst
// way: replay counts refused frames into `failed` and keeps going, so a recording that is part
// classic and part FD replays its classic half and produces "a convincing-looking measurement
// that is missing traffic". But the run is not worthless — the classic half is real, and a bench
// may deliberately be exercising it — so refusing to start would take away something that works.
// The honest answer is to say so before the operator reads the results, which is what #141
// established for a channel that cannot open at all.
//
// NOT a destination_conflicts entry, for that reason: everything in there refuses the project.
// This is one row being wrong about its own hardware rather than two rows contradicting each
// other on one wire.
pub fn fd_capability_warnings(chs []Channel) []string {
	mut out := []string{}
	for c in chs {
		// ENABLED ROWS ONLY, the rule every check here follows: a row switched off states nothing
		// about the run and will open nothing.
		if !c.enabled || !c.fd {
			continue
		}
		if c.can_carry_fd() {
			continue
		}
		if c.is_doip() {
			// A `doip:` row with `type: canfd` is a different mistake — an Ethernet channel
			// carrying a CAN protocol flag — and naming CAN-FD support would answer a question
			// nobody asked. Said as what it is.
			out << '${c.name} is a DoIP channel configured as CAN-FD; the protocol flag does not apply to it and is ignored'
			continue
		}
		out << '${c.name} is configured as CAN-FD on ${c.adapter}, whose backend refuses CAN-FD frames — its classic traffic will run and every FD frame will be counted as failed'
	}
	return out
}

// fd_wanted reduces a channel's CAN-FD configuration to the one comparable number
// destination_conflicts groups on: 0 for classic, and otherwise the data bitrate the wire's
// payload phase would run at.
//
// THE DEFAULT MATCHES iface_with_bitrate's. A row marked FD with no data bitrate opens at its
// arbitration rate, so that is the figure it must be compared with — reading it as 0 here would
// make an FD row look classic and let it share a wire with one.
fn fd_wanted(c Channel) int {
	if !c.fd {
		return 0
	}
	if c.data_bitrate > 0 {
		return c.data_bitrate
	}
	return if c.bitrate > 0 { c.bitrate } else { default_bitrate }
}

// fd_describe names an fd_wanted value the way an operator would read it back.
fn fd_describe(v int) string {
	return if v == 0 { 'classic CAN' } else { 'CAN-FD with a ${v} bit/s data phase' }
}

pub fn destination_conflicts(chs []Channel) []string {
	return check_destinations(chs).problems
}

// The refusals that need no driver. Split out so check_destinations can add the alias verdict from
// its own single sweep instead of triggering a second one.
fn destination_conflicts_without_alias(chs []Channel) []string {
	mut out := []string{}
	mut quiet := map[string]string{}
	mut rate := map[string]int{}
	mut rate_row := map[string]string{}
	// The protocol a wire runs, as a comparable value: 0 classic, otherwise the data bitrate.
	// One map rather than two, because "is it FD" and "at what data rate" are one answer — a row
	// asking FD at 2 Mbit/s disagrees with a classic row and with an FD row at 4 Mbit/s alike.
	mut fd_mode := map[string]int{}
	mut fd_row := map[string]string{}
	for c in chs {
		if !c.enabled {
			continue
		}
		// Keyed on what the bus will be OPENED with, so this groups rows exactly as the
		// transport table does — a mark filed under one spelling and looked up under another
		// finds nothing, and would report agreement between rows that will not agree at run time.
		if c.listen_only && !c.is_doip() {
			quiet[conflict_wire_key(c)] = c.name
		}
		if !transport.adapter_configures_bitrate(c.adapter) {
			continue
		}
		// WITHOUT THE RATE. The rate is what these rows disagree about, so a key containing it
		// gave each of them their own and the comparison below never happened.
		k := transport.wire_key_for(c.adapter, c.iface)
		want := if c.bitrate > 0 { c.bitrate } else { default_bitrate }
		if prev := rate[k] {
			if prev != want {
				out << '${c.name} and ${rate_row[k]} share ${c.iface} but ask for ${want} and ${prev} bit/s'
			}
		} else {
			rate[k] = want
			rate_row[k] = c.name
		}
		// THE PROTOCOL AND ITS DATA PHASE, checked exactly as the rate above and for the same
		// reason: a wire runs one of them. Two enabled rows that disagree have stated something
		// the hardware cannot do — the Vector backend refuses the second port with -1011/-1012 —
		// and that is answerable here, from the file, instead of as a channel that fails to open
		// halfway through a Start.
		//
		// WHERE A DATA PHASE IS CONFIGURED, unlike the rate above. The asymmetry was the point
		// while an adapter existed that configured none — PCAN opened both rows on the same
		// classic bus and refused each FD frame individually, so refusing the WHOLE PROJECT here
		// overrode fd_capability_warnings, whose entire policy is that an FD row on such an
		// adapter is a warning because its classic
		// traffic still runs. Two rules contradicting each other, with the stricter one
		// silently winning (codex #181 r5).
		// The comparison is on the ROW's fields rather than on its address, because that is what
		// the operator edits and what iface_with_bitrate composes the address from; comparing the
		// composed strings would make this a test of the composer.
		if !transport.adapter_configures_data_phase(c.adapter) {
			continue
		}
		fdw := fd_wanted(c)
		if prev := fd_mode[k] {
			if prev != fdw {
				out << '${c.name} and ${fd_row[k]} share ${c.iface} but ask for ${fd_describe(fdw)} and ${fd_describe(prev)}'
			}
		} else {
			fd_mode[k] = fdw
			fd_row[k] = c.name
		}
	}
	// DISAGREEMENT IS THE CONFLICT, not "would this row transmit".
	//
	// This reverses an earlier reading of mine, and the reason is worth keeping: I judged a row
	// passive from its CONFIGURATION — no simulated nodes, no replay — and concluded it could
	// share a silenced wire harmlessly. Runtime does not respect that. A Lua script can call
	// bus.send on any channel, and so can Quick Send, the shell and the diagnostic panel; the
	// row's configuration says nothing about whether somebody will ask it to talk.
	//
	// A wire has one mode. Two enabled rows on it that disagree about it have stated something
	// that cannot be done, whoever ends up transmitting, and that is answerable now instead of a
	// frame at a time later.
	for c in chs {
		if !c.enabled || c.listen_only {
			continue
		}
		if who := quiet[conflict_wire_key(c)] {
			out << '${c.name} shares ${c.iface} with ${who}, which is listen-only'
		}
	}
	// NO DRIVER BELOW THIS LINE, and no alias verdict either — check_destinations appends that from
	// the ONE sweep it owns. This function used to end by scanning and appending it itself, which
	// meant check_destinations swept twice and reported a stable alias twice over; worse, the two
	// verdicts came from two snapshots, so a changing XL answer produced a combination that
	// described neither moment (codex #199 r2). Everything above is pure and stays that way.
	return out
}

// scan_physical asks the driver ONCE about every enabled row, and returns both answers the alias
// rule needs: the rows it could resolve, and the rows it could not.
//
// ONE SWEEP, TWO ANSWERS, and that is the whole point of it existing. Asking twice — once for the
// conflict check and again for the warning — lets the two disagree about the same row, because the
// driver's answer can change between them: a lookup that failed for the comparison and succeeded
// for the warning leaves a row neither checked NOR reported, which is the exact gap the warning was
// added to close (codex #199 r1).
fn scan_physical(chs []Channel) (map[string]string, []string) {
	mut phys := map[string]string{}
	mut unread := []string{}
	for c in chs {
		if !c.enabled {
			continue
		}
		reach, k := transport.physical_wire(c.adapter, c.iface)
		match reach {
			.resolved { phys[c.iface] = k }
			.unreadable { unread << '${c.name} (${c.iface})' }
			.nothing {}
		}
	}
	return phys, unread
}

// check_destinations is destination_conflicts and its warnings from a SINGLE driver sweep.
//
// Every caller that starts a project should use this rather than the two separately: the refusals
// and the warning are two readings of one set of answers, and taking them from two sweeps is how
// they come to contradict each other.
pub struct DestinationCheck {
pub:
	problems []string // any one of these refuses the project
	warnings []string // said, never refused — see alias_unreadable_warnings
}

pub fn check_destinations(chs []Channel) DestinationCheck {
	phys, unread := scan_physical(chs)
	mut problems := destination_conflicts_without_alias(chs)
	problems << alias_conflicts(chs, phys)
	problems << address_problems(chs)
	return DestinationCheck{
		problems: problems
		warnings: alias_unreadable_lines(unread)
	}
}

// address_problems asks every enabled row whether its own address can be opened as configured.
//
// IN THE SHARED CHECK, because until now `address_config_error` had exactly one caller: the GUI
// editor. So everything it refuses — an impossible FD rate pair, a CANsub rate the clock cannot
// divide, a rate suffix left in the address field, a sample point the backend cannot be told about
// — was enforced while somebody typed and enforced nowhere at all for a `.blobnet` started
// headless. `cmd/script/run.v` calls this function and went straight past all of it (codex round
// 11 on #204).
//
// The editor keeps its own call: it needs the answer per row, as the row changes, to mark the
// field. This is the same question asked once more at the moment a project is about to run, which
// is the only moment the headless runner has.
//
// ENABLED ROWS ONLY, like every other check here. A disabled row is not going to be opened, and
// refusing to start because of one is refusing over a wire nobody asked for.
fn address_problems(chs []Channel) []string {
	mut out := []string{}
	for c in chs {
		if !c.enabled {
			continue
		}
		if why := c.address_config_error() {
			out << '${c.name}: ${why}'
		}
	}
	return out
}

// alias_unreadable_warnings names the enabled rows whose physical channel the driver would not
// report, so the operator knows which rows the alias check above could not cover.
//
// A WARNING, NOT A REFUSAL, and the split matters. Everything destination_conflicts returns stops
// a project; this cannot, because "the driver would not answer" is a state a perfectly good bench
// passes through — the XL library mid-upgrade, or a moment of contention with another tool. Fail
// closed there and every project on that machine is rejected for a question nobody could answer.
//
// But silence is not right either. The gap it leaves is precisely the #167 alias — two rows on one
// transceiver, reasoned about as two wires by the rate check, the listen-only check, the
// one-monitor rule and the pin guard. Saying which rows were unresolvable turns an invisible gap
// into one the operator can close by asking again.
pub fn alias_unreadable_warnings(chs []Channel) []string {
	return check_destinations(chs).warnings
}

// The wording, split out PURE so it can be tested at all. On Linux physical_wire answers `.nothing`
// for everything, so a test driving alias_unreadable_warnings there can only ever see the empty
// case — the same reason alias_conflicts is separate from the resolver that feeds it.
fn alias_unreadable_lines(rows []string) []string {
	if rows.len == 0 {
		return []
	}
	// ONE LINE FOR THE SET, not one per row. The condition is a property of the driver at this
	// moment rather than of any individual row, so repeating it per row would say the same thing
	// several times — the same reasoning alias_conflicts uses for `said`.
	return [
		'could not read which physical channel ${rows.join(', ')} ${if rows.len == 1 {
			'reaches'
		} else {
			'reach'
		}} — the check for two channels sharing one transceiver could not cover ${if rows.len == 1 {
			'it'
		} else {
			'them'
		}}; Refresh or restart to ask the driver again',
	]
}

// alias_conflicts reports rows that this app calls different wires and the hardware calls one.
//
// SEPARATE, AND PURE, so it can be tested at all. `phys` maps a row's interface to the physical
// channel it resolves to, for the rows where that is knowable; a row absent from the map is one
// nobody could resolve, and it is left alone rather than assumed distinct. Splitting it this way
// is what lets the comparison — which is the part with the mistakes in it — be exercised on
// Linux, where the resolver itself can only ever answer none.
//
// THE CONFLICT IS A DISAGREEMENT BETWEEN THE TWO KEYS, not a shared physical channel on its own.
// `vector:1` and `vector:ch1` share one, and must: they are one wire under both readings, which
// is exactly what destination_key exists to say. What cannot stand is two rows whose wire keys
// DIFFER while their hardware is the same — that is one transceiver being reasoned about as two,
// which is how a listen-only tick fails to silence its own bus and two monitors split one receive
// queue between them.
fn alias_conflicts(chs []Channel, phys map[string]string) []string {
	mut out := []string{}
	mut owner := map[string]string{} // physical channel -> the wire key that claimed it
	mut owner_row := map[string]string{}
	// ONE LINE PER PHYSICAL CHANNEL, not one per pair, and not per row after the first. Three
	// rows aliased onto one channel is a SINGLE mistake in the assignment; saying it twice more
	// tells the operator nothing the first line did not, and a set is what keeps that true —
	// dropping the claim instead would let the third row re-claim the channel and the fourth
	// report it all over again.
	mut said := map[string]bool{}
	for c in chs {
		if !c.enabled {
			continue
		}
		pk := phys[c.iface] or { continue }
		if pk in said {
			continue
		}
		// conflict_wire_key, NOT transport.wire_key_for, though only Vector rows can reach here
		// today and the two agree on those. This file already has ONE answer to "which wire is
		// this row on" and every other check in it goes through that answer; a second copy is
		// how they drift. It is not hypothetical either — wire_key_for splits a vendor `@rate`
		// suffix unconditionally, so the moment physical_wire_key learns another adapter,
		// `inproc:bench@A` and `inproc:bench@B` would compare equal HERE while the rest of
		// destination_conflicts goes on treating them as two hubs.
		wk := conflict_wire_key(c)
		if prev := owner[pk] {
			if prev != wk {
				out << '${c.name} (${c.iface}) and ${owner_row[pk]} are different channels in this project but are assigned to the same physical adapter channel — one transceiver cannot be two wires; give them separate channels in Vector Hardware Manager, or remove one'
				said[pk] = true
			}
			continue
		}
		owner[pk] = wk
		owner_row[pk] = c.name
	}
	return out
}
