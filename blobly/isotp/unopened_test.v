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
