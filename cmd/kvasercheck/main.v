// kvasercheck — bring up Kvaser channels and prove CAN-FD works on this bench, through the
// backend the app uses rather than beside it.
//
// WHY A LOOPBACK TOOL AND NOT A LISTENER. vectorcheck opens silent by default, because a VN
// channel is usually clipped to a running vehicle and the danger is disturbing it. The Kvaser
// question is a different one: FD is a capability of the adapter, the driver AND the wire, and
// nothing but a real frame going out one connector and arriving at another settles it. So this
// tool asks for two channels and a cable between them, and is explicit that it transmits.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/kvasercheck/main.v --list
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/kvasercheck/main.v --from 0 --to 1
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/kvasercheck/main.v --from 0 --to 1 --data 4000000
//
// `--from`/`--to` are canlib channel numbers as `--list` prints them, NOT the numbers silk-screened
// on the box: canlib counts from 0, the connectors from 1, so the cable between connectors 1 and 2
// is `--from 0 --to 1`. Getting that wrong is the single likeliest reason a good bench reports
// nothing, so --list prints both.
//
// `-enable-globals` is not optional: modules/transport/inproc.v uses `__global`.
//
// From WSL, cross-compile and run the result on Windows — canlib lives there:
//   v -os windows -enable-globals -path "@vlib|@vmodules|modules" -o kvasercheck.exe cmd/kvasercheck/main.v
module main

import os
import time
import transport

struct Opts {
mut:
	list    bool
	from    int = -1
	to      int = -1
	arb     int = 500000
	data    int // 0 = classic only
	ladder  bool
	rtr     bool
	timeout int = 300
}

fn usage() {
	println('kvasercheck — prove CAN-FD on a Kvaser bench')
	println('  --list                 canlib channels, with the connector number each one is')
	println('  --from N --to M        loop a frame from channel N to channel M (canlib numbering)')
	println('  --arb HZ               arbitration rate (default 500000)')
	println('  --data HZ              CAN-FD data rate; omit for classic only')
	println('  --ladder               classic, then FD at 500k/1M/2M/4M/8M — the full bench report')
	println('  --rtr                  remote frames: sent as remote, read back as remote')
	println('  --timeout MS           per-frame receive timeout (default 300)')
}

fn main() {
	mut o := Opts{}
	args := os.args[1..]
	for i := 0; i < args.len; i++ {
		match args[i] {
			'--list' {
				o.list = true
			}
			'--ladder' {
				o.ladder = true
			}
			'--rtr' {
				o.rtr = true
			}
			'--from' {
				i++
				o.from = arg_int(args, i, '--from')
			}
			'--to' {
				i++
				o.to = arg_int(args, i, '--to')
			}
			'--arb' {
				i++
				o.arb = arg_int(args, i, '--arb')
			}
			'--data' {
				i++
				o.data = arg_int(args, i, '--data')
			}
			'--timeout' {
				i++
				o.timeout = arg_int(args, i, '--timeout')
			}
			'--help', '-h' {
				usage()
				return
			}
			else {
				eprintln('unknown argument: ${args[i]}')
				usage()
				exit(2)
			}
		}
	}
	if o.list {
		list_channels()
		return
	}
	if o.from < 0 || o.to < 0 {
		usage()
		exit(2)
	}
	if o.timeout <= 0 {
		// A ZERO OR NEGATIVE BUDGET NEVER POLLS, so every case reported "nothing arrived" —
		// a bench tool announcing a hardware failure it created in its own argument handling.
		eprintln('--timeout must be positive (milliseconds); ${o.timeout} would report every case as a failure without ever reading')
		exit(2)
	}
	if o.from == o.to {
		eprintln('--from and --to must differ: one channel cannot receive what it transmits (the')
		eprintln('controller does not hand its own frames back). Use the two ends of your cable.')
		exit(2)
	}
	mut fails := 0
	// The modes COMPOSE rather than shadowing each other: `--rtr --ladder` was accepted and ran
	// only the remote-frame case, which is a bench tool quietly doing less than it was asked.
	if o.rtr {
		fails += run_rtr_case(o)
		if o.data != 0 {
			fails += run_fd_rtr_refusal(o)
		}
	}
	if o.ladder {
		fails += run_case(o, 0)
		for rate in [500000, 1000000, 2000000, 4000000, 8000000] {
			fails += run_case(o, rate)
		}
	} else if !o.rtr {
		fails += run_case(o, o.data)
	}
	if fails > 0 {
		eprintln('\n${fails} case(s) FAILED')
		exit(1)
	}
	println('\nall cases passed')
}

