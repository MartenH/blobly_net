// What a CAN bridge and this app say to each other, in bytes.
//
// A bridge is a small program beside a CAN interface this process cannot open itself — a vcan in
// WSL seen from the Windows build, later a Linux box with real CAN on the LAN. It holds the
// interfaces; this process holds the TCP listener, and the bridge DIALS IN (WSL's firewall blocks
// inbound connections by default and lets outbound ones through, #451).
//
// One TCP connection per bridge carries every channel it offers. TCP is already an ordered,
// reliable byte stream, so a record needs a length and nothing else: no framing bytes, no CRC.
//
//     record  = u32 LE body length, then the body
//     body    = u8 kind, then the kind's fields
//     str     = u16 LE length, then UTF-8 bytes
//
//     hello   (bridge -> app)  u16 version, str token, str name, u8 count, count x str channel
//     open    (app -> bridge)  u8 channel, u32 gen
//     opened  (bridge -> app)  u8 channel, u32 gen, str error ('' when the channel opened)
//     close   (app -> bridge)  u8 channel
//     frame   (both ways)      u8 channel, u32 gen, u8 flags, u32 seq, u32 id, i64 stamp ns, u8 len,
//                              data
//     senderr (bridge -> app)  u8 channel, u32 seq, u8 definite, str error — a frame the app sent
//                              failed; `definite` when it certainly did not reach the wire
//     status  (bridge -> app)  u8 channel, u32 gen, u8 health, u64 dropped, u64 bus errors,
//                              u64 decode errors
//     lost    (bridge -> app)  u8 channel, u32 gen, str error — the channel failed on the bridge
//
// `gen` is the app's number for one OPEN of a channel, carried by every record about that open, so
// a record still in the stream from a previous open of the same channel is told apart by value
// rather than by where it falls in the stream.
//     refused (app -> bridge)  str reason — the hello was not accepted; the app then closes
//
// A `frame` from the bridge with the `tx` flag is the acknowledgement of one the app sent: the
// bridge puts it on its interface and returns it stamped, so this side can tell its own traffic
// from the device's. `seq` is the app's number for that send, echoed by its acknowledgement or
// its `senderr`, so a send waits for its own answer and never a late one to an earlier send; a
// frame the bridge received carries seq 0. Every stamp is the BRIDGE host's monotonic clock — one clock domain per
// bridge, placed on this host's timeline by `timebase`.
//
// Pure functions and a streaming decoder, no sockets: the format is testable with nothing on the
// other end.
module transport

pub const bridge_version = u16(1)

// bridge_max_record bounds one record's body. The largest legitimate one is a hello naming many
// channels; a length past this is a stream that is not ours (or has lost sync), and nothing is
// allocated for it.
const bridge_max_record = 1 << 20

// bridge_max_str is the most bytes of a string that are sent: a name or an error message, never
// long enough to need more, and short enough that a hello of every channel fits a record.
const bridge_max_str = 1024

// bridge_max_channels is how many channels one bridge may offer: the index is a byte.
pub const bridge_max_channels = 255

pub enum BridgeKind as u8 {
	hello   = 1
	open    = 2
	opened  = 3
	close   = 4
	frame   = 5
	senderr = 6
	status  = 7
	lost    = 8
	refused = 9
}

const bridge_flag_ext = u8(0x01)
const bridge_flag_rtr = u8(0x02)
const bridge_flag_fd = u8(0x04)
const bridge_flag_brs = u8(0x08)
const bridge_flag_esi = u8(0x10)
const bridge_flag_tx = u8(0x20)

// BridgeRecord is one decoded record. Which fields mean anything depends on `kind`.
pub struct BridgeRecord {
pub:
	kind    BridgeKind
	channel u8
	// hello
	version  u16
	token    string
	name     string
	channels []string
	// opened (empty = success), senderr, lost
	error string
	// open, opened, frame, status, lost: which open of the channel the record is about
	gen u32
	// frame, senderr
	seq u32
	// senderr: the frame certainly did not reach the wire
	definite bool
	// frame
	frame    CanFrame
	tx       bool
	stamp_ns i64
	// status
	health BusHealth
	diag   BusDiagnostics
}

fn bridge_put_u16(mut b []u8, v u16) {
	b << u8(v)
	b << u8(v >> 8)
}

fn bridge_put_u64(mut b []u8, v u64) {
	for i in 0 .. 8 {
		b << u8(v >> (8 * i))
	}
}

fn bridge_put_str(mut b []u8, s string) {
	mut n := if s.len > bridge_max_str { bridge_max_str } else { s.len }
	// Cut at a character boundary, never inside a UTF-8 sequence.
	for n < s.len && n > 0 && s[n] & 0xC0 == 0x80 {
		n--
	}
	bridge_put_u16(mut b, u16(n))
	b << s.bytes()[..n]
}

