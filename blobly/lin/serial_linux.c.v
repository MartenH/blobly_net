// serial — LIN over a Linux serial port. One handle per device in this process; a reader thread
// decodes what the port gives through the one Decoder and, on a slave, answers the headers it
// publishes. Every read happens under the handle's lock with its decode, and a write first
// decodes what is already waiting, so the decoder sees bytes in the order the line carried them.
//
// `tty:` is a UART behind a LIN transceiver. Breaks and framing errors arrive in-band (PARMRK).
// The rate is read back from the driver, and a port that took another one is refused. A break is
// sent with TIOCSBRK/TIOCCBRK; its length is the host's, and a USB adapter, which turns each
// ioctl into a control transfer, makes the break and its delimiter longer than asked. The
// transceiver echoes everything sent — a tty needs that echo, which a transceiver on its one wire
// gives — so a handle's own header and response come back through the reader and are decoded
// with the rest; a response read back other than as written is a `bit` error on this handle's
// copy. A master and a monitor are reliable; a slave answers from a user-space thread after the
// PID arrives, so whether its response meets the master's response window depends on the
// adapter's latency (a USB adapter's latency timer, the host's scheduling): best effort.
//
// `pty:` is a pseudo-terminal, for tests and for talking to another program. A pty carries no
// break and no echo, so a break is written in-band in the PARMRK form (FF 00 00, a data 0xFF as
// FF FF), the reader passes input through untouched, and what this handle writes is fed to its
// own decoder as it goes out. `pty:<path>,plain` is a pty another program writes LIN into as it
// would into a UART: no break mark and no escaped 0xFF. What the reader takes is put into the
// PARMRK form before it is decoded — a sync byte read between frames gets the break it stood
// for — and a frame whose header came from the other end, the master there, ends when the line
// has been quiet for plain_quiet_ns.
module lin

import os
import sync
import sync.stdatomic
import time
import blobly.transport

#include "serial_shim.h"

fn C.bl_ser_open(path &char, baud i32, parmrk i32, got &u32) i32
fn C.bl_ser_raw(fd i32, baud i32, parmrk i32, got &u32) i32
fn C.bl_ser_wait(fd i32, timeout_ms i32) i32
fn C.bl_ser_read(fd i32, buf &u8, cap i32, timeout_ms i32) i32
fn C.bl_ser_write(fd i32, b &u8, n i32, timeout_ms i32) i32
fn C.bl_ser_break(fd i32, brk_ns i64, delim_ns i64) i32
fn C.bl_ser_icount(fd i32, frame &u64, parity &u64, overrun &u64) i32
fn C.bl_ser_close(fd i32)
fn C.bl_pty_new(name &u8, cap i32) i32
fn C.bl_pty_relay(a i32, b i32, timeout_ms i32, dropped &u64) i32

const serial_queue_cap = 4096
const serial_write_ms = 100 // the longest a write waits for room in the port
const serial_poll_ms = 20 // the longest the reader waits before looking at closed again

// The errnos a write or a break fails with when the port itself is gone.
const port_gone_errnos = [5, 6, 9, 19] // EIO, ENXIO, EBADF, ENODEV

struct SerialRegistry {
mut:
	open map[string]string // device -> the address that holds it
}

__global (
	lin_serial_reg shared SerialRegistry
)

// Wrote is what this handle wrote for a frame: the response (none for no response), whom the
// trace attributes it to, and whether this handle wrote the header too.
struct Wrote {
	id     u8
	bytes  []u8
	src    Src
	header bool
}

// Answer is what an entry makes this handle do after a header: bytes to write, or none when its
// fault keeps it silent.
struct Answer {
	entry Entry
	bytes ?[]u8
}

// most_pending bounds the headers awaiting their break, so the queue stays small if breaks go
// unread (a tty whose echo has stopped).
const most_pending = 4

