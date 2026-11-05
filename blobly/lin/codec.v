module lin

// The LIN wire rules, decided once for every backend: the protected identifier, the checksum,
// a frame's length in bit times, and the byte stream a serial port delivers (PARMRK), decoded
// into frames.

// master_req is the diagnostic MasterReq frame. Ids 0x3C..0x3F always carry a classic checksum.
pub const master_req = u8(0x3C)
// slave_resp is the diagnostic SlaveResp frame.
pub const slave_resp = u8(0x3D)
// max_id is the highest frame identifier: six bits.
pub const max_id = u8(0x3F)
// max_data is the most data bytes a frame carries.
pub const max_data = 8
// broadcast_nad addresses every slave in a MasterReq.
pub const broadcast_nad = u8(0x7F)
// functional_nad is the functional address of a MasterReq; no node has it as its own.
pub const functional_nad = u8(0x7E)

// Model is which checksum a frame carries: classic over the data, enhanced over the PID too.
pub enum Model {
	classic
	enhanced
}

pub fn (m Model) str() string {
	return match m {
		.classic { 'classic' }
		.enhanced { 'enhanced' }
	}
}

// pid is the protected identifier: the six-bit id with parity P0 (bit 6) and P1 (bit 7). An id
// above 0x3F is taken modulo 64.
pub fn pid(id u8) u8 {
	i := id & max_id
	p0 := (i ^ (i >> 1) ^ (i >> 2) ^ (i >> 4)) & 1
	p1 := ((i >> 1) ^ (i >> 3) ^ (i >> 4) ^ (i >> 5) ^ 1) & 1
	return i | (p0 << 6) | (p1 << 7)
}

// id_of is the id a protected identifier carries, none when its parity is wrong.
pub fn id_of(p u8) ?u8 {
	id := p & max_id
	if pid(id) != p {
		return none
	}
	return id
}

// effective_model is the checksum a frame of this id actually carries: ids 0x3C..0x3F (the
// diagnostic and reserved frames) are classic whatever is asked (LIN 2.2A 2.3.1.5).
pub fn effective_model(id u8, model Model) Model {
	if (id & max_id) >= master_req {
		return .classic
	}
	return model
}

// checksum is the inverted eight-bit sum with carry, over the data (classic) or the PID and the
// data (enhanced), the model taken through effective_model of the PID's id.
pub fn checksum(model Model, p u8, data []u8) u8 {
	mut sum := u32(0)
	if effective_model(p & max_id, model) == .enhanced {
		sum = p
	}
	for d in data {
		sum += d
		if sum > 0xFF {
			sum -= 0xFF
		}
	}
	return u8(~sum)
}

// is_sleep_command is whether a MasterReq's data is the go-to-sleep command: first byte 0x00.
pub fn is_sleep_command(id u8, data []u8) bool {
	return id == master_req && data.len > 0 && data[0] == 0
}

