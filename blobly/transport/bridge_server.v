// The bridge's side of a CAN bridge (#451): it has dialled the app, offers its channels in a
// hello, and from then on opens what the app asks for, puts the app's frames on the channel and
// returns every frame the channel carries.
//
// Written over the Bus interface rather than SocketCAN, so a test can run it over in-process
// buses; `cmd/canbridge` runs it over the host's CAN interfaces. A Bus does not hand a sender
// its own frame back, so the acknowledgement of a send is built here, stamped when the bus
// accepted it.
module transport

import io
import net
import sync
import sync.stdatomic
import time

// How long one receive on a served channel waits before it looks at the channel's health.
const bridge_pump_ms = 100

// How many bytes of frame records one write may carry: a few hundred frames.
const bridge_pump_batch = 32768

pub struct BridgeServeCfg {
pub:
	token    string
	name     string
	channels []string
	// What opens a channel by its name. `open` on the bridge's host by default.
	opener fn (string) !Bus = open
}

struct BridgeServedState {
mut:
	running bool = true
	pump    thread
	// The app's number for this open of the channel, carried by every record about it.
	gen u32
	// Frame records the pump has received and not yet written. Here rather than in the pump, so a
	// send writes them ahead of its acknowledgement: they were on the wire before it.
	pending []u8
}

// BridgeServed is one channel the app has open.
@[heap]
struct BridgeServed {
mut:
	bus Bus
	st  shared BridgeServedState
}

@[heap]
struct BridgeServer {
	cfg BridgeServeCfg
mut:
	conn  &net.TcpConn
	wmu   &sync.Mutex = sync.new_mutex()
	chans map[u8]&BridgeServed
	// When the write in progress began, or 0; read by the reader, which ends a connection whose
	// write has stalled (an app that stopped reading without closing). Atomic: written by every
	// writer, read by the reader.
	writing_since i64
	stalled       i64
	done          i64
}

// bridge_stamp is the bridge host's monotonic clock now, the domain every stamp it sends is in.
fn bridge_stamp() i64 {
	return i64(time.sys_mono_now())
}

// bridge_serve runs the bridge over a connection to the app until the app closes it, then closes
// every channel it opened. An error is a connection that failed rather than ended.
pub fn bridge_serve(mut c net.TcpConn, cfg BridgeServeCfg) ! {
	if cfg.channels.len == 0 {
		return error('a bridge needs at least one channel to offer')
	}
	if cfg.channels.len > bridge_max_channels {
		return error('a bridge offers at most ${bridge_max_channels} channels, not ${cfg.channels.len}')
	}
	if why := bridge_label_error(cfg.name, cfg.channels) {
		return error(why)
	}
	mut srv := &BridgeServer{
		cfg:  cfg
		conn: c
	}
	// The watchdog outlives the channels' teardown — a pump stuck in a write is what it unsticks —
	// and ends before this returns, since the caller closes the socket it shuts down. Deferred
	// first, so it runs last.
	wd := spawn srv.watchdog()
	defer {
		stdatomic.store_i64(&srv.done, 1)
		wd.wait()
	}
	defer {
		srv.close_all()
	}
	srv.write(bridge_encode_hello(cfg.token, cfg.name, cfg.channels, ''))!
	c.set_read_timeout(time.second)
	mut dec := BridgeDecoder{}
	mut buf := []u8{len: 8192}
	for {
		recs := bridge_read(mut c, mut dec, mut buf) or {
			if stdatomic.load_i64(&srv.stalled) != 0 {
				return error('a write to the app stalled for more than ${bridge_send_ms} ms')
			}
			if bridge_is_timeout(err) {
				continue
			}
			if err is io.Eof {
				return
			}
			return err
		}
		for rec in recs {
			srv.handle(rec)!
		}
	}
}

// watchdog ends a connection whose write has stalled — an app that stopped reading without
// closing — on its own thread, because any thread can be the one stuck in that write, the reader
// included (it writes the acknowledgement of a send).
fn (mut srv BridgeServer) watchdog() {
	for stdatomic.load_i64(&srv.done) == 0 {
		since := stdatomic.load_i64(&srv.writing_since)
		if since != 0 && time.ticks() - since > bridge_send_ms
			&& stdatomic.load_i64(&srv.stalled) == 0 {
			stdatomic.store_i64(&srv.stalled, 1)
			srv.fail()
		}
		time.sleep(100 * time.millisecond)
	}
}

// fail ends the connection after a write from a channel's pump failed: the stream may hold part of
// a record, and a channel that stopped forwarding must not look as if it were still open. The
// reader sees the shutdown and bridge_serve returns; the socket is closed by its caller after the
// pumps have been joined, so the descriptor is still this connection's here.
fn (mut srv BridgeServer) fail() {
	net.shutdown(srv.conn.sock.handle)
}

// bridge_report_failure tells the app this bridge could not start, and why, in place of a hello
// offering channels: a bridge the app launched has no console anybody sees.
pub fn bridge_report_failure(mut c net.TcpConn, token string, name string, why string) ! {
	c.write(bridge_encode_hello(token, name, [], why))!
}

fn (mut srv BridgeServer) write(rec []u8) ! {
	srv.wmu.lock()
	defer {
		srv.wmu.unlock()
	}
	srv.write_locked(rec)!
}

fn (mut srv BridgeServer) write_locked(rec []u8) ! {
	stdatomic.store_i64(&srv.writing_since, time.ticks())
	defer {
		stdatomic.store_i64(&srv.writing_since, 0)
	}
	srv.conn.write(rec)!
}

