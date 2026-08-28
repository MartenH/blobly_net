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
// `shared_open` like `pcan:` does, keyed on the WIRE without its bitrate. Every opener gets an
// independent logical receive cursor behind one connection and one raw reader.
module transport

import net.websocket
import sync
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
	// A DEVICE ID BECOMES A HOSTNAME. `cansub_host` builds `<id>-usb.local` and hands it to mDNS,
	// so an id that is not a legal hostname label cannot resolve — and checked only for emptiness,
	// `bad id/1` was accepted by the editor AND by the shared start check, then failed several
	// seconds into an open as a network error (codex round 14 on #204). Refused here, where it is
	// still a string somebody typed, like the channel number beside it.
	if !cansub_id_ok(id) {
		return error('"${id}" is not a device id — it becomes the hostname ${cansub_host(id)}, so it can hold letters, digits and inner hyphens only')
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
	ws &websocket.Client = unsafe { nil }
	rx chan CansubRecord
	// ONE WRITER AT A TIME on the one socket. The shared hub hands every logical opener of a wire
	// the SAME raw driver, by design — the vendor permits a single client per channel — so the
	// simulation worker, a UDS server and a script can all be inside send() at once. A WebSocket
	// write is a framed, stateful operation over TLS. Two interleaving writes corrupt framing or
	// lose a message outright (codex round 9 on #204).
	//
	// The GUI's TapBus takes a mutex of its own, which is why this was not showing there — but it
	// protects only what goes through the tap, and the headless runner's workers hold buses
	// straight from `transport.open`. The socket is what needs protecting, so the lock belongs
	// with the socket.
	wmu        &sync.Mutex = sync.new_mutex()
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
	// A write failure: refuses every later send; the reader is unaffected — see fail_send.
	send_err string
	// Whether close() has run: its guard, SEPARATE from `running`. A bus that stopped itself
	// (fail_send) has `running` false and a reader still holding the device's one WebSocket;
	// guarded on `running`, close() returned at once and the hub admitted a reopen the device
	// then refused (codex round 3 on #251).
	closed bool
	// What the CONTROLLER was last configured to, which is not the same question as what this
	// process's silence policy currently says — see reconcile_listen_only.
	phy_silent bool
	// Records this decoder could not parse. Counted rather than kept, so a persistent bad stream
	// costs one integer instead of one string per record — see read_loop.
	decode_errors      u64
	first_decode_error string
	// Consecutive health polls that could not reach the device. See poll_health: a stale verdict
	// is worse than no verdict.
	health_misses int
	// Whether THIS handle has put a frame on the wire in this run — see cansub_ladder: a channel
	// that has never transmitted is judged by its receive counter, because its transmit counter
	// is the firmware's start value and cannot move (#241).
	transmitted bool
	// Controller errors the device reported as records rather than as a state change — see recv.
	// Counted rather than kept, like the decode errors above.
	bus_errors      u64
	first_bus_error string
	// Records dropped because the receiver was not keeping up — see enqueue.
	dropped u64
}

// open_cansub_bus is what shared_open_events calls. It creates the one raw connection behind that
// wire's logical handles. SharedDriver is private to transport: it carries the device's
// TX-acknowledgement bit as far as the shared hub without widening the public Bus contract.
// cansub_write_timeout bounds one WebSocket write — see cansub_client_opts. Named so a test can
// hold it below what a Stop is allowed to cost.
const cansub_write_timeout = 2 * time.second

// cansub_client_opts is the WebSocket client's configuration — a function rather than a literal
// at the call site so the test can read what the client is actually GIVEN (codex round 12 on
// #251): a constant asserted on its own would stay green with the option unwired.
fn cansub_client_opts() websocket.ClientOpt {
	return websocket.ClientOpt{
		// SHORT, because this is what bounds Stop: the reader owns the socket and closes it on
		// its way out (see close()), so a wire is released one read timeout after it is asked
		// to stop. An idle reader waking twice a second costs nothing measurable; two seconds
		// of dead air per wire at Stop is the thing somebody notices.
		read_timeout:  500 * time.millisecond
		// AND THE WRITE, for the same reason from the other side. Stop closes the socket under
		// the write lock and waits for a send in flight to finish first — "a bounded thing",
		// bounded by THIS, and the library's default is thirty seconds. A send to a device that
		// has stopped taking bytes (unplugged mid-run, a WebSocket the firmware has abandoned)
		// blocks in write() until then, and with it every sender on the wire and the Stop
		// behind them (#240). Two seconds is longer than any send this device has been seen to
		// take and shorter than anybody's patience.
		write_timeout: cansub_write_timeout
	}
}

