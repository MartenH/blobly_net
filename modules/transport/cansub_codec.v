// What a CANsub says, in bytes.
//
// The CANsub.4 is not a vendor-DLL adapter like PCAN, Kvaser or Vector: it enumerates as a USB
// *network* adapter and speaks HTTP. Configuration is a REST API; frames go over a WebSocket, one
// per CAN channel. This file is the part that decides what those bytes MEAN, which is why it lives
// here and not in a front end — the GUI and any CLI tool would otherwise each have to interpret
// them, and that interpretation is exactly what a module is for.
//
// It is deliberately free of sockets. Everything below is a pure function or a state machine fed
// with bytes, so the whole wire format is testable with no device attached, and CI covers it. The
// vendor publishes 20 test vectors for precisely this purpose; `cansub_codec_test.v` pins every
// one of them.
//
// THE FRAMING. Each WebSocket binary message carries HDLC:
//
//     7E <payload, byte-stuffed> <CRC32, big-endian, also stuffed> 7E
//
// with `7E` -> `7D 5E` and `7D` -> `7D 5D`. Four properties of that framing are not obvious and
// each has a test vector behind it:
//
//   * an HDLC frame may be SPLIT across WebSocket messages (TV-10), so decoding cannot be
//     per-message — this is a streaming state machine, fed whatever arrives;
//   * a message may carry several HDLC frames (TV-12), back to back as `... 7E 7E ...`, the
//     closing boundary of one immediately followed by the opening boundary of the next;
//   * bytes outside a frame are garbage to be skipped, before the first frame (TV-13) and between
//     frames (TV-14). Neither is an error — resynchronising on `7E` is the whole point of a
//     boundary byte;
//   * a bad CRC (TV-15) or a truncated CAN frame (TV-18) costs you THAT frame and nothing more.
//     Frames already parsed out of the same HDLC payload are kept, and the next HDLC frame decodes
//     normally.
//
// THE PAYLOAD. One HDLC payload holds one or more serialised CAN frames, each:
//
//     bytes 0-5  48-bit big-endian timestamp, microseconds since 2025-01-01 UTC
//     byte  6    FDF(7) | RTR·BRS(6) | ESI(5) | TX(4) | DLC(3-0)
//     byte  7+   big-endian ID field: 2 bytes if IDE=0, 4 if IDE=1 — the field's MSB *is* IDE
//     then       the payload, DLC bytes (FD length codes above 8; none at all for a remote frame)
//
// Bit 6 is RTR on a classic frame and BRS on an FD one — the same bit, two meanings, chosen by
// FDF. Bit 5 is ESI except on an error frame, which is why an error frame is recognised by the
// whole top nibble (`b6 & 0xE0 == 0x20`) and not by bit 5 alone: an FD frame from an error-passive
// node sets bit 5 too, and testing that bit on its own would file it as a bus error (TV-06 against
// TV-19).
module transport

// cansub_epoch_us is the device's zero: 2025-01-01 00:00:00 UTC, in microseconds since the Unix
// epoch. Device timestamps are offsets from this, so a reader converts by adding it.
pub const cansub_epoch_us = u64(1735689600000000)

// CansubErr is what the controller reported, when a record is a bus error rather than a frame.
pub enum CansubErr {
	bit_err   = 0
	ack_err   = 1
	form_err  = 2
	stuff_err = 3
	crc_err   = 4
}

// CansubRecord is one thing the device told us: a frame, or an error the controller saw.
pub struct CansubRecord {
pub:
	// The frame, when `is_error` is false. Empty otherwise.
	frame CanFrame
	// A TRANSMIT ACKNOWLEDGEMENT rather than a received frame: the device confirming one of our
	// own sends reached the wire. Kept distinct because `wiretap` already exists to tell our
	// traffic from the ECU's, and a TX ack filed as an RX would be our own frame coming back as
	// somebody else's.
	tx bool
	// Microseconds since cansub_epoch_us, as the device stamped it. Sampled at start-of-frame for
	// both RX and TX acks (firmware 02.03.00 onward), so the two are comparable.
	us u64
	// The controller's verdict, when `is_error` is true.
	is_error bool
	err      CansubErr
}

