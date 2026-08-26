// The CANsub as a Bus.
//
//     cansub:<device-id>/<channel>[@<arbitration>[/<data>]]
//     cansub:e5a16adf/1@500000            classic, 500 kbit/s
//     cansub:e5a16adf/2@500000/2000000    CAN-FD, 2 Mbit/s data phase
//
// BY DEVICE ID, never by address. A firmware update clears persistent data and the device returns
// on a different subnet — a CANsub.4 went from 10.63.38.1 to 10.215.129.1 across 02.03.00 ->
// 02.04.00 — while `<id>-usb.local` followed it. An IP written into a project is one reboot from
// naming nothing, and worse, from naming somebody else's device. The id is on the box and in
// `/api/info`, so it is what a wire is called here and what its identity derives from.
//
// CROSS-PLATFORM, unlike the other hardware backends. PCAN, Kvaser and Vector are Windows-only
// because they are vendor DLLs; a CANsub is an HTTP server on the end of a USB cable, so the same
// code reaches it from Linux. That is why `vendor_iface` had to learn about it outside its
// `$if windows` guard: on Linux `pcan:bench` really is a SocketCAN name, but `cansub:` means the
// same thing everywhere.
//
// ONE CLIENT PER CHANNEL, which the vendor states plainly: "A single client can be connected to
// each WebSocket". That is the PCAN problem again — the app opens each wire several times per
// Start (a monitor, a transmit tap per channel, the anonymous tap) and whichever call arrived
// first would win while the rest were told the device was busy. So `cansub:` goes through
// `shared_open` like `pcan:` does, keyed on the WIRE without its bitrate, and every opener of one
// channel shares the one connection.
module transport

import net.websocket
import time

// CansubSpec is a parsed `cansub:` address.
pub struct CansubSpec {
pub:
	id      string // device id, e.g. e5a16adf
	channel int    // 1-based, as the device numbers them
	arb     int    // arbitration bitrate
	data    int    // data-phase bitrate, 0 when classic
	fd      bool
}

// parse_cansub_iface reads an address, refusing what it cannot make sense of rather than opening
// something adjacent to what was asked for.
pub fn parse_cansub_iface(iface string) !CansubSpec {
	i := iface.trim_space()
	if !i.to_lower().starts_with('cansub:') {
		return error('not a cansub address: ${i}')
	}
	body := i['cansub:'.len..]
	spec, rate_tok := cansub_split_rate(body)!
	arb, data, fd := vendor_split_fd_rate(rate_tok, 500000)!
	if !spec.contains('/') {
		return error('"${i}" names no channel — the form is cansub:<device-id>/<channel>')
	}
	id := spec.all_before('/').trim_space().to_lower()
	ch_tok := spec.all_after('/').trim_space()
	if id == '' {
		return error('"${i}" names no device')
	}
	for c in ch_tok {
		if !c.is_digit() {
			return error('"${ch_tok}" is not a channel number')
		}
	}
	ch := ch_tok.int()
	if ch < 1 || ch > cansub_channels {
		// The device numbers 1..4 and answers 404 outside that, which arrives as an unhelpful
		// HTTP error several seconds into an open -- and, because this parser is what
		// address_config_error asks, an out-of-range channel was accepted by the editor and
		// saved before anybody found out. Caught here, while it is still a string somebody typed
		// (codex round 2 on #204: the floor was checked and the ceiling was not).
		return error('channel ${ch}: a CANsub.4 numbers its channels 1 to ${cansub_channels}')
	}
	return CansubSpec{
		id:      id
		channel: ch
		arb:     arb
		data:    data
		fd:      fd
	}
}

// cansub_split_rate separates the address from its `@rate`, the same rule the vendor backends
// use — at most one rate — but kept separate because a cansub channel contains a `/` and
// vendor_split_rate's callers do not.
fn cansub_split_rate(spec string) !(string, string) {
	parts := spec.split('@')
	if parts.len > 2 {
		return error('"${spec}" has more than one bitrate — the rate belongs in the channel\'s bitrate field, not in its address')
	}
	if parts.len == 2 {
		return parts[0], parts[1]
	}
	return parts[0], '500000'
}

