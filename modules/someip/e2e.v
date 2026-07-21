module someip

// e2e — the blobly E2E trailer, ported from blobly_emb comm/e2e (keep in
// sync; e2e_test.v pins a golden vector generated from that implementation):
// SAE J1850 CRC-8 (poly 0x1D, init 0xFF, final xor 0xFF) over the 16-bit data
// id (lo, hi) + every payload byte except the CRC byte; a 4-bit alive counter
// in the low nibble of its byte. Protected eth events append a 2-byte trailer
// — counter at len-2, CRC at len-1 (the loom2v `<fb>_e2e_ctr/_e2e_crc`
// convention; the manifest's declared frame length INCLUDES the trailer).
// RX semantics mirror the target exactly: ok and lost (counter skipped) are
// USABLE fresh frames; crc_error and repeated are not.

fn e2e_crc_update(crc u8, b u8) u8 {
	mut c := crc ^ b
	for _ in 0 .. 8 {
		c = if c & 0x80 != 0 { (c << 1) ^ 0x1D } else { c << 1 }
	}
	return c
}

fn e2e_compute(data []u8, data_id u16, crc_pos int) u8 {
	mut c := e2e_crc_update(0xFF, u8(data_id))
	c = e2e_crc_update(c, u8(data_id >> 8))
	for i, b in data {
		if i != crc_pos {
			c = e2e_crc_update(c, b)
		}
	}
	return c ^ 0xFF
}

// E2eTx stamps the trailer on outgoing protected frames (the test/fake-board
// side of the pincer; the GUI itself only receives).
pub struct E2eTx {
pub mut:
	counter u8
}

// protect stamps the alive counter and CRC into the frame's 2-byte trailer,
// then advances the counter.
pub fn (mut t E2eTx) protect(mut data []u8, data_id u16) {
	ctr := data.len - 2
	data[ctr] = (data[ctr] & 0xF0) | (t.counter & 0x0F)
	data[data.len - 1] = e2e_compute(data, data_id, data.len - 1)
	t.counter = (t.counter + 1) & 0x0F
}

pub enum E2eStatus {
	ok        // CRC valid, counter advanced by exactly 1
	crc_error // corrupted (CRC mismatch)
	repeated  // counter did not advance — duplicate / stuck sender
	lost      // CRC valid but the counter skipped — frames were lost before it
}

// usable reports whether the frame's data should be consumed: ok and lost are
// both valid, fresh frames (lost just notes a gap before it).
pub fn (s E2eStatus) usable() bool {
	return s == .ok || s == .lost
}

pub struct E2eRx {
pub mut:
	last    u8
	started bool
}

// check verifies the trailer CRC and the counter progression (delta 0 =
// repeated, 1 = ok, >1 = lost). It resyncs to the received counter except on
// a CRC error — same as the target.
pub fn (mut r E2eRx) check(data []u8, data_id u16) E2eStatus {
	if data.len < 2 {
		return .crc_error // no room for a trailer — never index out of bounds
	}
	crc_pos := data.len - 1
	if data[crc_pos] != e2e_compute(data, data_id, crc_pos) {
		return .crc_error
	}
	ctr := data[data.len - 2] & 0x0F
	mut st := E2eStatus.ok
	if r.started {
		delta := (ctr - r.last) & 0x0F
		st = if delta == 0 {
			E2eStatus.repeated
		} else if delta > 1 {
			E2eStatus.lost
		} else {
			E2eStatus.ok
		}
	}
	r.last = ctr
	r.started = true
	return st
}
