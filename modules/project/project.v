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

import os
import yaml

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
	speed  f64 = 1.0
	repeat bool // yaml key `loop`
}

// GenCfg configures one signal's value generator for a simulated ECU. `typ`
// selects the kind; only the relevant params are used (see modules/sim Gen).
pub struct GenCfg {
pub mut:
	signal    string
	typ       string = 'const' // const | sine | sawtooth | counter | stepmod
	value     f64    // const
	offset    f64    // sine bias
	amplitude f64    // sine amplitude
	freq      f64    // sine angular freq (rad/s·t)
	phase     f64    // sine phase
	min       f64    // sawtooth
	max       f64    // sawtooth
	period    f64    // sawtooth / stepmod period (s)
	start     f64    // counter start
	step      f64 = 1.0 // counter increment
	modulo    f64    // counter wrap
	count     f64    // stepmod step count
	base      f64    // stepmod base
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
	rx      u64 // request id  (tester -> ECU)
	tx      u64 // response id (ECU -> tester)
	dids    []DidCfg
	dtcs    []DtcCfg
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
	// Whether the written id was a clean number. A stripped character yields a DIFFERENT VALID
	// id, so no range check can catch it — `0x2G2` became `0x22` and bound to whatever lives
	// there, while saving replaced the typo with the sanitized value.
	id_malformed bool
	counter string // signal carrying the alive counter ('' = none)
	crc     string // signal carrying the checksum ('' = none)
	profile string = 'crc8_j1850' // crc8_j1850 | crc8_autosar | sum8 | xor8
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
	cycle_ms int    // cyclic period (ms); only used when trigger == cyclic
}

