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
      - dbc/blobly_net.dbc
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
	assert c.databases == ['dbc/blobly_net.dbc']
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
	assert p.channels[0].databases == ['dbc/blobly_net.dbc']
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

const senders_sample = '
project:
  name: senders
channels:
  - name: CAN1
    interface: inproc:CAN1
    senders:
      - name: Ignition On
        key: i
        message: Powertrain
        trigger: key
        signals:
          - { name: EngineSpeed, value: 800 }
          - { name: Gear, value: 1 }
      - name: Wake pulse
        id: "0x123"
        data: DE AD BE EF
        trigger: cyclic
        cycle_ms: 100
'

fn test_parse_senders() {
	p := parse(senders_sample) or { panic(err) }
	c := p.channels[0]
	assert c.senders.len == 2

	s0 := c.senders[0]
	assert s0.name == 'Ignition On'
	assert s0.key == 'i'
	assert s0.message == 'Powertrain'
	assert s0.trigger == 'key'
	assert s0.signals.len == 2
	assert s0.signals[0].name == 'EngineSpeed'
	assert s0.signals[0].value == 800.0
	assert s0.signals[1].name == 'Gear'
	assert s0.signals[1].value == 1.0

	s1 := c.senders[1]
	assert s1.name == 'Wake pulse'
	assert s1.id == 0x123
	assert s1.data == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert s1.trigger == 'cyclic'
	assert s1.cycle_ms == 100
}

fn test_sender_defaults() {
	p := parse('project:\n  name: d\nchannels:\n  - name: CAN1\n    senders:\n      - name: Bare\n') or {
		panic(err)
	}
	s := p.channels[0].senders[0]
	assert s.name == 'Bare'
	assert s.trigger == 'manual' // default
	assert s.key == ''
	assert s.signals.len == 0
}

fn test_parse_hex_bytes() {
	assert parse_hex_bytes('DEADBEEF') == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert parse_hex_bytes('DE AD BE EF') == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert parse_hex_bytes('de:ad') == [u8(0xDE), 0xAD]
	assert parse_hex_bytes('') == []u8{}
	assert parse_hex_bytes('AABBC') == [u8(0xAA), 0xBB] // odd trailing nibble dropped
}
