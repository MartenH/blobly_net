module transport

// What a wire's OPEN PORTS have fixed (pinned.v, issue #165).
//
// THE BUS UNDERNEATH IS AN `inproc:` ONE, deliberately, and it is the only pretence here. The
// promise this file is about belongs to a driver no Linux machine has, and the alternative to a
// seam is a rule tested nowhere: mode_pinned_by_ports and pinned_wire_key are both kept off
// `$if windows` precisely so the part that CAN be checked is checked where the tests run.
// Everything else is real — the wrapper open() applies, the table it writes, the refcount the
// taps share, the close path that releases it. What a bench still has to answer is the other
// half: that the XL driver refuses the mismatch these numbers predict. That is
// `cmd/vectorcheck --modecheck`, and docs/windows_can_hardware.md records the run.
//
// NO TEST TOUCHES THE TABLE. Every one asserts through wire_pinned_config, which is what the
// panel asks; and each takes a channel of its own and closes what it opened, so none of them
// needs a reset hook on a table that is a record of physical reality — one that could be cleared
// would report a wire free while ports still hold it, which is this file's failure from the far
// side. (V would not have offered the shortcut anyway: a module's `__global` is not visible to
// a _test.v compilation unit.)

fn test_nothing_open_pins_nothing() {
	if c := wire_pinned_config('vector:9') {
		assert false, 'an untouched wire reported ${c}'
	}
}

fn test_an_open_port_pins_its_wire_and_releases_it() {
	mut b := track_pinned('vector:3@500000', open_inproc('pin_one')!)
	cfg := wire_pinned_config('vector:3') or {
		assert false, 'an open port pinned nothing'
		return
	}
	assert cfg.silent == false
	assert cfg.bitrate == 500000
	b.close()
	if c := wire_pinned_config('vector:3') {
		assert false, 'the last port closed and the wire still reported ${c}'
	}
}

// THE ISSUE ITSELF, in the only form a machine with no VN device can state it: every row anybody
// would call part of the run has gone, and the wire is still pinned — because a disabled row
// keeps its transmit taps open on purpose and the driver has never heard of a row.
fn test_a_surviving_port_keeps_the_wire_pinned() {
	mut monitor := track_pinned('vector:4@500000', open_inproc('pin_two')!)
	mut tap := track_pinned('vector:4@500000', open_inproc('pin_two')!)
	monitor.close()
	cfg := wire_pinned_config('vector:4') or {
		assert false, 'one port closed and the wire stopped being pinned while another held it'
		return
	}
	assert cfg.silent == false
	tap.close()
	if c := wire_pinned_config('vector:4') {
		assert false, 'every port closed and the wire still reported ${c}'
	}
}

fn test_silent_ports_pin_silence() {
	mut b := track_pinned('vector:5@250000,silent', open_inproc('pin_silent')!)
	defer {
		b.close()
	}
	cfg := wire_pinned_config('vector:5') or {
		assert false, 'a silent port pinned nothing'
		return
	}
	assert cfg.silent == true
	assert cfg.bitrate == 250000
}

// AN OPEN THAT RETURNED IS ONE THE CHANNEL AGREES WITH, so the latest one is what the record
// says — not the first. On a bench the second open here usually does not return at all (the
// driver answers -1004/-1005 and the first configuration stands, which the wire_pinned_config
// above still reports); but when the port holding initialisation access has closed while
// siblings stayed open, XL releases that access and the next port RECONFIGURES the channel. A
// table that kept the first answer would describe a configuration no longer installed, and wave
// through the very open the driver then refuses.
fn test_the_latest_successful_open_is_what_the_wire_is_set_to() {
	mut first := track_pinned('vector:6@500000', open_inproc('pin_first')!)
	defer {
		first.close()
	}
	mut second := track_pinned('vector:6@250000,silent', open_inproc('pin_first')!)
	cfg := wire_pinned_config('vector:6') or {
		assert false, 'nothing pinned'
		return
	}
	assert cfg.silent == true, 'a port that opened successfully did not become the record'
	assert cfg.bitrate == 250000
	// ... and the one still open keeps the wire pinned when it goes, at what IT installed being
	// the last word only until something else opens.
	second.close()
	after := wire_pinned_config('vector:6') or {
		assert false, 'a port was still open and the wire read as free'
		return
	}
	assert after.silent == true, 'closing a port rewrote the record'
}

