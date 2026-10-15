// The app's side of a CAN bridge: the listener bridges dial in to, one session per connected
// bridge, and the `bridge:<name>/<channel>` backend that opens a channel on one (#451).
//
// The listener is process-wide and bound to loopback. `bridge_listen` starts it once and hands
// back the port and a token; whatever launches a bridge passes both on its command line, and a
// connection whose hello does not carry the token is told so and closed. A bridge's name is the
// session's identity — `bridge:Ubuntu-24.04/vcan0` survives the port changing on every launch —
// and a bridge that dials in under a name already connected REPLACES that session: a bridge
// restarted after its host went away without closing the connection (WSL shut down under it)
// must not be refused by the ghost of itself.
//
// A channel is opened through `shared_open_events`, like a CANsub's: one driver per wire however
// many handles a Start opens on it. The driver asks the bridge to open the channel, sends frames
// over the session's connection and waits for each one's acknowledgement, and receives what the
// session's reader thread files under the channel. The acknowledgement comes back on the receive
// stream marked as a TX ack, which is how the hub tells this process's frames from the bus's.
module transport

import crypto.rand as crypto_rand
import io
import net
import sync
import time

// How long a new connection may take to say hello before it is dropped.
const bridge_hello_ms = 5000

// How long a channel open waits for the bridge's answer.
const bridge_open_ms = 3000

// How long a send waits for its acknowledgement, and how long one write to the connection may
// take. A bridge answers every frame it is sent, so running out means the bridge has stopped, not
// that the bus is slow, and the session is ended.
const bridge_send_ms = 2000

// The ceiling on one wait inside recv and send, so a dead session is noticed.
const bridge_poll_ms = i64(100)

// Received frames queued per channel before further arrivals are dropped and counted.
const bridge_queue_cap = 4096

// Room beyond that kept for TX acknowledgements alone: a send reports success when its
// acknowledgement arrives, so the hub must get that acknowledgement too, however far behind the
// bus has left it. Order is kept — nothing is evicted — and only a hub this many acknowledgements
// behind on top of a full queue loses one.
const bridge_ack_reserve = 256

// BridgeSpec is a parsed `bridge:<name>/<channel>`.
pub struct BridgeSpec {
pub:
	name    string
	channel string
}

// parse_bridge_iface reads `bridge:<name>/<channel>`. The channel is everything after the last
// '/', since an interface name cannot contain one.
pub fn parse_bridge_iface(iface string) !BridgeSpec {
	if !iface.starts_with('bridge:') {
		return error('"${iface}" is not a bridge interface')
	}
	body := iface['bridge:'.len..]
	name := body.all_before_last('/')
	ch := body.all_after_last('/')
	if !body.contains('/') || name == '' || ch == '' {
		return error('"${iface}" is not bridge:<name>/<channel>')
	}
	if body.contains('@') {
		return error('"${iface}": a bridge channel takes no bitrate here; it is set on the bridge\'s host')
	}
	return BridgeSpec{
		name:    name
		channel: ch
	}
}

// bridge_domain is the clock domain of one session of a bridge: its host's monotonic clock, in
// the epoch that session started in. Per SESSION, because a bridge that reconnects may do so after
// its host restarted, with a clock that started again; one domain is one clock and one epoch.
pub fn bridge_domain(name string, session u64) string {
	return 'bridge:${name}#${session}'
}

// BridgeEndpoint is what a bridge needs to dial in.
pub struct BridgeEndpoint {
pub:
	port  int
	token string
}

struct BridgeResult {
	seq      u32
	failed   bool
	definite bool // the frame certainly did not reach the wire
	err      string
}

struct BridgeChanState {
mut:
	health BusHealth
	// What the bridge reported about its own side of the channel.
	remote BusDiagnostics
	// Frames this side dropped because the channel's queue was full.
	dropped u64
	// Why the bridge closed the channel, once it has.
	lost      bool
	lost_why  string
	closed    bool
}

