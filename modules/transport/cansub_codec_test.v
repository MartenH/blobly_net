module transport

// The vendor's 20 published test vectors, verbatim.
//
// They exist "for validation of custom implementations of the WS API", which is exactly what
// `cansub_codec.v` is, and they cover the cases a hand-rolled decoder gets wrong: fragmentation,
// several frames per HDLC frame, several HDLC frames per message, garbage before and between
// frames, a bad CRC in the middle, a truncated frame, stuffing in the payload AND in the CRC, and
// error records. Pinning them here means the format is checked with no device attached — the
// bench has one CANsub and CI has none.
//
// Vectors are written as the hex the docs print, so a reader can diff a row against the source.

fn hex(s string) []u8 {
	mut out := []u8{}
	for part in s.split(' ') {
		p := part.trim_space()
		if p == '' {
			continue
		}
		mut v := 0
		for c in p {
			d := match true {
				c >= `0` && c <= `9` { int(c - `0`) }
				c >= `a` && c <= `f` { int(c - `a`) + 10 }
				c >= `A` && c <= `F` { int(c - `A`) + 10 }
				else { 0 }
			}

			v = v * 16 + d
		}
		out << u8(v)
	}
	return out
}

// one_year_us and two_years_us are what the doc's dates mean as device timestamps: 2026-01-01 and
// 2027-01-01, neither year a leap year.
const one_year_us = u64(365) * 24 * 3600 * 1000000
const two_years_us = u64(730) * 24 * 3600 * 1000000

fn decode_all(s string) ([]CansubRecord, []string) {
	mut d := CansubDecoder{}
	recs := d.feed(hex(s))
	return recs, d.errors
}

// TV-01 — standard identifier. Also pins the epoch: the doc says 2026-01-01, and the encoded
// 0x1CAE8C13E000 is exactly 365 days of microseconds, which is only true if the zero is
// 2025-01-01.
fn test_tv01_standard_identifier() {
	recs, errs := decode_all('7E 1C AE 8C 13 E0 00 01 07 FF 00 98 4F D1 B8 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert recs[0].frame.id == 0x7FF
	assert !recs[0].frame.extended
	assert !recs[0].frame.fd
	assert !recs[0].frame.rtr
	assert !recs[0].tx
	assert recs[0].frame.data == [u8(0x00)]
	assert recs[0].us == one_year_us, 'timestamp epoch is not 2025-01-01'
}

// TV-02 — extended identifier. The ID field is four bytes here, not two, and its top bit is IDE
// rather than part of the number.
fn test_tv02_extended_identifier() {
	recs, errs := decode_all('7E 39 5D 18 27 C0 00 01 9F FF FF FF 00 82 83 9F 92 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert recs[0].frame.id == 0x1FFFFFFF
	assert recs[0].frame.extended
	assert recs[0].us == two_years_us
}

// TV-03 — a remote frame carries a DLC but no data. Two different statements, and the decoder
// has to keep them apart:
//
//   * NO BYTES ARE CONSUMED FROM THE WIRE. Reading DLC bytes here would swallow whatever follows
//     in the payload. That is the wire fact this vector pins, and it is unchanged.
//   * THE DLC IS STILL REPORTED, as zeroes. It is what the frame is ASKING FOR — this vector asks
//     for eight — and dropping it left a recorded request replayed as a request for zero bytes,
//     which is a different question (codex round 3 on #204). Zero-filled to the requested length
//     is what SocketCAN, Vector and (since #177) Kvaser all hand up, so this was the odd one out.
//
// The assertion below changed with that fix. It was pinning a REPRESENTATION choice of ours, not
// anything the vendor's vector says: the wire carries a DLC of 8 and no payload either way.
fn test_tv03_remote_frame_has_no_data() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 48 00 01 EF 87 F8 40 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert recs[0].frame.rtr
	assert recs[0].frame.id == 0x001
	assert recs[0].frame.data.len == 8, 'the request is for eight bytes, and that survives'
	assert recs[0].frame.data == []u8{len: 8}, 'a remote frame carries no data, so the bytes are zeroes'
	// The framing still parsed to exactly one record with no errors, which is what says the
	// decoder took its DLC from the header and no payload bytes from the wire.
}

fn test_tv04_fd_frame() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 81 00 01 00 AF 74 88 69 7E')
	assert errs.len == 0, '${errs}'
	assert recs[0].frame.fd
	assert !recs[0].frame.brs
	assert recs[0].frame.data == [u8(0x00)]
}

