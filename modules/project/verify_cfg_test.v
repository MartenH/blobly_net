module project

// A channel's `verify:` must survive load → save → load. Dropped on save, the checks on the ECU
// under test silently disappear the first time the project is written.
fn test_channel_verify_round_trips() {
	y := 'project:
  name: t
channels:
  - name: CAN1
    interface: can0
    verify:
      - { message: EcuStatus, counter: AliveCounter, crc: CRC, profile: crc8_j1850, data_id: 7 }
      - { message: Other, counter: Cnt }
'
	p := parse(y) or { panic(err) }
	v := p.channels[0].verify
	assert v.len == 2
	assert v[0].message == 'EcuStatus' && v[0].crc == 'CRC'
	assert v[0].data_id or { u32(999) } == 7
	assert v[1].crc == '' && v[1].counter == 'Cnt'

	again := parse(p.to_yaml()) or { panic('saved project cannot be reopened: ${err}') }
	w := again.channels[0].verify
	assert w.len == 2, 'verify: dropped on save'
	assert w[0].message == 'EcuStatus' && w[0].crc == 'CRC' && w[0].profile == 'crc8_j1850'
	assert w[0].data_id or { u32(999) } == 7
	assert w[1].counter == 'Cnt'
}