// BridgeChan is one open channel's mailboxes, filled by the session's reader thread.
@[heap]
struct BridgeChan {
	// This open's number: every record about it carries it, and one carrying another is from a
	// previous open of the channel, still in the stream.
	gen     u32
	rx      chan SharedIngress
	results chan BridgeResult
	opened  chan string
mut:
	st shared BridgeChanState
}

struct BridgeSessionState {
mut:
	chans map[u8]&BridgeChan
	ended bool
	err   string
	seq   u32
	// When the write in progress began, or 0. A write to a bridge that stopped reading (its host
	// asleep) blocks once the socket's buffer is full, whatever timeout is set, so the reader —
	// which wakes at least once a second — cuts a session whose write has stalled.
	writing_since i64
}

// BridgeSession is one connected bridge. Its reader thread owns the connection's receive side
// and closes the connection when it ends; writers serialise on `wmu`. Anything else that has to
// stop the session shuts the socket down through `cut`, under `cmu`, which no I/O ever holds —
// so a write stalled on a bridge that stopped reading cannot hold up its own teardown.
@[heap]
struct BridgeSession {
	name     string
	channels []string
	domain   string
mut:
	conn   &net.TcpConn
	wmu    &sync.Mutex = sync.new_mutex()
	cmu    &sync.Mutex = sync.new_mutex()
	closed bool // under cmu: the socket is closed, so its descriptor may already be reused
	st     shared BridgeSessionState
}

struct BridgeRegistry {
mut:
	port     int
	token    string
	sessions map[string]&BridgeSession
	// Sessions accepted so far: each gets its own clock domain.
	session_count u64
}

__global (
	bridge_reg shared BridgeRegistry
)

// bridge_listen starts the process's bridge listener on loopback, once, and returns where a
// bridge dials and the token it must present.
pub fn bridge_listen() !BridgeEndpoint {
	mut ep := BridgeEndpoint{}
	lock bridge_reg {
		if bridge_reg.port == 0 {
			// Everything that can fail first, so a failure leaves nothing half-published.
			token := (crypto_rand.bytes(16)!).hex()
			mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
			port := int(l.addr()!.port()!)
			spawn bridge_accept_loop(mut l, token)
			bridge_reg.token = token
			bridge_reg.port = port
		}
		ep = BridgeEndpoint{
			port:  bridge_reg.port
			token: bridge_reg.token
		}
	}
	return ep
}

fn bridge_accept_loop(mut l net.TcpListener, token string) {
	for {
		mut c := l.accept() or {
			time.sleep(50 * time.millisecond)
			continue
		}
		spawn bridge_session_run(mut c, token)
	}
}

// bridge_session reports the connected bridge of that name.
fn bridge_session(name string) ?&BridgeSession {
	return rlock bridge_reg {
		bridge_reg.sessions[name] or { none }
	}
}

// bridge_names lists the connected bridges.
pub fn bridge_names() []string {
	mut out := rlock bridge_reg {
		bridge_reg.sessions.keys()
	}
	out.sort()
	return out
}

// bridge_rows is one Discover row per channel of every connected bridge.
pub fn bridge_rows() []Iface {
	mut out := []Iface{}
	for name in bridge_names() {
		s := bridge_session(name) or { continue }
		for ch in s.channels {
			out << Iface{
				name:  '${ch} (${name})'
				iface: 'bridge:${name}/${ch}'
				kind:  'bridge'
			}
		}
	}
	return out
}

// bridge_drop disconnects the named bridge, which ends it: a bridge exits when its connection
// closes. Every channel open on it fails.
pub fn bridge_drop(name string) {
	if mut s := bridge_session(name) {
		s.cut('disconnected by this app')
	}
}

// bridge_read reads once from the connection and returns the records it completed.
fn bridge_read(mut c net.TcpConn, mut dec BridgeDecoder, mut buf []u8) ![]BridgeRecord {
	n := c.read(mut buf)!
	return dec.feed(buf[..n])!
}