// wake_quiet_ns is the quiet after a lone pulse that makes it a wakeup: far below the 150 ms a
// node waits after a wakeup, and above a USB adapter's usual packet gap within one burst.
const wake_quiet_ns = i64(10_000_000)

// drain_reads bounds one drain, so a port that never runs dry cannot hold the lock for ever.
const drain_reads = 4

// Counts are the port's error counters: TIOCGICOUNT's 32-bit values, or totals of their moves.
struct Counts {
mut:
	frame   u64
	parity  u64
	overrun u64
}

@[heap]
pub struct SerialBus {
mut:
	addr    SerialAddr
	key     string
	cfg     Config // its baud the port's
	idle_ns i64
	queue   chan Frame
	dropped u64
	closed  u64
	// lost_flag is set once `lost` is: the port is gone.
	lost_flag u64
	// waiting counts callers waiting for mu; the reader lets them in before it locks again.
	waiting u64
	reader  thread
	// mu guards the rest: the port, the decoder, the entries, and what this handle has sent.
	mu sync.Mutex
	fd i32 = -1 // -1 once closed
	// counted: the port keeps counters; last is their value at the last read, total what they
	// moved since open.
	counted bool
	last    Counts
	total   Counts
	dec     Decoder
	entries map[u8]Entry
	// armed: the last MasterReq addressed this handle's NAD, so its SlaveResp entry may answer.
	armed   bool
	state   State
	last_id int = -1
	// last_byte_ns is when the line last carried a byte, on the host's monotonic clock.
	last_byte_ns i64
	// slot_end_ns is when the last header's slot ends: TFrame_Maximum after it went out (this
	// handle's) or after its break was read (another node's). No header goes out before it.
	slot_end_ns i64
	brk_ns      i64  // when the last break was decoded
	own_break   bool // the last break decoded was this handle's
	// pending is the headers this handle wrote whose break has not been decoded yet.
	pending []Wrote
	// sent is what this handle wrote for the frame being read, until that frame ends.
	sent ?Wrote
	// woke: this handle sent a wakeup that has not been read yet; woke_ns when it went out.
	woke    bool
	woke_ns i64
	// brk_out: the last put's break reached the line (tty) or this handle's decoder (pty).
	brk_out bool
	// lost is why the port stopped, '' while it works.
	lost string
}

fn open_serial(a SerialAddr, cfg Config) !Bus {
	baud := serial_baud(a, cfg)!
	c := Config{
		...cfg
		baud: baud
	}
	check_config(c)!
	dev := device_path(a)!
	key := os.real_path(dev)
	lock lin_serial_reg {
		if holder := lin_serial_reg.open[key] {
			return error('lin: cannot open `${a.address}`: ${dev} is already open in this process as `${holder}`')
		}
		lin_serial_reg.open[key] = a.address
	}
	mut got := u32(0)
	fd := C.bl_ser_open(&char(dev.str), i32(baud), i32(if a.kind == .tty { 1 } else { 0 }),
		&got)
	if fd < 0 {
		release_device(key)
		return error('lin: cannot open `${a.address}`: ${os.get_error_msg(-int(fd))}')
	}
	if why := rate_refusal(a.address, c.role, baud, int(got)) {
		C.bl_ser_close(fd)
		release_device(key)
		return error(why)
	}
	mut b := &SerialBus{
		addr:    a
		key:     key
		cfg:     c
		fd:      fd
		idle_ns: serial_idle_ns(a.kind, baud)
		queue:   chan Frame{cap: serial_queue_cap}
		dec:     new_decoder(map[u8]Expect{}, baud)
	}
	mut at_open := Counts{}
	if C.bl_ser_icount(fd, &at_open.frame, &at_open.parity, &at_open.overrun) == 0 {
		b.counted = true
		b.last = at_open
	}
	b.reader = spawn b.read_loop()
	return b
}

fn release_device(key string) {
	lock lin_serial_reg {
		lin_serial_reg.open.delete(key)
	}
}

fn (b &SerialBus) is_closed() bool {
	return stdatomic.load_u64(&b.closed) != 0
}