// cansub_dlc_len is the payload length a DLC stands for. Above 8 the codes are FD-only and jump:
// `fd_lengths` already states them once for this module, and this indexes it rather than repeating
// the table.
pub fn cansub_dlc_len(dlc u8, fd bool) int {
	d := int(dlc) & 0x0F
	if !fd {
		return if d > 8 { 8 } else { d } // a classic frame never carries more than 8
	}
	return fd_lengths[d]
}

// cansub_len_dlc is the DLC for a payload length, for the transmit path. The length must be one
// CAN can express — `fd_padded_len` rounds to one — and this refuses rather than guesses.
pub fn cansub_len_dlc(n int, fd bool) !u8 {
	if !fd {
		if n > 8 {
			return error('${n} bytes needs an FD frame')
		}
		return u8(n)
	}
	for i, l in fd_lengths {
		if l == n {
			return u8(i)
		}
	}
	return error('${n} is not a CAN-FD payload length')
}

// cansub_crc32 is the IEEE 802.3 CRC32 the framing uses: reflected polynomial 0xEDB88320, all-ones
// initial value, all-ones final inversion — the same one zlib computes. Over the RAW payload, so
// it is calculated before stuffing and checked after unstuffing.
pub fn cansub_crc32(data []u8) u32 {
	mut crc := u32(0xFFFFFFFF)
	for b in data {
		crc ^= u32(b)
		for _ in 0 .. 8 {
			if crc & 1 != 0 {
				crc = (crc >> 1) ^ u32(0xEDB88320)
			} else {
				crc >>= 1
			}
		}
	}
	return crc ^ u32(0xFFFFFFFF)
}

// cansub_hdlc_wrap turns a raw payload into a complete HDLC frame, ready to be sent as one
// WebSocket binary message: boundaries, big-endian CRC32, and byte-stuffing over both the payload
// and the CRC (the CRC's own bytes can land on 0x7E or 0x7D — TV-17).
pub fn cansub_hdlc_wrap(payload []u8) []u8 {
	crc := cansub_crc32(payload)
	mut body := []u8{cap: payload.len + 4}
	body << payload
	body << u8(crc >> 24)
	body << u8(crc >> 16)
	body << u8(crc >> 8)
	body << u8(crc)
	mut out := []u8{cap: body.len + 8}
	out << 0x7E
	for b in body {
		match b {
			0x7E {
				out << 0x7D
				out << 0x5E
			}
			0x7D {
				out << 0x7D
				out << 0x5D
			}
			else {
				out << b
			}
		}
	}
	out << 0x7E
	return out
}

// cansub_encode_frame serialises one frame for transmission. The timestamp a client sends is not
// the device's to honour — it stamps what actually reaches the wire and reports that back in the
// TX acknowledgement — so this writes zero rather than inventing one.
pub fn cansub_encode_frame(f CanFrame) ![]u8 {
	// EVERY SHAPE RULE FIRST, from the one place that states them (frame_rules.v). This path used
	// to mask an oversized standard id down to eleven bits and drop `brs` from a classic frame,
	// both silently and both reported as success — so the device put a different frame on the wire
	// from the one wiretap recorded, and the echo of our own frame could never match it.
	if why := frame_shape_error(f) {
		return error('CANsub: ${why}')
	}
	dlen := if f.rtr && !f.fd { 0 } else { f.data.len }
	dlc := cansub_len_dlc(if f.rtr { f.data.len } else { dlen }, f.fd)!
	mut b6 := dlc & 0x0F
	if f.fd {
		b6 |= 0x80
		if f.brs {
			b6 |= 0x40
		}
	} else if f.rtr {
		b6 |= 0x40
	}
	if f.esi {
		b6 |= 0x20
	}
	mut out := []u8{cap: 16 + dlen}
	for _ in 0 .. 6 {
		out << 0 // timestamp: the device stamps the wire, not us
	}
	out << b6
	if f.extended {
		id := f.id & 0x1FFFFFFF
		out << u8(id >> 24) | 0x80 // the field's MSB is IDE
		out << u8(id >> 16)
		out << u8(id >> 8)
		out << u8(id)
	} else {
		id := f.id & 0x7FF
		out << u8(id >> 8) // IDE clear
		out << u8(id)
	}
	if !f.rtr {
		out << f.data
		for _ in f.data.len .. cansub_dlc_len(dlc, f.fd) {
			out << 0 // pad up to the length the DLC promises
		}
	}
	return out
}