fn bridge_is_timeout(err IError) bool {
	return err.code() == net.err_timed_out_code
}

// bridge_refusal is why a hello is not accepted, or none.
fn bridge_refusal(hello BridgeRecord, token string) ?string {
	if hello.kind != .hello {
		return 'the first record was ${hello.kind}, not a hello'
	}
	if hello.version != bridge_version {
		return 'protocol version ${hello.version}; this app speaks ${bridge_version}'
	}
	if hello.token != token {
		return 'wrong token'
	}
	if hello.channels.len == 0 {
		return 'no channels offered'
	}
	if why := bridge_label_error(hello.name, hello.channels) {
		return why
	}
	return none
}

// bridge_max_label is the longest bridge or channel name: one is a WSL distribution's name, the
// other an interface's, and both are part of an address.
pub const bridge_max_label = 255

// bridge_label_error is why a bridge name and its channel names cannot all be spelled as
// `bridge:<name>/<channel>`, or none. Asked by the bridge before it says hello and by the app of
// the hello it hears, so a channel is never offered that no address could open.
pub fn bridge_label_error(name string, channels []string) ?string {
	for label in [name] {
		if label == '' || label.len > bridge_max_label || label.contains('/') || label.contains('@') {
			return 'the bridge name "${label}" cannot be part of an address bridge:<name>/<channel>'
		}
	}
	mut seen := map[string]bool{}
	for ch in channels {
		if ch == '' || ch.len > bridge_max_label || ch.contains('/') || ch.contains('@') {
			return 'the channel name "${ch}" cannot be part of an address bridge:<name>/<channel>'
		}
		if ch in seen {
			return 'the channel ${ch} is offered twice'
		}
		seen[ch] = true
	}
	return none
}

// bridge_session_run serves one connection: the hello, then every record until it ends.
fn bridge_session_run(mut c net.TcpConn, token string) {
	mut dec := BridgeDecoder{}
	mut buf := []u8{len: 65536}
	c.set_write_timeout(bridge_send_ms * time.millisecond)
	// The first record must be a hello carrying the token, and must arrive in time.
	deadline := time.ticks() + bridge_hello_ms
	mut recs := []BridgeRecord{}
	for recs.len == 0 {
		left := deadline - time.ticks()
		if left <= 0 {
			c.close() or {}
			return
		}
		c.set_read_timeout(left * time.millisecond)
		recs = bridge_read(mut c, mut dec, mut buf) or {
			c.close() or {}
			return
		}
	}
	hello := recs[0]
	if why := bridge_refusal(hello, token) {
		c.write(bridge_encode_refused(why)) or {}
		c.close() or {}
		return
	}
	session := lock bridge_reg {
		bridge_reg.session_count++
		bridge_reg.session_count
	}
	mut s := &BridgeSession{
		name:     hello.name
		channels: hello.channels
		domain:   bridge_domain(hello.name, session)
		conn:     c
	}
	mut replaced := ?&BridgeSession(none)
	lock bridge_reg {
		replaced = bridge_reg.sessions[hello.name] or { none }
		bridge_reg.sessions[hello.name] = s
	}
	if mut old := replaced {
		old.cut('replaced by a new connection from the same bridge')
	}
	c.set_read_timeout(time.second)
	mut why := ''
	for rec in recs[1..] {
		s.dispatch(rec) or {
			why = err.msg()
			break
		}
	}
	// Records until the bridge goes away or says something this side cannot follow.
	for why == '' {
		s.check_stall()
		more := bridge_read(mut c, mut dec, mut buf) or {
			if bridge_is_timeout(err) {
				continue
			}
			why = if err is io.Eof { 'the bridge disconnected' } else { err.msg() }
			break
		}
		for rec in more {
			s.dispatch(rec) or {
				why = err.msg()
				break
			}
		}
	}
	s.end(why)
}