// lock takes mu for a caller other than the reader, which steps aside for it.
fn (mut b SerialBus) lock() {
	stdatomic.add_u64(&b.waiting, 1)
	b.mu.lock()
	stdatomic.sub_u64(&b.waiting, 1)
}

// reader_lock takes mu for the reader once nobody else is waiting for it: a port that never runs
// dry would otherwise let the reader take it back every time.
fn (mut b SerialBus) reader_lock() {
	for stdatomic.load_u64(&b.waiting) > 0 && !b.is_closed() {
		time.sleep(50 * time.microsecond)
	}
	b.mu.lock()
}

fn (b &SerialBus) is_lost() bool {
	return stdatomic.load_u64(&b.lost_flag) != 0
}

// gone_locked is the error of a handle that is closed or whose port is lost. `lost` is written
// once, before lost_flag, so it may be read without mu once the flag is seen.
fn (b &SerialBus) gone_locked() IError {
	if b.is_lost() {
		return transport.carrier_gone('lin ${b.addr.address}: ${b.lost}')
	}
	return transport.carrier_gone('lin ${b.addr.address}: handle is closed')
}

// live refuses a call on a handle that is closed or whose port is lost. The caller holds mu.
fn (b &SerialBus) live() ! {
	if b.is_closed() || b.lost != '' {
		return b.gone_locked()
	}
}

// fail records that the port is gone; the reader stops and recv answers CarrierGone. The caller
// holds mu.
fn (mut b SerialBus) fail(why string) {
	if b.lost == '' {
		b.lost = why
		stdatomic.store_u64(&b.lost_flag, 1)
	}
	b.queue.close()
}

fn (b &SerialBus) usable(call string, master_only bool) ! {
	if b.cfg.role == .monitor || (master_only && b.cfg.role != .master) {
		return RoleRefused{
			role: b.cfg.role
			call: call
		}
	}
}

// relearn gives the decoder every entry's length and model. The caller holds mu.
fn (mut b SerialBus) relearn() {
	mut lengths := map[u8]Expect{}
	for id, e in b.entries {
		if e.dir != .ignore {
			lengths[id] = Expect{
				len:   e.len
				model: e.model
			}
		}
	}
	b.dec.lengths = lengths
}

// expected_len is the data length a header for id opens a slot for.
fn (b &SerialBus) expected_len(id u8) int {
	if e := b.dec.lengths[id] {
		return e.len
	}
	return max_data
}

pub fn (mut b SerialBus) set_entry(e Entry) ! {
	b.usable('set_entry', false)!
	check_entry(e)!
	b.lock()
	defer {
		b.mu.unlock()
	}
	b.live()!
	b.entries[e.id] = Entry{
		...e
		data: e.data.clone()
	}
	b.relearn()
}

pub fn (mut b SerialBus) update(id u8, data []u8) ! {
	b.usable('update', false)!
	check_id(id)!
	b.lock()
	defer {
		b.mu.unlock()
	}
	b.live()!
	e := b.entries[id] or { return error('lin: no publish entry for 0x${id:02X}') }
	if e.dir != .publish {
		return error('lin: no publish entry for 0x${id:02X}')
	}
	if data.len != e.len {
		return error('lin: 0x${id:02X} has length ${e.len}, not ${data.len}')
	}
	b.entries[id] = Entry{
		...e
		data: data.clone()
	}
}

// answer is what this handle does after a header for id, none when it has no part in it. Nothing
// is consumed: consume does that once the response is out. The caller holds mu.
fn (b &SerialBus) answer(id u8) ?Answer {
	e := b.entries[id] or { return none }
	if e.dir != .publish || (id == slave_resp && !b.armed) {
		return none
	}
	if e.inject == .silent {
		return Answer{
			entry: e
		}
	}
	return Answer{
		entry: e
		bytes: response_bytes(id, e)
	}
}

