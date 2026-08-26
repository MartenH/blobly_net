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
	list       bool
	probe      bool
	selftest   bool
	assign     int = -1
	assign_set bool // WHETHER --assign was given: -1 is the sentinel, and a user can type -1
	release    int = -1
	pair       string
	channel    int
	bitrate    int
	seconds    int
	transmit   bool
	modecheck  bool
	fd         bool
	dbitrate   int
	length     int
	// WHETHER THE OPTION WAS GIVEN, for both of the numeric ones whose zero is typeable. This is
	// the same mistake in two places and it has now been made twice: a value of 0 read as "not
	// supplied", so an explicit request was silently replaced by a default and the run reported a
	// pass for an experiment nobody asked for (codex #181 r2 for --length, r3 for --dbitrate).
	length_set   bool
	dbitrate_set bool
}

// FdOpts is what the FD flags actually MEAN, resolved once.
//
// ONE RESOLVER, because the ad-hoc version was wrong twice in one round — both times because a
// second copy of the arithmetic drifted from the first. `--pair` computed an effective data rate
// and `--channel` computed its own; the `--channel` one then decided BRS from whether --dbitrate
// was EXPLICIT rather than from the rate it had just opened with, so the documented
// `--channel N --fd --transmit` opened at 2 Mbit/s and sent without the bit-rate switch — an FD
// frame carrying its payload at the arbitration rate, reported as a pass. Codex #181 r2.
//
// The rule that makes both call sites correct is that the EFFECTIVE data rate decides BRS, not
// the provenance of the number.
struct FdOpts {
	fd    bool
	dbr   int    // the data phase actually opened with; 0 when classic
	brs   bool   // is there a faster phase to switch into
	rate  string // the `@…` body of the address, both phases where there are two
	len   int    // payload bytes
	given bool   // --length was supplied, as opposed to defaulted
}

// resolve_fd answers the three questions every FD-capable mode asks, in one place.
fn resolve_fd(o Opts) !FdOpts {
	// AN EXPLICIT RATE MUST BE A RATE. `--dbitrate 0` and `--dbitrate -1` parse (whole_int allows a
	// sign) and then read as "not supplied": `--pair --dbitrate 0` quietly ran a CLASSIC experiment
	// and `--fd --dbitrate 0` substituted the 2 Mbit/s default, either way reporting a pass at a
	// rate the operator never asked for — and contradicting the help, which says --dbitrate implies
	// --fd. Refused on provenance, not on value (codex #181 r3).
	if o.dbitrate_set && o.dbitrate <= 0 {
		return error('--dbitrate ${o.dbitrate} is not a rate — give the data phase in bits per second, e.g. --dbitrate 2000000')
	}
	// EITHER FLAG ASKS FOR FD. `--dbitrate` alone says what the data phase should be, and would
	// otherwise be accepted and silently ignored.
	fd := o.fd || o.dbitrate_set
	dbr := if !fd {
		0
	} else if o.dbitrate_set {
		o.dbitrate
	} else {
		2000000
	}
	// 64 bytes is the point of FD, so that is what its default proves; 8 remains the classic one.
	mut ln := if o.length_set {
		o.length
	} else if fd {
		64
	} else {
		8
	}
	// EXPLICIT ZERO IS NOT ABSENT. `--length 0` is a legal DLC size and usage() advertises it, so
	// silently substituting the default reported a passing experiment for one that was never run.
	// It is refused below by the same floor as 1, 2 and 3 — but it has to REACH that floor, which
	// it could not while zero meant "unset" (codex #181 r2).
	if ln !in transport.fd_lengths {
		return error('--length ${ln} is not a payload size a DLC can express — use one of ${transport.fd_lengths}')
	}
	// EIGHT IS THIS TEST'S FLOOR, and it is a property of the FORMAT rather than of CAN: every
	// frame carries a 4-byte sequence number so that loss, duplication and reordering are
	// detectable per frame, and 4 marker bytes so a foreign frame of the right length cannot
	// finish the run for us. 0..3 are legal DLC sizes this test cannot express itself in.
	if ln < 8 {
		return error('--length ${ln} is too short for this test: every frame carries a 4-byte sequence number and 4 marker bytes, so the smallest checkable payload is 8')
	}
	if !fd && ln > 8 {
		return error('--length ${ln} needs --fd: a classic CAN frame carries at most 8 bytes')
	}
	return FdOpts{
		fd:    fd
		dbr:   dbr
		// FROM THE EFFECTIVE RATE, which is the whole reason this struct exists. With an equal
		// data rate there is no faster phase to switch into and the library refuses the flag.
		brs:   fd && dbr != o.bitrate
		rate:  if fd { '${o.bitrate}/${dbr}' } else { '${o.bitrate}' }
		len:   ln
		given: o.length_set
	}
}

