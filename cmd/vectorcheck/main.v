// vectorcheck — bring up a Vector XL channel safely and prove it works, before any project or
// bench depends on it.
//
// SILENT BY DEFAULT. The channel is opened listen-only, so the transceiver never acknowledges
// and cannot disturb whatever is already on the wire. That matters most in exactly the case you
// reach for this tool: a VN channel wired to a running target, whose bitrate you believe you
// know. A node that goes on the bus at the wrong bitrate floods error frames and degrades the
// bus for everyone on it; a silent one that has the bitrate wrong simply reports nothing.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/vectorcheck/main.v --list
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/vectorcheck/main.v --channel 1
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/vectorcheck/main.v --channel 1 --transmit
//
// `-enable-globals` is not optional: modules/transport/inproc.v uses `__global`, and without it
// the build fails before anything Vector-specific is reached.
//
// From WSL, cross-compile and run the result on Windows — the XL library lives there:
//   v -os windows -enable-globals -path "@vlib|@vmodules|modules" -o vectorcheck.exe cmd/vectorcheck/main.v
module main

import os
import time
import sync
import transport

struct Opts {
	list     bool
	probe    bool
	selftest bool
	assign   int = -1
	release  int = -1
	pair     string
	channel  int
	bitrate  int
	seconds  int
	transmit bool
}

// nonempty is `?string` sugar so an unloaded library prints nothing rather than a blank label.
fn nonempty(s string) ?string {
	return if s == '' { none } else { s }
}

// whole_int refuses a token that is only PARTLY a number. V's `.int()` takes a numeric prefix
// and maps anything else to zero, so `--assign 1x` silently selected row 1 and `--assign oops`
// selected row 0 — and --assign permanently rewrites an application-channel assignment.
// is_test_frame recognises a frame this tool sent: the marker bytes, and an id that agrees with
// the sequence number in the payload. Shared by the main loop and the final drain, because a
// drain that accepts anything eight bytes long will happily pass the test on other people's
// traffic.
// borrow_channels takes the application channels a test needs, remembering what they pointed at
// so they can be handed back.
//
// The 1..64 range is entirely the operator's — picking high numbers made a collision less likely,
// not impossible, and "less likely" is not a property to rely on when the cost is permanently
// rewriting somebody's bench configuration. Anything found in use is restored on the way out.
struct Borrowed {
	app  int
	prev ?transport.VectorChannel
}

// The borrowed channels, reachable from a signal handler. A `defer` covers a return; it does
// not cover Ctrl-C, which is how anybody stops a diagnostic that is transmitting for ten
// seconds — and the process then exits with somebody's bench still pointed at our test
// hardware. The one thing this tool must never do is leave a configuration changed.
__global (
	g_borrowed      []Borrowed
	g_borrow_mu     &sync.Mutex
	g_shutting_down bool
)

// The handler runs on another thread, and `borrow()` appends to the same array — an append that
// may reallocate while the handler is walking it. A torn read there restores the wrong channels,
// or none, which is the failure this whole mechanism exists to prevent.
// Created ONCE, by borrow_init, before the interrupt handler is installed. Creating it lazily
// was itself an unsynchronised check-and-assign: the handler thread and the first borrow could
// each make a mutex, lock different objects, and protect nothing — a lock with a race in its own
// construction.
fn borrow_init() {
	if isnil(g_borrow_mu) {
		g_borrow_mu = sync.new_mutex()
	}
}

fn borrow_lock() {
	g_borrow_mu.lock()
}

fn borrow_unlock() {
	if !isnil(g_borrow_mu) {
		g_borrow_mu.unlock()
	}
}

fn on_interrupt(_ os.Signal) {
	eprintln('')
	eprintln('interrupted — restoring Vector application channels')
	borrow_lock()
	// CLOSED FOR NEW BORROWS before the snapshot is taken. The handler runs on another thread,
	// so releasing the lock and then exiting left the main thread free to borrow one more
	// channel — which no snapshot could contain, and which therefore stayed pointed at the test
	// hardware for good.
	g_shutting_down = true
	snapshot := g_borrowed.clone()
	borrow_unlock()
	give_back(snapshot)
	exit(130)
}

