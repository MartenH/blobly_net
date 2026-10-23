module isotp

import blobly.transport

fn ending_of_send(mut c SoftChannel, data []u8) Ending {
	c.send(data) or { return c.ending_of(err, true) }
	assert false, 'the send went through'
	return .failed
}

fn ending_of_recv(mut c SoftChannel, ms int) Ending {
	c.recv(ms) or { return c.ending_of(err, false) }
	assert false, 'a message came'
	return .failed
}

// silence both ways, a transfer kept for the next receive, a message refused, a stop, a frame
// that is not ISO-TP and a receiver's overflow: each its own ending
fn test_each_way_a_raw_send_or_receive_ends() {
	mut c := open_software('inproc:isotp-ending', 0x700, 0x708, false)!
	mut peer := transport.open('inproc:isotp-ending')!
	defer {
		c.close()
		peer.close()
	}
	c.fc_window_ms = 30
	assert ending_of_recv(mut c, 20) == .waited_out
	assert ending_of_send(mut c, []u8{len: 20, init: 0x11}) == .waited_out
	assert ending_of_send(mut c, []u8{}) == .refused
	assert ending_of_send(mut c, []u8{len: max_pdu + 1}) == .refused

	// a First Frame and nothing after it: kept past the deadline, then given up at N_Cr
	peer.send(transport.CanFrame{ id: 0x708, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] })!
	c.cr_window_ms = 60
	assert ending_of_recv(mut c, 30) == .waited_out
	assert ending_of_recv(mut c, 200) == .failed

	peer.send(transport.CanFrame{ id: 0x708, data: [u8(0x40), 0, 0, 0, 0, 0, 0, 0] })!
	assert ending_of_recv(mut c, 200) == .failed

	// a First Frame of ours answered with overflow (an earlier send's is still queued for the peer),
	// in a window wide enough for the peer's thread to be scheduled
	c.fc_window_ms = 2000
	spawn fn (mut peer transport.Bus) {
		for {
			f := peer.recv(500) or { return }
			if f.id == 0x700 && f.data[0] & 0xF0 == 0x10 && f.data[2] == 0x22 {
				peer.send(transport.CanFrame{ id: 0x708, data: [u8(0x32), 0, 0, 0, 0, 0, 0, 0] }) or {}
				return
			}
		}
	}(mut peer)
	assert ending_of_send(mut c, []u8{len: 20, init: 0x22}) == .failed

	c.stop_requested = fn () bool {
		return true
	}
	assert ending_of_recv(mut c, 200) == .abandoned
	assert ending_of_send(mut c, []u8{len: 20, init: 0x33}) == .abandoned
	// a stop after an orphan Flow Control was skipped is still the stop
	assert c.ending_of(error(orphan_note(abandoned_recv_note, 1, 0x30)), false) == .abandoned
	assert c.ending_of(error(orphan_note('timeout', 1, 0x30)), false) == .waited_out
}

// on a listen-only wire a send is refused, a Single Frame and a First Frame alike
fn test_a_listen_only_wire_refuses_the_send() {
	transport.set_listen_only('inproc:isotp-ending-silent', true)
	defer {
		transport.clear_listen_only()
	}
	mut c := open_software('inproc:isotp-ending-silent', 0x700, 0x708, false)!
	defer {
		c.close()
	}
	assert ending_of_send(mut c, [u8(0x3E), 0x00]) == .refused
	assert ending_of_send(mut c, []u8{len: 20}) == .refused
	// a receive whose Flow Control the wire refused failed: nothing of the caller's was refused
	assert c.ending_of(transport.not_written('${c.iface}: listen-only — nothing is transmitted on this wire'),
		false) == .failed
}
