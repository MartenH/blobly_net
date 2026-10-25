module isotp

import blobly.transport

// UnopenedChannel is the Channel a field holds before its channel is opened. V leaves an
// uninitialised interface field nil, and a read of it before the open crashes; this refuses
// instead, as transport.UnopenedBus does for a bus.
pub struct UnopenedChannel {
pub:
	iface string
	tx_id u32
	rx_id u32
}

// channel_not_open is the refusal an UnopenedChannel gives both ways.
pub const channel_not_open = 'ISO-TP channel is not open'

pub fn (mut c UnopenedChannel) send(_ []u8) ! {
	return error(channel_not_open)
}

pub fn (mut c UnopenedChannel) recv(_ int) ![]u8 {
	return transport.carrier_gone(channel_not_open)
}

pub fn (mut c UnopenedChannel) close() {}

pub fn (mut c UnopenedChannel) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}