// cansub_parse_payload reads the CAN frames out of one HDLC payload.
//
// It returns everything it managed to read, plus the reason it stopped if it stopped early. A
// truncated frame at the end does not discard the frames before it (TV-18) — the device sent
// those, and throwing them away because a later one was cut short loses real traffic.
pub fn cansub_parse_payload(p []u8) ([]CansubRecord, string) {
	mut out := []CansubRecord{}
	mut i := 0
	for i < p.len {
		if p.len - i < 7 {
			return out, 'Not enough data bytes for header'
		}
		mut us := u64(0)
		for k in 0 .. 6 {
			us = (us << 8) | u64(p[i + k])
		}
		b6 := p[i + 6]
		if b6 & 0xE0 == 0x20 {
			// An error record: no identifier, no data, seven bytes in total. Recognised on the
			// top three bits together — bit 5 alone is ESI on an FD frame.
			out << CansubRecord{
				us:       us
				is_error: true
				err:      unsafe { CansubErr(int(b6 & 0x1F)) }
			}
			i += 7
			continue
		}
		fd := b6 & 0x80 != 0
		bit6 := b6 & 0x40 != 0
		dlc := b6 & 0x0F
		if p.len - i < 9 {
			return out, 'Not enough data bytes for payload'
		}
		ide := p[i + 7] & 0x80 != 0
		mut id := u32(0)
		mut hdr := 0
		if ide {
			if p.len - i < 11 {
				return out, 'Not enough data bytes for payload'
			}
			id = (u32(p[i + 7]) << 24) | (u32(p[i + 8]) << 16) | (u32(p[i + 9]) << 8) | u32(p[i + 10])
			id &= 0x1FFFFFFF
			hdr = 11
		} else {
			id = ((u32(p[i + 7]) << 8) | u32(p[i + 8])) & 0x7FF
			hdr = 9
		}
		rtr := !fd && bit6
		dlen := if rtr { 0 } else { cansub_dlc_len(dlc, fd) } // a remote frame asks; it does not carry
		// THE REQUESTED LENGTH SURVIVES, as zeroes. A remote frame carries no bytes but it does
		// carry a DLC — it is asking for that many — and dropping it left `data` empty, so a
		// recorded request replayed through cansub_encode_frame went back out as a request for
		// ZERO bytes, which is a different question (codex round 3 on #204). Zero-filled is how
		// every other backend represents it, and how the Kvaser reader was fixed for the same
		// defect one PR over (#177).
		want := if rtr { cansub_dlc_len(dlc, false) } else { dlen }
		if p.len - i < hdr + dlen {
			return out, 'Not enough data bytes for payload'
		}
		out << CansubRecord{
			frame: CanFrame{
				id:       id
				extended: ide
				rtr:      rtr
				fd:       fd
				brs:      fd && bit6
				esi:      b6 & 0x20 != 0
				data:     if rtr {
					[]u8{len: want}
				} else {
					p[i + hdr..i + hdr + dlen].clone()
				}
			}
			tx:    b6 & 0x10 != 0
			us:    us
		}
		i += hdr + dlen
	}
	return out, ''
}

// CansubDecoder turns a byte stream into records.
//
// Fed with whatever arrives — a whole WebSocket message, several, or half of one — because an
// HDLC frame is not guaranteed to align with a message boundary (TV-10). Hold one per channel and
// feed it; it keeps the partial frame between calls.
pub struct CansubDecoder {
mut:
	buf      []u8 // the unstuffed body of the frame being read
	in_frame bool // between an opening 7E and its closing one
	escaped  bool // the previous byte was 7D, so this one is unstuffed
pub mut:
	// Why records were dropped, in order. A caller that logs these can say "the wire is noisy"
	// with evidence; one that ignores them still gets every frame that decoded.
	errors []string
}