// dispatch files one record from the bridge.
fn (mut s BridgeSession) dispatch(rec BridgeRecord) ! {
	if rec.kind in [.hello, .open, .close] {
		return error('the bridge sent a ${rec.kind} record')
	}
	ch := rlock s.st {
		s.st.chans[rec.channel] or { unsafe { nil } }
	}
	if isnil(ch) {
		// A record for a channel this side has closed: its answer, or traffic still in flight.
		return
	}
	// A record about a previous open of this channel, still in the stream (a send's failure is
	// matched by its own sequence number instead).
	if rec.kind != .senderr && rec.gen != ch.gen {
		return
	}
	match rec.kind {
		.frame {
			ingress := SharedIngress{
				frame:  CanFrame{
					...rec.frame
					hw_ns:     rec.stamp_ns
					hw_domain: s.domain
				}
				tx_ack: rec.tx
			}
			// One producer, this thread, so the length read and the push cannot be overtaken.
			room := if rec.tx { bridge_queue_cap + bridge_ack_reserve } else { bridge_queue_cap }
			if ch.rx.len >= room || ch.rx.try_push(ingress) != .success {
				lock ch.st {
					ch.st.dropped++
				}
			}
			if rec.tx {
				_ := ch.results.try_push(BridgeResult{ seq: rec.seq })
			}
		}
		.senderr {
			_ := ch.results.try_push(BridgeResult{
				seq:      rec.seq
				failed:   true
				definite: rec.definite
				err:      if rec.error == '' { 'the bridge could not send the frame' } else { rec.error }
			})
		}
		.opened {
			_ := ch.opened.try_push(rec.error)
		}
		.status {
			lock ch.st {
				ch.st.health = rec.health
				ch.st.remote = rec.diag
			}
		}
		.lost {
			lock ch.st {
				ch.st.lost = true
				ch.st.lost_why = if rec.error == '' { 'the bridge closed the channel' } else { rec.error }
			}
		}
		else {}
	}
}

// cut stops the session from outside its reader thread: the socket is shut down, which ends the
// reader's read and any write in progress, and the reader then ends the session. `why` is what
// every channel on it reports, unless the session had already ended for another reason.
fn (mut s BridgeSession) cut(why string) {
	lock s.st {
		if !s.st.ended && s.st.err == '' {
			s.st.err = why
		}
	}
	s.cmu.lock()
	if !s.closed {
		net.shutdown(s.conn.sock.handle)
	}
	s.cmu.unlock()
}

// end retires the session, on its reader thread: it leaves the registry (unless a newer
// connection from the same bridge has taken its place), every channel on it fails, and the
// socket is closed once no write is using it.
fn (mut s BridgeSession) end(why string) {
	lock s.st {
		s.st.ended = true
		if s.st.err == '' {
			s.st.err = why
		}
	}
	lock bridge_reg {
		if cur := bridge_reg.sessions[s.name] {
			if voidptr(cur) == voidptr(s) {
				bridge_reg.sessions.delete(s.name)
			}
		}
	}
	// Shut down first so a write stalled on the socket gives up, then close under both locks.
	s.cut(why)
	s.wmu.lock()
	s.cmu.lock()
	s.conn.close() or {}
	s.closed = true
	s.cmu.unlock()
	s.wmu.unlock()
}

// failure is why the session can no longer carry anything, if it cannot.
fn (s &BridgeSession) failure() ?string {
	return rlock s.st {
		if s.st.ended {
			'bridge "${s.name}": ${s.st.err}'
		} else {
			none
		}
	}
}

// write sends one record. A write that fails may have left part of a record on the stream, so
// it ends the session: the bridge could not find the next record boundary.
fn (mut s BridgeSession) write(rec []u8) ! {
	s.wmu.lock()
	defer {
		s.wmu.unlock()
	}
	s.write_locked(rec)!
}