// ONE WIRE, HOWEVER IT IS SPELLED — the identity destination_key is built on. The rate and mode
// suffixes are not part of a wire's name, and an ALIAS is how a wire comes to carry two rows at
// all, so a key any narrower would miss precisely the pair that produces this bug.
fn test_every_spelling_of_a_wire_shares_its_pin() {
	mut b := track_pinned('vector:app08@500000,silent', open_inproc('pin_alias')!)
	defer {
		b.close()
	}
	for spelling in ['vector:8', 'vector:ch8', 'vector:app8', 'vector:8@250000', 'vector:8,silent',
		'vector:CH8'] {
		cfg := wire_pinned_config(spelling) or {
			assert false, '${spelling} did not find the pin on the wire it names'
			return
		}
		assert cfg.silent == true, '${spelling} read the wrong mode'
	}
	if c := wire_pinned_config('vector:2') {
		assert false, 'a different channel reported ${c}'
	}
}

// Idempotent, for the reason SharedHandle.close is. A double close that decremented twice would
// report a wire free while a port still holds it.
fn test_closing_a_port_twice_does_not_free_the_wire() {
	mut a := track_pinned('vector:7@500000', open_inproc('pin_dbl')!)
	mut b := track_pinned('vector:7@500000', open_inproc('pin_dbl')!)
	a.close()
	a.close()
	cfg := wire_pinned_config('vector:7') or {
		assert false, 'a double close freed a wire another port was holding'
		return
	}
	assert cfg.bitrate == 500000
	b.close()
	if c := wire_pinned_config('vector:7') {
		assert false, 'the wire stayed pinned after its last port closed, reporting ${c}'
	}
}

// NOTHING ELSE PINS, and the ordinary paths pay nothing for this. A stale normal tap on
// SocketCAN, PCAN or a software bus costs nothing since #164 — those consult the listen-only
// table per send — so a refusal there would be one nobody needs.
fn test_the_backends_that_do_not_pin_record_nothing() {
	mut b := open('inproc:pin_none')!
	defer {
		b.close()
	}
	for spelling in ['inproc:pin_none', 'pcan:PCAN_USBBUS1@500000', 'kvaser:0', 'vcan0',
		'udp:239.1.2.3:5000'] {
		if c := wire_pinned_config(spelling) {
			assert false, '${spelling} is not a pinning backend and reported ${c}'
		}
	}
}

// A bus this file declines to track is handed back UNTOUCHED — not wrapped in a no-op — so the
// common path keeps the backend's own type and one less indirection per frame.
fn test_a_non_pinning_bus_is_not_wrapped() {
	mut raw := open_inproc('pin_bare')!
	defer {
		raw.close()
	}
	tracked := track_pinned('inproc:pin_bare', raw)
	assert tracked !is PinnedBus, 'a non-pinning bus was wrapped anyway'
}

// The address is read by the backend's OWN parser, so every spelling it accepts is one this
// agrees with, and one it refuses leaves the wire unpinned rather than pinned to a guess.
fn test_the_mode_is_read_by_the_backends_own_parser() {
	for spelling in ['vector:1,silent', 'vector:1,listen_only', 'vector:1,listenonly',
		'vector:1@500000,silent'] {
		cfg := pinned_open_config(spelling) or {
			assert false, '${spelling} parsed to nothing'
			return
		}
		assert cfg.silent == true, '${spelling} was not read as listen-only'
	}
	for spelling in ['vector:1', 'vector:ch2@250000', 'vector:1,normal'] {
		cfg := pinned_open_config(spelling) or {
			assert false, '${spelling} parsed to nothing'
			return
		}
		assert cfg.silent == false, '${spelling} was not read as normal'
	}
	// Refused by parse_vector_spec, and this file does not get a second opinion: an address that
	// cannot open pins nothing.
	for bad in ['vector:', 'vector:0', 'vector:65', 'vector:1,loud', 'vector:1@abc',
		'vector:nonsense'] {
		if c := pinned_open_config(bad) {
			assert false, '${bad} is not openable and produced ${c}'
		}
	}
}