fn borrow(app int, hw transport.VectorChannel) !Borrowed {
	// Held from the first borrow to the last restore — see transport.vector_borrow_lock. Taken
	// per borrow and released in give_back, which is the span that must be atomic against
	// another copy of this tool.
	transport.vector_borrow_lock()!
	// REFUSED if we cannot see what we would overwrite. A read failure used to look like a free
	// channel, and the borrow then "restored" it by clearing a mapping the operator had made.
	prev, had := transport.vector_assignment(app)!
	b := Borrowed{
		app:  app
		prev: if had { ?transport.VectorChannel(prev) } else { none }
	}
	// RECORDED BEFORE THE CHANGE. Appending afterwards left a window in which Ctrl-C restored
	// every earlier borrow and not this one — the assignment already written, and nothing left
	// that knew to undo it. Recording an intention we might not carry out is harmless: giving
	// back a channel that was never taken restores it to what it already is.
	// RECORDED AND ASSIGNED UNDER ONE LOCK. Split, the handler could snapshot between them and
	// restore a channel the main thread was about to overwrite — putting the assignment back
	// after the cleanup that was meant to undo it.
	borrow_lock()
	if g_shutting_down {
		borrow_unlock()
		return error('interrupted before this channel was taken')
	}
	g_borrowed << b
	transport.vector_assign(app, hw) or {
		g_borrowed.delete_last()
		borrow_unlock()
		return err
	}
	borrow_unlock()
	return b
}

// EXACTLY ONCE PER CHANNEL, whoever gets there first. The interrupt handler and the ordinary
// deferred cleanup can run at the same time, and neither used to claim what it was about to
// restore — so both wrote the same mappings, and a handler delayed past the interprocess unlock
// could overwrite the assignments of the NEXT vectorcheck to take the lock. Each entry is
// removed from the shared list under the mutex before it is restored; a caller that finds
// nothing left has nothing to do.
fn give_back(bs []Borrowed) {
	borrow_lock()
	mut mine := []Borrowed{}
	for b in bs {
		for i, g in g_borrowed {
			if g.app == b.app {
				mine << g
				g_borrowed.delete(i)
				break
			}
		}
	}
	borrow_unlock()
	defer {
		for _ in mine {
			transport.vector_borrow_unlock()
		}
	}
	for b in mine {
		// AS WE FOUND IT includes "not assigned at all". Restoring only the channels that had a
		// mapping left the others pointing at our test hardware for good, which is the same
		// unasked-for change to somebody's bench, just quieter.
		if p := b.prev {
			transport.vector_assign(b.app, p) or {
				eprintln('note: could not restore Vector application channel ${b.app}: ${err}')
			}
		} else {
			transport.vector_unassign(b.app) or {
				eprintln('note: could not clear Vector application channel ${b.app}: ${err}')
			}
		}
	}
}

// poll returns a frame, or none when the queue is simply empty, and FAILS on anything else.
//
// The fourth place this distinction was needed. It was added to the --channel loop, then the
// --pair drain, then its tail, and each time the remaining loops went on reporting a broken
// adapter as an idle bus. A predicate every caller shares cannot be got right in one of them.
fn poll(mut b transport.Bus, ms int) !(transport.CanFrame, bool) {
	f := b.recv(ms) or {
		if err.msg().contains('timeout') {
			return transport.CanFrame{}, false
		}
		return err
	}
	return f, true
}

