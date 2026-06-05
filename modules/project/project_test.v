module project

const sample = '
project:
  name: demo-bench
  version: 2
channels:
  - name: CAN1
    type: can
    interface: vcan0
    bitrate: 500000
    mode: monitor
    databases:
      - dbc/cantester.dbc
  - name: CAN2
    interface: vcan1
    bitrate: 250000
    mode: replay
    enabled: false
    listen_only: true
    timing:
      brp: 4
      tseg1: 13
      tseg2: 2
      sjw: 1
    replay:
      source: samples/demo.mf4
      speed: 2.0
      loop: true
'

fn test_parse_project_meta() {
	p := parse(sample) or { panic(err) }
	assert p.name == 'demo-bench'
	assert p.version == 2
	assert p.channels.len == 2
}

fn test_channel_one_defaults_and_db() {
	p := parse(sample) or { panic(err) }
	c := p.channels[0]
	assert c.name == 'CAN1'
	assert c.iface == 'vcan0'
	assert c.bitrate == 500000
	assert c.mode == .monitor
	assert c.enabled == true // default
	assert c.listen_only == false // default
	assert c.databases == ['dbc/cantester.dbc']
	assert c.replay == none
}

fn test_channel_two_full() {
	p := parse(sample) or { panic(err) }
	c := p.channels[1]
	assert c.iface == 'vcan1'
	assert c.bitrate == 250000
	assert c.mode == .replay
	assert c.enabled == false
	assert c.listen_only == true
	assert c.timing.brp == 4
	assert c.timing.tseg1 == 13
	r := c.replay or { panic('expected replay') }
	assert r.source == 'samples/demo.mf4'
	assert r.speed == 2.0
	assert r.repeat == true
}

fn test_default_project() {
	p := default_project()
	assert p.channels.len == 1
	assert p.channels[0].iface == 'vcan0'
	assert p.channels[0].mode == .monitor
	assert p.channels[0].databases == ['dbc/cantester.dbc']
}

fn test_mode_from_and_str() {
	assert mode_from('off') == .off
	assert mode_from('REPLAY') == .replay
	assert mode_from('nonsense') == .monitor
	assert Mode.monitor.str() == 'monitor'
}

fn test_empty_channels() {
	p := parse('project:\n  name: bare\n') or { panic(err) }
	assert p.name == 'bare'
	assert p.channels.len == 0
}
