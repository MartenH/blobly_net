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
	defer {
		srv.close_all()
	}
	srv.write(bridge_encode_hello(cfg.token, cfg.name, cfg.channels))!
	c.set_read_timeout(time.second)
	mut dec := BridgeDecoder{}
	mut buf := []u8{len: 8192}
	for {
		since := stdatomic.load_i64(&srv.writing_since)
		if since != 0 && time.ticks() - since > bridge_send_ms {
			stdatomic.store_i64(&srv.stalled, 1)
			srv.fail()
		}
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

// fail ends the connection after a write from a channel's pump failed: the stream may hold part of
// a record, and a channel that stopped forwarding must not look as if it were still open. The
// reader sees the shutdown and bridge_serve returns; the socket is closed by its caller after the
// pumps have been joined, so the descriptor is still this connection's here.
fn (mut srv BridgeServer) fail() {
	net.shutdown(srv.conn.sock.handle)
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
			srv.open_channel(rec.channel)!
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

fn (mut srv BridgeServer) open_channel(ch u8) ! {
	if ch in srv.chans {
		srv.write(bridge_encode_opened(ch, ''))!
		return
	}
	name := srv.cfg.channels[ch]
	bus := srv.cfg.opener(name) or {
		srv.write(bridge_encode_opened(ch, 'cannot open ${name}: ${err}'))!
		return
	}
	mut s := &BridgeServed{
		bus: bus
	}
	srv.chans[ch] = s
	t := spawn srv.pump(ch, mut s)
	lock s.st {
		s.st.pump = t
	}
	srv.write(bridge_encode_opened(ch, ''))!
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
		srv.write(bridge_encode_senderr(rec.channel, rec.seq, 'channel ${srv.cfg.channels[rec.channel]} is not open'))!
		return
	}
	// The output lock is held from the send to its acknowledgement, so a reply the pump hears
	// is written after the acknowledgement of the request that caused it, as the wire had them.
	srv.wmu.lock()
	defer {
		srv.wmu.unlock()
	}
	s.bus.send(rec.frame) or {
		why := if err.msg() == '' { 'the interface refused the frame' } else { err.msg() }
		srv.write_locked(bridge_encode_senderr(rec.channel, rec.seq, why))!
		return
	}
	srv.write_locked(bridge_encode_frame(rec.channel, rec.frame, rec.seq, true, bridge_stamp()))!
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
		// receive queue one write rather than one per frame.
		mut batch := []u8{}
		mut wait := bridge_pump_ms
		for batch.len < bridge_pump_batch {
			f := s.bus.recv(wait) or {
				if err.msg() != 'timeout' {
					srv.write(batch) or {}
					srv.write(bridge_encode_lost(ch, err.msg())) or {}
					return
				}
				break
			}
			stamp := if f.hw_domain == socketcan_domain { f.hw_ns } else { bridge_stamp() }
			batch << bridge_encode_frame(ch, f, 0, false, stamp)
			wait = 0
		}
		if batch.len > 0 {
			srv.write(batch) or {
				srv.fail()
				return
			}
		}
		h := s.bus.health()
		d := s.bus.diagnostics()
		if h != health || d != diag {
			health = h
			diag = d
			srv.write(bridge_encode_status(ch, h, d)) or {
				srv.fail()
				return
			}
		}
	}
}