// CansubBus is one channel's connection: a WebSocket carrying frames, and the REST calls that
// configured it.
struct CansubBus {
	iface string
	host  string
	spec  CansubSpec
mut:
	ws         &websocket.Client = unsafe { nil }
	rx         chan CansubRecord
	stop       shared CansubStop
	reader     thread
	health_thr thread
	started    bool
}

// CansubStop carries what the reader thread and the bus both touch. `shared` rather than a plain
// mutex because V checks the locking for us, and this is exactly the "shared state touched from
// more than one thread" that this repo's reviews keep finding.
struct CansubStop {
mut:
	running bool      = true
	health  BusHealth = .unknown
	err     string
	// What the CONTROLLER was last configured to, which is not the same question as what this
	// process's silence policy currently says — see reconcile_listen_only.
	phy_silent bool
	// Records this decoder could not parse. Counted rather than kept, so a persistent bad stream
	// costs one integer instead of one string per record — see read_loop.
	decode_errors      int
	first_decode_error string
}

// open_cansub_bus is what shared_open calls. One connection per wire; every opener of the same
// channel gets this same bus back.
fn open_cansub_bus(iface string) !Bus {
	spec := parse_cansub_iface(iface)!
	host := cansub_host(spec.id)

	// Configuration first, over REST, while nothing is streaming. Opening the WebSocket is what
	// starts the bus, so the timing has to be right before it — a channel configured after the
	// fact is a channel that ran at the wrong rate for however long that took.
	nominal := cansub_timing_for(spec.arb, cansub_default_sample_point)!
	mut data := ?CansubTiming(none)
	if spec.fd {
		data = cansub_timing_for_data(spec.data, cansub_default_sample_point)!
	}
	// The controller is silenced too, not just this process's send path. `silenced()` in open()
	// still wraps the result and still answers per send — it has to, because a row toggled
	// mid-run moves and a register cannot — but a listen-only channel that still ACKs is not
	// really listening: on a bus with one other node our acknowledgement is the difference
	// between its frames succeeding and it going error-passive.
	silent := is_listen_only(iface)
	body := cansub_phy_json(nominal, data, silent)
	r := cansub_request(host, 'PUT', '/api/can/${spec.channel}/phy', body, 5 * time.second) or {
		return error('cannot configure ${iface}: ${err}')
	}
	if r.status != 200 && r.status != 204 {
		return error('cannot configure ${iface}: HTTP ${r.status} ${r.body}')
	}

	// The device clock resets with a reboot and the vendor's own flow says to set it, so it is set
	// on every open rather than once: frame timestamps are microseconds from a fixed epoch, and an
	// unsynced device stamps them from its uptime. On a bench correlating fourteen channels, that
	// is the difference between a trace that lines up and one that silently does not.
	cansub_sync_clock(host) or {} // best effort: a bus that runs with odd stamps beats no bus

	mut ws := websocket.new_client('wss://${host}/api/can/${spec.channel}/ws',
		// SHORT, because this is now what bounds Stop: the reader owns the socket and closes it
		// on its way out (see close()), so a wire is released one read timeout after it is asked
		// to stop. An idle reader waking twice a second costs nothing measurable; two seconds of
		// dead air per wire at Stop is the thing somebody notices.
		read_timeout: 500 * time.millisecond
	)!
	ws.connect() or { return error('cannot open ${iface}: ${err}') }

	mut b := &CansubBus{
		iface: iface
		host:  host
		spec:  spec
		ws:    ws
		rx:    chan CansubRecord{cap: 4096}
	}
	lock b.stop {
		b.stop.phy_silent = silent
	}
	b.reader = spawn b.read_loop()
	b.health_thr = spawn b.health_loop()
	b.started = true
	return b
}

