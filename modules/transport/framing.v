module transport

import sync

// CAN-FD framing — what format a wire carries, and the ONE place frames we ORIGINATE are given it.
//
// WHY NOT AT EACH EMITTER, which is the mistake this file replaced. #182 opened a Vector channel as
// CAN-FD and #183 configured its data phase, but every frame this app CONSTRUCTS was built classic
// — so a channel the operator had just configured as CAN-FD could be exercised by nothing except
// replay (#185). The first fix stamped at what looked like a choke point in each front end, and
// missed most of the emitters: the GUI's simulated ECUs send through a tapped bus, the ISO-TP
// diagnostic servers and flash build their own frames, GUI-launched Lua holds a raw bus, and the
// headless runner's UDS nodes and `bus.send` never touched the path that stamped.
//
// That is the argument listen.v already makes, word for word, about the same set of emitters — and
// the same answer applies. Checked inside `open`, an emitter cannot opt out, because it never sees
// the decision: it is simply handed a bus that frames what it sends.
//
// WHY A TABLE RATHER THAN THE ADDRESS. A Vector address already carries the data phase, and
// `vector:1@500000/2000000` is what asks the driver for FD — so reading the format back out of the
// interface string looks like the smaller change. It does not reach: SilentBus is given the LOGICAL
// iface (open_tap passes it deliberately), an `inproc:` or `socketcan:` address carries no rates at
// all, and a project's `type: canfd` must mean the same thing on a software bus so a test can
// exercise FD with no hardware. The format is a policy ON a wire, like silence is, and this table
// is what keeps it out of the wire's name.
//
// Process-wide, like listen_tbl and sim's fault table, and for the same reason: the GUI, a script
// and a CLI tool must not be able to disagree about what a bus carries.

// Framing is the format frames originated on a wire are given. Mirrors project.Framing, which is
// where the RULE that derives it lives and is tested; this module only applies it.
pub struct Framing {
pub:
	fd  bool
	brs bool
}

// wire_framing reports the format declared for this wire; classic when nothing was declared.
//
// Reads the SAME entry listen-only does — see WirePolicy in listen.v for why silence and format
// share one table, one lock and one swap.
pub fn wire_framing(iface string) Framing {
	return wire_policy(iface).framing
}

// framed_for_wire gives a frame the format its wire declared.
//
// UPWARD ONLY. A frame that already says `fd` keeps it — replay carries recorded flags through this
// same path, and demoting one to classic silently would be the truncation the whole change exists
// to stop. Nothing here ever contradicts a caller that has already stated a format.
//
// ASKED PER SEND, not cached at open, for the reason SilentBus asks per send: a project can be
// replaced while a Lua script still holds a bus it opened, and an answer frozen at open time is one
// that goes stale while a wire transmits.
pub fn framed_for_wire(iface string, f CanFrame) CanFrame {
	if f.fd {
		return f
	}
	return wire_framing(iface).apply(f)
}

// apply is the stamp itself. Idempotent: it is applied at the GUI tap (so the trace RECORDS the
// frame that will actually go out) and again inside the bus for emitters that hold no tap, and a
// frame already carrying `fd` passes through both untouched.
pub fn (fr Framing) apply(f CanFrame) CanFrame {
	if f.fd || !fr.fd {
		return f
	}
	return CanFrame{
		...f
		fd:  true
		brs: fr.brs
	}
}
