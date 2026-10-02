module transport



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
	if f.fd || f.format_stated {
		return f.unstated()
	}
	return wire_framing(iface).apply(f)
}

// apply is the stamp itself. Idempotent: it is applied at the GUI tap (so the trace RECORDS the
// frame that will actually go out) and again inside the bus for emitters that hold no tap, and a
// frame already carrying `fd` passes through both untouched.
//
// A frame whose format was STATED (`format_stated`, #203) is the caller's decision and is never
// stamped — that is how a classic frame reaches a CAN-FD wire. The flag is consumed here: what
// comes out is the frame that goes on, and nothing past this point needs to know it was stated.
pub fn (fr Framing) apply(f CanFrame) CanFrame {
	if f.format_stated {
		return f.unstated()
	}
	if f.fd || !fr.fd {
		return f
	}
	return CanFrame{
		...f
		fd:  true
		brs: fr.brs
	}
}

// unstated is the frame with the send-side intent removed, once the format has been decided.
pub fn (f CanFrame) unstated() CanFrame {
	if !f.format_stated {
		return f
	}
	return CanFrame{
		...f
		format_stated: false
	}
}

// ---- a format chosen PER FRAME (#203) ---------------------------------------------------------
//
// The wire table above answers "what does this wire carry". Two formats on one CAN-FD wire is
// ordinary traffic, though, and an operator poking a bus by hand needs to say "this one frame is
// classic" — which `fd == false` cannot, since that already means "not stated". FrameFormat is the
// statement, made by the one caller that means it (Quick Send, Lua's `bus.send` with `format =`),
// and carried ON THE FRAME so it survives every wrapper between that caller and the wire: the
// GUI's tap and `SilentBus` both frame through `Framing.apply`, which leaves a stated frame alone.
//
// Everything else — generators, simulated ECUs, ISO-TP, flash, replay — states nothing and is
// framed per wire as before.

// FrameFormat is a per-frame format choice. `wire` states nothing: the wire's declaration decides.
pub enum FrameFormat {
	wire
	classic
	fd
	fd_brs
}

// frame_formats is every choice, in the order a picker lists them.
pub const frame_formats = [FrameFormat.wire, .classic, .fd, .fd_brs]

// frame_format_names are the spellings `parse_frame_format` accepts, one per `frame_formats` entry.
pub const frame_format_names = ['wire', 'classic', 'fd', 'fd_brs']

// parse_frame_format reads a format name; '' is `wire`.
pub fn parse_frame_format(s string) !FrameFormat {
	return match s.to_lower() {
		'', 'wire' { FrameFormat.wire }
		'classic' { FrameFormat.classic }
		'fd' { FrameFormat.fd }
		'fd_brs', 'fd+brs' { FrameFormat.fd_brs }
		else { error('unknown frame format "${s}" (want classic, fd or fd_brs)') }
	}
}

// label is how a picker names the choice.
pub fn (ff FrameFormat) label() string {
	return match ff {
		.wire { 'as declared' }
		.classic { 'classic' }
		.fd { 'FD' }
		.fd_brs { 'FD+BRS' }
	}
}

// label is how a picker names a wire's declared format.
pub fn (fr Framing) label() string {
	return if !fr.fd {
		'classic'
	} else if fr.brs {
		'FD+BRS'
	} else {
		'FD'
	}
}

// stamp states this format on `f`. `wire` returns it unchanged — unstated, so the wire decides.
//
// A classic frame carries at most eight bytes and an FD one 64, so a stated frame with more is
// REFUSED here,
// where the operator asked for it, rather than clamped by SocketCAN or refused by a vendor DLL
// with a message that says nothing about the choice that caused it.
pub fn (ff FrameFormat) stamp(f CanFrame) !CanFrame {
	if ff == .wire {
		return f
	}
	if ff == .classic && f.data.len > 8 {
		return error('a classic frame carries at most 8 bytes, this one has ${f.data.len} — choose FD')
	}
	if f.data.len > 64 {
		return error('a CAN-FD frame carries at most 64 bytes, this one has ${f.data.len}')
	}
	return CanFrame{
		...f
		fd:            ff != .classic
		brs:           ff == .fd_brs
		format_stated: true
	}
}

// format_choice_offered reports whether a per-frame format choice can change anything for a frame
// sent from a row declaring `row` (enabled or not) onto a wire declaring `wire`.
//
// On a classic row of an undeclared wire every frame goes out classic and the choice would be one
// the operator has to reason about for nothing. On an FD wire it is how a classic frame gets out;
// on an ENABLED FD row of an undeclared wire (two enabled rows disagree, `project.wire_framings`)
// it is how an FD frame gets out. A DISABLED row declares nothing about the run — the wire table
// ignores it — so its FD alone offers nothing: an FD frame from it would contradict the only
// declaration the run has.
pub fn format_choice_offered(row Framing, row_enabled bool, wire Framing) bool {
	return wire.fd || (row.fd && row_enabled)
}