// feed consumes bytes and returns whatever completed. Never errors: a stream is allowed to contain
// garbage, and saying so is what `errors` is for.
pub fn (mut d CansubDecoder) feed(chunk []u8) []CansubRecord {
	mut out := []CansubRecord{}
	for b in chunk {
		if b == 0x7E {
			// A boundary. It closes the frame in progress, and the NEXT one opens the following
			// frame — which is why `7E 7E` between two frames (TV-12) works, and why the garbage
			// after a closing boundary (TV-14) is discarded rather than accumulated into a body
			// that would then fail its CRC and report an error nobody should see.
			if d.in_frame {
				d.close(mut out)
			} else {
				d.buf.clear()
			}
			d.in_frame = !d.in_frame
			d.escaped = false
			continue
		}
		if !d.in_frame {
			continue // outside a frame: garbage, and skipping it is the point of a boundary byte
		}
		if d.escaped {
			d.buf << b ^ 0x20
			d.escaped = false
			// THE SAME BOUND, because this is the other way a byte reaches `buf`. Checked only
			// after the ordinary append, a stream of escape pairs — `7D 00 7D 00 …` with no
			// closing flag — walked straight past it and grew without limit, which is the whole
			// failure the bound was added for, alive on the path a hostile or broken device is
			// most likely to take (codex round 10 on #204).
			if d.buf.len > cansub_max_payload {
				d.overrun(mut out)
			}
			continue
		}
		if b == 0x7D {
			d.escaped = true
			continue
		}
		d.buf << b
		// AN OPENING FLAG WITH NO CLOSING ONE would otherwise append every byte the device ever
		// sends. That path never reaches close(), so it never produces a decode error either --
		// it just grows, silently, for the life of the bus, which is the one failure mode the
		// error-clearing in read_loop cannot help with (codex round 5 on #204).
		//
		// The bound is generous on purpose: the largest legal record is a 64-byte FD payload plus
		// its header and CRC, and escaping can double every byte of it. Anything past this is not
		// a frame we lost the end of, it is a stream that has stopped making sense -- so the
		// buffer is dropped and said so, rather than kept in the hope that a flag arrives.
		if d.buf.len > cansub_max_payload {
			d.overrun(mut out)
		}
	}
	return out
}

// cansub_max_payload bounds an unterminated HDLC frame.
//
// SIZED FOR A BATCH, not for one record. One HDLC payload carries as MANY CAN records as the
// device chose to put in it, so a bound derived from a single record is a bound a busy bus walks
// straight through — seven extended 64-byte records and a CRC already pass 512 bytes, and the
// first version of this dropped exactly that (codex round 6 on #204). Silently losing a valid
// batch under load is a worse failure than the unbounded growth this was added to stop.
//
// So the number is deliberately far above anything the device sends. Its only job is to keep a
// stream with NO frame boundaries in it from growing until the process dies; it is not a policy
// about how much the device may batch, and it must never be read as one.
const cansub_max_payload = 64 * 1024

// overrun drops a frame that has no end. Said once, so both append paths report it the same way
// — the escaped path having been the one that did not (codex round 10 on #204).
fn (mut d CansubDecoder) overrun(mut out []CansubRecord) {
	d.buf.clear()
	d.escaped = false
	// AND LEAVE FRAME MODE, which is what makes this a resynchronisation rather than a truncation.
	// Staying `in_frame`, every byte after the drop was accumulated as the body of a frame whose
	// opening boundary was never seen — so if that suffix happened to carry a valid payload and
	// CRC before the next flag, the decoder emitted CAN records it had invented, immediately after
	// announcing that it had discarded the stream (codex round 14 on #204). Outside a frame, bytes
	// are skipped until a real boundary opens the next one.
	d.in_frame = false
	d.errors << 'no frame boundary within ${cansub_max_payload} bytes — stream discarded'
}

// close finishes the frame in `buf`: check its CRC, then read the CAN frames out of it.
fn (mut d CansubDecoder) close(mut out []CansubRecord) {
	body := d.buf.clone()
	d.buf.clear()
	if body.len == 0 {
		return
	}
	if body.len < 5 {
		d.errors << 'HDLC frame too short (${body.len} bytes)'
		return
	}
	n := body.len - 4
	want := (u32(body[n]) << 24) | (u32(body[n + 1]) << 16) | (u32(body[n + 2]) << 8) | u32(body[
		n + 3])
	payload := body[..n]
	if cansub_crc32(payload) != want {
		d.errors << 'Frame CRC32 mismatch'
		return
	}
	recs, err := cansub_parse_payload(payload)
	out << recs
	if err != '' {
		d.errors << err
	}
}

// reset drops any half-read frame. For a reconnect: the bytes before the break are not the start
// of what comes after it.
pub fn (mut d CansubDecoder) reset() {
	d.buf.clear()
	d.in_frame = false
	d.escaped = false
}
