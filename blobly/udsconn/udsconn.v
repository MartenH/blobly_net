// udsconn — a UDS connection on a project row: which carrier the row's diagnostics ride (ISO-TP
// over its CAN bus, or its DoIP connection), which CAN ids a request goes out and comes back on,
// and the uds.Client over the opened channel; and a DoIP row's discovery (discovery.v). The ONE
// rule for it: the Lua `uds.open` and `doip.*` (blobly/script) and the C ABI's bb_uds_open and
// bb_doip_* (cmd/libblobly) all go through here, so a script and a Python host reach a row's ECU
// the same way.
module udsconn

import blobly.doip
import blobly.isotp
import blobly.project
import blobly.transport
import blobly.uds
import time

// Carrier is the transport UDS rides on a row. Derived from the project channel by carrier_of()
// rather than assembled by each caller, so every front end reaches a row the same way.
pub struct Carrier {
pub:
	doip   bool
	someip bool // a SOME/IP listener endpoint: host/port are where it binds, group what it joins
	group  string
	host   string
	port   int
	tester u16
	ecu    u16
}

// eth_kind names this carrier's Ethernet kind, or none for a CAN row. One predicate, so a third
// kind does not become a third `|| c.someip` in every caller.
pub fn (c Carrier) eth_kind() ?string {
	if c.doip {
		return 'DoIP'
	}
	if c.someip {
		return 'SOME/IP'
	}
	return none
}

// carrier_of derives the UDS carrier from a project channel.
pub fn carrier_of(ch project.Channel) Carrier {
	if ch.is_someip() {
		host, port := ch.someip_endpoint()
		return Carrier{
			someip: true
			group:  ch.group
			host:   host
			port:   port
		}
	}
	if !ch.is_doip() {
		return Carrier{}
	}
	host, port := ch.doip_endpoint()
	return Carrier{
		doip:   true
		host:   host
		port:   port
		tester: ch.tester_addr
		ecu:    ch.ecu_addr
	}
}

// Ask is what a caller asked of a connection: the CAN ids it gave, as given (`has_tx` false =
// omitted: presence is not carried by a sentinel, since 0 is a valid id and a negative one is a
// mistake to report), and the ids an omitted one defaults to. `what` names the caller in the
// refusals ('uds.open', 'flash.program').
pub struct Ask {
pub:
	what   string
	has_tx bool
	tx     i64
	has_rx bool
	rx     i64
	dtx    u32 = 0x7E0
	drx    u32 = 0x7E8
}

// Target is what a connection is opened on: a DoIP row's connection, or a CAN row's request and
// response ids and whether they are 29-bit.
pub struct Target {
pub:
	doip bool
	tx   u32
	rx   u32
	ext  bool
}

// check_ids refuses an id that is not a CAN identifier. Asked by `resolve` too; a caller may ask
// it first, before it has the row, to refuse a bad id before a bad name.
pub fn check_ids(a Ask, name string) ! {
	if a.has_tx && (a.tx < 0 || a.tx > 0x1FFF_FFFF) {
		return error('${a.what}("${name}"): tx = ${a.tx} is not a CAN identifier (0..0x1FFFFFFF)')
	}
	if a.has_rx && (a.rx < 0 || a.rx > 0x1FFF_FFFF) {
		return error('${a.what}("${name}"): rx = ${a.rx} is not a CAN identifier (0..0x1FFFFFFF)')
	}
}

// resolve is the target `a` asks for on row `name` of carrier `car`: refused for a SOME/IP row
// (not a diagnostics carrier) and for ids given to a DoIP row (its addressing is the row's logical
// pair); on a CAN row an omitted id takes its default, and the ids are 29-bit when either is past
// 0x7FF, as the server side infers it — opened standard, SocketCAN masks 0x18DA10F1 to 0x0F1.
pub fn resolve(a Ask, name string, car Carrier) !Target {
	check_ids(a, name)!
	if car.someip {
		return error('"${name}" is a SOME/IP channel — not a diagnostics carrier')
	}
	if car.doip {
		if a.has_tx || a.has_rx {
			return error('${a.what}("${name}"): DoIP addressing comes from the channel (tester_address/ecu_address); drop tx/rx')
		}
		return Target{
			doip: true
		}
	}
	tx := if a.has_tx { u32(a.tx) } else { a.dtx }
	rx := if a.has_rx { u32(a.rx) } else { a.drx }
	if tx > 0x1FFF_FFFF || rx > 0x1FFF_FFFF {
		return error('${a.what}("${name}"): the default ids 0x${a.dtx:X}/0x${a.drx:X} are not CAN identifiers')
	}
	return Target{
		tx:  tx
		rx:  rx
		ext: tx > 0x7FF || rx > 0x7FF
	}
}

// Conn is an opened connection: the channel UDS rides and the client over it.
pub struct Conn {
pub mut:
	ch  isotp.Channel
	cli uds.Client
}

// open opens `t` on row `name`: the row's DoIP connection, or an ISO-TP channel on the bus
// `opener` gives for `iface` (and the row's name: two rows may share one interface, and a host
// attributing traffic must know which was meant), framed as the wire declares — a CAN-FD row
// stamps its frames FD.
pub fn open(t Target, name string, iface string, car Carrier, opener fn (string, string) !transport.Bus) !Conn {
	ch := if t.doip {
		// in the words of the open, of its cause's kind: a routing activation denied stays one
		isotp.Channel(open_doip(car) or {
			return uds.ContextError{
				text:  'doip open failed on ${name} (${car.host}:${car.port}): ${err}'
				cause: err
			}
		})
	} else {
		isotp.Channel(open_isotp(t, name, iface, opener)!)
	}
	return Conn{
		ch:  ch
		cli: uds.new_client(ch)
	}
}

// doip_open_ms bounds a DoIP row's open, the TCP connect and the routing activation together: the
// connect's own bound (doip.connect_ms) leaves no time for the activation, and a routing
// activation answer may trickle in.
pub const doip_open_ms = 7000

// open_doip is a DoIP row's connection: to its entity's endpoint, from its tester address to its
// ECU address, within doip_open_ms. The error is doip's own; the caller says what it was opening
// for.
pub fn open_doip(car Carrier) !&doip.DoipClient {
	deadline := time.ticks() + doip_open_ms
	mut c := doip.open_doip_stoppable(car.host, car.port, car.tester, car.ecu, fn [deadline] () bool {
		return time.ticks() >= deadline
	}) or {
		if err.msg() == doip.stopped_note {
			return error('DoIP: no connection with routing activated within ${doip_open_ms} ms')
		}
		return err
	}
	c.stop_requested = unsafe { nil } // the deadline was the open's; the connection's waits are its own
	return c
}