// bridge_wrap prefixes a body with its length, making it a record.
fn bridge_wrap(body []u8) []u8 {
	mut out := []u8{cap: 4 + body.len}
	put_u32_le(mut out, u32(body.len))
	out << body
	return out
}

pub fn bridge_encode_hello(token string, name string, channels []string) []u8 {
	mut b := [u8(BridgeKind.hello)]
	bridge_put_u16(mut b, bridge_version)
	bridge_put_str(mut b, token)
	bridge_put_str(mut b, name)
	n := if channels.len > bridge_max_channels { bridge_max_channels } else { channels.len }
	b << u8(n)
	for c in channels[..n] {
		bridge_put_str(mut b, c)
	}
	return bridge_wrap(b)
}

pub fn bridge_encode_open(ch u8, gen u32) []u8 {
	mut b := [u8(BridgeKind.open), ch]
	put_u32_le(mut b, gen)
	return bridge_wrap(b)
}

pub fn bridge_encode_opened(ch u8, gen u32, err string) []u8 {
	mut b := [u8(BridgeKind.opened), ch]
	put_u32_le(mut b, gen)
	bridge_put_str(mut b, err)
	return bridge_wrap(b)
}

pub fn bridge_encode_close(ch u8) []u8 {
	return bridge_wrap([u8(BridgeKind.close), ch])
}

// bridge_encode_frame serialises one frame. `tx` marks the bridge's acknowledgement of a frame
// the app sent; the app always sends it false. A remote frame carries its requested length as
// zeroes, the way every backend here represents one.
pub fn bridge_encode_frame(ch u8, gen u32, f CanFrame, seq u32, tx bool, stamp_ns i64) []u8 {
	mut flags := u8(0)
	if f.extended {
		flags |= bridge_flag_ext
	}
	if f.rtr {
		flags |= bridge_flag_rtr
	}
	if f.fd {
		flags |= bridge_flag_fd
	}
	if f.brs {
		flags |= bridge_flag_brs
	}
	if f.esi {
		flags |= bridge_flag_esi
	}
	if tx {
		flags |= bridge_flag_tx
	}
	n := if f.data.len > 64 { 64 } else { f.data.len }
	mut b := []u8{cap: 28 + n}
	b << u8(BridgeKind.frame)
	b << ch
	put_u32_le(mut b, gen)
	b << flags
	put_u32_le(mut b, seq)
	put_u32_le(mut b, f.id)
	bridge_put_u64(mut b, u64(stamp_ns))
	b << u8(n)
	b << f.data[..n]
	return bridge_wrap(b)
}

pub fn bridge_encode_senderr(ch u8, seq u32, definite bool, err string) []u8 {
	mut b := [u8(BridgeKind.senderr), ch]
	put_u32_le(mut b, seq)
	b << u8(if definite { 1 } else { 0 })
	bridge_put_str(mut b, err)
	return bridge_wrap(b)
}

pub fn bridge_encode_lost(ch u8, gen u32, err string) []u8 {
	mut b := [u8(BridgeKind.lost), ch]
	put_u32_le(mut b, gen)
	bridge_put_str(mut b, err)
	return bridge_wrap(b)
}

pub fn bridge_encode_refused(why string) []u8 {
	mut b := [u8(BridgeKind.refused)]
	bridge_put_str(mut b, why)
	return bridge_wrap(b)
}

pub fn bridge_encode_status(ch u8, gen u32, h BusHealth, d BusDiagnostics) []u8 {
	mut b := [u8(BridgeKind.status), ch]
	put_u32_le(mut b, gen)
	b << u8(h)
	bridge_put_u64(mut b, d.dropped)
	bridge_put_u64(mut b, d.bus_errors)
	bridge_put_u64(mut b, d.decode_errors)
	return bridge_wrap(b)
}

// BridgeReader reads the fields of one body front to back. A read past the end sets `short`
// and yields zero, so a decoder reads every field and asks once at the end.
struct BridgeReader {
	b []u8
mut:
	i     int
	short bool
}

fn (mut r BridgeReader) u8() u8 {
	if r.i + 1 > r.b.len {
		r.short = true
		return 0
	}
	r.i++
	return r.b[r.i - 1]
}

fn (mut r BridgeReader) u16() u16 {
	if r.i + 2 > r.b.len {
		r.short = true
		return 0
	}
	v := u16(r.b[r.i]) | (u16(r.b[r.i + 1]) << 8)
	r.i += 2
	return v
}

fn (mut r BridgeReader) u32() u32 {
	if r.i + 4 > r.b.len {
		r.short = true
		return 0
	}
	v := get_u32_le(r.b, r.i)
	r.i += 4
	return v
}

fn (mut r BridgeReader) u64() u64 {
	if r.i + 8 > r.b.len {
		r.short = true
		return 0
	}
	mut v := u64(0)
	for k in 0 .. 8 {
		v |= u64(r.b[r.i + k]) << (8 * k)
	}
	r.i += 8
	return v
}

