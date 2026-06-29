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
pub const schema_version = 1

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
}

// SenderSig is one signal value applied when building a Sender's frame: the
// signal `name` (must be a signal of the resolved message) set to `value`
// (physical units; encoded onto the payload via the DBC).
pub struct SenderSig {
pub mut:
	name  string
	value f64
}

// Sender is a declarative "interactive generator" (CANoe IG-style): a named,
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
	trigger  string = 'manual' // manual | key | cyclic
	cycle_ms int    // cyclic period (ms); only used when trigger == cyclic
}

// Channel is one bus the tester attaches to.
pub struct Channel {
pub mut:
	name         string = 'CAN'
	typ          string = 'can' // yaml `type`: can | canfd | doip
	iface        string = 'vcan0' // yaml `interface` (a V keyword, so the field is `iface`)
	bitrate      int    = 500000
	fd           bool
	data_bitrate int
	sample_point f64
	timing       Timing
	mode         Mode = .monitor
	listen_only  bool
	enabled      bool = true
	databases    []string
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
}

// is_doip reports whether this channel is a DoIP (diagnostics-over-Ethernet)
// endpoint rather than a CAN bus.
pub fn (ch Channel) is_doip() bool {
	return ch.typ == 'doip' || ch.iface.starts_with('doip:')
}

// doip_endpoint parses `iface` ("doip:host:port" / "doip:host" / "doip") into a
// host + port, defaulting to 127.0.0.1:13400. Only meaningful when is_doip().
pub fn (ch Channel) doip_endpoint() (string, int) {
	mut rest := ch.iface.trim_space()
	rest = if rest.starts_with('doip:') { rest['doip:'.len..] } else if rest == 'doip' { '' } else { rest }
	if rest == '' {
		return '127.0.0.1', 13400
	}
	// host may itself contain ':' (IPv6); split on the LAST colon for the port.
	if i := rest.last_index(':') {
		host := rest[..i]
		port := rest[i + 1..].int()
		return if host == '' { '127.0.0.1' } else { host }, if port == 0 { 13400 } else { port }
	}
	return rest, 13400
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
	if chs := doc.value_opt('channels') {
		for c in chs.array() {
			if c is yaml.Null {
				continue
			}
			p.channels << parse_channel(c)
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

fn parse_channel(c yaml.Any) Channel {
	mut ch := Channel{
		name:         c.value('name').default_to('CAN').string()
		typ:          c.value('type').default_to('can').string()
		iface:        c.value('interface').default_to('vcan0').string()
		bitrate:      c.value('bitrate').default_to(i64(500000)).int()
		fd:           c.value('fd').default_to(false).bool()
		data_bitrate: c.value('data_bitrate').default_to(i64(0)).int()
		sample_point: c.value('sample_point').default_to(f64(0)).f64()
		mode:         mode_from(c.value('mode').default_to('monitor').string())
		listen_only:  c.value('listen_only').default_to(false).bool()
		enabled:      c.value('enabled').default_to(true).bool()
	}
	if v := c.value_opt('tester_address') {
		ch.tester_addr = u16(parse_id(v.str()))
	}
	if v := c.value_opt('ecu_address') {
		ch.ecu_addr = u16(parse_id(v.str()))
	}
	if dbs := c.value_opt('databases') {
		ch.databases = dbs.array().as_strings()
	}
	if sim := c.value_opt('simulate') {
		ch.simulate = sim.array().as_strings()
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

// parse_id reads a CAN id written as decimal or `0x`-prefixed hex.
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