// consume uses up a one-shot entry (every SlaveResp, and the arming it answered). The caller
// holds mu.
fn (mut b SerialBus) consume(id u8, e Entry) {
	if e.one_shot || id == slave_resp {
		b.entries.delete(id)
		b.relearn()
	}
	if id == slave_resp {
		b.armed = false
	}
}

// header sends break, sync and PID once the previous slot has ended, and this handle's own
// response right after.
pub fn (mut b SerialBus) header(id u8) ! {
	b.usable('header', true)!
	check_id(id)!
	b.lock()
	defer {
		b.mu.unlock()
	}
	b.live()!
	b.wait_slot(false)!
	ans := b.answer(id)
	mut resp := []u8{}
	mut src := b.cfg.src
	if a := ans {
		if r := a.bytes {
			resp = r.clone()
			src = a.entry.src_on(b.cfg.src)
		}
	}
	// A MasterReq this handle writes arms its SlaveResp now, not when its echo is read, and only
	// a whole one with its checksum right.
	if id == master_req && resp.len == 0 {
		b.armed = false
	}
	mut bytes := [u8(0x55), pid(id)]
	bytes << resp
	b.send_header(Wrote{ id: id, bytes: resp, src: src, header: true }, bytes)!
	if a := ans {
		b.consume(id, a.entry)
	}
	if id == master_req && resp.len > 0 {
		b.armed = request_valid(resp) && names_nad(b.cfg.nad, resp)
	}
}

// sleep sends the go-to-sleep command: a MasterReq of 0x00 and seven 0xFF, classic checksum.
pub fn (mut b SerialBus) sleep() ! {
	b.usable('sleep', true)!
	b.lock()
	defer {
		b.mu.unlock()
	}
	b.live()!
	b.wait_slot(false)!
	mut resp := sleep_data()
	resp << checksum(.classic, pid(master_req), resp)
	mut bytes := [u8(0x55), pid(master_req)]
	bytes << resp
	b.send_header(Wrote{ id: master_req, bytes: resp, src: b.cfg.src, header: true }, bytes)!
	b.armed = false
}

// send_header notes a header as this handle's, opens its slot and writes it. What the port
// holds is decoded before the header is noted, so a break read in between cannot take it. A
// header whose break did not get out is forgotten, so the next break read is not matched to it.
// The caller holds mu.
fn (mut b SerialBus) send_header(w Wrote, bytes []u8) ! {
	b.drain()
	b.live()!
	if b.pending.len == most_pending {
		b.pending.delete(0)
	}
	b.pending << w
	b.put(true, bytes, false) or {
		if !b.brk_out && b.pending.len > 0 {
			b.pending.delete_last()
		}
		return err
	}
	// From when the header has gone out, so the break and the write's own time (seconds of USB
	// round trips on an adapter) never eat into the response window.
	b.slot_end_ns = i64(time.sys_mono_now()) + frame_ns_max(b.expected_len(w.id), b.cfg.baud)
}

// wakeup sends a dominant pulse of 250 us .. 5 ms (wake_byte) once the previous slot has ended.
pub fn (mut b SerialBus) wakeup() ! {
	b.usable('wakeup', false)!
	b.lock()
	defer {
		b.mu.unlock()
	}
	b.live()!
	b.wait_slot(true)!
	b.woke = true
	b.woke_ns = i64(time.sys_mono_now())
	b.put(false, [wake_byte(b.cfg.baud)], true) or {
		b.woke = false
		return err
	}
}