// health_loop polls the controller's fault ladder on its OWN thread.
//
// IT USED TO RUN INSIDE read_loop, every 500 ms, and each poll is a fresh TLS dial plus an HTTP
// GET with a five-second read timeout — so for as long as that took, nothing read the socket. On
// an idle bench that is invisible; on a loaded bus it is a reader that stops reading for seconds
// at a time, and the frames it missed are gone. The device reports the ladder as a word on a REST
// endpoint and nothing in the frame stream carries it, so polling is the only source — but it has
// no business sharing a thread with the frames.
fn (mut b CansubBus) health_loop() {
	for {
		if !rlock b.stop {
			b.stop.running
		} {
			break
		}
		b.poll_health()
		b.reconcile_listen_only()
		// Slept in short steps rather than one long one, so close() is noticed promptly instead of
		// after the poll interval: a thread this one has to be joined by is a thread that must not
		// take half a second to look up.
		for _ in 0 .. 10 {
			if !rlock b.stop {
				b.stop.running
			} {
				return
			}
			time.sleep(50 * time.millisecond)
		}
	}
}

// read_loop is the only reader of the socket.
//
// One reader, deliberately: `listen()` is itself a loop over read_next_message dispatching to
// handlers, so running it alongside a direct read puts two readers on one socket and they take
// each other's frames.
fn (mut b CansubBus) read_loop() {
	mut dec := CansubDecoder{}
	// THE SOCKET DIES WITH THIS THREAD, whichever way the loop ends — a stop, a read error, or a
	// receiver that went away. close() deliberately does not touch it; see the argument there.
	//
	// Closing the WebSocket is what closes the CAN channel — the vendor's model, not ours. The
	// graceful path is a close message and its confirmation; `DELETE /api/can/{ch}/ws` is the
	// escape hatch when that does not come back, added in API 04.00, and answering 404 when
	// nothing is connected is a defined no-op rather than a failure to special-case.
	defer {
		b.ws.close(1000, 'closing') or {
			cansub_request(b.host, 'DELETE', '/api/can/${b.spec.channel}/ws', '', 2 * time.second) or {
			}
		}
	}
	for {
		if !rlock b.stop {
			b.stop.running
		} {
			break
		}
		msg := b.ws.read_next_message() or {
			// A read timeout is an idle bus, not a fault. Anything else ends the loop, and the
			// reason is kept so send/recv can report something better than silence.
			if err.msg().contains('timed out') || err.msg().contains('timeout') {
				continue
			}
			lock b.stop {
				if b.stop.running {
					b.stop.err = err.msg()
				}
			}
			break
		}
		if msg.opcode != .binary_frame {
			continue
		}
		for rec in dec.feed(msg.payload) {
			if !b.enqueue(rec) {
				return
			}
		}
		// TAKEN AND CLEARED EVERY PASS. `dec.errors` grows by one string per malformed record and
		// nothing here ever read it — so a device on incompatible firmware, sending records this
		// decoder cannot parse, dropped every frame silently AND accumulated an error history for
		// the lifetime of the bus (codex round 3 on #204). Both halves are fixed by the same
		// three lines: the count reaches `health()`'s neighbours where somebody can see it, and
		// the array goes back to empty.
		if dec.errors.len > 0 {
			lock b.stop {
				b.stop.decode_errors += dec.errors.len
				// The FIRST one is kept, not the latest: a stream that has gone wrong repeats
				// itself, and the first message is the one that describes what changed.
				if b.stop.first_decode_error == '' {
					b.stop.first_decode_error = dec.errors[0]
				}
			}
			dec.errors.clear()
		}
	}
}

// enqueue hands one record to the receiver without ever PARKING on a full queue.
//
// `b.rx <- rec` blocks when the buffer is full, and a CANsub handle used only for sending still
// receives: the device acknowledges every transmission, so a send-only handle fills all 4096
// records and the reader parks forever on the push. `close()` joins the reader — and it must,
// because closing `rx` out from under a reader parked in the socket is the panic the comment
// there describes — so closing such a handle never returned at all (codex round 1 on #204).
//
// close() clears `running` BEFORE it touches the socket, so the wait below is what the reader
// notices: a full queue is only worth waiting on while somebody is still going to drain it.
// Nothing is dropped while the bus is up; a bus on its way down stops caring.
fn (mut b CansubBus) enqueue(rec CansubRecord) bool {
	for {
		if b.rx.try_push(rec) == .success {
			return true
		}
		running := rlock b.stop {
			b.stop.running
		}
		if !running {
			return false
		}
		time.sleep(2 * time.millisecond)
	}
	return false
}

