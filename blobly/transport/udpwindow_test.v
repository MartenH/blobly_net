module transport

// The port rule itself, every branch.
fn test_listen_port_rule() {
	// no `from`: the request, or the default
	assert listen_port(0, '', none, 13400, 'entity')! == 13400
	assert listen_port(13555, '', none, 13400, 'entity')! == 13555
	// `from`: the channel's port, and a request that agrees is not a contradiction
	assert listen_port(0, 'Alt', 13555, 13400, 'entity')! == 13555
	assert listen_port(13555, 'Alt', 13555, 13400, 'entity')! == 13555
	// a request that disagrees is refused, naming both
	if p := listen_port(13400, 'Alt', 13555, 13400, 'entity') {
		assert false, 'accepted a contradicting port: ${p}'
	} else {
		assert err.msg().contains('contradicts')
		assert err.msg().contains('13400')
		assert err.msg().contains('13555')
	}
}