fn list_channels() {
	ifs := transport.list_interfaces() or {
		eprintln('cannot enumerate: ${err}')
		return
	}
	mut n := 0
	for f in ifs {
		if !f.iface.starts_with('kvaser:') {
			continue
		}
		ch := f.iface.all_after(':').int()
		// BOTH NUMBERS. canlib counts channels from 0 and the box is silk-screened from 1, and a
		// cable plugged into the connectors marked 1 and 2 is `--from 0 --to 1`. Printing only one
		// of them is how a working bench gets reported as broken.
		// WHICH ONES ARE VIRTUAL, because the number is machine-dependent: canlib numbers the
		// software channels alongside the physical ones, so they are 5 and 6 on a bench with a
		// 5-channel adapter and 0 and 1 on a machine with none. A doc cannot name them; this can.
		tag := if f.virtual { 'SOFTWARE virtual' } else { 'connector CH${ch + 1}' }
		println('  ${f.iface}   (${tag})   ${f.name}')
		n++
	}
	if n == 0 {
		println('  no Kvaser channels — are the drivers installed?')
	}
}

// run_case opens both ends and loops one frame per payload length. data_rate 0 = classic.
fn run_case(o Opts, data_rate int) int {
	label := if data_rate == 0 {
		'classic CAN, arbitration ${o.arb}'
	} else {
		'CAN-FD, arbitration ${o.arb}, data ${data_rate}'
	}
	println('\n== ${label} ==')
	suffix := if data_rate == 0 { '@${o.arb}' } else { '@${o.arb}/${data_rate}' }
	mut tx := transport.open('kvaser:${o.from}${suffix}') or {
		eprintln('  open kvaser:${o.from}${suffix}: ${err}')
		return 1
	}
	defer { tx.close() }
	mut rx := transport.open('kvaser:${o.to}${suffix}') or {
		eprintln('  open kvaser:${o.to}${suffix}: ${err}')
		return 1
	}
	defer { rx.close() }
	lens := if data_rate == 0 { [1, 8] } else { [8, 12, 16, 24, 32, 48, 64] }
	mut bad := 0
	for n in lens {
		mut payload := []u8{len: n}
		for i in 0 .. n {
			payload[i] = u8(0xA0 + i)
		}
		f := transport.CanFrame{
			id:   0x123
			fd:   data_rate != 0
			brs:  data_rate != 0
			data: payload
		}
		tx.send(f) or {
			println('  len ${n:2}: send failed — ${err}')
			bad++
			continue
		}
		got := recv_matching(mut rx, 0x123, o.timeout) or {
			println('  len ${n:2}: nothing arrived within ${o.timeout} ms')
			bad++
			continue
		}
		// EVERY FIELD, not just the length. A backend that dropped BRS, or handed back a classic
		// frame for an FD one, would pass a test that only counted bytes — and that is precisely
		// the silent downgrade this whole path exists to prevent.
		mut why := []string{}
		if got.data.len != n {
			why << 'len ${got.data.len}'
		}
		if got.data != payload {
			why << 'payload differs'
		}
		if got.fd != (data_rate != 0) {
			why << 'fd=${got.fd}'
		}
		if got.brs != (data_rate != 0) {
			why << 'brs=${got.brs}'
		}
		if why.len == 0 {
			println('  len ${n:2}: ok   (fd=${got.fd} brs=${got.brs})')
		} else {
			println('  len ${n:2}: FAIL — ${why.join(', ')}')
			bad++
		}
	}
	println('  -> ${lens.len - bad}/${lens.len} passed')
	return if bad > 0 { 1 } else { 0 }
}