// wait_slot waits, with mu released, until the last header's slot has ended. Before a wakeup,
// which has no break to end what is open, an open frame or wakeup pulse is ended too: on a pty,
// whose decoder is current, once two byte times (a pulse: twice wake_quiet_ns, so another
// receiver has confirmed it) have passed since the last byte; on a tty once the reader has the echo,
// or after idle_ns. The caller holds mu.
fn (mut b SerialBus) wait_slot(ends_frame bool) ! {
	for {
		b.drain()
		b.live()!
		now := i64(time.sys_mono_now())
		mut until := b.slot_end_ns
		if ends_frame && (b.frame_open() || b.dec.st == .wake) {
			if b.addr.kind == .pty {
				quiet := b.last_byte_ns + if b.dec.st == .wake {
					2 * wake_quiet_ns
				} else {
					i64(20) * 1_000_000_000 / i64(b.cfg.baud)
				}
				if quiet > until {
					until = quiet
				}
				if now >= until {
					b.finish(b.dec.idle(b.cfg.clock.now_ns()))
					return
				}
			} else {
				if now >= until + b.idle_ns {
					b.finish(b.dec.idle(b.cfg.clock.now_ns()))
					return
				}
				until = if now >= until { now + 1_000_000 } else { until }
			}
		} else if ends_frame && b.woke && b.addr.kind == .tty
			&& now < b.woke_ns + b.idle_ns + 20_000_000 {
			// this handle's last wakeup has not come back yet
			until = now + 1_000_000
		}
		if now >= until {
			return
		}
		left := until - now
		b.mu.unlock()
		time.sleep(if left < 1_000_000 { left } else { 1_000_000 })
		b.lock()
	}
}

// frame_open is whether the decoder is inside a frame. The caller holds mu.
fn (b &SerialBus) frame_open() bool {
	return b.dec.st in [.after_brk, .want_pid, .response, .tail]
}

// put writes a break (optional) and bytes, after decoding what the port already holds when
// `drain` asks it. On a pty they are written in-band and fed to this handle's own decoder,
// since nothing echoes them. brk_out says whether the break got out. The caller holds mu.
fn (mut b SerialBus) put(brk bool, bytes []u8, drain bool) ! {
	b.brk_out = false
	if drain {
		b.drain()
		b.live()!
	}
	if b.addr.kind == .tty {
		if brk {
			r := C.bl_ser_break(b.fd, break_ns(b.cfg.baud), delimiter_ns(b.cfg.baud))
			if r < 0 {
				return b.port_error('break', -int(r))
			}
			b.brk_out = true
		}
		r := C.bl_ser_write(b.fd, bytes.data, i32(bytes.len), serial_write_ms)
		if r < 0 {
			return b.port_error('write', -int(r))
		}
		return
	}
	enc := pty_bytes(brk, bytes)
	out := if b.addr.plain { bytes } else { enc }
	r := C.bl_ser_write(b.fd, out.data, i32(out.len), serial_write_ms)
	if r < 0 {
		return b.port_error('write', -int(r))
	}
	b.brk_out = brk
	b.last_byte_ns = i64(time.sys_mono_now())
	b.decode(enc, b.cfg.clock.now_ns())
}

// port_error is a failed write or break: CarrierGone when the port itself is gone, which also
// stops the reader. The caller holds mu.
fn (mut b SerialBus) port_error(what string, errno int) IError {
	msg := '${what}: ${os.get_error_msg(errno)}'
	if errno in port_gone_errnos {
		b.fail(msg)
		return b.gone_locked()
	}
	return error('lin ${b.addr.address}: ${msg}')
}

// drain reads and decodes what the port holds now, without waiting, at most drain_reads reads.
// The caller holds mu.
fn (mut b SerialBus) drain() {
	if b.lost != '' || b.fd < 0 {
		return
	}
	mut buf := []u8{len: 256}
	for _ in 0 .. drain_reads {
		n := C.bl_ser_read(b.fd, buf.data, i32(buf.len), 0)
		if n < 0 {
			b.fail(os.get_error_msg(-int(n)))
			return
		}
		if n == 0 {
			return
		}
		now := i64(time.sys_mono_now())
		if b.addr.plain {
			// a frame the quiet before these bytes has ended is over before they are read
			if b.dec.wants_idle() && now >= b.end_at() {
				b.finish(b.dec.idle(b.cfg.clock.now_ns()))
			}
			b.last_byte_ns = now
			b.decode_plain(buf[..n], b.cfg.clock.now_ns())
			continue
		}
		b.last_byte_ns = now
		b.decode(buf[..n], b.cfg.clock.now_ns())
	}
}

