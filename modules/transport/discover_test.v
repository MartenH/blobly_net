module transport

fn test_virtual_ifaces_present() {
	v := virtual_ifaces()
	assert v.len == 2
	assert v[0].kind == 'udp'
	assert v[0].virtual
	assert v[0].iface == 'udp:${udp_default_group}:${udp_default_port}'
	assert v[1].kind == 'inproc'
	assert v[1].virtual
}

fn test_channels_yaml_shape() {
	ifaces := [
		Iface{
			name:    'vcan0'
			iface:   'vcan0'
			kind:    'vcan'
			bitrate: 0
			virtual: false
		},
		Iface{
			name:    'can0'
			iface:   'can0'
			kind:    'can'
			bitrate: 500000
			virtual: false
		},
		Iface{
			name:    'UDP'
			iface:   'udp:239.63.42.1:20000'
			kind:    'udp'
			virtual: true
		},
	]
	y := channels_yaml(ifaces)
	assert y.starts_with('channels:\n')
	// real interfaces: enabled, monitor; can0 carries its bitrate, vcan omits it
	assert y.contains('  - name: vcan0\n')
	assert y.contains('    interface: vcan0\n')
	assert y.contains('    bitrate: 500000\n')
	assert !y.contains('    bitrate: 0\n')
	assert y.contains('    enabled: true\n')
	// virtual fallback: disabled, real connection string
	assert y.contains('    interface: udp:239.63.42.1:20000\n')
	assert y.contains('    enabled: false\n')
}