// handle acts on one record from the app.
fn (mut srv BridgeServer) handle(rec BridgeRecord) ! {
	if rec.kind != .refused && int(rec.channel) >= srv.cfg.channels.len {
		return error('the app named channel ${rec.channel}; this bridge offers ${srv.cfg.channels.len}')
	}
	match rec.kind {
		.open {
			srv.open_channel(rec.channel, rec.gen)!
		}
		.close {
			srv.close_channel(rec.channel)
		}
		.frame {
			srv.send_frame(rec)!
		}
		.refused {
			return error('the app refused this bridge: ${rec.error}')
		}
		else {
			return error('the app sent a ${rec.kind} record')
		}
	}
}

fn (mut srv BridgeServer) open_channel(ch u8, gen u32) ! {
	// Already open: from here its records are this open's.
	if mut s := srv.chans[ch] {
		lock s.st {
			s.st.gen = gen
		}
		srv.write(bridge_encode_opened(ch, gen, ''))!
		return
	}
	name := srv.cfg.channels[ch]
	bus := srv.cfg.opener(name) or {
		srv.write(bridge_encode_opened(ch, gen, 'cannot open ${name}: ${err}'))!
		return
	}
	mut s := &BridgeServed{
		bus: bus
	}
	lock s.st {
		s.st.gen = gen
	}
	srv.chans[ch] = s
	t := spawn srv.pump(ch, mut s)
	lock s.st {
		s.st.pump = t
	}
	srv.write(bridge_encode_opened(ch, gen, ''))!
}

// flush writes the channel's pending frame records.
fn (mut srv BridgeServer) flush(mut s BridgeServed) ! {
	srv.wmu.lock()
	defer {
		srv.wmu.unlock()
	}
	srv.flush_locked(mut s)!
}

// flush_locked is flush for a caller holding the output lock. The records are taken under the
// channel's lock and written under the output lock, so none is written twice or out of order.
fn (mut srv BridgeServer) flush_locked(mut s BridgeServed) ! {
	recs := lock s.st {
		p := s.st.pending
		s.st.pending = []u8{}
		p
	}
	if recs.len > 0 {
		srv.write_locked(recs)!
	}
}

// served_gen is the open a channel's records are currently about.
fn served_gen(s &BridgeServed) u32 {
	return rlock s.st {
		s.st.gen
	}
}

// send_refusal_definite is whether a send that `name`'s bus refused certainly did not reach the
// wire: a driver's own refusal, or any failure of a SocketCAN write (the kernel takes a frame
// whole or not at all). Anything else may have reached the wire before it failed.
fn send_refusal_definite(name string, err IError) bool {
	return err is NotWritten || !name.contains(':')
}

fn (mut srv BridgeServer) close_channel(ch u8) {
	mut s := srv.chans[ch] or { return }
	srv.chans.delete(ch)
	t := lock s.st {
		s.st.running = false
		s.st.pump
	}
	t.wait()
	s.bus.close()
}

fn (mut srv BridgeServer) close_all() {
	for ch in srv.chans.keys() {
		srv.close_channel(ch)
	}
}

// send_frame puts the app's frame on the channel and answers with its acknowledgement, or with
// why it did not go out.
fn (mut srv BridgeServer) send_frame(rec BridgeRecord) ! {
	mut s := srv.chans[rec.channel] or {
		srv.write(bridge_encode_senderr(rec.channel, rec.seq, true, 'channel ${srv.cfg.channels[rec.channel]} is not open'))!
		return
	}
	// The output lock is held from the send to its acknowledgement, so a reply the pump hears
	// is written after the acknowledgement of the request that caused it, as the wire had them.
	srv.wmu.lock()
	defer {
		srv.wmu.unlock()
	}
	// What the channel received before this send goes out before its acknowledgement.
	srv.flush_locked(mut s)!
	s.bus.send(rec.frame) or {
		why := if err.msg() == '' { 'the interface refused the frame' } else { err.msg() }
		definite := send_refusal_definite(srv.cfg.channels[rec.channel], err)
		srv.write_locked(bridge_encode_senderr(rec.channel, rec.seq, definite, why))!
		return
	}
	srv.write_locked(bridge_encode_frame(rec.channel, served_gen(s), rec.frame, rec.seq, true,
		bridge_stamp()))!
}

// pump returns every frame the channel receives, and its health and counts whenever they change,
// until the channel is closed or fails.
fn (mut srv BridgeServer) pump(ch u8, mut s BridgeServed) {
	mut health := BusHealth.unknown
	mut diag := BusDiagnostics{}
	for {
		if !rlock s.st {
			s.st.running
		} {
			return
		}
		// Everything the channel has queued goes out in one write, so a burst costs the interface's
		// receive queue one write rather than one per frame. Collected into the channel's pending
		// records, which a send flushes ahead of its acknowledgement.
		mut wait := bridge_pump_ms
		for {
			f := s.bus.recv(wait) or {
				if err.msg() != 'timeout' {
					srv.flush(mut s) or {}
					srv.write(bridge_encode_lost(ch, served_gen(s), err.msg())) or {}
					return
				}
				break
			}
			stamp := if f.hw_domain == socketcan_domain { f.hw_ns } else { bridge_stamp() }
			rec := bridge_encode_frame(ch, served_gen(s), f, 0, false, stamp)
			full := lock s.st {
				s.st.pending << rec
				s.st.pending.len >= bridge_pump_batch
			}
			if full {
				break
			}
			wait = 0
		}
		srv.flush(mut s) or {
			srv.fail()
			return
		}
		h := s.bus.health()
		d := s.bus.diagnostics()
		if h != health || d != diag {
			health = h
			diag = d
			srv.write(bridge_encode_status(ch, served_gen(s), h, d)) or {
				srv.fail()
				return
			}
		}
	}
}