// end_at is when the decoder's open frame, or a stray byte's hold on the next wakeup, ends: once
// the line has been quiet for idle_ns (a wakeup pulse for wake_quiet_ns), or, for a response that has begun and has either reached
// its length or has none stated, when its slot ends. The caller holds mu.
fn (b &SerialBus) end_at() i64 {
	if b.dec.st == .wake {
		return b.last_byte_ns + wake_quiet_ns
	}
	if b.addr.plain && b.frame_open() && !b.own_break {
		quiet := b.last_byte_ns + plain_quiet_ns(b.cfg.baud)
		// a response of a stated length not begun yet may come late from a slave behind the
		// other end, as on a wire: it has its slot
		if b.dec.awaits_response() && b.slot_end_ns > quiet {
			return b.slot_end_ns
		}
		return quiet
	}
	idle_at := b.last_byte_ns + b.idle_ns
	if b.dec.response_begun() {
		end := response_end(b.addr.kind, b.dec.st == .tail, b.slot_end_ns)
		if end < idle_at {
			return end
		}
	}
	return idle_at
}

// read_loop waits for the port and decodes what it has under mu, until the handle closes or
// the port fails; what is open is ended at end_at.
fn (mut b SerialBus) read_loop() {
	for {
		b.reader_lock()
		if b.is_closed() || b.lost != '' {
			b.mu.unlock()
			return
		}
		mut wait := i64(serial_poll_ms)
		if b.dec.wants_idle() {
			left := b.end_at() - i64(time.sys_mono_now())
			wait = if left <= 0 { 0 } else { (left + 999_999) / 1_000_000 }
			if wait > serial_poll_ms {
				wait = serial_poll_ms
			}
		}
		fd := b.fd
		b.mu.unlock()
		r := C.bl_ser_wait(fd, i32(wait))
		b.reader_lock()
		if r < 0 {
			b.fail(os.get_error_msg(-int(r)))
		} else if r > 0 {
			b.drain()
		}
		if b.lost == '' && b.dec.wants_idle() && i64(time.sys_mono_now()) >= b.end_at() {
			b.finish(b.dec.idle(b.cfg.clock.now_ns()))
		}
		b.mu.unlock()
	}
}

// decode feeds the decoder a byte at a time, so that at a break the header this handle wrote
// becomes its own (after the frame the break ended is finished), the slot of another node's
// header is known, and a slave answers a header it publishes as soon as the PID is in. The
// caller holds mu.
fn (mut b SerialBus) decode(bytes []u8, now i64) {
	for i in 0 .. bytes.len {
		brk := b.dec.esc == 2 && bytes[i] == 0
		at_pid := b.dec.st == .want_pid
		b.finish(b.dec.feed(bytes[i..i + 1], now))
		if brk {
			mono := i64(time.sys_mono_now())
			b.brk_ns = mono
			b.woke = false
			b.own_break = b.pending.len > 0
			if b.own_break {
				b.sent = b.pending[0]
				b.pending.delete(0)
			} else {
				b.slot_end_ns = mono + frame_ns_max(max_data, b.cfg.baud)
			}
		}
		if at_pid && b.dec.st == .response {
			id := b.dec.id
			if !b.own_break {
				b.slot_end_ns = b.brk_ns + frame_ns_max(b.expected_len(id), b.cfg.baud)
			}
			if b.cfg.role == .slave {
				b.respond(id)
			}
		}
	}
}

// decode_plain decodes bytes read from a plain pty in the PARMRK form: a sync byte read between
// frames as the break it follows, a 0xFF as FF FF. The caller holds mu.
fn (mut b SerialBus) decode_plain(bytes []u8, now i64) {
	for x in bytes {
		// a frame at its length is over on a plain pty, which has no break to end a long one
		if x == 0x55 && b.dec.st in [.idle, .wake, .tail] {
			b.decode([u8(0xFF), 0x00, 0x00, 0x55], now)
		} else if x == 0xFF {
			b.decode([u8(0xFF), 0xFF], now)
		} else {
			b.decode([x], now)
		}
	}
}