// TV-05 — bit 6 is BRS on an FD frame, where the same bit was RTR on a classic one.
fn test_tv05_fd_with_brs_is_not_a_remote_frame() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 C1 00 01 00 34 60 D0 54 7E')
	assert errs.len == 0, '${errs}'
	assert recs[0].frame.fd
	assert recs[0].frame.brs
	assert !recs[0].frame.rtr, 'BRS was read as RTR'
}

// TV-06 — an FD frame from an error-passive node sets bit 5. Against TV-19 this is the pair that
// forces the error test to look at the whole top nibble.
fn test_tv06_fd_with_esi_is_not_an_error_record() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 A1 00 01 00 0F 46 27 57 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert !recs[0].is_error, 'ESI was read as a bus error'
	assert recs[0].frame.esi
	assert recs[0].frame.fd
}

// TV-07 — DLC 15 means 64 bytes, not 15.
fn test_tv07_fd_length_codes() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 8F 00 01 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F DE 43 31 51 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert recs[0].frame.data.len == 64
	assert recs[0].frame.data[0] == 0x00
	assert recs[0].frame.data[63] == 0x3F
}

// TV-08 — a transmit acknowledgement: our own frame, confirmed on the wire. It must not be filed
// as traffic somebody else sent.
fn test_tv08_tx_acknowledgement() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 11 00 01 00 12 34 69 CD 7E')
	assert errs.len == 0, '${errs}'
	assert recs[0].tx, 'a TX ack was read as a received frame'
	assert recs[0].frame.id == 0x001
}

fn test_tv09_plain_frame() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 01 00 01 00 42 2D 3E 52 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert recs[0].us == 0, 'the epoch itself must decode as zero'
}

// TV-10 — the same frame as TV-09, arriving in seven pieces. A decoder that works per WebSocket
// message decodes none of it.
fn test_tv10_one_frame_split_across_messages() {
	mut d := CansubDecoder{}
	mut recs := []CansubRecord{}
	for part in ['7E', '00 00 00 00 00 00', '01', '00 01', '00', '42 2D 3E 52', '7E'] {
		recs << d.feed(hex(part))
	}
	assert d.errors.len == 0, '${d.errors}'
	assert recs.len == 1, 'a fragmented frame did not reassemble'
	assert recs[0].frame.id == 0x001
	assert recs[0].frame.data == [u8(0x00)]
}

// TV-11 — four CAN frames inside ONE HDLC payload.
fn test_tv11_several_frames_in_one_hdlc_frame() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 01 00 01 01 00 00 00 00 00 00 01 00 02 02 00 00 00 00 00 00 01 00 03 03 00 00 00 00 00 00 01 00 04 04 D1 2C 1F D9 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 4
	for i, r in recs {
		assert r.frame.id == u32(i + 1)
		assert r.frame.data == [u8(i + 1)]
	}
}

// TV-12 — four HDLC frames back to back, each closing boundary immediately followed by the next
// opening one.
fn test_tv12_several_hdlc_frames_back_to_back() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 01 00 01 01 35 2A 0E C4 7E 7E 00 00 00 00 00 00 01 00 02 02 87 0E 0C BD 7E 7E 00 00 00 00 00 00 01 00 03 03 E9 12 0D 6A 7E 7E 00 00 00 00 00 00 01 00 04 04 38 37 0E 0E 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 4
	for i, r in recs {
		assert r.frame.id == u32(i + 1)
	}
}

