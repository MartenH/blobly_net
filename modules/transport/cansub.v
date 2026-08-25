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
	if ch < 1 {
		// The device numbers from 1 and answers 404 for 0, which arrives as an unhelpful HTTP
		// error several seconds into an open. Caught here, while it is still a string somebody
		// typed.
		return error('channel ${ch}: a CANsub numbers its channels from 1')
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
	ws      &websocket.Client = unsafe { nil }
	rx      chan CansubRecord
	stop    shared CansubStop
	reader  thread
	started bool
}

// CansubStop carries what the reader thread and the bus both touch. `shared` rather than a plain
// mutex because V checks the locking for us, and this is exactly the "shared state touched from
// more than one thread" that this repo's reviews keep finding.
struct CansubStop {
mut:
	running bool      = true
	health  BusHealth = .unknown
	err     string
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
	body := cansub_phy_json(nominal, data, is_listen_only(iface))
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
		read_timeout: 2 * time.second
	)!
	ws.connect() or { return error('cannot open ${iface}: ${err}') }

	mut b := &CansubBus{
		iface: iface
		host:  host
		spec:  spec
		ws:    ws
		rx:    chan CansubRecord{cap: 4096}
	}
	b.reader = spawn b.read_loop()
	b.started = true
	return b
}

// read_loop is the only reader of the socket.
//
// One reader, deliberately: `listen()` is itself a loop over read_next_message dispatching to
// handlers, so running it alongside a direct read puts two readers on one socket and they take
// each other's frames.
fn (mut b CansubBus) read_loop() {
	mut dec := CansubDecoder{}
	mut last_poll := i64(0)
	for {
		if !rlock b.stop {
			b.stop.running
		} {
			break
		}
		// The controller's own verdict, polled rather than derived. The device reports the fault
		// ladder as a word on a REST endpoint and nothing in the frame stream carries it, so this
		// is the only source — at a cadence slow enough not to matter beside the frames.
		now := time.ticks()
		if now - last_poll > 500 {
			last_poll = now
			b.poll_health()
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
			b.rx <- rec or { break } // the channel is closed: we are shutting down
		}
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

pub fn (mut b CansubBus) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		remaining := deadline - time.ticks()
		if remaining <= 0 {
			return error('timeout')
		}
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
			200 * time.millisecond {
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
	// Closing the WebSocket is what closes the CAN channel — the vendor's model, not ours. The
	// graceful path is a close message and its confirmation; `DELETE /api/can/{ch}/ws` is the
	// escape hatch when that does not come back, added in API 04.00, and answering 404 when
	// nothing is connected is a defined no-op rather than a failure to special-case.
	b.ws.close(1000, 'closing') or {
		cansub_request(b.host, 'DELETE', '/api/can/${b.spec.channel}/ws', '', 2 * time.second) or {
		}
	}
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
