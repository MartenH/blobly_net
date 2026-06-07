// project — CANTester project / configuration files (`.yml`).
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

// Channel is one bus the tester attaches to.
pub struct Channel {
pub mut:
	name         string = 'CAN'
	typ          string = 'can' // yaml `type`: can | canfd
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
	replay       ?Replay
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

// parse decodes a project `.yml` document.
pub fn parse(text string) !Project {
	doc := yaml.parse_text(text)!
	mut p := Project{}
	pj := doc.value('project')
	p.name = pj.value('name').default_to('untitled').string()
	p.version = pj.value('version').default_to(i64(1)).int()
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
// a single vcan0 monitor channel decoding dbc/cantester.dbc.
pub fn default_project() Project {
	return Project{
		name:     'default'
		channels: [
			Channel{
				name:      'CAN1'
				iface:     'vcan0'
				databases: ['dbc/cantester.dbc']
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
	if dbs := c.value_opt('databases') {
		ch.databases = dbs.array().as_strings()
	}
	if sim := c.value_opt('simulate') {
		ch.simulate = sim.array().as_strings()
	}
	if ns := c.value_opt('nodes') {
		for n in ns.array() {
			ch.nodes << parse_node(n)
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
	mut node := NodeCfg{
		name: n.value('name').string()
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