// respond answers a header a slave read, if it publishes the id. A response that cannot be
// written is not on the wire: the frame is not this handle's and the entry is kept. The caller
// holds mu.
fn (mut b SerialBus) respond(id u8) {
	a := b.answer(id) or { return }
	if bytes := a.bytes {
		b.sent = Wrote{
			id:    id
			bytes: bytes
			src:   a.entry.src_on(b.cfg.src)
		}
		b.put(false, bytes, false) or {
			b.sent = none
			return
		}
	}
	b.consume(id, a.entry)
}

// finish gives decoded frames what this handle knows of them — whether it sent the header, the
// response or the event, and so whose they are — keeps the bus state, arms a SlaveResp from a
// MasterReq another node wrote, and queues them. On a tty a response this handle sent is checked
// against what came back. The caller holds mu.
fn (mut b SerialBus) finish(frames []Frame) {
	for g in frames {
		mut f := g
		if f.event == .wakeup {
			f.ours = b.woke
			b.woke = false
			b.state = .active
			f.src = if f.ours { b.cfg.src } else { Src.remote }
		} else {
			mut resp_src := ?Src(none)
			if sent := b.sent {
				f.header = sent.header
				if sent.bytes.len > 0 && has_id(f) && f.id == sent.id {
					f.ours = true
					resp_src = sent.src
					if b.addr.kind == .tty
						&& (f.raw.len < sent.bytes.len || f.raw[..sent.bytes.len] != sent.bytes) {
						f.errs.set(.bit)
						f.event = .frame
					}
				}
			}
			b.sent = none
			if has_id(f) {
				b.last_id = f.id
				// this handle's own MasterReq armed at its write, and is only undone by a bad echo
				if f.id == master_req && f.header && f.ours {
					if f.errs != Errs.zero() || f.event != .frame {
						b.armed = false
					}
				} else if f.id == master_req {
					b.armed = f.errs == Errs.zero() && f.event == .frame
						&& names_nad(b.cfg.nad, f.data)
				}
			}
			b.state = if f.event == .sleep { State.sleep } else { State.active }
			f.src = if s := resp_src {
				s
			} else if f.header && f.raw.len == 0 {
				b.cfg.src
			} else {
				Src.remote
			}
		}
		if b.queue.try_push(f) != .success {
			stdatomic.add_u64(&b.dropped, 1)
		}
	}
}

// recv: a closed handle is gone, whatever is still queued on it; so is one whose port failed.
// It takes no lock, so a look is immediate whatever a writer is waiting on.
pub fn (mut b SerialBus) recv(timeout_ms int) !Frame {
	if b.is_closed() || b.is_lost() {
		return b.gone_locked()
	}
	f := queue_pop(b.queue, timeout_ms) or {
		if err is QueueClosed {
			return b.gone_locked()
		}
		return err
	}
	if b.is_closed() || b.is_lost() {
		return b.gone_locked()
	}
	return f
}

pub fn (mut b SerialBus) status() Status {
	b.lock()
	defer {
		b.mu.unlock()
	}
	return Status{
		state:   b.state
		last_id: b.last_id
	}
}

// count adds what the port's 32-bit counters moved since the last read to the totals. The
// caller holds mu.
fn (mut b SerialBus) count() {
	if !b.counted || b.fd < 0 {
		return
	}
	mut c := Counts{}
	if C.bl_ser_icount(b.fd, &c.frame, &c.parity, &c.overrun) < 0 {
		return
	}
	b.total.frame += wrap_delta(c.frame, b.last.frame)
	b.total.parity += wrap_delta(c.parity, b.last.parity)
	b.total.overrun += wrap_delta(c.overrun, b.last.overrun)
	b.last = c
}