// TV-13 — garbage before the first boundary is skipped, not decoded and not reported.
fn test_tv13_garbage_before_the_first_frame() {
	recs, errs := decode_all('01 02 03 04 05 7E 00 00 00 00 00 00 01 00 01 00 42 2D 3E 52 7E')
	assert errs.len == 0, 'resynchronising is not an error: ${errs}'
	assert recs.len == 1
	assert recs[0].frame.id == 0x001
}

// TV-14 — garbage BETWEEN two frames. The subtle one: if a closing boundary is treated as also
// opening the next frame, that garbage accumulates into a body which then fails its CRC, and the
// decoder reports an error for a stream the vendor says is fine.
fn test_tv14_garbage_between_frames_is_not_an_error() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 01 00 01 01 35 2A 0E C4 7E 01 02 03 04 05 7E 00 00 00 00 00 00 01 00 02 02 87 0E 0C BD 7E')
	assert errs.len == 0, 'garbage between frames was reported as a bad frame: ${errs}'
	assert recs.len == 2
	assert recs[0].frame.id == 0x001
	assert recs[1].frame.id == 0x002
}

// TV-15 — the middle frame's CRC is wrong. It costs that frame and only that frame.
fn test_tv15_a_bad_crc_drops_only_its_own_frame() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 01 00 01 01 35 2A 0E C4 7E 7E 00 00 00 00 00 00 01 00 02 02 00 00 00 00 7E 7E 00 00 00 00 00 00 01 00 03 03 E9 12 0D 6A 7E')
	assert recs.len == 2
	assert recs[0].frame.id == 0x001
	assert recs[1].frame.id == 0x003, 'the frame after a bad CRC was lost'
	assert errs.len == 1
	assert errs[0].contains('CRC32'), '${errs}'
}

// TV-16 — payload bytes that collide with the framing. Both escapes, in one frame.
fn test_tv16_stuffing_in_the_payload() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 08 00 01 7D 5E 7D 5E 7D 5E 7D 5E 7D 5D 7D 5D 7D 5D 7D 5D 67 49 97 08 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 1
	assert recs[0].frame.data == [u8(0x7E), 0x7E, 0x7E, 0x7E, 0x7D, 0x7D, 0x7D, 0x7D]
}

// TV-17 — the CRC's OWN bytes need unstuffing. A decoder that unstuffs only the payload computes
// the right checksum and compares it against the wrong bytes.
fn test_tv17_stuffing_inside_the_checksum() {
	recs, errs := decode_all('7E 00 00 00 00 2A D1 01 00 01 01 27 88 7D 5E 7D 5D 7E')
	assert errs.len == 0, 'the checksum was compared against stuffed bytes: ${errs}'
	assert recs.len == 1
	assert recs[0].frame.id == 0x001
	assert recs[0].frame.data == [u8(0x01)]
}

// TV-18 — a truncated frame at the end of an otherwise valid HDLC payload. The frame BEFORE it
// was really on the wire and is kept; the next HDLC frame decodes normally.
fn test_tv18_a_truncated_frame_keeps_its_predecessors() {
	recs, errs :=
		decode_all('7E 00 00 00 00 00 00 01 00 01 01 00 00 00 00 00 00 02 00 02 02 BE C0 22 71 7E 7E 00 00 00 00 00 00 01 00 03 03 E9 12 0D 6A 7E')
	assert recs.len == 2
	assert recs[0].frame.id == 0x001, 'the frame before the truncated one was discarded'
	assert recs[1].frame.id == 0x003
	assert errs.len == 1
	assert errs[0].contains('Not enough data'), '${errs}'
}

// TV-19 — an error record, then a normal frame, in two separate messages.
fn test_tv19_error_record_then_a_frame() {
	mut d := CansubDecoder{}
	mut recs := d.feed(hex('7E 00 00 00 00 00 00 20 A6 02 FF B6 7E'))
	recs << d.feed(hex('7E 00 00 00 00 00 00 01 00 01 00 42 2D 3E 52 7E'))
	assert d.errors.len == 0, '${d.errors}'
	assert recs.len == 2
	assert recs[0].is_error
	assert recs[0].err == .bit_err
	assert !recs[1].is_error
	assert recs[1].frame.id == 0x001
}

