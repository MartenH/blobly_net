module flash

import blobly.isotp
import crypto.ed25519 as ed

// bootsim — a simulated blobly_emb bootloader, to rehearse a flash with no board: the session
// `program` runs, answered on an ISO-TP channel and strict where a real one is — 0x29 verifies
// the proof against the dev tester key, erase is refused until it has, the download gives 64-byte
// blocks and the check routine answers from the CRC the image header states over the bytes it was
// sent, a download taking its blocks in sequence after 0x34. Nothing is written anywhere; what it
// was sent is counted (BootReport).

// BootReport is what a simulated bootloader was asked to do, read once it is stopped.
pub struct BootReport {
pub mut:
	authenticated bool // the last 0x29 proof verified
	erases        int  // 0x31 FF00 requests answered
	blocks        int  // 0x36 blocks taken
	image         []u8 // what the last download was sent, header included
	checks        int  // 0x31 FF01 requests answered
	verified      bool // the last check routine passed
	resets        int  // 0x11 requests answered
}

// BootSim is a simulated bootloader serving its channel on a thread of its own until stopped.
@[heap]
pub struct BootSim {
mut:
	ch     isotp.Channel
	stop   chan bool
	t      thread
	rep    BootReport
	got     []u8
	authed  bool
	stopped bool
	next    int = -1 // the block counter the download in progress expects; -1: none in progress
}

// boot_challenge is the challenge the simulated bootloader signs against.
const boot_challenge = []u8{len: 32, init: u8(0xA0 + index)}

// start_boot_sim serves `ch` (requests in, answers out) as a blobly_emb bootloader until stop.
pub fn start_boot_sim(ch isotp.Channel) &BootSim {
	mut b := &BootSim{
		ch:   ch
		stop: chan bool{cap: 1}
	}
	b.t = spawn serve_boot(mut b)
	return b
}

// stop ends the serving thread and closes the channel, once; it answers what the bootloader was
// asked.
pub fn (mut b BootSim) stop() BootReport {
	if !b.stopped {
		b.stopped = true
		b.stop <- true
		b.t.wait()
		b.rep.image = b.got.clone()
	}
	return b.rep
}

fn rd32(b []u8, off int) u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

fn serve_boot(mut b BootSim) {
	public := ed.new_key_from_seed(tester_seed('') or { panic(err) }).public_key()
	for {
		select {
			_ := <-b.stop {
				b.ch.close()
				return
			}
			else {}
		}
		req := b.ch.recv(50) or { continue }
		if req.len == 0 {
			continue
		}
		b.ch.send(b.answer(req, public)) or {}
	}
}

// answer is the bootloader's answer to `req`.
fn (mut b BootSim) answer(req []u8, public ed.PublicKey) []u8 {
	nrc := fn [req] (code u8) []u8 {
		return [u8(0x7F), req[0], code]
	}
	match req[0] {
		0x10 {
			if req.len < 2 {
				return nrc(0x13)
			}
			return [u8(0x50), req[1], 0x00, 0x32, 0x01, 0xF4]
		}
		0x29 {
			if req.len < 2 {
				return nrc(0x13)
			}
			if req[1] == 0x01 {
				mut r := [u8(0x69), 0x01]
				r << boot_challenge
				return r
			}
			b.authed = req.len == 2 + 64 && (ed.verify(public, boot_challenge, req[2..]) or { false })
			b.rep.authenticated = b.authed
			return if b.authed { [u8(0x69), 0x02] } else { nrc(0x35) }
		}
		0x31 {
			if req.len < 4 {
				return nrc(0x13)
			}
			if !b.authed {
				return nrc(0x33)
			}
			if req[2] != 0xFF || req[3] > 0x01 {
				return nrc(0x31) // erase (FF00) and check (FF01) are its routines
			}
			mut result := u8(0)
			if req[3] == 0x00 {
				b.rep.erases++
			} else {
				// the header states the body length and its CRC
				n := if b.got.len >= hdr_size { int(rd32(b.got, 8)) } else { -1 }
				ok := n >= 0 && b.got.len >= hdr_size + n
					&& crc32(b.got[hdr_size..hdr_size + n]) == rd32(b.got, 12)
				if !ok {
					result = 1
				}
				b.rep.checks++
				b.rep.verified = ok
			}
			return [u8(0x71), 0x01, req[2], req[3], result]
		}
		0x34 {
			if !b.authed {
				return nrc(0x33)
			}
			b.got = []u8{} // a download starts the slot over
			b.next = 1
			return [u8(0x74), 0x20, 0x00, 0x42] // 64-byte blocks
		}
		0x36 {
			if b.next < 0 {
				return nrc(0x24) // requestSequenceError: no download in progress
			}
			if req.len < 2 {
				return nrc(0x13)
			}
			if int(req[1]) != b.next {
				return nrc(0x73) // wrongBlockSequenceCounter
			}
			b.next = (b.next + 1) & 0xFF
			b.got << req[2..]
			b.rep.blocks++
			return [u8(0x76), req[1]]
		}
		0x37 {
			if b.next < 0 {
				return nrc(0x24)
			}
			b.next = -1
			return [u8(0x77)]
		}
		0x11 {
			b.rep.resets++
			return [u8(0x51), if req.len > 1 { req[1] } else { u8(0x01) }]
		}
		else {
			return nrc(0x11)
		}
	}
}