fn (mut s BridgeSession) write_locked(rec []u8) ! {
	if e := s.failure() {
		return error(e)
	}
	lock s.st {
		s.st.writing_since = time.ticks()
	}
	s.conn.write(rec) or {
		s.cut('write failed: ${err}')
		return error('bridge "${s.name}": write failed: ${err}')
	}
	lock s.st {
		s.st.writing_since = 0
	}
}

// check_stall cuts the session when a write has been blocked longer than a send may take.
fn (mut s BridgeSession) check_stall() {
	since := rlock s.st {
		s.st.writing_since
	}
	if since != 0 && time.ticks() - since > bridge_send_ms {
		s.cut('a write to the bridge stalled for more than ${bridge_send_ms} ms')
	}
}

fn (mut s BridgeSession) next_seq() u32 {
	return lock s.st {
		s.st.seq++
		if s.st.seq == 0 {
			s.st.seq = 1
		}
		s.st.seq
	}
}

fn (mut s BridgeSession) forget(ch u8, c &BridgeChan) {
	lock s.st {
		if cur := s.st.chans[ch] {
			if voidptr(cur) == voidptr(c) {
				s.st.chans.delete(ch)
			}
		}
	}
}

// BridgeBus is one channel of a connected bridge — the raw driver behind the shared hub.
struct BridgeBus {
	iface string
	ch    u8
mut:
	sess &BridgeSession
	c    &BridgeChan
}

// open_bridge_bus is what shared_open_events calls: it asks the bridge to open the channel and
// waits for the answer.
fn open_bridge_bus(iface string) !SharedDriver {
	spec := parse_bridge_iface(iface)!
	mut s := bridge_session(spec.name) or {
		return error('${iface}: no bridge named "${spec.name}" is connected')
	}
	idx := s.channels.index(spec.channel)
	if idx < 0 {
		return error('${iface}: bridge "${spec.name}" offers ${s.channels.join(', ')}, not ${spec.channel}')
	}
	ch := u8(idx)
	mut c := &BridgeChan{
		gen: s.next_seq()
		rx:      chan SharedIngress{cap: bridge_queue_cap + bridge_ack_reserve}
		results: chan BridgeResult{cap: 64}
		opened:  chan string{cap: 1}
	}
	lock s.st {
		s.st.chans[ch] = c
	}
	s.write(bridge_encode_open(ch, c.gen)) or {
		s.forget(ch, c)
		return error('${iface}: ${err}')
	}
	deadline := time.ticks() + bridge_open_ms
	for {
		mut answer := ?string(none)
		select {
			e := <-c.opened {
				answer = e
			}
			bridge_poll_ms * time.millisecond {}
		}
		if e := answer {
			if e != '' {
				s.forget(ch, c)
				return error('${iface}: ${e}')
			}
			break
		}
		if e := s.failure() {
			s.forget(ch, c)
			return error('${iface}: ${e}')
		}
		if time.ticks() >= deadline {
			// Ended, not retried: a late answer to this open would be taken for the next one's.
			why := 'the bridge did not answer an open within ${bridge_open_ms} ms'
			s.forget(ch, c)
			s.cut(why)
			return error('${iface}: ${why}')
		}
	}
	return &BridgeBus{
		iface: iface
		ch:    ch
		sess:  s
		c:     c
	}
}

// failure is why this channel can carry nothing more, if it cannot.
fn (b &BridgeBus) failure() ?string {
	if e := b.sess.failure() {
		return '${b.iface}: ${e}'
	}
	return rlock b.c.st {
		if b.c.st.closed {
			'bus is closed'
		} else if b.c.st.lost {
			'${b.iface}: ${b.c.st.lost_why}'
		} else {
			none
		}
	}
}