// Channel is one bus the tester attaches to.
//
// Schema v2 introduces `adapter` + `address` (the transport backend and its
// backend-specific address) and an optional `network` grouping label; `iface` is
// the derived internal scheme string that `transport.open()` consumes (composed
// from adapter+address). v1 files (`channels:` with `interface:`/`type:`) still
// load — the parser decomposes `interface` back into adapter+address so the editor
// always has them. See compose_iface / decompose_iface.
pub struct Channel {
pub mut:
	name         string = 'CAN'
	network      string // v2: optional grouping label (buses of one logical network)
	adapter      string = 'vcan' // v2: virtual | vcan | socketcan | udp | pcan | kvaser | doip
	address      string = 'vcan0' // v2: adapter-specific (CAN1 / vcan0 / can0 / grp:port / host:port)
	typ          string = 'can' // yaml `type`/`protocol`: can | canfd | doip
	iface        string = 'vcan0' // derived scheme string (composed from adapter+address)
	bitrate      int    = 500000
	fd           bool
	data_bitrate int
	sample_point f64
	timing       Timing
	mode         Mode = .monitor
	listen_only  bool
	enabled      bool = true
	databases    []string
	manifest     string    // telemetry handler manifest (CSV) — resolves handler_id -> FB/handler/core
	// Protection to VERIFY on received frames. Independent of `simulation:` on purpose: in a
	// rest-bus setup the ECU under test is the one node NOT simulated, so its protected messages
	// can never be described by a simulated node's `protect:` — and it is precisely that ECU's
	// counter and checksum a bench needs checked.
	verify       []ProtectCfg
	simulate     []string  // shorthand: ECU node names to simulate with default behaviour
	nodes        []NodeCfg // fully-configured simulated ECUs (signals + responses)
	senders      []Sender  // interactive generators: triggerable custom frames
	replay       ?Replay
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
	version  int = 1
	channels []Channel
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
		bitrate:      c.value('bitrate').default_to(i64(500000)).int()
		fd:           c.value('fd').default_to(false).bool()
		data_bitrate: c.value('data_bitrate').default_to(i64(0)).int()
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
		ch.iface = compose_iface(ch.adapter, ch.address)
	} else if iv := c.value_opt('interface') {
		raw := iv.string()
		ch.adapter, ch.address = decompose_iface(raw)
		// A legacy vendor iface embeds the bitrate (`pcan:CH@500000`): lift it into the bitrate
		// field (decompose stripped it from the address) and recompose a clean iface.
		if (ch.adapter == 'pcan' || ch.adapter == 'kvaser') && raw.contains('@') {
			br := raw.all_after_last('@').int()
			if br > 0 {
				ch.bitrate = br
			}
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
	}
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
		ch.replay = Replay{
			source: r.value('source').string()
			speed:  r.value('speed').default_to(f64(1)).f64()
			repeat: r.value('loop').default_to(false).bool()
		}
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
		if v := p.value_opt('data_id') {
			id = clamp_i64_u32(v.i64()) // present, even when 0 — that is a real id
		}
		mut mid := ?u32(none)
		mut mbad := false
		if v := p.value_opt('id') {
			mid = clamp_u32(parse_id_wide(v.str()))
			mbad = !hex_id_is_clean(v.str())
		}
		mut mext := ?bool(none)
		if v := p.value_opt('extended') {
			mext = v.bool()
		}
		out << ProtectCfg{
			message:      p.value('message').default_to('').string()
			id:           mid
			extended:     mext
			id_malformed: mbad
			counter: p.value('counter').default_to('').string()
			crc:     p.value('crc').default_to('').string()
			profile: p.value('profile').default_to('crc8_j1850').string()
			data_id: id
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
		mut ucfg := UdsCfg{
			rx:      parse_id_wide(u.value('rx').str())
			tx:      parse_id_wide(u.value('tx').str())
			malformed: bad_ids({
				'rx': u.value('rx').str()
				'tx': u.value('tx').str()
			})
			session: clamp_i64_u32(u.value('session').default_to(i64(1)).i64())
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
// parse_id_wide accumulates in u64 so an over-long identifier is still VISIBLE to validation.
// parse_id itself wraps at 32 bits, which made 0x1000007E0 arrive as a perfectly ordinary
// 0x7E0: the range check passed and the server started on an address nobody configured.
// clamp_i64_u32 narrows a parsed integer without WRAPPING, so an out-of-range value stays out
// of range for validation instead of becoming a different valid one. Every narrowing in the
// uds/protect parse path goes through this or clamp_u32 — session, DTC status and data_id were
// each found separately, which is three times too many for one mistake.
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
	body := if t.starts_with('0x') || t.starts_with('0X') { t[2..] } else { return t.u64() > 0
			|| t.trim_space() == '0' }
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
pub const adapters = ['virtual', 'vcan', 'socketcan', 'udp', 'pcan', 'kvaser', 'doip']

// compose_iface builds the internal scheme string `transport.open()` consumes from an
// adapter + its backend-specific address. It is the inverse of decompose_iface.
//   virtual  CAN1            -> inproc:CAN1   (bare `inproc` if address empty)
//   vcan     vcan0           -> vcan0         (raw; SocketCAN backend)
//   socketcan can0           -> can0          (raw; SocketCAN backend)
//   udp      239.0.0.1:5000  -> udp:239.0.0.1:5000  (bare `udp` if empty)
//   pcan     PCAN_USBBUS1    -> pcan:PCAN_USBBUS1
//   kvaser   0               -> kvaser:0
//   doip     127.0.0.1:13400 -> doip:127.0.0.1:13400 (bare `doip` if empty)
pub fn compose_iface(adapter string, address string) string {
	a := address.trim_space()
	return match adapter {
		'virtual' { if a == '' { 'inproc' } else { 'inproc:${a}' } }
		'udp' { if a == '' { 'udp' } else { 'udp:${a}' } }
		'pcan' { 'pcan:${a}' }
		'kvaser' { 'kvaser:${a}' }
		'doip' { if a == '' { 'doip' } else { 'doip:${a}' } }
		// vcan / socketcan / unknown: the address IS the raw interface name.
		else { a }
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
	if s.starts_with('kvaser:') {
		return 'kvaser', s['kvaser:'.len..].all_before('@')
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
