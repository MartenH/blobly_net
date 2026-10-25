module transport

// every receive whose carrier is gone says so by its type, its text unchanged
fn test_a_receive_whose_carrier_is_gone_is_typed() {
	mut closed := open_inproc('T-gone') or { panic(err) }
	closed.close()
	mut buses := [Bus(closed), Bus(UnopenedBus{})]
	$if linux {
		// a socket the kernel fails under the reader (here a descriptor that is not open), as a
		// link gone down fails it
		buses << Bus(&SocketCanBus{
			iface: 'vcan0'
			fd:    1 << 20
		})
	}
	for mut b in buses {
		for timeout in [0, 50] {
			b.recv(timeout) or {
				assert err is CarrierGone, err.msg()
				continue
			}
			assert false, 'a receive on a gone carrier delivered a frame'
		}
	}
	// and a timeout is not one
	mut quiet := open_inproc('T-gone-quiet') or { panic(err) }
	defer {
		quiet.close()
	}
	quiet.recv(0) or {
		assert err !is CarrierGone
		assert err.msg() == 'timeout'
		return
	}
	assert false, 'a quiet bus delivered a frame'
}
