// cansub_smoke — prove a CANsub is on the wire, end to end, against real hardware.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/cansub_smoke/smoke.v <device-id> [tx-ch] [rx-ch]
//   v ... run cmd/cansub_smoke/smoke.v e5a16adf 1 2
//
// It configures nothing destructive: it reads the device's identity over REST, opens the transmit
// and receive channels' WebSockets, sends a handful of frames on one and requires them to arrive
// on the other. That needs the two channels WIRED TOGETHER — which is the point. A loopback pair
// is the only way to check the transmit path without a second tool on the bus, and the only way to
// prove the codec against a real controller rather than against the vendor's test vectors, which
// `modules/transport/cansub_codec_test.v` already does with no hardware at all.
//
// What it is really testing is the seam: TLS to a device with its own certificate, the WebSocket
// upgrade, HDLC on the way out, HDLC on the way back, and the identity of a frame surviving the
// round trip. Everything above that seam is unit-tested; nothing below it can be.
module main

import os
import time
import transport

fn main() {
	args := os.args[1..].filter(!it.starts_with('-'))
	if args.len == 0 {
		eprintln('usage: cansub_smoke <device-id> [tx-channel] [rx-channel] [rate]')
		eprintln('  e.g. cansub_smoke e5a16adf 1 2   (channels 1 and 2 wired together)')
		exit(2)
	}
	id := args[0]
	tx_ch := if args.len > 1 { args[1].int() } else { 1 }
	rx_ch := if args.len > 2 { args[2].int() } else { 2 }
	rate := if args.len > 3 { args[3] } else { '250000' } // the device's factory nominal rate
	if tx_ch == rx_ch {
		// BOTH OPENS WOULD RESOLVE TO ONE CONNECTION. shared_open keys on the wire, the vendor
		// permits one client per channel, and the device deliberately echoes its own sends as TX
		// acknowledgements — which `recv` hands up like any other record. So a same-channel run
		// would count the sender's own echo as the expected receive and report a successful
		// channel-to-channel round trip while proving nothing about a cable (codex round 3 on
		// #204). The one result this tool exists to give would be the one it cannot give.
		eprintln('tx-channel and rx-channel must differ: this proves two channels are WIRED')
		eprintln('  together, and on one channel the device echo of the send would be counted')
		eprintln('  as the receive.')
		exit(2)
	}
	host := '${id}-usb.local'

	// The device is addressed by its ID through mDNS, never by an IP. A firmware update clears
	// persistent data and the device comes back on a different subnet — observed going from
	// 10.63.38.1 to 10.215.129.1 across 02.03.00 -> 02.04.00 — so an address written down
	// anywhere is one reboot from being wrong, while the name follows it.
	println('device: ${host}  tx=ch${tx_ch}  rx=ch${rx_ch}')

	info := rest(host, '/api/info') or {
		eprintln('cannot reach ${host}: ${err}')
		eprintln('  is it plugged in? does ${host} resolve?')
		exit(1)
	}
	println('  info    ${info}')
	println('  version ${rest(host, '/api/version') or { '?' }}')
	println('  channels ${rest(host, '/api/can') or { '?' }}')

	// Through transport.open(), not the WebSocket directly: that is the path the app uses, so it
	// is the path worth proving. It carries the REST configuration, the shared registry that
	// gives one channel one connection however many times it is opened, and the listen-only
	// wrapper every emitter in this process goes through.
	rx_iface := 'cansub:${id}/${rx_ch}@${rate}'
	tx_iface := 'cansub:${id}/${tx_ch}@${rate}'

	// The receiver first: connecting the WebSocket is what opens the CAN channel, so a receiver
	// opened after the sender misses the frames it is meant to catch.
	mut rx := transport.open(rx_iface) or {
		eprintln('cannot open ${rx_iface}: ${err}')
		exit(1)
	}
	defer { rx.close() }
	mut tx := transport.open(tx_iface) or {
		eprintln('cannot open ${tx_iface}: ${err}')
		exit(1)
	}
	defer { tx.close() }
	println('  both channels open  (${rx_iface}, ${tx_iface})')

	// One channel, opened twice, must be ONE connection — the device permits a single client per
	// channel WebSocket, and the app opens each wire several times per Start.
	mut second := transport.open(tx_iface) or {
		eprintln('a second open of ${tx_iface} was refused: ${err}')
		eprintln('  the shared registry should have handed back the first connection')
		exit(1)
	}
	println('  a second open of ch${tx_ch} shared the first connection')
	second.close()

	mut sent := [
		transport.CanFrame{
			id:   0x123
			data: [u8(0xDE), 0xAD, 0xBE, 0xEF]
		},
		transport.CanFrame{
			id:       0x1ABCDEF
			extended: true
			data:     [u8(1), 2, 3, 4, 5, 6, 7, 8]
		},
		transport.CanFrame{
			id:   0x7FF
			data: [u8(0x7E), 0x7D, 0x7E, 0x7D] // bytes that collide with the framing
		},
	]
	// CAN-FD only when the address asked for it — the data rate IS the request, so there is
	// nothing else to check and no way for the two to disagree. 64 bytes with the bit-rate switch
	// set is the case that exercises the data phase; a DLC of 15 is the only way to say 64.
	if rate.contains('/') {
		sent << transport.CanFrame{
			id:   0x200
			fd:   true
			brs:  true
			data: []u8{len: 64, init: u8(index)}
		}
		sent << transport.CanFrame{
			id:   0x201
			fd:   true
			data: [u8(0xAA), 0xBB, 0xCC] // FD without the rate switch is a real configuration too
		}
	}
	for f in sent {
		tx.send(f) or {
			eprintln('send ${describe(f)}: ${err}')
			exit(1)
		}
		println('  TX ch${tx_ch}  ${describe(f)}')
	}

	mut got := []transport.CanFrame{}
	for _ in 0 .. sent.len {
		f := rx.recv(1500) or { break }
		println('  RX ch${rx_ch}  ${describe(f)}')
		got << f
	}
	println('  health tx=${transport.health_name(tx.health())} rx=${transport.health_name(rx.health())}')

	mut missing := 0
	for f in sent {
		// THE FD FLAGS TOO. One case here exists precisely to show that an FD frame WITHOUT
		// bit-rate switching survives the path — and matched on id, width and payload alone, that
		// case passed when the frame came back CLASSIC, which is the silent downgrade the whole
		// backend refuses to make anywhere else (codex round 4 on #204).
		if !got.any(it.id == f.id && it.extended == f.extended && it.data == f.data && it.fd == f.fd
			&& it.brs == f.brs) {
			eprintln('  MISSING: ${describe(f)}')
			missing++
		}
	}
	if missing > 0 {
		eprintln('FAIL: ${missing}/${sent.len} frames did not arrive on ch${rx_ch}')
		eprintln('  are ch${tx_ch} and ch${rx_ch} wired together, and terminated?')
		exit(1)
	}
	println('OK: all ${sent.len} frames made the round trip ch${tx_ch} -> ch${rx_ch}')
}

fn describe(f transport.CanFrame) string {
	mut s := if f.extended { '0x${f.id:08X}' } else { '0x${f.id:03X}' }
	if f.fd {
		s += ' FD'
	}
	if f.brs {
		s += ' BRS'
	}
	if f.rtr {
		return s + ' RTR'
	}
	return s + ' [${f.data.len}] ${f.data.hex()}'
}

// rest goes through transport's own client, not V's. `net.http` cannot read this device at all:
// the status line carries no reason phrase, V's parser demands three tokens, and every request
// fails with "expected at least 3 tokens, but found: 2" after reading to the close.
// modules/transport/cansub_http.v has the captured bytes and the reasoning.
fn rest(host string, path string) !string {
	return transport.cansub_get(host, path)
}