// send puts a frame on the bridge's channel and waits for the bridge to say it went out.
fn (mut b BridgeBus) send(frame CanFrame, commit fn ()) ! {
	// REFUSED, not clamped: the interface on the bridge's side clamps what SocketCAN clamps, and
	// this side's record of the frame would then not be what went out.
	if why := frame_shape_error(frame) {
		return not_written('${b.iface}: ${why}')
	}
	seq := b.sess.next_seq()
	rec := bridge_encode_frame(b.ch, b.c.gen, frame, seq, false, 0)
	b.sess.wmu.lock()
	if e := b.failure() {
		b.sess.wmu.unlock()
		return not_written(e)
	}
	commit()
	b.sess.write_locked(rec) or {
		b.sess.wmu.unlock()
		return error('${b.iface}: ${err}')
	}
	b.sess.wmu.unlock()
	// The answer to THIS send; one left over from a send that ran out of time is passed over.
	deadline := time.ticks() + bridge_send_ms
	for {
		mut got := ?BridgeResult(none)
		select {
			r := <-b.c.results {
				got = r
			}
			bridge_poll_ms * time.millisecond {}
		}
		if r := got {
			if r.seq == seq {
				// Refused on the bridge's side: the frame did not go out, and no acknowledgement
				// will come for it, so the hub must not hold this send's token open.
				if r.failed {
					// A failure the bridge is sure of means nothing went out, and the hub drops
					// this send's token; otherwise the frame may be on the wire, and the hub keeps
					// it matchable for its grace.
					if r.definite {
						return not_written('${b.iface}: ${r.err}')
					}
					return error('${b.iface}: ${r.err}')
				}
				return
			}
		}
		if e := b.failure() {
			return error(e)
		}
		if time.ticks() >= deadline {
			why := 'the bridge did not confirm a send within ${bridge_send_ms} ms'
			b.sess.cut(why)
			return error('${b.iface}: ${why}')
		}
	}
}

// recv_shared returns the next frame the bridge filed under this channel, a TX ack included.
// Frames already queued are delivered before a failure is reported.
fn (mut b BridgeBus) recv_shared(timeout_ms int) !SharedIngress {
	deadline := time.ticks() + i64(timeout_ms)
	mut first := true
	for {
		wait := if first {
			cansub_first_wait(timeout_ms, deadline, time.ticks()) or { return error('timeout') }
		} else {
			cansub_wait_slice(timeout_ms, deadline, time.ticks()) or { return error('timeout') }
		}
		first = false
		mut got := ?SharedIngress(none)
		select {
			ing := <-b.c.rx {
				got = ing
			}
			wait * time.millisecond {}
		}
		if g := got {
			return g
		}
		if e := b.failure() {
			return error(e)
		}
	}
	return error('timeout')
}

fn (mut b BridgeBus) recv(timeout_ms int) !CanFrame {
	return b.recv_shared(timeout_ms)!.frame
}

// health is the ladder the bridge last reported for its interface. The bridge reads the
// interface all the time, so this is current whether or not anything here receives.
fn (mut b BridgeBus) health() BusHealth {
	return rlock b.c.st {
		b.c.st.health
	}
}

// diagnostics is the bridge's own counts for the interface plus the frames this side dropped.
fn (mut b BridgeBus) diagnostics() BusDiagnostics {
	return rlock b.c.st {
		BusDiagnostics{
			...b.c.st.remote
			dropped: b.c.st.remote.dropped + b.c.st.dropped
		}
	}
}

// reconcile_silence — the interface's mode is set on the bridge's host, as for SocketCAN, and a
// vcan has no transceiver at all.
fn (mut b BridgeBus) reconcile_silence(want bool) ! {}

fn (mut b BridgeBus) reports_tx_ack() bool {
	return true
}

fn (mut b BridgeBus) close() {
	already := lock b.c.st {
		was := b.c.st.closed
		b.c.st.closed = true
		was
	}
	if already {
		return
	}
	b.sess.forget(b.ch, b.c)
	b.sess.write(bridge_encode_close(b.ch)) or {}
}