// sleep_data is the go-to-sleep command a master sends: 0x00 then 0xFF.
pub fn sleep_data() []u8 {
	return [u8(0), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
}

// frame_bits is a frame's nominal length in bit times: a 34-bit header (break, delimiter, sync,
// PID) and ten bits per data byte and the checksum.
pub fn frame_bits(n int) int {
	return 34 + 10 * (n + 1)
}

// frame_bits_max is TFrame_Maximum, 1.4 times the nominal length, rounded up.
pub fn frame_bits_max(n int) int {
	return (frame_bits(n) * 14 + 9) / 10
}

// frame_ns is a frame's nominal duration at a baud rate.
pub fn frame_ns(n int, baud int) i64 {
	return i64(frame_bits(n)) * 1_000_000_000 / i64(baud)
}

// Expect is what a receiver knows about an id: its data length and checksum model.
pub struct Expect {
pub:
	len   int
	model Model = .enhanced
}

// diag_expect is what every MasterReq and SlaveResp is: 8 data bytes, classic checksum.
const diag_expect = Expect{
	len:   max_data
	model: .classic
}

// interpret is the one reading of a response: the bytes read after a valid PID, judged against
// what is expected of the id (MasterReq and SlaveResp are always diag_expect), or with no
// expectation by trying enhanced then classic. A response cut short holds every byte read as
// data, since which one was the checksum cannot be told; one longer than its length is `long`,
// read by its length.
pub fn interpret(id u8, raw []u8, given ?Expect) Frame {
	exp := if e := given {
		?Expect(e)
	} else if id == master_req || id == slave_resp {
		?Expect(diag_expect)
	} else {
		?Expect(none)
	}
	p := pid(id)
	mut f := Frame{
		id:  id
		pid: p
		raw: raw.clone()
	}
	if raw.len == 0 {
		f.errs.set(.no_response)
		if e := exp {
			f.model = effective_model(id, e.model)
		}
		return f
	}
	if e := exp {
		f.model = effective_model(id, e.model)
		if raw.len < e.len + 1 {
			f.errs.set(.short)
			f.data = raw.clone()
			return f
		}
		f.data = raw[..e.len].clone()
		f.checksum = raw[e.len]
		if checksum(f.model, p, f.data) != f.checksum {
			f.errs.set(.checksum)
		}
		if raw.len > e.len + 1 {
			f.errs.set(.long)
		}
	} else {
		if raw.len < 2 {
			f.errs.set(.short)
			f.data = raw.clone()
			return f
		}
		f.data = raw[..raw.len - 1].clone()
		f.checksum = raw[raw.len - 1]
		if checksum(.enhanced, p, f.data) == f.checksum {
			f.model = effective_model(id, .enhanced)
		} else if checksum(.classic, p, f.data) == f.checksum {
			f.model = .classic
		} else {
			f.model = effective_model(id, .enhanced)
			f.errs.set(.checksum)
		}
	}
	if f.errs == Errs.zero() && is_sleep_command(id, f.data) {
		f.event = .sleep
	}
	return f
}

// wire_errs are the flags a re-reading cannot change: facts about the bytes on the wire.
const wire_errs = [Errs.framing, Errs.collision, Errs.bit]

// reread reads a received frame's response again against another expectation (a receiver's own
// length and model), keeping who sent what and when, and the wire's own flags. A frame with no
// response bytes is returned as it is.
pub fn reread(f Frame, exp Expect) Frame {
	if f.raw.len == 0 {
		return f
	}
	g := interpret(f.id, f.raw, exp)
	mut errs := g.errs
	for flag in wire_errs {
		if f.errs.has(flag) {
			errs.set(flag)
		}
	}
	// A sleep command only when the frame is error-free.
	event := if errs == Errs.zero() { g.event } else { Event.frame }
	return Frame{
		...g
		errs:      errs
		event:     event
		ours:      f.ours
		header:    f.header
		src:       f.src
		t_ns:      f.t_ns
		hw_ns:     f.hw_ns
		hw_domain: f.hw_domain
	}
}

// The serial byte stream, PARMRK-marked: FF 00 00 is a break, FF FF a data byte 0xFF, FF 00 x
// (x != 0) byte x received with a framing error.

enum Sym {
	data
	brk
	ferr
}

enum DecState {
	idle      // between frames: bytes here are stray
	wake      // between frames, one byte that may be a wakeup pulse
	after_brk // a break seen, the sync byte awaited
	want_pid  // the sync seen, the PID awaited
	response  // the PID seen, response bytes being read
	tail      // the response has its expected length; bytes after it make the frame long
}

// Decoder turns PARMRK chunks into frames. A response is ended at the next break or at idle;
// with an expectation for an id, bytes past its length are kept, so the frame reads `long`, and
// without one, at the most a frame can hold. A frame is stamped with the time of the chunk its
// last byte came in.
//
// A wakeup is a break with no sync after it, or a pulse too short for a break: a lone byte between
// frames whose bits are one dominant run from the start bit (0x00, 0x80, 0xC0 .. 0xFE) lasting at
// least the 150 us a receiver must accept, confirmed by idle or a break after it and stamped with
// its own chunk's time. A byte beside other stray bytes is noise, not a wakeup.
// The bytes after a rejected header (bad sync, parity or framing) are noise too.
pub struct Decoder {
pub mut:
	lengths map[u8]Expect
	// stray is bytes read outside any frame.
	stray u64
mut:
	baud    int
	garbage bool // a stray byte since the last idle or break
	esc     int  // 1: FF seen, 2: FF 00 seen
	st      DecState
	id      u8
	// exp is what the open frame is read by, taken from lengths when its PID came in, so a
	// change to lengths does not change how a frame already open is read.
	exp    ?Expect
	buf    []u8
	errs   Errs
	last_t i64
}

pub fn new_decoder(lengths map[u8]Expect, baud int) Decoder {
	return Decoder{
		lengths: lengths
		baud:    baud
	}
}

// min_wake_ns is the shortest dominant pulse a receiver must accept as a wakeup.
const min_wake_ns = i64(150_000)

// is_wake_pulse is whether a byte read between frames is a dominant run from its start bit
// (start bit and k data bits, 0xFF << k) long enough to be a wakeup at this baud.
fn (d &Decoder) is_wake_pulse(b u8) bool {
	for k in 0 .. 9 {
		if b == u8((u32(0xFF) << k) & 0xFF) {
			return i64(1 + k) * 1_000_000_000 >= min_wake_ns * i64(d.baud)
		}
	}
	return false
}

// feed decodes one chunk read at t_ns and returns the frames it completed.
pub fn (mut d Decoder) feed(chunk []u8, t_ns i64) []Frame {
	mut out := []Frame{}
	for b in chunk {
		match d.esc {
			1 {
				d.esc = 0
				if b == 0xFF {
					d.symbol(.data, 0xFF, t_ns, mut out)
				} else if b == 0x00 {
					d.esc = 2
				} else {
					// Not a PARMRK mark: the FF was a data byte as read, then this one.
					d.symbol(.data, 0xFF, t_ns, mut out)
					d.symbol(.data, b, t_ns, mut out)
				}
			}
			2 {
				d.esc = 0
				if b == 0 {
					d.symbol(.brk, 0, t_ns, mut out)
				} else {
					d.symbol(.ferr, b, t_ns, mut out)
				}
			}
			else {
				if b == 0xFF {
					d.esc = 1
				} else {
					d.symbol(.data, b, t_ns, mut out)
				}
			}
		}
	}
	return out
}

// response_begun is whether a response has begun and can only end at a break or idle: it has
// reached its expected length, or none is stated for its id.
pub fn (d &Decoder) response_begun() bool {
	if d.st == .tail {
		return true
	}
	if d.st != .response || d.buf.len == 0 {
		return false
	}
	_ := d.exp or { return true }
	return false
}

// wants_idle is whether the decoder is waiting on the line going quiet: a frame or a wakeup pulse
// is open, or a stray byte keeps the next lone pulse from reading as a wakeup.
pub fn (d &Decoder) wants_idle() bool {
	return d.st != .idle || d.garbage
}

// idle tells the decoder the line has been idle since its last byte: what is open ends now.
pub fn (mut d Decoder) idle(t_ns i64) []Frame {
	mut out := []Frame{}
	d.end_open(mut out)
	d.garbage = false
	return out
}

fn (mut d Decoder) symbol(s Sym, b u8, t_ns i64, mut out []Frame) {
	if s == .brk {
		d.end_open(mut out)
		d.garbage = false
		d.st = .after_brk
		d.errs = Errs.zero()
		d.buf.clear()
		d.last_t = t_ns
		return
	}
	match d.st {
		.idle {
			if s == .data && !d.garbage && d.is_wake_pulse(b) {
				d.st = .wake
				d.last_t = t_ns
			} else {
				d.stray++
				d.garbage = true
			}
		}
		.wake {
			// Another byte: the candidate and this one are noise.
			d.stray += 2
			d.garbage = true
			d.st = .idle
		}
		.after_brk {
			d.last_t = t_ns
			if s == .ferr {
				d.errs.set(.framing)
			}
			if b != 0x55 {
				d.errs.set(.sync)
			}
			if d.errs != Errs.zero() {
				d.emit(Frame{ errs: d.errs }, mut out)
				d.garbage = true
				return
			}
			d.st = .want_pid
		}
		.want_pid {
			d.last_t = t_ns
			if s == .ferr {
				d.errs.set(.framing)
				d.emit(Frame{ pid: b, errs: d.errs }, mut out)
				d.garbage = true
				return
			}
			id := id_of(b) or {
				d.errs.set(.parity)
				d.emit(Frame{ id: b & max_id, pid: b, errs: d.errs }, mut out)
				d.garbage = true
				return
			}
			d.id = id
			d.exp = if e := d.lengths[id] { ?Expect(e) } else { ?Expect(none) }
			d.st = .response
		}
		.response {
			d.last_t = t_ns
			d.buf << b
			if s == .ferr {
				d.errs.set(.framing)
			}
			if e := d.exp {
				if d.buf.len >= e.len + 1 {
					d.st = .tail
				}
			} else if d.buf.len >= max_data + 1 {
				d.end_open(mut out)
			}
		}
		.tail {
			d.last_t = t_ns
			d.buf << b
			if s == .ferr {
				d.errs.set(.framing)
			}
			// past anything a frame carries: the frame ends, long, and what follows is stray
			if d.buf.len > max_data + 1 {
				d.end_open(mut out)
				d.garbage = true
			}
		}
	}
}

// end_open ends what the decoder has open: a wakeup pulse, or a break with nothing after it, is a
// wakeup; a break
// and sync with no PID a header cut short, a PID the response read so far.
fn (mut d Decoder) end_open(mut out []Frame) {
	match d.st {
		.idle {}
		.wake, .after_brk {
			d.emit(Frame{ event: .wakeup }, mut out)
		}
		.want_pid {
			mut errs := d.errs
			errs.set(.short)
			d.emit(Frame{ errs: errs }, mut out)
		}
		.response, .tail {
			mut f := interpret(d.id, d.buf, d.exp)
			if d.errs.has(.framing) {
				f.errs.set(.framing)
				if f.event == .sleep {
					f.event = .frame
				}
			}
			d.emit(f, mut out)
		}
	}
}

fn (mut d Decoder) emit(f Frame, mut out []Frame) {
	out << Frame{
		...f
		t_ns: d.last_t
	}
	d.st = .idle
	d.errs = Errs.zero()
	d.buf.clear()
}