fn open_cansub_bus(iface string) !SharedDriver {
	spec := parse_cansub_iface(iface)!
	host := cansub_host(spec.id)
	// THE DEVICE IS ASKED WHO IT IS BEFORE IT IS TOLD ANYTHING. The name is resolved once per
	// process and remembered (cansub_addr); an address a device left behind — a firmware update
	// moves it to another subnet — can be reassigned to another reachable CANsub, and TLS is not
	// validating a self-signed certificate. So the first request on an open is the identity
	// read, and a device that answers with another id costs a re-resolve and one more look; one
	// that still does not match is refused, before the PHY PUT that would have configured it
	// (codex round 1 on #243).
	cansub_confirm_identity(host, spec.id) or {
		cansub_forget_addr(host)
		cansub_confirm_identity(host, spec.id) or { return error('cannot open ${iface}: ${err}') }
	}

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
	// BOUNDED. This used to run INSIDE the process-wide registry lock, so a device reachable
	// enough to stall but not to answer held up every other opener, PCAN included (codex round 8
	// on #204); since #211 it runs behind a per-wire reservation and stalls only this wire's own
	// openers. The budget stays what somebody waiting at Start actually experiences, not what a
	// patient client would allow: those openers are still waiting.
	r := cansub_request(host, 'PUT', '/api/can/${spec.channel}/phy', body, cansub_open_timeout) or {
		return error('cannot configure ${iface}: ${err}')
	}
	if r.status != 200 && r.status != 204 {
		return error('cannot configure ${iface}: HTTP ${r.status} ${r.body}')
	}
	note_silence_applied(iface, silent) // the device took the mark: recorded, and nothing stands refused

	// The device clock resets with a reboot and the vendor's own flow says to set it, so it is set
	// on every open rather than once: frame timestamps are microseconds from a fixed epoch, and an
	// unsynced device stamps them from its uptime. On a bench correlating fourteen channels, that
	// is the difference between a trace that lines up and one that silently does not.
	cansub_sync_clock(host) or {} // best effort: a bus that runs with odd stamps beats no bus

	// BY ADDRESS, NOT BY NAME — see cansub_addr: the name was resolved for the PHY PUT above, and
	// resolving it again here is another cold mDNS lookup (2.7 s, measured) on the open path.
	mut ws := websocket.new_client('wss://${cansub_addr(host) or { host }}/api/can/${spec.channel}/ws',
		cansub_client_opts())!
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
		// SILENCE FIRST, THEN DIAGNOSTICS. Ordered the other way round, a wire toggled to
		// listen-only kept ACKing for a health GET plus whatever remained of the sleep before the
		// PUT went out — around 1.2 s of a controller acknowledging traffic on a bus the UI had
		// already declared silent (codex round 8 on #204). Health is a number somebody reads;
		// this is a promise about what the transceiver is doing.
		b.reconcile_listen_only(is_listen_only(b.iface), true) or {}
		b.poll_health()
		// Slept in short steps rather than one long one, so close() is noticed promptly instead of
		// after the poll interval: a thread this one has to be joined by is a thread that must not
		// take half a second to look up.
		for _ in 0 .. 10 {
			if !rlock b.stop {
				b.stop.running
			} {
				return
			}
			// AND THE SLEEP IS INTERRUPTED BY A MODE CHANGE, for the same reason. Slept through,
			// the toggle waited out the rest of the interval before the loop even reached the
			// reconcile — so the worst case was a full poll period of ACKing rather than the one
			// step it is now.
			// ...UNLESS A REFUSAL ALREADY STANDS. With a device that refuses, `phy_silent` never
			// reaches the mark, so breaking on the difference alone made this loop a zero-sleep
			// GET+PUT+GET hammer on the REST API for the life of the run (code-review high on
			// #223). A standing fault means the answer is known; it is re-asked once per period.
			if is_listen_only(b.iface) != rlock b.stop {
				b.stop.phy_silent
			} && wire_silence_fault(b.iface) == none {
				break
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
		// UNDER THE WRITE LOCK. Round 9 serialised sender against sender; this is the other pair,
		// and it is the one that crashes. A send that got past failure() an instant before the
		// read error can be inside ws.write() right now, and closing a client underneath an
		// active socket operation is exactly the segfault close() documents — the reason the
		// socket is closed HERE rather than there (codex round 14 on #204).
		//
		// A write completes or errors, so this waits for a bounded thing. The reverse order
		// cannot deadlock: send takes the lock and never waits on this thread.
		b.wmu.lock()
		b.ws.close(1000, 'closing') or {
			cansub_request(b.host, 'DELETE', '/api/can/${b.spec.channel}/ws', '', 2 * time.second) or {
			}
		}
		b.wmu.unlock()
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
				b.stop.decode_errors += u64(dec.errors.len)
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
// `b.rx <- rec` blocks when the buffer is full, and a raw CANsub client which is not drained still
// receives every transmit acknowledgement. It can fill all 4096 records and park the reader
// forever on the push. `close()` joins the reader — and it must,
// because closing `rx` out from under a reader parked in the socket is the panic the comment
// there describes — so closing such a handle never returned at all (codex round 1 on #204).
//
// close() clears `running` BEFORE it touches the socket, so the wait below is what the reader
// notices: a full queue is only worth waiting on while somebody is still going to drain it.
// Nothing is dropped while the bus is up; a bus on its way down stops caring.
fn (mut b CansubBus) enqueue(rec CansubRecord) bool {
	if b.rx.try_push(rec) == .success {
		return true
	}
	// A FULL QUEUE DROPS A RECORD; IT NEVER STOPS THE READER.
	//
	// This used to wait for space while the bus was running, which is a worse trade than it looks:
	// every send produces a TX acknowledgement on this same connection, so a stalled consumer can
	// fill 4096 records and then park the SOLE reader of the socket. Traffic backs up into the TLS
	// and device buffers behind it, and what follows is lost frames or a dropped connection — while
	// sends keep reporting success (codex round 10 on #204). Waiting was itself a fix, for a
	// close() that hung on the parked reader; dropping cures both, because it never blocks.
	//
	// COUNTED, not silent: a receiver that fell behind has holes in its trace and must be able to
	// find out. `diagnostics()` is what carries it.
	lock b.stop {
		b.stop.dropped++
	}
	return rlock b.stop {
		b.stop.running
	}
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
// IT DOES NOT WORK ON THIS FIRMWARE, AND THIS FUNCTION NOW SAYS SO INSTEAD OF PRETENDING.
//
// The paragraph that used to sit here said a PHY PUT "restarts the channel, so traffic stops for
// the length of one HTTP round trip" — the cost of a bus bounce, accepted as the lesser evil. It
// was never measured mid-run. Measured on a CANsub.4 (02.04.00) with curl, from outside the app:
// the SAME PUT body is answered 200 with nothing on the channel and **500 while any client holds
// the channel's WebSocket**. So every mid-run PUT this function ever made was refused, and the
// silent `return` below kept that to itself: the mark moved, the panel said listen-only, and the
// controller went on acknowledging for as long as the run lasted. `cmd/silentcheck` phases 2 and
// 5 are what finally showed it, on the first bench run after #221.
//
// So CANsub is, like Vector, a backend whose mode FOLLOWS THE MARK ONLY AT OPEN — for a driver
// reason, not a gap: Vector's is pinned by its ports, CANsub's by a device that refuses PHY
// reconfiguration on a live channel. The honest behaviour is Vector's: keep asking (one small PUT
// per poll costs nothing and the firmware may change), and RECORD the refusal against the wire so
// the Buses row shows NOT SILENT / STILL SILENT with the device's own answer, until a Stop and
// Start applies the mark at open. What would make the toggle work is closing the WebSocket around
// the PUT — a real reconnect inside the poll thread, the #214 shape — and that is a feature to
// decide on, not a fix to slip in here.
//
// Best-effort: a failed PUT leaves `phy_silent` alone, so the next poll tries again rather than
// recording a change that did not happen.
fn (mut b CansubBus) reconcile_listen_only(want bool, force bool) ! {
	// THROUGH THE ONE SEAM. This used to hand-roll what silence.v owns — the per-wire lock, the
	// record-on-failure / clear-on-success pair, the fault the Buses row reads — and every
	// finding of the review on #223 was a consequence of the copy: a ghost poll thread of a
	// closed run clearing the next run's fault, close() clearing before it stopped its own
	// thread, a fast path that never cleared, and a caller left to GUESS what happened because
	// nothing was returned. apply_silence_explained does all of it once, under one lock, and
	// says what it did.
	//
	// What stays CANsub's is inside the closure: the device is asked before it is told, because
	// the controller's actual bit is the truth and our cache is not (codex round 17 on #204), and
	// a PUT is what changes it. `running` is re-checked INSIDE the closure, under the wire lock —
	// so a thread of a closed run that gets the lock late sees `false` and attempts nothing, and
	// close() (which takes the same lock through forget_wire_silence) never races a round trip.
	// THE PROBE'S READBACK HAPPENS OUTSIDE THE LOCK. The poll thread is the one caller that
	// reaches the device every period, and its readback ran inside the seam's closure — under the
	// per-wire lock, with the dial unbounded — so a device that resolved and then blackholed held
	// the lock for an OS connect timeout, every sender on the wire queued behind it, and close()
	// queued too, through forget_wire_silence: the Stop hang the detached health thread exists to
	// prevent, put back one layer up (codex round 3 on #223). So the poll thread asks the device
	// FIRST, on its own time, and takes the lock only to compare and — if the controller was
	// changed behind our back — to PUT. A readback that failed reaches the lock as "not
	// attempted": a wire we could not read is not written to, and not waited for either.
	pre := if force { b.phy_listen_only() } else { ?bool(none) }
	set := fn [mut b, force, pre] (silent bool) int {
		return b.apply_phy_silence(silent, force, pre)
	}
	if force {
		// THE POLL THREAD PROBES: the device is asked even when the record says it is already
		// where the policy wants it, because a REST device can be reconfigured behind our back.
		apply_silence_probe(b.iface, want, set, cansub_silence_reason)!
	} else {
		apply_silence_explained(b.iface, want, set, cansub_silence_reason)!
	}
}

// apply_phy_silence is the driver call apply_silence_explained wraps: readback, then PUT if the
// device disagrees with the mark. Returns 0 when the device is in the wanted mode afterwards, the
// HTTP status when it refused, and silence_not_attempted when it could not be asked at all.
// `pre` is the poll thread's readback, taken before the lock (see reconcile_listen_only); the
// ordinary caller passes none and reads under it, once per policy change.
fn (mut b CansubBus) apply_phy_silence(want bool, force bool, pre ?bool) int {
	// MEMORY IS CONSULTED FIRST, UNDER THE WIRE LOCK — before even the running check, because a
	// standing declared refusal is the more useful answer than "not attempted" for a sender on a
	// bus that is closing: it names the device's rule and the remedy. Checking for a standing
	// refusal outside the lock let N senders that all found "no fault yet" queue behind the first
	// attempt and then each run their own readback and PUT after it — N×1.4 s of stalled traffic
	// on one wire for one toggle, recording the identical fault N times (code-review high on
	// #223). Only the poll thread FORCES a real attempt, once per period; everybody else, once a
	// refusal stands, is answered from it without a round trip.
	if !force {
		if f := wire_silence_fault(b.iface) {
			if f.want == want && f.declared {
				return 500 // re-recorded identically; the device is not asked again
			}
		}
	}
	if !rlock b.stop {
		b.stop.running
	} {
		return silence_stale // a closed run's thread: records nothing, clears nothing
	}
	// A FAULT ABOUT THE OTHER DIRECTION IS RESOLVED BY THIS REQUEST. The device refused to go
	// silent, the fault says so, and now the row is unticked: the controller is where the row
	// wants it, and NOT SILENT would be a claim about a request nobody is making any more. It
	// went on being shown until the poll thread's next successful readback — indefinitely, if
	// that thread was stuck dialling (codex round 1 on #223). apply_silence clears on success,
	// so returning 0 below is what clears it; this comment is here so the next reader knows the
	// clearing is deliberate and not incidental.
	// THE DEVICE IS ASKED, NOT OUR MEMORY OF IT.
	//
	// `phy_silent` records what THIS bus last PUT, which is only the same thing as what the
	// controller is doing while nothing else touches it. Something else can: close() no longer
	// waits for this thread (see there, and #214), so a PUT from a PREVIOUS run of this wire can
	// still be in flight when a new Start has already configured the channel — and comparing our
	// own memory against the policy, both buses agree with themselves and neither ever notices
	// that the controller is doing something else entirely (codex round 17 on #204).
	//
	// Reading it back costs one small GET per poll to a device on the end of a USB cable, and it
	// makes this self-healing against any divergence rather than just the ones we caused: another
	// tool reconfiguring the channel, a device that rebooted, a PUT we thought had failed and had
	// not.
	//
	// If the device cannot be read, fall back on what we last set. A wire we cannot ask about is
	// not one to reconfigure on a guess.
	// NOT ONE TO RECONFIGURE ON A GUESS — and now that is enforced rather than stated: a wire we
	// cannot read is not written to. The previous version fell back to its cache and PUT anyway,
	// which could set phy_silent on the strength of a write never read back (codex #204 r17/18).
	// A PROBE WHOSE POLICY MOVED WHILE IT WAS READING IS DISCARDED. `want` and `pre` were taken
	// outside the lock; a row toggled meanwhile has already been reconciled on demand by the
	// time the probe holds it, and applying the stale pair would PUT the opposite mode LAST — a
	// listen-only wire acknowledging, or a normal one that cannot send (codex round 6 on #223).
	// The policy is re-read under the lock, and a probe that no longer matches it attempts
	// nothing; the next period asks again.
	if force && is_listen_only(b.iface) != want {
		// STALE, NOT "NOT ATTEMPTED": the status matters, because not-attempted clears a fault
		// about the other direction — which here is the CURRENT direction's fault, recorded by
		// the on-demand reconcile that overtook this probe (codex round 12 on #223). A
		// discarded probe touches nothing.
		return silence_stale
	}
	have := if force {
		pre or { return silence_not_attempted }
	} else {
		b.phy_listen_only() or { return silence_not_attempted }
	}
	// THE CACHE IS PUBLISHED BEFORE THE PUT, not after it, and whether they agree or not.
	//
	// `send()` refuses while `phy_silent` says the controller is silent — that is what keeps a
	// send from succeeding into a wire that cannot carry it. When the readback DISCOVERS a silent
	// controller under a normal policy, the old cache still said `false`, so for the whole
	// duration of the PUT — and forever if it failed — send() went on reporting success for
	// frames that never reached the wire (codex round 18 on #204). The readback learned the truth
	// and kept it to itself.
	//
	// So what the DEVICE says is published the moment it is known. The PUT below moves it to
	// `want` only if it succeeds.
	lock b.stop {
		b.stop.phy_silent = have
	}
	if want == have {
		return 0 // the device already agrees; apply_silence records and clears
	}
	nominal := cansub_timing_for(b.spec.arb, cansub_default_sample_point) or {
		return silence_not_attempted
	}
	mut data := ?CansubTiming(none)
	if b.spec.fd {
		data = cansub_timing_for_data(b.spec.data, cansub_default_sample_point) or {
			return silence_not_attempted
		}
	}
	// THE SAME BOUNDED BUDGET AS THE HEALTH GET BESIDE IT, and for the same reason: this runs on
	// the thread close() joins, so a device that has gone unreachable would park Stop here for
	// five seconds — in precisely the case this function exists for, a policy mismatch. Shortening
	// only the GET left the stall exactly where it started (codex round 6 on #204).
	//
	// Safe to bound because a failure changes nothing: `phy_silent` holds what the device was last
	// OBSERVED to be, so a PUT that runs out of time is simply retried on the next poll.
	//
	// AND `running` IS CHECKED AGAIN, because the readback above is a network round trip and Stop
	// can happen inside it. The check at the top of this function had already passed by then — so
	// a stalled GET, a Stop, and a new run configuring this channel left the old thread free to
	// resume here and PUT a configuration nobody had asked for since (codex round 18 on #204).
	// That also makes close()'s claim true again: an abandoned thread finishes a GET and stops.
	if !rlock b.stop {
		b.stop.running
	} {
		return silence_stale // a closed run's thread: records nothing, clears nothing
	}
	// A PUT THAT COULD NOT BE DELIVERED IS A FAULT, NOT "NOT ATTEMPTED". The readback above has
	// just shown the controller in the OTHER mode from the record, so the record is disproved
	// whatever happens to the PUT; returning not-attempted preserved it, every ordinary caller
	// then took the recorded-state shortcut, and a controller another tool had set back to normal
	// went on acknowledging under a silent record with nothing on the Buses row until a later
	// probe succeeded (codex round 8 on #223). Not-attempted is right only when the readback
	// itself could not be made. This status clears the record and shows the fault; the poll
	// thread retries.
	r := cansub_request(b.host, 'PUT', '/api/can/${b.spec.channel}/phy', cansub_phy_json(nominal,
		data, want), cansub_health_timeout) or { return cansub_put_undelivered }
	if r.status != 200 && r.status != 204 {
		return r.status // apply_silence records it, in cansub_silence_reason's words
	}
	lock b.stop {
		b.stop.phy_silent = want
	}
	return 0
}

// cansub_silence_reason reads a refused PHY PUT for the operator. A 500 on a live channel is
// DECLARED — the device's rule, not a fault — which is what lets a bench tool call that phase not
// applicable while still failing on a driver error elsewhere.
fn cansub_silence_reason(want bool, status int) SilenceReason {
	return SilenceReason{
		why:      cansub_phy_refusal(status)
		declared: status == 500
	}
}

// cansub_phy_refusal is the operator-facing reading of a refused PHY PUT.
//
// Pure, so CI can hold the one answer that matters: a 500 on a live channel is not a fault in the
// device or in us, it is the device declining to reconfigure a channel somebody is using — and the
// remedy is a Stop and Start, which applies the mark at open, where the device accepts it.
// cansub_put_undelivered is the status apply_phy_silence returns when the device was read but the
// PUT to change it could not be delivered: a fault (the record is disproved), not a refusal.
pub const cansub_put_undelivered = -1

pub fn cansub_phy_refusal(status int) string {
	if status == cansub_put_undelivered {
		return 'the controller was read in the other mode and the PHY PUT to change it could not be delivered; retried every poll'
	}
	if status == 500 {
		return 'the device refuses PHY reconfiguration while the channel is open (HTTP 500) — a CANsub follows listen-only only at open; Stop and Start to apply it'
	}
	return 'PHY reconfiguration refused (HTTP ${status})'
}

// phy_listen_only reads the controller's ACTUAL listen-only bit off the device. `/api/can/{ch}`
// carries the fault state and not this, so it is its own small GET against `/phy`.
fn (b &CansubBus) phy_listen_only() ?bool {
	body := cansub_get_within(b.host, '/api/can/${b.spec.channel}/phy', cansub_health_timeout) or {
		return none
	}
	return extract_json_bool(body, 'listen_only')
}

// poll_health asks the device what its controller thinks. The states map one to one onto this
// repo's ladder, which is the whole reason `health()` can say anything here at all.
fn (mut b CansubBus) poll_health() {
	// SHORT, because this thread is joined by close(): see cansub_get_within.
	body := cansub_get_within(b.host, '/api/can/${b.spec.channel}', cansub_health_timeout) or {
		b.health_miss()
		return
	}
	// AN ANSWER WE CANNOT READ IS NOT AN ANSWER. A 200 whose body this parser does not understand
	// — a renamed field, a firmware that dropped it — used to return quietly, leaving the LAST
	// sample standing. That is the same stale-verdict failure as an unreachable device, arriving
	// down the one path that had not been told about it, and it is worse: it could hold `.ok` over
	// a controller that had gone BUS-OFF (codex round 13 on #204). Both roads lead to the same
	// place now.
	sent := rlock b.stop {
		b.stop.transmitted
	}
	h := cansub_ladder(body, sent) or {
		b.health_miss()
		return
	}

	lock b.stop {
		b.stop.health = h
		b.stop.health_misses = 0
	}
}

// cansub_ladder reads the device's status body onto this repo's ladder.
//
// THE FIRMWARE STARTS A CHANNEL AT TEC 129 (CANsub.4, 02.04.00, measured on 2026-08-28: state
// error_passive, tx_error_count 129, frame_count 0 — alone on the wire, and even opened
// listen-only, where a controller cannot transmit at all). A CAN node lowers its transmit error
// counter only by transmitting successfully, so a MONITOR — which never transmits — sits at 129
// for the life of the run while receiving every frame with a receive counter of 0. The device's
// `state` follows the higher counter, so mapping `state` alone painted a healthy monitor
// ERROR-PASSIVE at Start and forever after (#241).
//
// So the ladder is read from the counter that describes what this node is DOING: a channel that
// has not transmitted in this run is judged by `rx_error_count` (the thresholds are ISO 11898's:
// warning at 96, error-passive at 128); once it has transmitted, its `state` is the controller's
// verdict about both, as on every other backend. Bus-off is bus-off whatever the counters say.
fn cansub_ladder(body string, transmitted bool) ?BusHealth {
	state := extract_json_string(body, 'state')?
	if state == 'bus_off' {
		return BusHealth.bus_off
	}
	if transmitted || state == 'stopped' {
		return cansub_state_health(state)
	}
	// ONLY A STATE THIS CODE KNOWS IS READ THROUGH ITS COUNTER. A firmware that adds or renames
	// a state still returns counters, and a low receive counter beside a state nobody here
	// understands is not "ok" — it is the unknown poll_health already treats as no verdict
	// (codex round 1 on #243).
	if state !in ['error_active', 'error_warning', 'error_passive'] {
		return BusHealth.unknown
	}
	rec := extract_json_int(body, 'rx_error_count') or { return cansub_state_health(state) }
	if rec >= 128 {
		return BusHealth.error_passive
	}
	if rec >= 96 {
		return BusHealth.warning
	}
	return BusHealth.ok
}

// health_miss records a poll that produced no verdict, whatever the reason — unreachable, or an
// answer this code could not read.
//
// A VERDICT WE CAN NO LONGER OBTAIN MUST STOP BEING REPORTED. Returning quietly left the LAST
// sample standing — commonly `.ok` — and `recv` reads socket timeouts as an idle bus, so a device
// that had stopped answering went on reporting a healthy controller indefinitely (codex rounds 7
// and 13 on #204). One miss is a hiccup; several in a row is not knowing, and `.unknown` is what
// this ladder has for that.
// cansub_confirm_identity reads /api/info and requires the id the address was opened for.
fn cansub_confirm_identity(host string, id string) ! {
	body := cansub_get_within(host, '/api/info', cansub_open_timeout) or {
		return error('the device at ${host} did not answer /api/info: ${err}')
	}
	got := extract_json_string(body, 'id') or { return error('the device at ${host} reports no id') }
	if got.to_lower() != id.to_lower() {
		return error('the device at ${host} is ${got}, not ${id} — the address has been reassigned')
	}
}

// cansub_state_health maps the device's controller state onto this repo's ladder — one to one,
// which is the whole reason health() can say anything here at all.
fn cansub_state_health(state string) BusHealth {
	return match state {
		'error_active' { BusHealth.ok }
		'error_warning' { BusHealth.warning }
		'error_passive' { BusHealth.error_passive }
		'bus_off' { BusHealth.bus_off }
		'stopped' { BusHealth.unknown } // not on the bus: nothing to report, and not a fault
		else { BusHealth.unknown }
	}
}

// cansub_health_now asks the device for its controller state RIGHT NOW, on the caller's thread,
// and returns none if it cannot be asked. Not what health() returns: that is the poll thread's
// cache, and a bench tool proving that acknowledgements resumed needs a sample it can date —
// one that provably postdates the frames it just sent — which a cache cannot give it whatever
// its age is assumed to be (codex round 8 on #223). One GET per call; a tool's cost, not the
// app's.
pub fn cansub_health_now(iface string) ?BusHealth {
	spec := parse_cansub_iface(iface) or { return none }
	host := cansub_host(spec.id)
	body := cansub_get_within(host, '/api/can/${spec.channel}', cansub_health_timeout) or {
		return none
	}
	state := extract_json_string(body, 'state') or { return none }
	return cansub_state_health(state)
}

fn (mut b CansubBus) health_miss() {
	lock b.stop {
		b.stop.health_misses++
		if b.stop.health_misses >= cansub_health_misses {
			b.stop.health = .unknown
		}
	}
}

// extract_json_bool pulls one boolean field out of a flat JSON object, with the same tolerance for
// whitespace that extract_json_string has and for the same reason.
fn extract_json_bool(s string, key string) ?bool {
	i := s.index('"${key}"') or { return none }
	mut j := i + key.len + 2
	for j < s.len && s[j] in [` `, `\t`, `\n`, `\r`] {
		j++
	}
	if j >= s.len || s[j] != `:` {
		return none
	}
	j++
	for j < s.len && s[j] in [` `, `\t`, `\n`, `\r`] {
		j++
	}
	rest := s[j..]
	if rest.starts_with('true') {
		return true
	}
	if rest.starts_with('false') {
		return false
	}
	return none
}

// extract_json_string pulls one string field out of a flat JSON object. The device's replies are
// small and flat, and a full parser here would be a dependency for four fields.
// extract_json_int reads a bare integer field ("rx_error_count": 129) from the device's status
// body — the same flat JSON extract_json_string reads, so the same non-parser: the device's
// bodies are one level deep and this repo has no JSON module on the engine side.
fn extract_json_int(s string, key string) ?int {
	needle := '"${key}"'
	i := s.index(needle) or { return none }
	mut j := i + needle.len
	// Whitespace is legal JSON on either side of the colon — see extract_json_string; a firmware
	// that pretty-prints must not turn a healthy monitor back into error-passive (codex round 1
	// on #243).
	for j < s.len && s[j] in [` `, `\t`, `\n`, `\r`] {
		j++
	}
	if j >= s.len || s[j] != `:` {
		return none
	}
	j++
	for j < s.len && s[j] in [` `, `\t`, `\n`, `\r`] {
		j++
	}
	mut k := j
	if k < s.len && s[k] == `-` {
		k++
	}
	for k < s.len && s[k].is_digit() {
		k++
	}
	if k == j || (k == j + 1 && s[j] == `-`) {
		return none
	}
	return s[j..k].int()
}

fn extract_json_string(s string, key string) ?string {
	// WHITESPACE IS LEGAL JSON. Matching `"key":"` exactly meant a device that pretty-printed its
	// reply — `"state": "bus_off"`, one space — parsed as nothing at all, and the caller treated
	// that as an answer (codex round 13 on #204). The device does not format that way today; a
	// firmware update is not something to find out about through a health indicator stuck on ok.
	i := s.index('"${key}"') or { return none }
	mut j := i + key.len + 2
	for j < s.len && s[j] in [` `, `\t`, `\n`, `\r`] {
		j++
	}
	if j >= s.len || s[j] != `:` {
		return none
	}
	j++
	for j < s.len && s[j] in [` `, `\t`, `\n`, `\r`] {
		j++
	}
	if j >= s.len || s[j] != `"` {
		return none
	}
	rest := s[j + 1..]
	end := rest.index('"') or { return none }
	return rest[..end]
}

// refusal is what send would refuse before writing — asked by the hub before it registers the
// send (SharedDriver.refusal), and asked again by send itself as the belt to that brace.
pub fn (b &CansubBus) refusal(frame CanFrame) ?string {
	if frame.fd && !b.spec.fd {
		// Refuse rather than truncate, which is what the Windows vendor backends do with an FD
		// frame they cannot carry. The address is what asks for FD, so a classic channel being
		// handed an FD frame is a project that disagrees with itself.
		return '${b.iface} is a classic channel — its address names one bitrate, so it cannot carry a CAN-FD frame'
	}
	if e := b.failure() {
		return '${b.iface}: ${e}${b.diagnostic_suffix()}'
	}
	if e := b.send_refusal() {
		return '${b.iface}: ${e}'
	}
	return none
}

pub fn (mut b CansubBus) send(frame CanFrame) ! {
	if reason := b.refusal(frame) {
		return not_written(reason)
	}
	// A SILENCED CONTROLLER CANNOT TRANSMIT, whatever this process's policy currently says.
	//
	// The two answers are not updated together and cannot be: `silenced()` is a table this process
	// rewrites the moment a row is toggled, while the PHY is a register reached over HTTP by the
	// health thread on its next pass. Going from listen-only to normal, SilentBus therefore starts
	// permitting sends immediately while the controller is still silent — and a send in that window
	// returned SUCCESS for a frame that never reached the wire, which the tap then recorded as a
	// TX that happened (codex round 7 on #204). An experiment loses traffic and the trace says it
	// did not, which is the one failure this backend exists to prevent.
	//
	// So the controller's ACTUAL state is what decides, and the window is a refusal rather than a
	// lie. It also covers a reconcile that keeps failing: sends stay refused, honestly, instead of
	// succeeding into a wire that cannot carry them. The reverse direction needs nothing — normal
	// PHY with a silent policy is what SilentBus already refuses before reaching here.
	if rlock b.stop {
		b.stop.phy_silent
	} {
		// THE RECORDED REASON, when there is one. "is being reconfigured" was a hope this branch
		// measured to be false on a live channel; when the device has refused, the sender is told
		// what the Buses row shows, remedy included.
		if f := wire_silence_fault(b.iface) {
			return error('${b.iface}: ${f.why}; the frame was not sent')
		}
		return error('${b.iface}: the controller is still in listen-only; the frame was not sent — a CANsub follows the mark at open, so Stop and Start')
	}
	body := cansub_encode_frame(frame)!
	// Encoded outside the lock, written inside it: the encoding is per-frame work with no shared
	// state, and the socket is the thing that cannot take two writers.
	b.wmu.lock()
	defer {
		b.wmu.unlock()
	}
	b.ws.write(cansub_hdlc_wrap(body), .binary_frame) or {
		// A WRITE THAT FAILED IS THE END OF THIS CONNECTION. A timed-out write may have put the
		// frame header or part of the payload on the stream before giving up; the next send would
		// be read by the device as the rest of that frame, and CAN traffic is lost or misdecoded
		// (codex round 2 on #251). So the bus is marked stopped with the reason: the reader,
		// which owns the socket, sees `running` drop within one read timeout and closes it under
		// this lock on its way out, and every later send refuses through failure().
		b.fail_send('send on ${b.iface}: ${err}')
		return error('send on ${b.iface}: ${err}')
	}
	// From here the transmit counter is this node's own doing — see cansub_ladder.
	lock b.stop {
		b.stop.transmitted = true
	}
}

// cansub_poll_ms is how often an idle receiver looks up from the queue to ask whether the socket
// is still there. A CEILING on one select, never a floor.
const cansub_poll_ms = i64(200)

// How long a health poll may wait for the device. Bounded by what Stop can tolerate rather than by
// what the network might need: this runs on a thread close() joins.
const cansub_health_timeout = 700 * time.millisecond

// How many consecutive unreachable health polls before the last verdict is withdrawn. One is a
// timeout on a busy device; three in a row, at two polls a second, is a device that has stopped
// answering.
const cansub_health_misses = 3

// How long any single request on the OPEN path may take. Short because a Start waits on it: every
// opener of this wire waits on the one attempt (#211), and a GUI Start opens each wire three
// times — see the note beside the PHY PUT.
const cansub_open_timeout = 2 * time.second

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

// recv_shared is the shared hub's private receive seam. A CANsub reports both traffic received
// from the wire and acknowledgements for this process's own transmissions over the one WebSocket;
// projecting both straight to CanFrame makes a TX acknowledgement indistinguishable from RX.
// The hub needs this one bit so it can suppress the frame for its originating logical handle and
// fan it out to the other subscribers. The public Bus contract stays CanFrame-only below.
fn (mut b CansubBus) recv_shared(timeout_ms int) !SharedIngress {
	deadline := time.ticks() + i64(timeout_ms)
	// `probe` means the next slice may be a zero-length look at the queue rather than a wait. True
	// to begin with, and true again after anything is TAKEN from the queue — because a record that
	// came straight out is not time spent waiting, and a recv(0) that consumed an error record and
	// then reported `timeout` left a perfectly good frame sitting behind it. That was a defect of
	// the previous round's recv(0) fix (codex round 4 on #204).
	mut probe := true
	for {
		wait := if probe {
			cansub_first_wait(timeout_ms, deadline, time.ticks()) or { return error('timeout') }
		} else {
			cansub_wait_slice(timeout_ms, deadline, time.ticks()) or { return error('timeout') }
		}
		probe = false
		select {
			rec := <-b.rx {
				if rec.is_error {
					// Something came out of the queue, so look again rather than counting this as
					// time spent waiting — see `probe` above.
					probe = true
					// A bus error is real news, but it is not a frame and the Bus interface has
					// nowhere to put it, so it is skipped here rather than returned as a junk
					// frame.
					//
					// RECORDED ON THE WAY PAST, though. This used to say `health()` is where it
					// surfaces, and that was simply untrue: health() reports the state the REST
					// poll last sampled and never looks at `rec.err`, so an isolated ACK, CRC,
					// bit, form or stuffing error that cleared before the next poll disappeared
					// from the trace, the log and the indicators alike — the controller told us
					// and we dropped it (codex round 9 on #204). Counted here, with the first one
					// kept, beside the decode errors and for the same reason.
					lock b.stop {
						b.stop.bus_errors++
						if b.stop.first_bus_error == '' {
							b.stop.first_bus_error = rec.err.str()
						}
					}
					continue
				}
				return SharedIngress{
					frame:  rec.frame
					tx_ack: rec.tx
				}
			}
			// Bounded, so a closed socket does not park a caller here forever.
			wait * time.millisecond {
				if e := b.failure() {
					return error('${b.iface}: ${e}${b.diagnostic_suffix()}')
				}
			}
		}
	}
	return error('timeout')
}

// reports_tx_ack tells the shared hub that every successful write is expected to produce a
// flagged record on this ingress. The hub owns send ordering and origin correlation; the backend
// can report only what the device put in the record, not which logical SharedHandle initiated it.
fn (b &CansubBus) reports_tx_ack() bool {
	return true
}

pub fn (mut b CansubBus) recv(timeout_ms int) !CanFrame {
	return b.recv_shared(timeout_ms)!.frame
}

// diagnostics is everything this backend knows that is not a frame and not a health rung: records
// it could not decode, controller errors the device reported, and records dropped because the
// receiver fell behind. Round 3 and round 9 of #204 each answered a finding by COUNTING one of
// these and nothing ever read the counts — write-only state that looked like a fix and changed
// nothing observable (codex round 10 on #204). Since #213 they travel the Bus contract, which is
// where the Buses row and the Log read them; they still ride the text of this backend's own
// errors too, because that is where an operator is looking when a call has just failed.
pub fn (b &CansubBus) diagnostics() BusDiagnostics {
	return rlock b.stop {
		BusDiagnostics{
			dropped:       b.stop.dropped
			bus_errors:    b.stop.bus_errors
			decode_errors: b.stop.decode_errors
		}
	}
}

// diagnostic_suffix is the counts with the FIRST error of each kind, ready to append to a
// message, or nothing. The texts live here and not on BusDiagnostics: they belong beside the
// failure an operator is reading, not in a value the RX loop diffs once a second.
fn (b &CansubBus) diagnostic_suffix() string {
	d := rlock b.stop {
		mut parts := []string{}
		if b.stop.dropped > 0 {
			parts << '${b.stop.dropped} record(s) dropped — the receiver fell behind'
		}
		if b.stop.bus_errors > 0 {
			parts << '${b.stop.bus_errors} controller error(s), first ${b.stop.first_bus_error}'
		}
		if b.stop.decode_errors > 0 {
			parts << '${b.stop.decode_errors} undecodable record(s), first "${b.stop.first_decode_error}"'
		}
		parts.join('; ')
	}
	return if d == '' { '' } else { ' (${d})' }
}

// fail_send records a write failure as the reason this bus stopped — see send. The first
// reason wins: a reader that has already stopped has the better story.
fn (mut b CansubBus) fail_send(reason string) {
	// THE CONNECTION IS OVER FOR WRITING, AND ONLY FOR WRITING. A timed-out write may have
	// left part of a frame on the stream, so no later send may use it (send_err, read by send
	// alone); it may also have REACHED the device, whose TX acknowledgement arrives a moment
	// later and which the hub keeps matchable for its grace — so the reader is NOT stopped,
	// by this or by any clock of its own: three timers were tried and each raced the hub's
	// window from one side or the other (codex rounds 5–7 on #251). The reader reads on until
	// close(), which the hub drives, and the receive path is told nothing it did not see.
	lock b.stop {
		if b.stop.send_err == '' {
			b.stop.send_err = reason
		}
	}
}

// send_refusal is the write failure that ended this connection for sending, if one has.
fn (b &CansubBus) send_refusal() ?string {
	return rlock b.stop {
		if b.stop.send_err == '' {
			none
		} else {
			b.stop.send_err
		}
	}
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

// reconcile_silence — on demand, when the mark differs from what the controller was last told.
//
// This was a no-op in #219 on the grounds that the poll thread's `reconcile_listen_only` does the
// work continuously. True, and LATE: a handle joining an already-held wire, or a send after a
// toggle, went through here, found nothing to do, and the refusal (or the change) landed only when
// the poll thread next came round, up to a poll period later — so a check right after the join
// found no fault recorded and the wire looking obedient while it was not.
//
// THE COMMON PATH COSTS A LOCK READ, NOT A ROUND TRIP. `SilentBus.send` calls this before every
// send, so comparing against the cached `phy_silent` is what keeps an HTTP GET off the send path.
// Only a DIFFERENCE runs the full reconcile — readback, PUT, and the fault record — on the
// caller's thread, once, and the poll thread keeps retrying after that as before.
pub fn (mut b CansubBus) reconcile_silence(want bool) ! {
	// NO FAST PATH OUTSIDE THE LOCK. There used to be one — "if the cache already says `want`,
	// return" — and it inverted a toggle: thread A is mid-PUT setting normal, `phy_silent` still
	// says silent because it moves only when the PUT succeeds; the row is ticked back to
	// listen-only; thread B reads the stale cache, matches, returns "done"; A's PUT lands last
	// and the controller is normal under a listen-only mark, with nothing to correct it until the
	// next poll (codex round 1 on #223). The lock is where the truth is: apply_silence takes it,
	// checks its own record under it — which is what makes the common case a lock acquire and no
	// I/O — and the closure answers a standing refusal from memory without a round trip.
	b.reconcile_listen_only(want, false)!
}

pub fn (mut b CansubBus) close() {
	lock b.stop {
		if b.stop.closed {
			return
		}
		b.stop.closed = true
		b.stop.running = false
	}
	// A FAULT MUST NOT OUTLIVE THE WIRE IT DESCRIBES — and the order here is the whole point.
	// `running` goes false FIRST, so any reconcile that has not yet taken the wire lock attempts
	// nothing; THEN forget_wire_silence takes that lock, which waits out a reconcile already in
	// its (bounded) round trip and clears record and fault after it — never before it, which was
	// how a ghost of this run re-recorded a fault the next run then displayed. #219 fixed the
	// outliving fault for PCAN this way; the first cut of this branch cleared it up here, unlocked
	// and unordered, and got it wrong twice (code-review high on #223).
	forget_wire_silence(b.iface)
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
	// THE HEALTH THREAD IS NOT WAITED FOR, and that is the point.
	//
	// Its requests cannot be bounded from here. `read_timeout` is the only budget vlib's SSL
	// client offers and it starts AFTER the connection is up, so a device whose mDNS name resolves
	// to a host that blackholes connections leaves that thread inside `dial` for however long the
	// OS takes — and joining it made Stop wait out an OS connect timeout no matter what number
	// this code chose (codex round 16 on #204). Shortening the budget in rounds 7 and 8 could not
	// reach it, because the budget was never the thing in charge.
	//
	// So Stop does not depend on it. What it does depend on is the reader, which owns the socket
	// and is bounded by a read timeout this code CAN set — that join stays.
	//
	// Safe to leave running: it touches `host`, `spec` and `stop`, all of which outlive it under
	// the GC, and `running` is already false. Its loop exits on return, and reconcile_listen_only
	// checks `running` BOTH before its readback and again before the PUT that follows it — the
	// second check being what keeps this sentence true, since a network round trip sits between
	// them and Stop can happen inside it. So the worst an abandoned thread does is finish one GET
	// whose answer nobody reads. #214 is the missing connect timeout, and closing the last window
	// — a PUT already in flight — waits on it.
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
	r := cansub_request(host, 'PUT', '/api/time', stamp, cansub_open_timeout)!
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
// cansub_id_ok reports whether a device id can be half of a hostname: letters, digits and
// hyphens, no hyphen at either end, and short enough for a DNS label.
fn cansub_id_ok(id string) bool {
	// The suffix the device appends makes the label that much longer than the id, and a DNS
	// label is 63 at most.
	if id.len == 0 || id.len > 63 - cansub_host_suffix.len {
		return false
	}
	if id.starts_with('-') || id.ends_with('-') {
		return false
	}
	for c in id {
		if !((c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `-`) {
			return false
		}
	}
	return true
}

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