fn is_test_frame(f transport.CanFrame) bool {
	// ALL FOUR marker bytes. Checking two of them let a payload corrupted in byte 5 or 6 pass as
	// a good frame, which is the one thing a link test must not do: the markers are there to
	// notice corruption, and half of them notice half of it.
	// THE FORMAT TOO, not only the bytes. This test sends a standard classic data frame; a
	// remote, extended or FD frame carrying the same id and payload is a different message on
	// the wire, and accepting it would report a link that faithfully carries something we never
	// sent.
	if f.extended || f.rtr || f.fd {
		return false
	}
	if f.data.len != 8 || f.data[4] != 0xA5 || f.data[5] != 0x5A || f.data[6] != 0xC3
		|| f.data[7] != 0x3C {
		return false
	}
	seq := (u32(f.data[0]) << 24) | (u32(f.data[1]) << 16) | (u32(f.data[2]) << 8) | u32(f.data[3])
	return f.id == 0x100 + (seq % 8)
}

fn whole_int(tok string, what string) !int {
	t := tok.trim_space()
	if t == '' {
		return error('${what} needs a number')
	}
	mut digits := 0
	for i, c in t {
		if c.is_digit() {
			digits++
			continue
		}
		if i == 0 && c == `-` {
			continue
		}
		return error('${what}: "${t}" is not a number')
	}
	// AT LEAST ONE DIGIT. A lone "-" passed the character test and `.int()` made it zero, so
	// `--assign -` selected row 0 and rewrote an application-channel mapping for good. A sign
	// is not a number.
	if digits == 0 {
		return error('${what}: "${t}" is not a number')
	}
	return t.int()
}

fn usage() {
	eprintln('usage: vectorcheck --list')
	eprintln('       vectorcheck --channel <n> [--bitrate <bps>] [--seconds <n>] [--transmit]')
	eprintln('')
	eprintln('  --list      application channels with hardware assigned in Vector Hardware Manager')
	eprintln('  --probe     what the DRIVER says is present (hwType/hwIndex/hwChannel)')
	eprintln('  --selftest  prove the backend on Vector VIRTUAL channels — touches no real bus')
	eprintln('  --assign N  point --channel at the hardware on row N of --probe, then listen')
	eprintln('  --release N clear application channel N — undo an assignment this tool made')
	eprintln('  --pair A,B  TWO channels wired together: send on A, receive on B.')
	eprintln('              TRANSMITS — both ends must acknowledge, so neither can be silent.')
	eprintln('  --channel   application channel, as numbered in that dialog (from 1)')
	eprintln('  --bitrate   bits/s (default 500000)')
	eprintln('  --seconds   how long to listen (default 5)')
	eprintln('  --transmit  ALSO go on the bus able to acknowledge, and send one frame.')
	eprintln('              Leave it off against a live target until the bitrate is confirmed.')
}

fn parse(args []string) !Opts {
	mut o := Opts{
		bitrate: 500000
		seconds: 5
	}
	mut i := 0
	for i < args.len {
		match args[i] {
			'--list' {
				o = Opts{
					...o
					list: true
				}
			}
			'--probe' {
				o = Opts{
					...o
					probe: true
				}
			}
			'--pair' {
				i++
				o = Opts{
					...o
					pair: args[i] or { return error('--pair needs two --probe rows, e.g. 0,2') }
				}
			}
			'--release' {
				i++
				o = Opts{
					...o
					release: whole_int(args[i] or { return error('--release needs a channel') },
						'--release')!
				}
			}
			'--assign' {
				i++
				o = Opts{
					...o
					assign: whole_int(args[i] or {
						return error('--assign needs a --probe row index')
					}, '--assign')!
				}
			}
			'--selftest' {
				o = Opts{
					...o
					selftest: true
				}
			}
			'--transmit' {
				o = Opts{
					...o
					transmit: true
				}
			}
			'--channel' {
				i++
				o = Opts{
					...o
					channel: whole_int(args[i] or { return error('--channel needs a value') },
						'--channel')!
				}
			}
			'--bitrate' {
				i++
				o = Opts{
					...o
					bitrate: whole_int(args[i] or { return error('--bitrate needs a value') },
						'--bitrate')!
				}
			}
			'--seconds' {
				i++
				o = Opts{
					...o
					seconds: whole_int(args[i] or { return error('--seconds needs a value') },
						'--seconds')!
				}
			}
			else {
				return error('unknown argument "${args[i]}"')
			}
		}

		i++
	}
	return o
}

