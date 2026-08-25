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
import net.websocket
import transport

fn main() {
	args := os.args[1..].filter(!it.starts_with('-'))
	if args.len == 0 {
		eprintln('usage: cansub_smoke <device-id> [tx-channel] [rx-channel]')
		eprintln('  e.g. cansub_smoke e5a16adf 1 2   (channels 1 and 2 wired together)')
		exit(2)
	}
	id := args[0]
	tx_ch := if args.len > 1 { args[1].int() } else { 1 }
	rx_ch := if args.len > 2 { args[2].int() } else { 2 }
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

	// The receiver first. Announcements are not queued for a listener that is not there yet, and
	// opening the bus is what connecting the WebSocket DOES — so a receiver opened after the
	// sender would miss the frames it is meant to catch.
	//
	// A FINITE read timeout, deliberately. The default is infinite, and `drain` below reads until
	// a read fails — on an idle bus that is a hang, not a result. The timeout is what turns "no
	// more frames" into an answer.
	mut rx := websocket.new_client('wss://${host}/api/can/${rx_ch}/ws',
		read_timeout: 1 * time.second
	)!
	rx.connect() or {
		eprintln('cannot open ch${rx_ch}: ${err}')
		exit(1)
	}
	time.sleep(300 * time.millisecond)

	mut tx := websocket.new_client('wss://${host}/api/can/${tx_ch}/ws')!
	tx.connect() or {
		eprintln('cannot open ch${tx_ch}: ${err}')
		exit(1)
	}
	println('  both channels open')

	sent := [
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
	for f in sent {
		body := transport.cansub_encode_frame(f)!
		tx.write(transport.cansub_hdlc_wrap(body), .binary_frame)!
		println('  TX ch${tx_ch}  ${describe(f)}')
		time.sleep(50 * time.millisecond)
	}

	// Collect for a moment, then report. The receive side runs its own decoder because an HDLC
	// frame is not guaranteed to align with a WebSocket message.
	time.sleep(700 * time.millisecond)
	mut dec := transport.CansubDecoder{}
	mut got := []transport.CanFrame{}
	for msg in drain(mut rx) {
		for rec in dec.feed(msg) {
			if rec.is_error {
				println('  RX ch${rx_ch}  bus error: ${rec.err}')
				continue
			}
			tag := if rec.tx { 'TX-ack' } else { 'RX' }
			println('  ${tag} ch${rx_ch}  ${describe(rec.frame)}  t=${rec.us}us')
			if !rec.tx {
				got << rec.frame
			}
		}
	}
	for e in dec.errors {
		eprintln('  decoder: ${e}')
	}

	rx.close(1000, 'done') or {}
	tx.close(1000, 'done') or {}

	mut missing := 0
	for f in sent {
		if !got.any(it.id == f.id && it.extended == f.extended && it.data == f.data) {
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

// drain takes whatever the receiver has buffered and stops when the reads dry up.
//
// It reads directly rather than running `listen()` in a thread: listen() is itself a loop over
// read_next_message dispatching to handlers, so doing both puts two readers on one socket and they
// take each other's frames. One reader, and the client's read timeout ends it.
fn drain(mut rx websocket.Client) [][]u8 {
	mut out := [][]u8{}
	for out.len < 4096 {
		msg := rx.read_next_message() or { break } // a timeout here means the bus went quiet
		if msg.opcode == .binary_frame {
			out << msg.payload
		}
	}
	return out
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
