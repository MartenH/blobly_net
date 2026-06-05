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
	replay       ?Replay
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