fn main() {
	// Said HERE rather than by rejecting `vector:` in open_linux.v: on Linux the dispatcher
	// deliberately sends anything that is not a software bus to SocketCAN, so a channel someone
	// named with a vendor prefix keeps working. That contract is worth more than a tidy error,
	// but the operator running this on the wrong machine still deserves a straight answer.
	$if !windows {
		eprintln('vectorcheck: the Vector XL backend is Windows-only (vxlapi64.dll).')
		eprintln('Run this from Windows, not WSL — WSL has no access to the Vector driver.')
		eprintln('')
	}
	o := parse(os.args[1..]) or {
		eprintln('vectorcheck: ${err}')
		usage()
		exit(2)
	}
	if o.probe {
		chans := transport.vector_channels()
		if chans.len == 0 {
			eprintln('the driver reports no channels (is the XL Driver Library installed?)')
			exit(1)
		}
		println('idx  name                              transceiver                   serial     bus     rate')
		for i, c in chans {
			bus := match c.bus_type {
				0 { '-' }
				1 { 'CAN' }
				else { '0x${c.bus_type:X}' }
			}

			rate := if c.bitrate > 0 { '${c.bitrate}' } else { '-' }
			println('${i:3}  ${c.name:-32}  ${c.transceiver:-28}  ${c.serial:-9}  ${bus:-6}  ${rate}')
		}
		return
	}
	// BEFORE anything is borrowed, not after: the window between taking a channel and installing
	// a handler is exactly when an impatient operator hits Ctrl-C.
	borrow_init()
	os.signal_opt(.int, on_interrupt) or {
		eprintln('note: could not install an interrupt handler; Ctrl-C may leave channels assigned')
	}
	if o.release >= 0 {
		// BEFORE it reaches XL. vector_unassign converts `n - 1` to u32, so --release 0 became
		// 0xFFFFFFFF and went straight into a persistent xlSetApplConfig; anything above 64 is
		// equally not a channel this program can address.
		if o.release < 1 || o.release > 64 {
			eprintln('vectorcheck: --release must be 1..64 (Vector application channels)')
			exit(2)
		}
		// The counterpart to --assign, and the way out of a diagnostic that was killed before it
		// could hand a channel back. Clearing is its own operation because an assignment is
		// persistent: nothing else in this tool can put a channel back to having no hardware.
		transport.vector_unassign(o.release) or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		println('application channel ${o.release} cleared')
		return
	}
	if o.pair != '' {
		pair_test(o) or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		return
	}
	if o.selftest {
		selftest() or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		return
	}
	if o.list {
		ifaces := transport.list_interfaces() or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		if lib := nonempty(transport.vector_driver_path()) {
			println('vxlapi: ${lib}')
		}
		mut n := 0
		for f in ifaces {
			if f.iface.starts_with('vector:') {
				println('${f.iface}\t${f.name}')
				n++
			}
		}
		if n == 0 {
			// ASKED, not guessed. These two look identical from outside — nothing listed — and
			// they send you to completely different places, so the tool finds out which it is
			// instead of printing both possibilities and letting you choose.
			match transport.vector_driver_status() {
				0 {
					eprintln('The Vector driver is installed and working, but no application channel')
					eprintln('is assigned to hardware yet.')
					eprintln('')
					eprintln('Open Vector Hardware Manager and assign a VN1630A channel to the')
					eprintln('application "blobly_net".')
					eprintln('')
					eprintln('If blobly_net is not listed there yet, run this once to register it:')
					eprintln('  vectorcheck --channel 1')
					eprintln('It will fail for the same reason, and the entry will then exist to assign.')
				}
				-1 {
					eprintln('vxlapi64.dll was not found.')
					eprintln('')
					eprintln('It is the Vector XL Driver Library, a SEPARATE download from the hardware')
					eprintln('drivers — the VN device, its kernel driver and Vector Hardware Manager can all')
					eprintln('be installed and working without it. Check Device Manager: if the VN adapter')
					eprintln('is listed and healthy, this library is the only thing missing.')
					eprintln('(On WSL this message is expected regardless: run the .exe from Windows.)')
				}
				-2 {
					eprintln('vxlapi64.dll loaded but is missing functions this backend needs.')
					eprintln('It is probably an old XL Driver Library; update the Vector Driver Setup.')
				}
				else {
					eprintln('vxlapi64.dll loaded, but xlOpenDriver failed (XL status ${-transport.vector_driver_status()}).')
					eprintln('Usually that means no Vector hardware is connected, or another')
					eprintln('application holds it exclusively.')
				}
			}

			exit(1)
		}
		return
	}
	// THE RANGE open() ACCEPTS, checked before anything is written. --assign persists an entry
	// in Vector Hardware Manager, so a channel number this tool would later refuse used to
	// leave a permanent record of a channel that can never be opened.
	if o.channel < 1 || o.channel > 64 {
		eprintln('vectorcheck: --channel must be 1..64 (Vector application channels)')
		exit(2)
	}
	if o.assign >= 0 {
		chans := transport.vector_channels()
		if o.assign >= chans.len {
			eprintln('vectorcheck: no --probe row ${o.assign}')
			exit(1)
		}
		c := chans[o.assign]
		// REFUSED for a channel that is not CAN. The VN1630A's fifth channel is D/A IO, and
		// pointing a CAN application at it would fail somewhere less obvious than here.
		if !c.transceiver.to_lower().contains('can') {
			eprintln('vectorcheck: row ${o.assign} is "${c.name}" (${c.transceiver}) — not a CAN channel')
			exit(1)
		}
		transport.vector_assign(o.channel, c) or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		println('application channel ${o.channel} -> ${c.name}  (${c.transceiver}, serial ${c.serial})')
	}
	mode := if o.transmit { '' } else { ',silent' }
	spec := 'vector:${o.channel}@${o.bitrate}${mode}'
	println('opening ${spec}${if o.transmit {
		'  [CAN ACKNOWLEDGE]'
	} else {
		'  [silent: cannot disturb the bus]'
	}}')
	mut bus := transport.open(spec) or {
		eprintln('vectorcheck: ${err}')
		exit(1)
	}
	defer { bus.close() }

	if o.transmit {
		// FAILS THE COMMAND. Printing and carrying on meant unrelated traffic could make the
		// run exit successfully while the transmit the flag asked for never happened — a
		// usable-looking setup report for a channel that cannot send.
		bus.send(transport.CanFrame{ id: 0x7FF, data: [u8(0xDE), 0xAD] }) or {
			eprintln('vectorcheck: transmit failed: ${err}')
			exit(1)
		}
	}

	println('listening ${o.seconds}s…')
	deadline := time.now().add(o.seconds * time.second)
	mut seen := 0
	mut ids := map[u32]int{}
	for time.now() < deadline {
		// A TIMEOUT IS NOT A FAULT, but everything else is. Treating every error as an empty
		// poll meant an adapter unplugged mid-run was diagnosed as an idle bus or a wrong
		// bitrate — and if any frame had arrived first, the command exited successfully.
		f := bus.recv(200) or {
			if err.msg().contains('timeout') {
				continue
			}
			eprintln('vectorcheck: receive failed after ${seen} frames: ${err}')
			exit(1)
		}
		seen++
		ids[f.id]++
		if seen <= 10 {
			println('  ${f.id:08X}  [${f.data.len}]  ${f.data.hex()}')
		}
	}
	println('')
	println('${seen} frames on ${ids.len} distinct id(s) in ${o.seconds}s')
	if seen == 0 {
		// The two explanations look identical from here, and only one of them is a fault.
		eprintln('nothing arrived. Either the bus is idle, or the bitrate is not ${o.bitrate}.')
		eprintln('A silent channel with the wrong bitrate reports exactly this and disturbs nothing,')
		eprintln('so trying the other likely rates is safe.')
		exit(1)
	}
}