// TV-20 — an error record and a frame inside ONE HDLC payload. The error record is seven bytes
// with no identifier and no data; reading an ID out of it would consume the frame behind it.
fn test_tv20_error_record_and_frame_in_one_payload() {
	recs, errs := decode_all('7E 00 00 00 00 00 00 20 00 00 00 00 00 00 01 00 01 00 EE D4 28 4E 7E')
	assert errs.len == 0, '${errs}'
	assert recs.len == 2, 'the error record swallowed the frame behind it'
	assert recs[0].is_error
	assert recs[0].err == .bit_err
	assert recs[1].frame.id == 0x001
	assert recs[1].frame.data == [u8(0x00)]
}

// The transmit path has no published vectors, so it is checked against the receive path: wrap a
// frame, decode it back, and require what comes out to be what went in. Every vector above pins
// the decoder, so a round trip through it is worth something.
fn test_encoding_round_trips_through_the_decoder() {
	cases := [
		CanFrame{
			id:   0x7FF
			data: [u8(1), 2, 3, 4, 5, 6, 7, 8]
		},
		CanFrame{
			id:       0x1FFFFFFF
			extended: true
			data:     [u8(0xAA)]
		},
		CanFrame{
			id:  0x123
			rtr: true
		},
		CanFrame{
			id:   0x100
			fd:   true
			brs:  true
			data: []u8{len: 64, init: u8(index)}
		},
		CanFrame{
			id:   0x7E // an identifier whose bytes collide with the framing
			data: [u8(0x7E), 0x7D, 0x7E, 0x7D]
		},
	]
	for c in cases {
		body := cansub_encode_frame(c) or {
			assert false, 'encode ${c.id:X}: ${err}'
			return
		}
		mut d := CansubDecoder{}
		recs := d.feed(cansub_hdlc_wrap(body))
		assert d.errors.len == 0, 'id ${c.id:X}: ${d.errors}'
		assert recs.len == 1, 'id ${c.id:X}: got ${recs.len} records'
		g := recs[0].frame
		assert g.id == c.id
		assert g.extended == c.extended
		assert g.rtr == c.rtr
		assert g.fd == c.fd
		assert g.brs == c.brs
		assert g.data == c.data, 'id ${c.id:X}: ${g.data.hex()} != ${c.data.hex()}'
	}
}

// A CAN-FD frame has no remote request — bit 6 is BRS there. Encoding one would set BRS and send
// a frame nobody asked for, so it is refused.
fn test_an_fd_remote_frame_is_refused() {
	cansub_encode_frame(CanFrame{ id: 0x1, fd: true, rtr: true }) or { return }
	assert false, 'encoded a CAN-FD remote frame'
}

// A payload length CAN cannot express is refused rather than silently rounded: fd_padded_len is
// the caller's tool for choosing, and guessing here would send a different frame than was asked
// for.
fn test_an_impossible_payload_length_is_refused() {
	cansub_len_dlc(9, true) or {
		cansub_len_dlc(9, false) or { return }
		assert false, '9 bytes accepted on a classic frame'
		return
	}
	assert false, '9 bytes accepted as an FD length'
}

fn test_dlc_length_table() {
	assert cansub_dlc_len(8, false) == 8
	assert cansub_dlc_len(15, false) == 8, 'a classic DLC above 8 still means 8'
	assert cansub_dlc_len(9, true) == 12
	assert cansub_dlc_len(15, true) == 64
}

// A reconnect must not glue the tail of the old stream to the head of the new one.
fn test_reset_drops_a_half_read_frame() {
	mut d := CansubDecoder{}
	d.feed(hex('7E 00 00 00 00 00 00 01 00'))
	d.reset()
	recs := d.feed(hex('7E 00 00 00 00 00 00 01 00 01 00 42 2D 3E 52 7E'))
	assert d.errors.len == 0, '${d.errors}'
	assert recs.len == 1
	assert recs[0].frame.id == 0x001
}
