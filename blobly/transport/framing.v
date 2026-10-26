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
// Everything else states nothing. A ROW'S OWN emitters — its generators, its simulated ECUs, a
// script's or a host's handle on the row — are raised to that row's format (`RowFramedBus`,
// #384); the rest — ISO-TP testers, flash, the shell, replay — are framed per wire.

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
// sent from a row declaring `row` (enabled or not) onto a wire declaring `wire`: whether that frame,
// stating nothing, goes out FD (`row_declared`). There a classic choice is how a classic frame gets
// out; on a classic one every frame goes out classic and the choice would be one the operator has
// to reason about for nothing.
pub fn format_choice_offered(row Framing, row_enabled bool, wire Framing) bool {
	return row_declared(row, row_enabled, wire).fd
}

// row_declared is the format a frame stating nothing goes out in from a row's own handle (#384): the
// row's where it is ENABLED and FD — on a wire two enabled rows dispute, which `project.wire_framings`
// leaves undeclared, each row's emitters keep the row's format — else the wire's. A DISABLED row
// declares nothing about the run, so its FD alone contradicts nothing the run has.
pub fn row_declared(row Framing, row_enabled bool, wire Framing) Framing {
	if row_enabled && row.fd && !wire.fd {
		return row
	}
	return wire
}

// raised is `f` in this format where its caller stated none: `apply`'s upward-only stamp, with a
// stated frame left as it is — the statement is the wire stage's to consume, so a stated classic
// frame is still classic there.
pub fn (fr Framing) raised(f CanFrame) CanFrame {
	if f.format_stated {
		return f
	}
	return fr.apply(f)
}

// row_framing is the format row `row`'s own emitters on `iface` raise a frame to: the row's where
// the published project has it as an enabled FD row of that name on that wire
// (project.row_framings), else classic, which raises nothing. Read per send, like wire_framing.
pub fn row_framing(iface string, row string) Framing {
	if row == '' {
		return Framing{}
	}
	return wire_policy(iface).rows[row] or { Framing{} }
}

// RowFramedBus is a bus a ROW's own emitters send through: every frame stating no format raised to
// the row's (`row_framing`, asked per send) before the bus beneath frames it for its wire. On a wire
// whose rows agree the two are one format; on a wire two enabled rows dispute, the wire is
// undeclared and this is what keeps an FD row's generators and simulated ECUs FD (#384). Replay
// never goes through one.
@[heap]
pub struct RowFramedBus {
	iface string
	row   string
mut:
	inner Bus
	sent  CanFrame
}

// row_framed is `b`, opened on `iface`, sending as row `row`'s own emitter; `b` itself for no row.
pub fn row_framed(b Bus, iface string, row string) Bus {
	if row == '' {
		return b
	}
	return &RowFramedBus{
		iface: iface
		row:   row
		inner: b
	}
}

pub fn (mut r RowFramedBus) send(f CanFrame) ! {
	out := row_framing(r.iface, r.row).raised(f)
	r.inner.send(out)!
	r.sent = out.unstated()
}

// sent_frame is what the bus beneath handed on, where it says (SentFrame), else the frame raised.
pub fn (r &RowFramedBus) sent_frame() CanFrame {
	inner := r.inner
	return if inner is SentFrame { inner.sent_frame() } else { r.sent }
}

pub fn (mut r RowFramedBus) recv(timeout_ms int) !CanFrame {
	return r.inner.recv(timeout_ms)!
}

pub fn (mut r RowFramedBus) close() {
	r.inner.close()
}

pub fn (mut r RowFramedBus) health() BusHealth {
	return r.inner.health()
}

pub fn (mut r RowFramedBus) diagnostics() BusDiagnostics {
	return r.inner.diagnostics()
}

pub fn (mut r RowFramedBus) reconcile_silence(want bool) ! {
	r.inner.reconcile_silence(want)!
}
