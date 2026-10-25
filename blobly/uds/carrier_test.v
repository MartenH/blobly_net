module uds

import blobly.doip
import blobly.isotp
import blobly.transport

// GoneChannel answers the pre-send drain's look with `err` every time, as a carrier that has
// failed does: whatever is asked of it, the same error.
struct GoneChannel {
	iface string = 'gone'
	tx_id u32
	rx_id u32
mut:
	err   IError
	sends int
}

fn (mut g GoneChannel) send(_ []u8) ! {
	g.sends++
}

fn (mut g GoneChannel) recv(_ int) ![]u8 {
	return g.err
}

fn (mut g GoneChannel) close() {}

fn (mut g GoneChannel) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

// a carrier gone ends the drain at once as the carrier's error, whatever its text: each carrier's
// own words, none of which the drain matches
fn test_a_carrier_gone_ends_the_drain_by_its_type() {
	for text in ['recv on vcan0: Network is down', 'recv failed on vcan0',
		'isotp recv failed on vcan0', '${doip.doip_connection_lost}DoIP: connection closed mid-message',
		'some backend: the device went away'] {
		mut g := &GoneChannel{
			err: transport.carrier_gone(text)
		}
		mut c := new_client(g)
		c.raw([u8(0x22), 0xF1, 0x90]) or {
			assert err is CarrierFailed, '${text}: ${err.msg()}'
			assert err.msg() == text
			k := failure_of(err)
			assert k == if text.starts_with(doip.doip_connection_lost) { Failure.lost } else { Failure.carrier }
			assert g.sends == 0, 'a request went out on a carrier that had failed'
			continue
		}
		assert false, '${text}: answered'
	}
}

// an untyped error is one PDU taken off the channel: counted, and a channel never seen empty is
// refused as not quiet rather than called the carrier's failure
fn test_an_untyped_drain_error_is_still_a_pdu() {
	mut g := &GoneChannel{
		err: error('ISO-TP: unexpected PCI 0x40')
	}
	mut c := new_client(g)
	c.raw([u8(0x22), 0xF1, 0x90]) or {
		assert err !is CarrierFailed
		assert err.msg().contains('not quiet'), err.msg()
		return
	}
	assert false, 'answered'
}

// the real carriers the drain meets: the software ISO-TP over a closed bus, over a bus never
// opened, and a channel never opened, each failing the request as CarrierFailed
fn test_the_software_channel_hands_the_drain_its_buses_failure_by_type() {
	mut ch := isotp.open_software('inproc:uds-gone-drain', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.close()
	mut channels := [isotp.Channel(ch), isotp.on_bus(transport.UnopenedBus{}, 'unopened',
		0x7E0, 0x7E8, false) or { panic(err) }, isotp.UnopenedChannel{}]
	for mut chan in channels {
		mut c := new_client(chan)
		c.raw([u8(0x22), 0xF1, 0x90]) or {
			assert err is CarrierFailed, err.msg()
			assert failure_of(err) == .carrier
			continue
		}
		assert false, 'answered'
	}
}

// the functional request's tap drain: a tap over a closed bus is the listener failing, not a quiet
// tap the targets are then judged against
fn test_the_functional_tap_drain_does_not_swallow_a_failure() {
	bus := 'inproc:FUNC-GONE-TAP'
	targets := [
		FunctionalTarget{
			client: &Client{
				ch: isotp.open_software(bus, 0x7E0, 0x7E8, false) or { panic(err) }
			}
			rsp_id: 0x7E8
		},
	]
	mut fch := isotp.Channel(isotp.open_software(bus, 0x7DF, 0x7DE, false) or { panic(err) })
	mut tap := transport.open(bus) or { panic(err) }
	tap.close()
	functional(mut fch, mut tap, targets, [u8(0x3E), 0x00], 100) or {
		assert err is CarrierFailed, err.msg()
		assert err.msg().contains('functional listener failed'), err.msg()
		return
	}
	assert false, 'a functional request went out over a closed tap'
}
