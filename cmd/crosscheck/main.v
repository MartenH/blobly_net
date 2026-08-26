// crosscheck — prove that two wires are on one bus, and that a frame survives the crossing.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/crosscheck/main.v <A> <B>
//   crosscheck kvaser:2@500000 cansub:e5a16adf/1@500000
//   crosscheck kvaser:2@500000/2000000 cansub:e5a16adf/1@500000/2000000   (CAN-FD)
//
// VENDOR-NEUTRAL ON PURPOSE, and that is the whole value. vectorcheck and kvasercheck each loop a
// device back to itself, which cannot catch a disagreement about what a bitrate MEANS: both ends
// derive their timing from the same table, so a sample point that no other controller would agree
// with passes every frame. Two DIFFERENT backends on one wire, each deriving its own timing from
// its own vendor's numbers, is the only arrangement that tests the number rather than the code
// that copied it. The 62.5%-versus-80% arbitration sample point fixed in the Kvaser CAN-FD work
// was found by reading, because a loopback structurally could not see it.
//
// It takes interface strings rather than a device and channels, so it works for any pair the
// transport layer can open -- including a software bus on one side while a real one is on the
// other.
module main

import os
import time
import transport

struct Case {
	label string
	fd    bool
	brs   bool
	lens  []int
}

fn main() {
	args := os.args[1..].filter(!it.starts_with('-'))
	fd_wanted := '--fd' in os.args
	if args.len < 2 {
		eprintln('usage: crosscheck <ifaceA> <ifaceB> [--fd]')
		eprintln('  e.g. crosscheck kvaser:2@500000 cansub:e5a16adf/1@500000')
		eprintln('       crosscheck kvaser:2@500000/2000000 cansub:e5a16adf/1@500000/2000000 --fd')
		exit(2)
	}
	a_if, b_if := args[0], args[1]
	println('A = ${a_if}')
	println('B = ${b_if}')
	// ONE WIRE CANNOT PROVE TWO ARE CONNECTED. Where both addresses resolve to the same
	// destination, a second open shares the first handle — and on a CANsub the device echoes its
	// own sends as TX acknowledgements, so each leg would happily consume its own echo and this
	// would report a working cable with nothing plugged into it. `cansub_smoke` refuses the same
	// thing for the same reason (codex round 4 on #204).
	if transport.destination_key(a_if) == transport.destination_key(b_if) {
		eprintln('A and B are the same wire (${transport.destination_key(a_if)}).')
		eprintln('  This tool proves two endpoints are connected; one endpoint cannot show that,')
		eprintln('  and on a device that echoes its own sends it would appear to.')
		exit(2)
	}
	mut a := transport.open(a_if) or {
		eprintln('open A (${a_if}): ${err}')
		exit(1)
	}
	defer { a.close() }
	mut b := transport.open(b_if) or {
		eprintln('open B (${b_if}): ${err}')
		exit(1)
	}
	defer { b.close() }
	// SETTLE. A controller that has just gone bus-on can miss the first frame offered to it, and a
	// bench tool reporting that as a wiring fault is the false negative this whole file exists to
	// avoid producing.
	time.sleep(300 * time.millisecond)

	mut cases := [
		Case{'classic', false, false, [1, 8]},
	]
	if fd_wanted {
		cases << Case{'CAN-FD with BRS', true, true, [8, 12, 16, 24, 32, 48, 64]}
	}
	mut bad := 0
	for c in cases {
		// BOTH DIRECTIONS, because they are not the same test: each end transmits with its own
		// vendor's timing and receives with the other's, and a sample-point disagreement can be
		// asymmetric -- the faster-sampling end tolerating what the slower one will not.
		bad += leg(mut a, mut b, 'A -> B', c)
		bad += leg(mut b, mut a, 'B -> A', c)
	}
	if bad > 0 {
		eprintln('\n${bad} leg(s) FAILED')
		exit(1)
	}
	println('\nboth wires are on one bus, in both directions')
}

// leg sends every length of one case from `tx` and requires it on `rx`.
fn leg(mut tx transport.Bus, mut rx transport.Bus, dir string, c Case) int {
	println('\n== ${dir} : ${c.label} ==')
	mut bad := 0
	drain(mut rx)
	for idx, n in c.lens {
		mut payload := []u8{len: n}
		for i in 0 .. n {
			// A PATTERN THAT IS NOT ITS OWN INDEX, so a frame reassembled from the wrong offset
			// looks wrong rather than plausible.
			payload[i] = u8((i * 7 + 0x5A) & 0xFF)
		}
		// ONE ID PER FRAME, so an arrival identifies itself. A shared id cannot distinguish this
		// frame from the one before it, which is how a queue offset reads as a payload fault.
		id := u32(0x200 + idx)
		f := transport.CanFrame{
			id:   id
			fd:   c.fd
			brs:  c.brs
			data: payload
		}
		tx.send(f) or {
			println('  len ${n:2}: send — ${err}')
			bad++
			continue
		}
		got := listen_for(mut rx, id, 400) or {
			println('  len ${n:2}: nothing arrived')
			bad++
			continue
		}
		mut why := []string{}
		if got.data != payload {
			why << 'payload differs'
		}
		if got.data.len != n {
			why << 'len ${got.data.len}'
		}
		if got.fd != c.fd {
			why << 'fd=${got.fd}'
		}
		if got.brs != c.brs {
			why << 'brs=${got.brs}'
		}
		if why.len == 0 {
			println('  len ${n:2}: ok')
		} else {
			println('  len ${n:2}: FAIL — ${why.join(', ')}')
			bad++
		}
	}
	return bad
}

// drain empties whatever a previous leg left in the receive queue.
//
// WITHOUT THIS the tool reports a codec fault it invented itself. Every frame carried one id, so
// listen_for could not tell a new frame from a leftover: each read returned the PREVIOUS leg's
// frame, and the failures printed "len 8 arrived as len 1" -- a stale queue wearing the costume of
// a length bug. Ids are unique per frame now as well, so a match is proof rather than a guess.
fn drain(mut b transport.Bus) {
	for _ in 0 .. 200 {
		b.recv(20) or { return }
	}
}

// listen_for reads until the wanted id turns up or the budget runs out. Other traffic is skipped:
// a bench cable is not always a private bus, and failing on somebody else's frame would make this
// tool useless exactly where it is most wanted.
fn listen_for(mut b transport.Bus, want u32, budget_ms int) ?transport.CanFrame {
	deadline := time.now().add(time.millisecond * budget_ms)
	for time.now() < deadline {
		f := b.recv(100) or { continue }
		if f.id == want {
			return f
		}
	}
	return none
}