// nonempty is `?string` sugar so an unloaded library prints nothing rather than a blank label.
fn nonempty(s string) ?string {
	return if s == '' { none } else { s }
}

// whole_int refuses a token that is only PARTLY a number. V's `.int()` takes a numeric prefix
// and maps anything else to zero, so `--assign 1x` silently selected row 1 and `--assign oops`
// selected row 0 — and --assign permanently rewrites an application-channel assignment.
//
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
	g_restoring     int // restorations in flight; the handler must not exit through one
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
	// WAIT OUT ANYONE ELSE'S RESTORE. The ordinary deferred cleanup may be partway through
	// writing assignments back — it claims the entries first, so the snapshot above saw an empty
	// list and this handler had nothing to do — and exiting over it leaves exactly the
	// half-restored bench the handler exists to prevent. Bounded, because a stuck restore must
	// not make Ctrl-C useless.
	for _ in 0 .. 300 {
		borrow_lock()
		busy := g_restoring > 0
		borrow_unlock()
		if !busy {
			break
		}
		time.sleep(10 * time.millisecond)
	}
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
	// COUNTED WHILE IT HAPPENS. Claiming removes the entries from the shared list, so between
	// the claim and the writes an interrupt sees an empty list, concludes there is nothing to do,
	// and exits THROUGH a restoration that is halfway done — the one moment when stopping is
	// worse than either finishing or never having started.
	g_restoring++
	borrow_unlock()
	defer {
		borrow_lock()
		g_restoring--
		borrow_unlock()
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

// test_payload builds the payload for sequence `seq` at `len` bytes: the sequence number, the
// four markers, and then every remaining byte derived from the sequence so that NO byte of a
// 64-byte FD frame is unchecked. A tail of constant filler would let corruption in the data
// phase — which is exactly what an under-terminated FD bus produces — pass as a good frame,
// and the data phase is the part FD adds.
fn test_payload(seq u32, len int) []u8 {
	// GUARDED HERE TOO, not only at the flag. The caller validates `--length`, and that validation
	// is one edit away from being the only thing between a short payload and four unconditional
	// writes into it — which panicked with both ports already open on the bus, skipping the
	// deferred restore of the borrowed channels. A helper that indexes fixed offsets should refuse
	// a buffer that cannot hold them rather than trust its caller (codex #181 r1).
	if len < 8 {
		return []u8{len: if len < 0 { 0 } else { len }}
	}
	mut d := []u8{len: len}
	d[0] = u8(seq >> 24)
	d[1] = u8(seq >> 16)
	d[2] = u8(seq >> 8)
	d[3] = u8(seq)
	if len > 4 {
		markers := [u8(0xA5), 0x5A, 0xC3, 0x3C]
		for i in 4 .. len {
			d[i] = if i < 8 { markers[i - 4] } else { u8(seq) ^ u8(i) }
		}
	}
	return d
}

// is_test_frame recognises a frame this tool sent, in the format it was asked to send.
//
// THE FORMAT IS PART OF THE ASSERTION, which is why the expected shape is passed in rather than
// assumed: a link that carries our 64-byte FD frame back as a classic 8-byte one has not carried
// it, and a run that accepted either would report a working FD wire on a bus that quietly fell
// back. `want_fd` and `want_len` are what the transmit side was configured for.
fn is_test_frame(f transport.CanFrame, want_fd bool, want_brs bool, want_len int) bool {
	// ALL FOUR marker bytes. Checking two of them let a payload corrupted in byte 5 or 6 pass as
	// a good frame, which is the one thing a link test must not do: the markers are there to
	// notice corruption, and half of them notice half of it.
	// THE FORMAT TOO, not only the bytes. A remote or extended frame carrying the same id and
	// payload is a different message on the wire, and accepting it would report a link that
	// faithfully carries something we never sent.
	if f.extended || f.rtr || f.fd != want_fd {
		return false
	}
	// THE BIT-RATE SWITCH IS PART OF THE EXPERIMENT, so it is part of what a frame has to match.
	// Checking only `fd` meant a backend that dropped BRS and carried the whole payload at the
	// ARBITRATION rate returned frames this accepted, every one of them counted, and the run
	// printed PAIR TEST PASSED — proving 64-byte frames and nothing whatever about the data phase
	// the operator asked for. Nothing else here would have caught it: the throughput is printed
	// but never compared against a threshold (codex #181 r6).
	if f.brs != want_brs {
		return false
	}
	if f.data.len != want_len {
		return false
	}
	// The same floor as test_payload's, and reached the same way: this reads four sequence bytes
	// unconditionally, so a frame shorter than the header it is about to parse is not ours by
	// definition rather than a panic.
	if f.data.len < 8 {
		return false
	}
	// EVERY BYTE against what was built for this sequence number. The alternative — checking the
	// markers and trusting the rest — leaves 56 of a 64-byte FD payload unexamined.
	seq := (u32(f.data[0]) << 24) | (u32(f.data[1]) << 16) | (u32(f.data[2]) << 8) | u32(f.data[3])
	if f.data != test_payload(seq, want_len) {
		return false
	}
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
	eprintln('  --modecheck prove that an OPEN PORT pins its channel and that the app knows it')
	eprintln('              (issue #165). Listen-only, and safe against a live bus. Add')
	eprintln('              --transmit for the normal-mode probe, which is only silent while')
	eprintln('              the driver refuses it — the thing being tested.')
	eprintln('  --assign N  point --channel at the hardware on row N of --probe, then listen')
	eprintln('  --release N clear application channel N — undo an assignment this tool made')
	eprintln('  --pair A,B  TWO channels wired together: send on A, receive on B.')
	eprintln('              TRANSMITS — both ends must acknowledge, so neither can be silent.')
	eprintln('  --channel   application channel, as numbered in that dialog (from 1)')
	eprintln('  --bitrate   bits/s (default 500000)')
	eprintln('  --seconds   how long to listen (default 5)')
	eprintln('  --transmit  ALSO go on the bus able to acknowledge, and send one frame.')
	eprintln('              Leave it off against a live target until the bitrate is confirmed.')
	eprintln('  --fd        CAN-FD: open both ends with a data phase and send FD frames.')
	eprintln('              Applies to --pair and --channel.')
	eprintln('  --dbitrate  CAN-FD data-phase bits/s (default 2000000). Implies --fd.')
	eprintln('  --length    payload bytes for --pair (default 8, or 64 with --fd). One of')
	eprintln('              8, 12, 16, 20, 24, 32, 48, 64 — the DLC sizes from 8 up. Shorter')
	eprintln('              frames are legal CAN but not checkable here: each carries a 4-byte')
	eprintln('              sequence number and 4 marker bytes.')
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
					assign:     whole_int(args[i] or {
						return error('--assign needs a --probe row index')
					}, '--assign')!
					assign_set: true
				}
			}
			'--selftest' {
				o = Opts{
					...o
					selftest: true
				}
			}
			'--modecheck' {
				o = Opts{
					...o
					modecheck: true
				}
			}
			'--transmit' {
				o = Opts{
					...o
					transmit: true
				}
			}
			'--fd' {
				o = Opts{
					...o
					fd: true
				}
			}
			'--dbitrate' {
				i++
				o = Opts{
					...o
					dbitrate:     whole_int(args[i] or { return error('--dbitrate needs a value') },
						'--dbitrate')!
					dbitrate_set: true
				}
			}
			'--length' {
				i++
				o = Opts{
					...o
					length:     whole_int(args[i] or { return error('--length needs a value') },
						'--length')!
					length_set: true
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
		println('idx  name                              transceiver                   serial     bus     rate      can-fd')
		for i, c in chans {
			bus := match c.bus_type {
				0 { '-' }
				1 { 'CAN' }
				else { '0x${c.bus_type:X}' }
			}

			rate := if c.bitrate > 0 { '${c.bitrate}' } else { '-' }
			// FROM THE DRIVER, not from the transceiver's part number, which was the only route
			// before and is not one anybody should have to take (#187). Blank means this channel
			// cannot carry CAN-FD at all; `bosch-only` means it can, in a frame format this
			// backend does not speak.
			fd := if c.fd_note() == '' { '-' } else { c.fd_note() }
			println('${i:3}  ${c.name:-32}  ${c.transceiver:-28}  ${c.serial:-9}  ${bus:-6}  ${rate:-9} ${fd}')
		}
		println('')
		println('rate is what the channel is running at NOW — it reflects whatever application')
		println('holds initialisation access, and falls back to the configured default when none does.')
		println('can-fd: iso = the variant this backend configures · bosch-only = FD hardware it cannot drive.')
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
		// THE SAME LOCK a borrow takes. These write the assignment permanently, so running one
		// beside a --pair let the diagnostic keep an older snapshot and restore over it — the
		// direct command's change quietly undone by a process that had photographed the world
		// before it.
		transport.vector_borrow_lock() or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		defer {
			transport.vector_borrow_unlock()
		}
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
	if o.modecheck {
		modecheck(o) or {
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
		// THE HARDWARE EACH ONE REACHES, beside the channel, because two application channels
		// pointed at ONE physical channel is invisible from the names alone — they read as two
		// perfectly ordinary wires (#167). Printed as the assignment triple, which is what the
		// conflict check compares and what Vector Hardware Manager sets.
		mut seen := map[string]string{}
		mut aliased := []string{}
		for f in ifaces {
			if !f.iface.starts_with('vector:') {
				continue
			}
			hw := transport.physical_wire_key('vector', f.iface) or { '' }
			if hw == '' {
				println('${f.iface}\t${f.name}')
			} else {
				println('${f.iface}\t${f.name}\t${hw}')
				if prev := seen[hw] {
					aliased << '${prev} and ${f.iface} are both assigned to ${hw}'
				} else {
					seen[hw] = f.iface
				}
			}
			n++
		}
		for a in aliased {
			eprintln('')
			eprintln('WARNING: ${a}.')
			eprintln('One transceiver cannot be two wires: a project naming both will be refused')
			eprintln('at Start. Give them separate channels in Vector Hardware Manager.')
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
	// NEGATIVE IS NOT THE SENTINEL. -1 means "no --assign given", but whole_int accepts a leading
	// minus, so `--assign -1` looked like the absent option: the block below was skipped, the
	// channel opened on whatever mapping it already had, and with --transmit that drives hardware
	// the operator did not choose.
	if o.assign < -1 {
		eprintln('vectorcheck: --assign takes a --probe row, which is not negative')
		exit(2)
	}
	// A SEPARATE FLAG, because -1 is the sentinel and whole_int accepts a leading minus — so
	// `--assign -1` was indistinguishable from not passing the option at all. It skipped this
	// block, opened the channel on whatever mapping it already had, and with --transmit drove
	// hardware the operator had not chosen. A value and "was a value given" are two questions,
	// and one int cannot answer both.
	if o.assign_set && o.assign < 0 {
		eprintln('vectorcheck: --assign takes a --probe row, which is not negative')
		exit(2)
	}
	if o.assign_set {
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
		transport.vector_borrow_lock() or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		defer {
			transport.vector_borrow_unlock()
		}
		transport.vector_assign(o.channel, c) or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		println('application channel ${o.channel} -> ${c.name}  (${c.transceiver}, serial ${c.serial})')
	}
	mode := if o.transmit { '' } else { ',silent' }
	// FD HERE TOO, and not only in --pair: listening to an FD bus as classic CAN hears nothing
	// decodable and reports an idle wire, which is the wrong answer to give about a bus that is
	// busy. `--dbitrate` on its own means FD, as it does for --pair.
	fo := resolve_fd(o) or {
		eprintln('vectorcheck: ${err}')
		exit(1)
	}
	spec := 'vector:${o.channel}@${fo.rate}${mode}'
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
		// AS THE FLAG SAID IT WOULD. With `--fd` this opened a V4 port and then probed it with a
		// CLASSIC frame, so the command reported success having exercised none of the data phase
		// — while the help promised `--fd` sends FD frames and applies to `--channel`. A probe
		// that tests something other than what was asked for is a passing report about the wrong
		// experiment (codex #181 r1).
		//
		// THROUGH THE SHARED RESOLVER, so the probe exercises the phase the port was opened with.
		// Deciding BRS here from whether --dbitrate was EXPLICIT sent an FD frame at the
		// arbitration rate for the documented `--channel N --fd --transmit` (codex #181 r2).
		//
		// 12 bytes with FD so the frame is one a classic controller could not have produced —
		// eight would go out as an ordinary CAN frame with EDL set and prove less.
		payload := if fo.fd {
			[]u8{len: 12, init: u8(0xDE + index)}
		} else {
			[u8(0xDE), 0xAD]
		}
		bus.send(transport.CanFrame{
			id:   0x7FF
			fd:   fo.fd
			brs:  fo.brs
			data: payload
		}) or {
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
// modecheck — what an OPEN PORT does to its channel, and whether the app knows before it tries.
// Issue #165.
//
// THE THING NO OTHER TEST CAN REACH. The XL driver fixes a channel's output mode and bitrate
// when the first port configures it, and will not reconfigure while any port on that channel is
// still open — so `transport.wire_pin_clash` predicts a refusal that only this driver can
// deliver. modules/transport/pinned_test.v checks the bookkeeping over `inproc:` buses because
// that is all a Linux machine has; what it cannot check is that the prediction is TRUE. That is
// this, and it wants silicon.
//
// The sequence is the bug's, with the disabled row's stale tap standing in for itself: a port is
// open, every row that opened it is gone as far as the model is concerned, and something asks
// for the other mode.
//
// SILENT BY DEFAULT, and that is not a detail — this is meant to be run against the live bus the
// adapter is already wired to. The port it holds open is listen-only, so the transceiver never
// acknowledges.
//
// WHICH IS WHY THE NORMAL-MODE PROBE NEEDS --transmit. Asking the driver to open a normal port
// is the sharpest check here, and its safety was resting on the very refusal it exists to prove:
// if the driver ever allowed it — a regression, a different XL version, a channel whose
// initialisation access had been released — the port would activate, and a normal port on a live
// bus acknowledges, or at the wrong bitrate floods error frames, for as long as it takes to
// close. A test that is safe only while it passes is not safe (codex #166 r1). So it is gated on
// the flag this tool already uses for "ALSO go on the bus able to acknowledge", and skipping it
// is SAID rather than silently left out. Everything else — the predictions, the second-bitrate
// refusal, the sibling open, the release — is listen-only and always runs.
fn modecheck(o Opts) ! {
	ch := if o.channel > 0 { o.channel } else { 1 }
	silent := 'vector:${ch}@${o.bitrate},silent'
	normal := 'vector:${ch}@${o.bitrate}'
	// A RATE THE PARSER ACCEPTS. Half the given one falls outside parse_vector_spec's
	// 5000..1000000 range below --bitrate 10000, and an address that will not parse makes
	// wire_pin_clash answer '' — which this test would then report as a failure that never
	// happened, with the driver probe beside it passing vacuously on the same unopenable string.
	alt_rate := if o.bitrate == 250000 { 500000 } else { 250000 }
	other_rate := 'vector:${ch}@${alt_rate},silent'
	// THE PROTOCOL IS PINNED TOO, and it is the strictest of the three: the mode and the rate are
	// settings on a channel, while the interface version a port was opened with decides how the
	// bytes on its receive queue are laid out. A sibling that guessed wrong does not disagree
	// about a setting, it decodes every frame through the wrong struct — so this asks the driver
	// the same question the other two ask, on the one bench that can answer it.
	as_fd := 'vector:${ch}@${o.bitrate}/2000000,silent'
	other_dbr := 'vector:${ch}@${o.bitrate}/4000000,silent'
	println('modecheck: application channel ${ch} at ${o.bitrate}, listen-only')

	pre := transport.wire_pin_clash(normal)
	if pre != '' {
		return error('channel ${ch} is pinned before this test opened anything: ${pre}')
	}

	mut held := transport.open(silent) or { return error('could not open ${silent}: ${err}') }
	println('  held  ${silent}')

	mut failures := []string{}
	// 1. The app's answer, which is the one the Buses panel acts on.
	mode_clash := transport.wire_pin_clash(normal)
	rate_clash := transport.wire_pin_clash(other_rate)
	agrees := transport.wire_pin_clash(silent)
	fd_clash := transport.wire_pin_clash(as_fd)
	println('  predicted, normal open : ${said(mode_clash)}')
	println('  predicted, other rate  : ${said(rate_clash)}')
	println('  predicted, as CAN-FD   : ${said(fd_clash)}')
	println('  predicted, same again  : ${said(agrees)}')
	if mode_clash == '' {
		failures << 'a normal open was predicted to be fine while a silent port held the channel'
	}
	if rate_clash == '' {
		failures << 'a different bitrate was predicted to be fine while a port held the channel'
	}
	if fd_clash == '' {
		failures << 'a CAN-FD open was predicted to be fine while a classic port held the channel'
	}
	if agrees != '' {
		failures << 'an open matching the held port was predicted to clash: ${agrees}'
	}

	// 2. What the DRIVER actually does with the same three requests. This is the half that
	//    cannot be faked, and the reason the numbers above are worth anything.
	if o.transmit {
		if mut b := transport.open(normal) {
			b.close()
			failures << 'the driver ALLOWED a normal open on a channel held silent — the mode is not pinned the way #165 describes, and this guard is solving a problem that is not there'
		} else {
			println('  driver refused normal  : ${err}')
		}
	} else {
		println('  driver refused normal  : NOT CHECKED — needs --transmit, because a driver that')
		println('                           allowed it would put an acknowledging port on the bus')
	}
	if mut b := transport.open(other_rate) {
		b.close()
		failures << 'the driver ALLOWED a second bitrate on a channel already configured'
	} else {
		println('  driver refused rate    : ${err}')
	}
	// SILENT EITHER WAY, so this one needs no --transmit: both addresses ask for listen-only, and
	// the only thing being changed is the protocol. If the driver ever allowed it, the port that
	// got through would still be unable to acknowledge.
	if mut b := transport.open(as_fd) {
		b.close()
		failures << 'the driver ALLOWED a CAN-FD port on a channel configured for classic CAN — the protocol is not pinned, and a sibling would be decoding the wrong event layout'
	} else {
		println('  driver refused CAN-FD  : ${err}')
	}
	// A second port asking for what the channel already IS must still work: this is every
	// ordinary run, where a monitor and its transmit taps all open the same wire.
	mut sibling := transport.open(silent) or {
		failures << 'a second port matching the held configuration was refused: ${err}'
		held.close()
		return report_modecheck(failures)
	}
	println('  driver allowed sibling : ${silent}')

	// 3. RELEASE. The prediction has to go away when the ports do, or the panel refuses forever.
	sibling.close()
	if transport.wire_pin_clash(normal) == '' {
		failures << 'the channel read as free while one port was still open on it'
	}
	held.close()
	left := transport.wire_pin_clash(normal)
	if left != '' {
		failures << 'every port closed and the channel still read as pinned: ${left}'
	} else {
		println('  released, channel free')
	}

	// 4. THE OTHER HALF OF THE FD PIN. Above, a classic-held channel refused an FD port; this is
	//    the case where both sides agree the wire is FD and disagree about its DATA phase (-1012).
	//    It needs its own held port, because the question only exists once something FD is open.
	//    Both addresses are silent, so this stays safe against a live bus.
	mut fd_held := transport.open(as_fd) or {
		// NOT A FAILURE. A library without the FD entry points refuses this by design, and so does
		// a channel whose transceiver cannot do FD — neither says anything about the pin.
		println('  CAN-FD not available on this channel, data-phase pin NOT CHECKED: ${err}')
		return report_modecheck(failures)
	}
	println('  held  ${as_fd}')
	dbr_clash := transport.wire_pin_clash(other_dbr)
	println('  predicted, other dphase: ${said(dbr_clash)}')
	if dbr_clash == '' {
		failures << 'a second CAN-FD data bitrate was predicted to be fine while an FD port held the channel'
	}
	if transport.wire_pin_clash(as_fd) != '' {
		failures << 'an FD open matching the held FD port was predicted to clash'
	}
	if mut b := transport.open(other_dbr) {
		b.close()
		failures << 'the driver ALLOWED a second CAN-FD data bitrate on a channel already configured'
	} else {
		println('  driver refused dphase  : ${err}')
	}
	// And a classic port on an FD-held channel — the refusal above, the other way round.
	if mut b := transport.open(silent) {
		b.close()
		failures << 'the driver ALLOWED a classic port on a channel configured for CAN-FD'
	} else {
		println('  driver refused classic : ${err}')
	}
	fd_held.close()
	if fd_left := nonempty(transport.wire_pin_clash(as_fd)) {
		failures << 'every FD port closed and the channel still read as pinned: ${fd_left}'
	} else {
		println('  released, FD channel free')
	}
	return report_modecheck(failures)
}

// said prints an empty prediction as words, so a blank line cannot be mistaken for a missing one.
fn said(clash string) string {
	return if clash == '' { '(no clash)' } else { clash }
}

fn report_modecheck(failures []string) ! {
	if failures.len == 0 {
		println('modecheck: OK — the driver pins what wire_pin_clash predicts, and releases it')
		return
	}
	for f in failures {
		eprintln('  FAIL ${f}')
	}
	return error('${failures.len} modecheck failure(s)')
}

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
	// RESOLVED AND VALIDATED BEFORE ANYTHING IS BORROWED. A refusal that arrives after two
	// application-channel assignments have been rewritten is a refusal that has already changed
	// somebody's bench, and it relies on the deferred restore to undo what it never needed to do.
	fo := resolve_fd(o)!
	want_fd, dbr, want_len := fo.fd, fo.dbr, fo.len
	rate_part := fo.rate
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
	if want_fd {
		println('CAN-FD: arbitration ${o.bitrate}, data ${dbr}, ${want_len}-byte payloads')
		// SAID OUT LOUD, because it is the difference between a backend bug and a bench one. A
		// CAN bus wants 120 ohm at BOTH ends; one resistor is survivable at 500 kbit/s and is the
		// first thing to suspect when an FD data phase at 2 Mbit/s or more starts producing
		// malformed frames, since the reflections it leaves scale with the bit rate.
		println('   (FD is sensitive to termination — 120 ohm at BOTH ends of the wire)')
	}
	println('bitrate ${o.bitrate}, both ends able to acknowledge — transmitting for ${o.seconds}s')

	mut tx := transport.open('vector:${a_app}@${rate_part}')!
	defer { tx.close() }
	mut rx := transport.open('vector:${b_app}@${rate_part}')!
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
				fd:   want_fd
				// BRS WITH FD, always, when the two rates differ: without the bit-rate switch the
				// payload goes out at the arbitration rate and the data phase — the thing being
				// tested — is never exercised. A run that passed that way would prove 64-byte
				// frames and nothing about the fast half.
				brs:  fo.brs
				data: test_payload(seq, want_len)
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
			if !is_test_frame(got, want_fd, fo.brs, want_len) {
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
		if !is_test_frame(got, want_fd, fo.brs, want_len) {
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
		// SAY WHICH BUS IT WAS. This printed "on real transceivers and a real wire"
		// unconditionally, including for --pair over the driver's own virtual channels,
		// where there is neither — a verification tool asserting the one thing the operator
		// cannot check from the output. hw_type 1 is XL_HWTYPE_VIRTUAL, the same test
		// --selftest uses to find them.
		virtual_pair := chans[a_row].hw_type == 1 && chans[b_row].hw_type == 1
		if virtual_pair {
			println('PAIR TEST PASSED on the driver VIRTUAL bus — no transceiver, no wire.')
		} else {
			println('PAIR TEST PASSED on real transceivers and a real wire.')
		}
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