// reconcile_listen_only re-configures the CONTROLLER when this process's silence policy for this
// wire changes underneath a running bus.
//
// WHY IT IS NEEDED. `listen_only` is burned into the PHY at open, once, from `is_listen_only()`.
// The policy behind that answer is not fixed: `project.apply_listen_only()` replaces the whole set
// whenever a project is applied or a row is toggled, and `silenced()` deliberately asks it PER SEND
// rather than caching it — because a mark moves and a handle outlives the row that made it. So the
// software half followed the toggle and the controller did not, in both directions and both of them
// wrong (codex round 2 on #204):
//
//   - marked silent after opening normal: this process refuses to transmit, but the controller is
//     still ACKing every frame on the bus. That is not listening. On a bus with one other node our
//     acknowledgement is the difference between its frames succeeding and it going error-passive —
//     which is the whole argument the open path already makes for silencing the controller at all.
//   - unmarked after opening silent: sends are permitted in software and the controller cannot
//     transmit them. The frame is recorded as sent and never reaches the wire.
//
// Vector answers this class by REFUSING (`wire_pin_clash`, #165) because an XL port's mode is fixed
// by the ports open on it and software cannot revise it. A CANsub can be revised: the mode is a
// field in a PHY object we can PUT again. So it is reconfigured rather than refused.
//
// THE COST IS A BUS BOUNCE. A PHY PUT restarts the channel, so traffic stops for the length of one
// HTTP round trip. That is the lesser evil by some distance: the alternative is a wire whose
// behaviour disagrees with what the Buses panel says it is, indefinitely, which is exactly the
// class of fault this repo refuses to ship elsewhere. It happens only when somebody actually
// changes the mark, which is a deliberate act.
//
// Best-effort: a failed PUT leaves `phy_silent` alone, so the next poll tries again rather than
// recording a change that did not happen.
fn (mut b CansubBus) reconcile_listen_only() {
	want := is_listen_only(b.iface)
	have := rlock b.stop {
		b.stop.phy_silent
	}
	if want == have {
		return
	}
	nominal := cansub_timing_for(b.spec.arb, cansub_default_sample_point) or { return }
	mut data := ?CansubTiming(none)
	if b.spec.fd {
		data = cansub_timing_for_data(b.spec.data, cansub_default_sample_point) or { return }
	}
	r := cansub_request(b.host, 'PUT', '/api/can/${b.spec.channel}/phy', cansub_phy_json(nominal,
		data, want), 5 * time.second) or { return }
	if r.status != 200 && r.status != 204 {
		return
	}
	lock b.stop {
		b.stop.phy_silent = want
	}
}

// poll_health asks the device what its controller thinks. The states map one to one onto this
// repo's ladder, which is the whole reason `health()` can say anything here at all.
fn (mut b CansubBus) poll_health() {
	body := cansub_get(b.host, '/api/can/${b.spec.channel}') or { return }
	state := extract_json_string(body, 'state') or { return }
	h := match state {
		'error_active' { BusHealth.ok }
		'error_warning' { BusHealth.warning }
		'error_passive' { BusHealth.error_passive }
		'bus_off' { BusHealth.bus_off }
		'stopped' { BusHealth.unknown } // not on the bus: nothing to report, and not a fault
		else { BusHealth.unknown }
	}

	lock b.stop {
		b.stop.health = h
	}
}

