module flash

import sync.stdatomic
import blobly.isotp
import crypto.ed25519 as ed

// bootsim — a simulated blobly_emb bootloader, to rehearse a flash with no board: the session
// `program` runs, answered on an ISO-TP channel by the rules of blobly_emb's boot/prog.v for what
// it serves — the programming session (0x10 02) gating 0x29, 0x31 and 0x34, a session change or a
// reset relocking it, 0x29 a one-shot challenge whose proof is verified against the dev tester key,
// a download only after an erase and its blocks in sequence within the size 0x34 asked for, the
// check routine refused while a download is open and passing only for a header that is BLBT,
// version 1, 64 bytes, a body of at most 16 MiB, its own CRC right and the body's CRC as it states, and a suppressed
// positive answer withheld. Its own: 64-byte blocks, and an erase answered at once. Nothing is
// written anywhere; what it was sent is counted (BootReport).

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
	ch      isotp.Channel
	stop    chan bool
	t       thread
	rep     BootReport
	stopped bool
	halt    i64 // set by stop: the channel's waits end
	// the session, as boot/prog.v keeps it
	session     u8 = 0x01
	unlocked    bool
	challenge   bool // a challenge was given and not yet answered
	erased      bool
	downloading bool
	dl_size     int
	next        u8
	got         []u8
}

// max_image_len is the longest body blobly_emb's check accepts (boot/boot.v).
const max_image_len = 0x0100_0000

// boot_challenge is the challenge the simulated bootloader signs against.
const boot_challenge = []u8{len: 32, init: u8(0xA0 + index)}

// start_boot_sim serves `ch` (requests in, answers out) as a blobly_emb bootloader until stop.
pub fn start_boot_sim(ch isotp.Channel) &BootSim {
	mut b := &BootSim{
		ch:   ch
		stop: chan bool{cap: 1}
	}
	halt := &b.halt
	if mut b.ch is isotp.SoftChannel {
		b.ch.stop_requested = fn [halt] () bool {
			return stdatomic.load_i64(halt) != 0
		}
	}
	b.t = spawn serve_boot(mut b)
	return b
}

// stop ends the serving thread and closes the channel, once; it answers what the bootloader was
// asked.
pub fn (mut b BootSim) stop() BootReport {
	if !b.stopped {
		b.stopped = true
		stdatomic.store_i64(&b.halt, 1)
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
		a := b.answer(req, public)
		if a.len > 0 {
			b.ch.send(a) or {}
		}
	}
}

// relock ends what a session holds: a session change and a reset both do.
fn (mut b BootSim) relock() {
	b.unlocked = false
	b.challenge = false
	b.erased = false
	b.downloading = false
}

fn be32_at(r []u8, off int) u32 {
	return u32(r[off]) << 24 | u32(r[off + 1]) << 16 | u32(r[off + 2]) << 8 | u32(r[off + 3])
}

// header_ok is boot/prog.v's check_and_mark over what the download was sent: the header, then the
// body its length and CRC state.
fn (b &BootSim) header_ok() bool {
	g := b.got
	if g.len < hdr_size || rd32(g, 0) != boot_magic || g[4] != 1 || g[5] != 0
		|| rd32(g, 20) != u32(hdr_size) {
		return false
	}
	n := int(rd32(g, 8))
	if n == 0 || n > max_image_len || g.len < hdr_size + n || crc32(g[..28]) != rd32(g, 28) {
		return false
	}
	return crc32(g[hdr_size..hdr_size + n]) == rd32(g, 12)
}

// answer is the bootloader's answer to `req`, empty for a suppressed positive one.
fn (mut b BootSim) answer(req []u8, public ed.PublicKey) []u8 {
	nrc := fn [req] (code u8) []u8 {
		return [u8(0x7F), req[0], code]
	}
	programming := b.session == 0x02
	match req[0] {
		0x10 {
			if req.len != 2 {
				return nrc(0x13)
			}
			s := req[1] & 0x7F
			if s != 0x01 && s != 0x02 {
				return nrc(0x12)
			}
			b.relock()
			b.session = s
			return if req[1] & 0x80 != 0 { []u8{} } else { [u8(0x50), s, 0x00, 0x32, 0x01, 0xF4] }
		}
		0x29 {
			if req.len < 2 {
				return nrc(0x13)
			}
			if !programming {
				return nrc(0x22)
			}
			match req[1] {
				0x01 {
					b.challenge = true
					mut r := [u8(0x69), 0x01]
					r << boot_challenge
					return r
				}
				0x02 {
					if !b.challenge {
						return nrc(0x24)
					}
					if req.len < 2 + 64 {
						return nrc(0x13)
					}
					b.challenge = false // one-shot: a fresh challenge per attempt
					ok := ed.verify(public, boot_challenge, req[2..2 + 64]) or { false }
					b.rep.authenticated = ok
					if !ok {
						return nrc(0x35) // an unlock already earned stands
					}
					b.unlocked = true
					return [u8(0x69), 0x02]
				}
				else {
					return nrc(0x31)
				}
			}
		}
		0x31 {
			if req.len < 4 {
				return nrc(0x13)
			}
			if req[1] != 0x01 {
				return nrc(0x31)
			}
			if !programming || !b.unlocked {
				return nrc(0x33)
			}
			rid := u16(req[2]) << 8 | u16(req[3])
			if rid == 0xFF00 {
				if req.len < 12 || be32_at(req, 8) == 0 {
					return nrc(if req.len < 12 { u8(0x13) } else { u8(0x31) })
				}
				b.erased = true
				b.downloading = false
				b.got = []u8{} // the slot is blank
				b.rep.erases++
				return [u8(0x71), 0x01, 0xFF, 0x00, 0x00]
			}
			if rid == 0xFF01 {
				if b.downloading {
					return nrc(0x24)
				}
				ok := b.header_ok()
				b.rep.checks++
				b.rep.verified = ok
				return [u8(0x71), 0x01, 0xFF, 0x01, if ok { u8(0) } else { u8(1) }]
			}
			return nrc(0x31)
		}
		0x34 {
			if req.len < 11 {
				return nrc(0x13)
			}
			if !programming || !b.unlocked {
				return nrc(0x33)
			}
			if !b.erased {
				return nrc(0x24)
			}
			size := be32_at(req, 7)
			if req[1] != 0x00 || req[2] != 0x44 || size == 0 || be32_at(req, 3) % 32 != 0 {
				return nrc(0x31)
			}
			b.got = []u8{} // a download starts the slot over
			b.downloading = true
			b.dl_size = int(size)
			b.next = 1
			return [u8(0x74), 0x20, 0x00, 0x42] // 64-byte blocks
		}
		0x36 {
			if !b.downloading {
				return nrc(0x24)
			}
			if req.len < 2 {
				return nrc(0x13)
			}
			if req[1] != b.next {
				return nrc(0x73)
			}
			n := req.len - 2
			if n == 0 || n > 64 {
				return nrc(0x13)
			}
			if b.got.len + n > b.dl_size {
				return nrc(0x31)
			}
			b.got << req[2..]
			b.next++
			b.rep.blocks++
			return [u8(0x76), req[1]]
		}
		0x37 {
			if !b.downloading {
				return nrc(0x24)
			}
			b.downloading = false
			return [u8(0x77)]
		}
		0x11 {
			if req.len < 2 {
				return nrc(0x13)
			}
			b.rep.resets++
			b.relock() // the reset: what the session held is gone
			b.session = 0x01
			return if req[1] & 0x80 != 0 { []u8{} } else { [u8(0x51), req[1] & 0x7F] }
		}
		else {
			return nrc(0x11)
		}
	}
}