// diagnostics: frames the queue had no room for and bytes the port overran, as dropped; framing
// and parity errors the port counted since open, as bus errors; bytes read outside any frame, as
// decode errors. A pty keeps no port counts; a closed handle reports the counts it closed with.
pub fn (mut b SerialBus) diagnostics() transport.BusDiagnostics {
	b.lock()
	b.count()
	t := b.total
	stray := b.dec.stray
	b.mu.unlock()
	return transport.BusDiagnostics{
		dropped:       stdatomic.load_u64(&b.dropped) + t.overrun
		bus_errors:    t.frame + t.parity
		decode_errors: stray
	}
}

// close ends the reader, closes the port and frees the device for another open.
pub fn (mut b SerialBus) close() {
	b.lock()
	if b.is_closed() {
		b.mu.unlock()
		return
	}
	stdatomic.store_u64(&b.closed, 1)
	b.entries.clear()
	b.mu.unlock()
	b.reader.wait()
	b.lock()
	b.count()
	C.bl_ser_close(b.fd)
	b.fd = -1
	b.mu.unlock()
	release_device(b.key)
	b.queue.close()
}

// PtyLink is two pseudo-terminals joined like a null-modem cable: what is written to one's path
// is read at the other's. Each slave end is held open by the link, so a program closing its end
// does not hang the link up, and stays raw for the next one to open it.
@[heap]
pub struct PtyLink {
pub:
	a string
	b string
mut:
	ma      i32 = -1
	mb      i32 = -1
	ha      i32 = -1
	hb      i32 = -1
	stop    u64
	dropped u64
	relay   thread
}

// pty_link opens a linked pair of pseudo-terminals; `a` and `b` are their paths.
pub fn pty_link() !&PtyLink {
	mut name := []u8{len: 64}
	ma := C.bl_pty_new(name.data, 64)
	if ma < 0 {
		return error('lin: cannot open a pty: ${os.get_error_msg(-int(ma))}')
	}
	a := unsafe { cstring_to_vstring(&char(name.data)) }
	mb := C.bl_pty_new(name.data, 64)
	if mb < 0 {
		C.bl_ser_close(ma)
		return error('lin: cannot open a pty: ${os.get_error_msg(-int(mb))}')
	}
	b := unsafe { cstring_to_vstring(&char(name.data)) }
	mut got := u32(0)
	ha := C.bl_ser_open(&char(a.str), default_baud, 0, &got)
	hb := C.bl_ser_open(&char(b.str), default_baud, 0, &got)
	if ha < 0 || hb < 0 {
		for fd in [ma, mb, ha, hb] {
			if fd >= 0 {
				C.bl_ser_close(fd)
			}
		}
		return error('lin: cannot hold the pty ends open: ${os.get_error_msg(-int(if ha < 0 {
			ha
		} else {
			hb
		}))}')
	}
	C.bl_ser_raw(ma, default_baud, 0, &got)
	C.bl_ser_raw(mb, default_baud, 0, &got)
	mut l := &PtyLink{
		a:  a
		b:  b
		ma: ma
		mb: mb
		ha: ha
		hb: hb
	}
	l.relay = spawn l.run()
	return l
}

fn (mut l PtyLink) run() {
	for stdatomic.load_u64(&l.stop) == 0 {
		if C.bl_pty_relay(l.ma, l.mb, serial_poll_ms, &l.dropped) < 0 {
			return
		}
	}
}

// dropped is bytes one end had no room for, because nothing read it.
pub fn (l &PtyLink) dropped() u64 {
	return stdatomic.load_u64(&l.dropped)
}

// close ends the link; both paths go away.
pub fn (mut l PtyLink) close() {
	if stdatomic.fetch_add_u64(&l.stop, 1) != 0 {
		return
	}
	l.relay.wait()
	for fd in [l.ma, l.mb, l.ha, l.hb] {
		C.bl_ser_close(fd)
	}
}
