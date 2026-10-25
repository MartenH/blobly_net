module transport

// Every refusal made before the driver is asked is NotWritten, the type the hub, the send
// watches, the GUI's trace and its transmit-tap health poll read (#350).

fn test_inproc_refuses_impossible_frames_as_not_written() {
	mut b := open('inproc:nw-shape')!
	defer {
		b.close()
	}
	for f in [CanFrame{
		id:  0x123
		brs: true
	}, CanFrame{
		id:   0x123
		data: []u8{len: 9}
	}, CanFrame{
		id:  0x800
	}, CanFrame{
		id:  0x123
		rtr: true
	}] {
		b.send(f) or {
			assert err is NotWritten, err.msg()
			assert err.msg().starts_with('inproc: ')
			continue
		}
		assert false, 'sent ${f}'
	}
	b.send(CanFrame{ id: 0x123, data: [u8(1)] })!
}

fn test_a_listen_only_refusal_is_not_written() {
	set_listen_only('inproc:nw-silent', true)
	defer {
		clear_listen_only()
	}
	mut b := open('inproc:nw-silent')!
	defer {
		b.close()
	}
	b.send(CanFrame{ id: 0x123 }) or {
		assert err is NotWritten, err.msg()
		assert err.msg().contains('listen-only')
		assert refused_for_certain(err)
		return
	}
	assert false, 'a listen-only wire transmitted'
}

fn test_socketcan_refuses_an_impossible_frame_as_not_written() {
	mut b := open('vcan0') or { return } // no vcan here
	defer {
		b.close()
	}
	b.send(CanFrame{ id: 0x123, brs: true }) or {
		assert err is NotWritten, err.msg()
		return
	}
	assert false, 'brs without fd was sent'
}

fn test_refused_for_certain_is_not_written_or_a_full_queue() {
	assert refused_for_certain(not_written('x'))
	assert refused_for_certain(busy_error('PCAN', 0x10))
	assert !refused_for_certain(error('canWrite failed (canStatus -1)'))
	assert !refused_for_certain(carrier_gone('gone'))
}