// extract_json_string pulls one string field out of a flat JSON object. The device's replies are
// small and flat, and a full parser here would be a dependency for four fields.
fn extract_json_string(s string, key string) ?string {
	needle := '"${key}":"'
	i := s.index(needle) or { return none }
	rest := s[i + needle.len..]
	end := rest.index('"') or { return none }
	return rest[..end]
}

pub fn (mut b CansubBus) send(frame CanFrame) ! {
	if frame.fd && !b.spec.fd {
		// Refuse rather than truncate, which is what the Windows vendor backends do with an FD
		// frame they cannot carry. The address is what asks for FD, so a classic channel being
		// handed an FD frame is a project that disagrees with itself.
		return error('${b.iface} is a classic channel — its address names one bitrate, so it cannot carry a CAN-FD frame')
	}
	if e := b.failure() {
		return error('${b.iface}: ${e}')
	}
	body := cansub_encode_frame(frame)!
	b.ws.write(cansub_hdlc_wrap(body), .binary_frame) or {
		return error('send on ${b.iface}: ${err}')
	}
}

// cansub_poll_ms is how often an idle receiver looks up from the queue to ask whether the socket
// is still there. A CEILING on one select, never a floor.
const cansub_poll_ms = i64(200)

// cansub_wait_slice decides how long ONE select may park, or none when the caller's budget is
// spent. Extracted from recv so both of its rules are visible to CI, because neither could be
// seen from outside without a device on the other end (codex round 1 on #204).
//
// A NEGATIVE TIMEOUT MEANS BLOCK — the Bus contract every other backend keeps, and `cmd/can_smoke`
// uses it. Added straight to the clock it put the deadline in the PAST, so the one caller asking
// to wait forever was the one that returned instantly.
//
// And a positive timeout BOUNDS the wait. The poll interval is there for the socket check, so
// parking the full 200 ms regardless made `recv(5)` — which polling and shutdown loops all over
// this repo use — forty times slower than the interface promises.
fn cansub_wait_slice(timeout_ms int, deadline i64, now i64) ?i64 {
	if timeout_ms < 0 {
		return cansub_poll_ms
	}
	remaining := deadline - now
	if remaining <= 0 {
		return none
	}
	return if remaining < cansub_poll_ms { remaining } else { cansub_poll_ms }
}

// cansub_first_wait is the FIRST slice of a recv, which is not the same question.
//
// `recv(0)` is a NON-BLOCKING POLL, not "do nothing": every other bus here answers it by looking
// at what is already queued and returning it. Derived from the deadline alone it came out as an
// expired budget, so a caller draining with a zero timeout was told the queue was empty while
// frames sat in it (codex round 3 on #204 — and the test beside this asserted the poll behaviour
// in a comment while the code did not do it).
//
// Zero, so the select takes the queued record if there is one and gives up immediately if not.
fn cansub_first_wait(timeout_ms int, deadline i64, now i64) ?i64 {
	if timeout_ms == 0 {
		return i64(0)
	}
	return cansub_wait_slice(timeout_ms, deadline, now)
}

pub fn (mut b CansubBus) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	mut first := true
	for {
		wait := if first {
			cansub_first_wait(timeout_ms, deadline, time.ticks()) or { return error('timeout') }
		} else {
			cansub_wait_slice(timeout_ms, deadline, time.ticks()) or { return error('timeout') }
		}
		first = false
		select {
			rec := <-b.rx {
				if rec.is_error {
					// A bus error is real news, but it is not a frame and the Bus interface has
					// nowhere to put it. `health()` is where it surfaces; here it is skipped so a
					// noisy bus does not return junk frames.
					continue
				}
				return rec.frame
			}
			// Bounded, so a closed socket does not park a caller here forever.
			wait * time.millisecond {
				if e := b.failure() {
					return error('${b.iface}: ${e}')
				}
			}
		}
	}
	return error('timeout')
}

// failure reports the reason the reader stopped, if it stopped.
fn (b &CansubBus) failure() ?string {
	return rlock b.stop {
		if b.stop.err == '' {
			none
		} else {
			b.stop.err
		}
	}
}