// selftest proves the whole path — assign, open, set the bitrate, go on the bus, transmit,
// receive — on Vector's SOFTWARE VIRTUAL channels, which exist once the driver is installed and
// are wired to nothing. That is the point: the first end-to-end run of a backend written from a
// header should not be against a bus with somebody's ECU on it, and the same trick is what makes
// the Kvaser backend verifiable without an adapter.
//
// It writes only our own application's channel assignments (`blobly_net`), never another
// application's, and never the physical adapter's.
fn selftest() ! {
	mut virt := []transport.VectorChannel{}
	for c in transport.vector_channels() {
		if c.hw_type == 1 { // XL_HWTYPE_VIRTUAL
			virt << c
		}
	}
	if virt.len < 2 {
		return error('need two Vector virtual channels; the driver reports ${virt.len}. They come with the XL Driver Library — check Vector Hardware Manager has a "Virtual Bus" device.')
	}
	// The last two application channels, so an operator's own channel 1 and 2 assignments are
	// left alone by a self-test they may run on a configured bench.
	a_ch, b_ch := 63, 64
	mut borrowed := []Borrowed{}
	defer {
		give_back(borrowed)
	}
	borrowed << borrow(a_ch, virt[0])!
	borrowed << borrow(b_ch, virt[1])!
	println('assigned app channel ${a_ch} -> virtual ${virt[0].hw_channel}, ${b_ch} -> virtual ${virt[1].hw_channel}')

	mut tx := transport.open('vector:${a_ch}@500000')!
	defer { tx.close() }
	mut rx := transport.open('vector:${b_ch}@500000')!
	defer { rx.close() }
	println('both ports open and on the bus')

	sent := transport.CanFrame{
		id:   0x1A5
		data: [u8(0xDE), 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
	}
	tx.send(sent)!
	println('sent  0x${sent.id:03X}  ${sent.data.hex()}')

	for _ in 0 .. 20 {
		got, ok := poll(mut rx, 200)!
		if !ok {
			continue
		}
		if got.id != sent.id {
			continue
		}
		// THE FORMAT, as the pair test checks it. The id has already had its extended flag
		// stripped by the time it reaches here, so comparing id and payload alone would pass a
		// standard frame that came back marked extended or remote — a receive path
		// misclassifying frames is exactly what a self-test is for.
		if got.extended || got.rtr || got.fd {
			return error('the frame came back as ${if got.extended {
				'extended'
			} else if got.rtr {
				'remote'
			} else {
				'FD'
			}}, but a standard data frame was sent')
		}
		if got.data != sent.data {
			return error('payload differs: sent ${sent.data.hex()}, got ${got.data.hex()}')
		}
		println('recv  0x${got.id:03X}  ${got.data.hex()}')
		println('')
		println('SELFTEST PASSED — open, bitrate, activate, transmit and receive all work.')
		return
	}
	return error('nothing arrived on the second virtual channel within 4s')
}