fn (mut r BridgeReader) bytes(n int) []u8 {
	if r.i + n > r.b.len {
		r.short = true
		return []u8{}
	}
	v := r.b[r.i..r.i + n].clone()
	r.i += n
	return v
}

fn (mut r BridgeReader) str() string {
	n := int(r.u16())
	return r.bytes(n).bytestr()
}

// bridge_decode_body decodes one record body (the bytes after the length).
pub fn bridge_decode_body(body []u8) !BridgeRecord {
	if body.len == 0 {
		return error('empty record')
	}
	mut r := BridgeReader{
		b: body
		i: 1
	}
	kind := body[0]
	rec := match kind {
		u8(BridgeKind.hello) {
			version := r.u16()
			token := r.str()
			name := r.str()
			n := int(r.u8())
			mut chans := []string{cap: n}
			for _ in 0 .. n {
				chans << r.str()
			}
			BridgeRecord{
				kind:     .hello
				version:  version
				token:    token
				name:     name
				channels: chans
			}
		}
		u8(BridgeKind.open) {
			ch := r.u8()
			BridgeRecord{
				kind:    .open
				channel: ch
				gen:     r.u32()
			}
		}
		u8(BridgeKind.close) {
			BridgeRecord{
				kind:    .close
				channel: r.u8()
			}
		}
		u8(BridgeKind.opened), u8(BridgeKind.lost) {
			ch := r.u8()
			gen := r.u32()
			BridgeRecord{
				kind:    unsafe { BridgeKind(kind) }
				channel: ch
				gen:     gen
				error:   r.str()
			}
		}
		u8(BridgeKind.refused) {
			BridgeRecord{
				kind:  .refused
				error: r.str()
			}
		}
		u8(BridgeKind.senderr) {
			ch := r.u8()
			seq := r.u32()
			definite := r.u8() != 0
			BridgeRecord{
				kind:     .senderr
				channel:  ch
				seq:      seq
				definite: definite
				error:    r.str()
			}
		}
		u8(BridgeKind.frame) {
			ch := r.u8()
			gen := r.u32()
			flags := r.u8()
			seq := r.u32()
			id := r.u32()
			stamp := i64(r.u64())
			n := int(r.u8())
			if n > 64 {
				return error('frame record: ${n} payload bytes, at most 64')
			}
			data := r.bytes(n)
			BridgeRecord{
				kind:     .frame
				channel:  ch
				gen:      gen
				seq:      seq
				tx:       flags & bridge_flag_tx != 0
				stamp_ns: stamp
				frame:    CanFrame{
					id:       id
					extended: flags & bridge_flag_ext != 0
					rtr:      flags & bridge_flag_rtr != 0
					fd:       flags & bridge_flag_fd != 0
					brs:      flags & bridge_flag_brs != 0
					esi:      flags & bridge_flag_esi != 0
					data:     data
				}
			}
		}
		u8(BridgeKind.status) {
			ch := r.u8()
			gen := r.u32()
			h := r.u8()
			if h > u8(BusHealth.bus_off) {
				return error('status record: health ${h} is not a rung this decoder knows')
			}
			d := BusDiagnostics{
				dropped:       r.u64()
				bus_errors:    r.u64()
				decode_errors: r.u64()
			}
			BridgeRecord{
				kind:    .status
				channel: ch
				gen:     gen
				health:  unsafe { BusHealth(h) }
				diag:    d
			}
		}
		else {
			return error('unknown record kind ${kind}')
		}
	}
	if r.short {
		return error('${rec.kind} record is ${body.len} bytes, shorter than its fields')
	}
	return rec
}

// BridgeDecoder turns a TCP byte stream into records, whatever the read boundaries were.
pub struct BridgeDecoder {
mut:
	buf []u8
}

// feed appends bytes and returns every whole record they complete. An error means the stream is
// not one this decoder can follow — a length past the bound or an undecodable body — and the
// connection should be dropped: a length-prefixed stream has no boundary to resynchronise on.
pub fn (mut d BridgeDecoder) feed(data []u8) ![]BridgeRecord {
	d.buf << data
	mut out := []BridgeRecord{}
	mut at := 0
	for d.buf.len - at >= 4 {
		// Bounded while still unsigned: a length past 2^31 converted first would go negative and
		// pass the bound.
		len32 := get_u32_le(d.buf, at)
		if len32 > u32(bridge_max_record) {
			return error('record of ${len32} bytes, at most ${bridge_max_record}')
		}
		n := int(len32)
		if d.buf.len - at - 4 < n {
			break
		}
		out << bridge_decode_body(d.buf[at + 4..at + 4 + n])!
		at += 4 + n
	}
	if at > 0 {
		d.buf = d.buf[at..].clone()
	}
	return out
}
