module isotp

import blobly.transport

// An unopened channel refuses both directions, where a nil one would crash.
fn test_an_unopened_channel_refuses() {
	mut c := Channel(UnopenedChannel{})
	if _ := c.send([u8(0x22), 0xF1, 0x90]) {
		assert false, 'an unopened channel sent'
	}
	if _ := c.recv(0) {
		assert false, 'an unopened channel received'
	}
	assert c.diagnostics() == transport.BusDiagnostics{}
	c.close()
}

// a receive whose carrier is gone says so by its type: an unopened channel, the software channel
// over a closed bus, and the kernel socket failing under the reader
fn test_a_receive_whose_carrier_is_gone_is_typed() {
	mut sw := open_software('inproc:isotp-gone', 0x7E0, 0x7E8, false) or { panic(err) }
	sw.close()
	mut channels := [Channel(UnopenedChannel{}), Channel(sw)]
	$if linux {
		channels << Channel(&KernelChannel{
			iface: 'vcan0'
			fd:    1 << 20
		})
	}
	for mut ch in channels {
		for timeout in [0, 50] {
			ch.recv(timeout) or {
				assert err is transport.CarrierGone, err.msg()
				continue
			}
			assert false, 'a receive on a gone carrier delivered a PDU'
		}
	}
}