// pair_test drives two channels of the same adapter that the operator has wired together.
//
// NEITHER END IS SILENT, and that is forced by CAN itself rather than chosen: a transmitter
// needs another node to acknowledge, so a listen-only receiver would leave every frame
// unacknowledged and retransmitting forever. This is the one mode of this tool that puts
// traffic on a real wire, which is why it is a separate flag and says so.
fn pair_test(o Opts) ! {
	parts := o.pair.split(',')
	if parts.len != 2 {
		return error('--pair takes two --probe rows, e.g. --pair 0,2')
	}
	a_row := whole_int(parts[0], '--pair')!
	b_row := whole_int(parts[1], '--pair')!
	chans := transport.vector_channels()
	// BOTH ENDS of the range. Checking only the upper one let `--pair -1,0` index backwards and
	// take the process down, which is a poor answer to a typo.
	if a_row < 0 || b_row < 0 || a_row >= chans.len || b_row >= chans.len {
		return error('no such --probe row (there are ${chans.len}, numbered from 0)')
	}
	if a_row == b_row {
		return error('--pair needs two different channels; a channel cannot acknowledge itself')
	}
	// The application channels used are high ones, so an operator's own 1 and 2 assignments
	// survive a test they may run on a configured bench.
	a_app, b_app := 61, 62
	mut borrowed := []Borrowed{}
	defer {
		give_back(borrowed)
	}
	borrowed << borrow(a_app, chans[a_row])!
	borrowed << borrow(b_app, chans[b_row])!
	println('TX  app ${a_app} -> ${chans[a_row].name}  (${chans[a_row].transceiver})')
	println('RX  app ${b_app} -> ${chans[b_row].name}  (${chans[b_row].transceiver})')
	println('bitrate ${o.bitrate}, both ends able to acknowledge — transmitting for ${o.seconds}s')

	mut tx := transport.open('vector:${a_app}@${o.bitrate}')!
	defer { tx.close() }
	mut rx := transport.open('vector:${b_app}@${o.bitrate}')!
	defer { rx.close() }

	// A COUNTER IN THE PAYLOAD, not one frame repeated. It makes every frame checkable rather
	// than just the first, so a link that drops or reorders is caught instead of being reported
	// as a pass because something with the right id came back.
	mut n_sent := 0
	mut n_busy := 0
	mut n_recv := 0
	mut n_bad := 0
	mut n_dup := 0
	// WHICH sequences arrived, not merely how many. A duplicate paired with a missing frame
	// nets out in a count: n_recv == n_sent, lost == 0, and the test passes over real loss.
	mut seen_seq := map[u32]bool{}
	mut last_seq := u32(0)
	mut sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < i64(o.seconds) * 1000 {
		// A BATCH between clock reads, and a NON-BLOCKING drain. Sending one frame per iteration
		// and then waiting a millisecond for a receive that had not arrived yet held this to
		// about seventy frames a second — a number that described this loop, not the bus.
		for _ in 0 .. 32 {
			seq := u32(n_sent)
			f := transport.CanFrame{
				id:   0x100 + u32(n_sent % 8) // eight ids, so a stuck mailbox shows up
				data: [u8(seq >> 24), u8(seq >> 16), u8(seq >> 8), u8(seq), 0xA5, 0x5A, 0xC3, 0x3C]
			}
			tx.send(f) or {
				// A FULL QUEUE IS THE WIRE, not a fault: at saturation the bus is the slowest
				// thing in the system and says so. Stop offering for now and go drain.
				if err.msg().starts_with(transport.vector_busy_msg) {
					n_busy++
					break
				}
				return error('send failed after ${n_sent} frames: ${err}')
			}
			n_sent++
		}
		for {
			// AN EMPTY QUEUE IS A TIMEOUT; anything else is the adapter in trouble. Treating
			// every error alike meant an RX port that disconnected mid-run was reported as
			// frame loss or a wiring fault, with the transmit side still cheerfully going.
			got, ok := poll(mut rx, 0)!
			if !ok {
				break
			}
			if !is_test_frame(got) {
				n_bad++
				continue
			}
			seq_got := (u32(got.data[0]) << 24) | (u32(got.data[1]) << 16) | (u32(got.data[2]) << 8) | u32(got.data[3])
			last_seq = seq_got
			if seq_got in seen_seq {
				n_dup++
			} else {
				seen_seq[seq_got] = true
			}
			n_recv++
		}
	}
	// LET THE WIRE FINISH. At saturation the transmit queue still holds a second or so of
	// frames when the clock stops, and counting them as lost would report a healthy link at
	// 97%. Drain until it goes quiet for a stretch rather than for a fixed number of tries.
	mut quiet := time.new_stopwatch()
	for quiet.elapsed().milliseconds() < 400 {
		got, ok := poll(mut rx, 5)!
		if !ok {
			continue
		}
		// THE SAME CHECK the main loop applies. Counting any eight-byte frame let unrelated
		// traffic on a live bus finish the test for us — PAIR TEST PASSED on somebody else's
		// frames, which is the one result this tool must never print.
		if !is_test_frame(got) {
			// COUNTED, as the main loop counts it. At saturation most frames arrive in this
			// drain, so a corrupted one landing here was silently skipped and the run reported
			// zero malformed — the tail is where the evidence mostly is.
			n_bad++
			continue
		}
		n_recv++
		seq_tail := (u32(got.data[0]) << 24) | (u32(got.data[1]) << 16) | (u32(got.data[2]) << 8) | u32(got.data[3])
		last_seq = seq_tail
		if seq_tail in seen_seq {
			n_dup++
		} else {
			seen_seq[seq_tail] = true
		}
		quiet = time.new_stopwatch()
	}
	println('')
	rate := if o.seconds > 0 { n_sent / o.seconds } else { 0 }
	println('sent ${n_sent} (${rate}/s), received ${n_recv} (${seen_seq.len} distinct), duplicates ${n_dup}, malformed ${n_bad}, last sequence ${last_seq}')
	if n_busy > 0 {
		println('${n_busy} times the transmit queue was full — the wire setting the pace, which is what saturation looks like')
	}
	if n_recv == 0 {
		// fall through to the diagnosis below
	} else {
		// THE SET, not its size. Marker-valid frames carrying sequence numbers we never sent —
		// left over from a previous run, or from a second diagnostic on the same wire — could
		// otherwise make up the count for frames of ours that never arrived, and the totals
		// would agree while the contents did not.
		mut missing := []u32{}
		mut foreign := 0
		for q in 0 .. u32(n_sent) {
			if q !in seen_seq {
				missing << q
			}
		}
		for q, _ in seen_seq {
			if q >= u32(n_sent) {
				foreign++
			}
		}
		if foreign > 0 {
			return error('${foreign} frames arrived carrying sequence numbers this run never sent — something else is transmitting on this wire')
		}
		lost := missing.len
		pct := 100.0 * f64(seen_seq.len) / f64(n_sent)
		println('${pct:.1f}% arrived (${lost} not seen)')
		if n_bad > 0 {
			return error('${n_bad} frames arrived corrupted — the link carries traffic but not intact')
		}
		// EVERY frame, not merely one. Passing on "something arrived" would certify a link that
		// dropped all but a handful, and the drain above already waits for the wire to go quiet,
		// so anything still missing is genuinely missing.
		if n_dup > 0 {
			return error('${n_dup} frames arrived more than once — a link that repeats itself is not carrying the recording faithfully')
		}
		if lost != 0 {
			return error('${lost} of ${n_sent} frames never arrived (${pct:.1f}%) — the link carries traffic but loses it')
		}
		println('')
		println('PAIR TEST PASSED on real transceivers and a real wire.')
		return
	}
	// ASK THE CONTROLLER before blaming the wire. A queued frame that never reached the bus and
	// one that reached it unacknowledged look the same from here, and they are different faults.
	errs := transport.vector_error_frames()
	if st := transport.chip_state_of(tx) {
		health := match true {
			st.bus_status & 0x01 != 0 { 'BUS OFF' }
			st.bus_status & 0x02 != 0 { 'error passive' }
			st.bus_status & 0x04 != 0 { 'error warning' }
			else { 'error active (healthy)' }
		}

		println('TX controller: ${health}, tx errors ${st.tx_errors}, rx errors ${st.rx_errors}')
		if st.tx_errors > 0 || st.bus_status & 0x07 != 0 {
			return error('the frame WAS driven onto the wire and nobody acknowledged it (tx error counter ${st.tx_errors}). The two channels are not electrically connected, or the bus is not terminated — a high-speed VN channel needs 120 ohm at each end and has none built in.')
		}
		return error('the controller is healthy and its transmit error counter is ${st.tx_errors}, so the frame never left the chip. That points at the port setup rather than the wiring.')
	}
	if errs > 0 {
		return error('no frame arrived, but ${errs} error frames did — something is on the wire and ${o.bitrate} is not its bitrate')
	}
	return error('nothing arrived, no error frames, and the controller would not report its state')
}