pub fn (mut b CansubBus) close() {
	lock b.stop {
		if !b.stop.running {
			return
		}
		b.stop.running = false
	}
	// THE SOCKET IS CLOSED BY THE THREAD THAT READS IT, and this function does not touch it.
	//
	// It used to: `running = false`, then `ws.close()` here to WAKE the reader out of
	// read_next_message, then join. That closed the connection underneath a thread parked inside
	// it, and the reader then segfaulted every single time — on this bench, on every open/close
	// of a CANsub wire, including the ones `cmd/crosscheck` was reporting as passing, because it
	// happens after the last result is printed and only the exit status says so (it was 139).
	//
	// Waking a blocked reader by destroying what it is blocked on is not something a guard here
	// can make safe: by the time this thread returns from ws.close(), the other one is already
	// inside freed structures. The only version that works is the one where a socket has exactly
	// one owner — so `running = false` is the whole signal, the reader notices it within one read
	// timeout, closes the socket itself and returns, and this waits.
	//
	// That costs up to one read timeout per wire at Stop, which is why the timeout is now 500 ms
	// rather than two seconds (see new_client): an idle reader waking twice a second costs
	// nothing, and Stop staying responsive is worth more than the wakeups.
	//
	// JOINED, THEN the channel closed. Closing `rx` while the reader still holds it is a panic
	// waiting for a bus that happens to be busy at Stop.
	b.reader.wait()
	b.health_thr.wait()
	b.rx.close()
}

pub fn (mut b CansubBus) health() BusHealth {
	return rlock b.stop {
		b.stop.health
	}
}

// cansub_sync_clock sets the device time from this host's, so frame timestamps are wall clock
// rather than an offset from whenever the device last booted.
fn cansub_sync_clock(host string) ! {
	now := time.utc()
	stamp := '"${now.year:04d}-${now.month:02d}-${now.day:02d}T${now.hour:02d}:${now.minute:02d}:${now.second:02d}.${now.nanosecond / 1_000_000:03d}Z"'
	r := cansub_request(host, 'PUT', '/api/time', stamp, 3 * time.second)!
	if r.status != 200 {
		return error('PUT /api/time -> HTTP ${r.status}')
	}
}

// cansub_address_error reports why this address could not be opened, or none when it can.
//
// THE SAME RULES `open_cansub` APPLIES, run without touching the device, so an editor can refuse a
// rate before it is persisted rather than at Start. Vector and Kvaser each have one and the reason
// is the same: a front end that reproduces the rules keeps producing a SUBSET of them, and the
// subset is always missing the case somebody just hit.
//
// The timing derivations are what can actually fail here — the device's registers are much
// narrower in the data phase than the nominal one, and an out-of-range data phase is answered with
// an HTTP 500 that names nothing (see the findings in #193). Catching it against the published
// table beats reading that 500 off a live device.
// cansub_canonical_spec reduces one address to what it actually ASKS FOR, so that two spellings
// of one wire compare equal.
//
// `shared_open` guards a shared handle by comparing the interface string that opened it, exactly --
// so `E5A16ADF/1` and `e5a16adf/01` resolved to the same wire key, then collided on that compare,
// and the second alias was refused its transmit handle over a difference that does not exist
// (codex round 2 on #204). The raw string is still what diagnostics print; this is only what they
// are COMPARED by.
pub fn cansub_canonical_spec(iface string) string {
	s := parse_cansub_iface(iface) or { return iface.trim_space().to_lower() }
	fd := if s.fd { '/${s.data}' } else { '' }
	return 'cansub:${s.id.to_lower()}/${s.channel}@${s.arb}${fd}'
}

pub fn cansub_address_error(iface string) ?string {
	s := parse_cansub_iface(iface) or { return err.msg() }
	cansub_timing_for(s.arb, cansub_default_sample_point) or {
		return 'arbitration ${s.arb}: ${err.msg()}'
	}
	if s.fd {
		cansub_timing_for_data(s.data, cansub_default_sample_point) or {
			return 'data phase ${s.data}: ${err.msg()}'
		}
	}
	return none
}