// run_rtr_case proves a REMOTE frame survives the round trip, in BOTH directions of the flag.
//
// Two assertions, because either one alone passes on a broken backend: a reader that never sets
// rtr fails the first, and one that sets it always fails the second. The send half of this
// landed with #177 and the read half did not, so an incoming remote frame arrived labelled as
// data -- and wiretap keys an echo on rtr, so our own request came back filed as the ECU's
// answer to it. None of this is reachable from CI: the backend is a _windows.v file over a
// vendor DLL, so the bench is where it is checked.
fn run_rtr_case(o Opts) int {
	println('
== remote frames, arbitration ${o.arb} ==')
	mut tx := transport.open('kvaser:${o.from}@${o.arb}') or {
		eprintln('  open kvaser:${o.from}@${o.arb}: ${err}')
		return 1
	}
	defer {
		tx.close()
	}
	mut rx := transport.open('kvaser:${o.to}@${o.arb}') or {
		eprintln('  open kvaser:${o.to}@${o.arb}: ${err}')
		return 1
	}
	defer {
		rx.close()
	}
	mut bad := 0

	mut sent := true
	tx.send(transport.CanFrame{ id: 0x321, rtr: true }) or {
		println('  remote:  FAIL — send failed: ${err}')
		sent = false
		bad++
	}
	if sent {
		if got := recv_matching(mut rx, 0x321, o.timeout) {
			if got.rtr {
				println('  remote:  ok   (rtr=true, dlc=${got.data.len})')
			} else {
				println('  remote:  FAIL — arrived as a DATA frame (rtr=false)')
				bad++
			}
		} else {
			println('  remote:  FAIL — nothing arrived within ${o.timeout} ms')
			bad++
		}
	}

	// The other direction of the same flag: an ordinary data frame must NOT come back marked
	// remote. A reader that hard-codes rtr=true would pass the check above on its own.
	payload := [u8(0xDE), 0xAD, 0xBE, 0xEF]
	mut dsent := true
	tx.send(transport.CanFrame{ id: 0x322, data: payload }) or {
		println('  data:    FAIL — send failed: ${err}')
		dsent = false
		bad++
	}
	if dsent {
		if got := recv_matching(mut rx, 0x322, o.timeout) {
			if got.rtr {
				println('  data:    FAIL — a data frame arrived marked remote')
				bad++
			} else if got.data != payload {
				println('  data:    FAIL — payload differs (${got.data.hex()})')
				bad++
			} else {
				println('  data:    ok   (rtr=false)')
			}
		} else {
			println('  data:    FAIL — nothing arrived within ${o.timeout} ms')
			bad++
		}
	}

	println('  -> ${bad} failure(s)')
	return if bad > 0 { 1 } else { 0 }
}

// run_fd_rtr_refusal checks that an FD channel REFUSES a remote frame: CAN-FD has none, the bit
// RTR used to occupy carries FDF, and a backend that sent one anyway would put a plain data
// frame on the wire and report success — the silent substitution the whole FD path exists to
// prevent.
//
// ITS OWN FUNCTION, and not a third check inside run_rtr_case, because canlib pins the PROTOCOL
// of a channel to the first handle a process opens on it (#201): asking for an FD handle while
// the classic ones above are still open is refused with canERR_NOTFOUND, and the tool then
// reports a bench failure it created itself. V runs a defer at function exit, so the classic
// handles are shut before this is called.
fn run_fd_rtr_refusal(o Opts) int {
	addr := 'kvaser:${o.from}@${o.arb}/${o.data}'
	println('
== remote frames refused on CAN-FD, ${addr} ==')
	mut fdtx := transport.open(addr) or {
		eprintln('  fd+rtr:  FAIL — open ${addr}: ${err}')
		return 1
	}
	mut why := ''
	fdtx.send(transport.CanFrame{ id: 0x323, rtr: true, fd: true }) or { why = err.msg() }
	fdtx.close()
	if why == '' {
		println('  fd+rtr:  FAIL — accepted; CAN-FD has no remote frames')
		return 1
	}
	println('  fd+rtr:  ok   (refused: ${why})')
	return 0
}

// recv_matching reads until the wanted id turns up or the budget runs out. Anything else on the
// wire is skipped rather than failing the case: a bench cable is not always a private bus.
fn recv_matching(mut b transport.Bus, want u32, timeout_ms int) ?transport.CanFrame {
	deadline := time.now().add(time.millisecond * timeout_ms * 4)
	for time.now() < deadline {
		f := b.recv(timeout_ms) or { continue }
		if f.id == want {
			return f
		}
	}
	return none
}

// arg_int reads a whole number, refusing one that is only PARTLY a number.
//
// V's `.int()` takes a numeric prefix, so `--from ch1` quietly meant channel 0 — and on a bench
// where the connectors are labelled from 1 and canlib counts from 0, "channel 0" is exactly the
// plausible-looking wrong answer somebody would not question. cmd/vectorcheck learned this the
// same way and has whole_int; this is the same rule, said once more because the two tools do not
// share a module.
fn arg_int(args []string, i int, what string) int {
	tok := args[i] or {
		eprintln('${what} needs a number')
		exit(2)
	}
	t := tok.trim_space()
	mut digits := 0
	for j, c in t {
		if c.is_digit() {
			digits++
			continue
		}
		if j == 0 && c == `-` {
			continue
		}
		eprintln('${what}: "${tok}" is not a whole number')
		exit(2)
	}
	// AT LEAST ONE DIGIT. A lone `-` walked the loop above without ever failing it, and `.int()`
	// turns that into 0 — so `--from -` opened channel 0 and the tool transmitted from it,
	// which is the argument-parsing equivalent of the silent-wrong-frame bugs this branch is
	// otherwise about. cmd/vectorcheck's whole_int counts digits for the same reason.
	if digits == 0 {
		eprintln('${what}: "${tok}" is not a whole number')
		exit(2)
	}
	return t.int()
}
