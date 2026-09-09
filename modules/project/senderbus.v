module project

// WHAT A GENERATOR'S `bus:` NAMES (#97).
//
// It used to be an INTERFACE, and an interface cannot say which CHANNEL a generator belongs to:
// two configured channels may share one wire deliberately — the codebase supports it, `rx_loop`
// runs per channel entry — so `bus: inproc:CAN2` picks a wire, not an owner. The GUI grew a
// runtime answer for the trace's `ch=` column (SenderRT.chan) with nowhere in the file to put it,
// so picking the SECOND channel on a shared wire stored `bus: ''` (its interface equals the
// generator's own), a save/reload restored ownership from the FIRST, and the selection silently
// reverted. That is the whole of #97.
//
// So `bus:` is a channel NAME. It is what the picker shows, it is unambiguous where an interface
// is not, and it is what a Save now writes.
//
// AN INTERFACE IS STILL UNDERSTOOD, and that is not a hedge — it is the migration. Projects are
// maintained by hand and `docs/simulation.md` told people in so many words to write an interface
// ("it takes the interface string, not the channel's name: `bus: inproc:CAN2`, not
// `bus: CAN2`"). Refusing those would break every file already written to the documented rule.
// It also keeps a real capability the name form cannot express: an interface that is NOT a
// configured channel at all — `bus: pcan:PCAN_USBBUS1@250000`, a bare wire carrying its own rate —
// which Start opens a transmit tap for on purpose (`phys_for_locked` keeps such a target
// verbatim, rate and all).
//
// THE TIE IS BROKEN BY RULE, NOT BY LUCK. A name is tried FIRST, because that is what the key
// now means; only a value no channel answers to by name is read as an interface. So a channel
// literally named `vcan0` sitting beside a wire spelled `vcan0` resolves to the channel — the
// answer the picker would give, and the one a reader of a key documented as taking a name would
// expect. The forms are not otherwise confusable: an interface carries an adapter prefix or is a
// device name, and a channel name is a label.
//
// NEITHER FORM IS AN IDENTITY BY ITSELF, which is why this returns a verdict rather than a
// string. Channel names are not enforced unique any more than interfaces are, so `bus:` can name
// two channels just as it could name two rows on one wire. Both cases resolve to `.ambiguous`,
// which transmits — on the one wire they share, exactly as today — and says so, rather than
// picking whichever came first and reverting a selection again.

// SenderBusKind is HOW a `bus:` value was answered, not just what it resolved to. The kind is
// what the warnings read: `.iface` is a file written to the old documentation and is fine,
// `.ambiguous` is a project that cannot say what it means, and `.bare` is deliberate.
pub enum SenderBusKind {
	own // `bus:` is empty — the generator's own channel
	named // a channel NAME: the current form, and the only unambiguous one
	iface // an interface string naming exactly one configured channel — the legacy form
	bare // an interface string no configured channel has: a wire, owned by nobody
	ambiguous // several channels answer to it, so it names no one of them
}

// SenderBus is where a generator transmits and who owns it. The two are separate facts, which is
// the lesson of #97: `iface` is what gets opened, `chan` is whose the frames are, and on a shared
// wire only the second can tell two generators apart. `chan` is empty exactly when no single
// channel owns the target — a bare wire, or an ambiguous reference.
pub struct SenderBus {
pub:
	kind  SenderBusKind
	chan  string // the owning channel's NAME; '' when no single channel owns the target
	iface string // the interface to transmit on; '' only when nothing could be resolved
	note  string // '' unless there is something worth saying at Start
}

// resolve_sender_bus answers one generator's `bus:` against the project's channels. `own` is the
// channel the generator is nested under, which is what an empty `bus:` means.
pub fn resolve_sender_bus(bus string, own Channel, chs []Channel) SenderBus {
	if bus == '' {
		return SenderBus{
			kind: .own
			chan: own.name
			iface: own.iface
		}
	}
	// BY NAME FIRST: that is what the key means now.
	mut named := []Channel{}
	for c in chs {
		if c.name == bus {
			named << c
		}
	}
	if named.len == 1 {
		return SenderBus{
			kind: .named
			chan: named[0].name
			iface: named[0].iface
		}
	}
	if named.len > 1 {
		// Same name, and possibly not even the same wire. Where they agree on the wire the
		// generator can still transmit (that is today's behaviour on a shared wire); where they
		// do not, there is nothing to open and saying which is the project's job.
		mut one := named[0].iface
		for c in named {
			if c.iface != one {
				one = ''
				break
			}
		}
		return SenderBus{
			kind: .ambiguous
			iface: one
			note: if one != '' {
				'`bus: ${bus}` names ${named.len} channels; they share ${one}, so it transmits there but no channel owns its frames'} else {
				'`bus: ${bus}` names ${named.len} channels on different interfaces — it cannot say which, and the generator has nowhere to send'}
		}
	}
	// THEN AS AN INTERFACE, the form every file written before #97 uses.
	mut by_iface := []Channel{}
	for c in chs {
		if c.iface == bus {
			by_iface << c
		}
	}
	if by_iface.len == 1 {
		return SenderBus{
			kind: .iface
			chan: by_iface[0].name
			iface: bus
		}
	}
	if by_iface.len > 1 {
		mut names := []string{}
		for c in by_iface {
			names << c.name
		}
		return SenderBus{
			kind: .ambiguous
			iface: bus
			note: '`bus: ${bus}` is an interface ${by_iface.len} channels share (${names.join(', ')}) — it transmits there, but name one of them to say whose the frames are'
		}
	}
	// A wire with no channel: legitimate, and the one thing a name cannot express.
	return SenderBus{
		kind: .bare
		iface: bus
		note: ''
	}
}

// sender_bus_value is what to WRITE in `bus:` so a generator nested under `own` transmits on
// `target` — or none when this project cannot express that at all.
//
// THE WRITER'S SIDE OF resolve_sender_bus, and it exists because guessing a spelling and hoping
// is how the picker kept being wrong. It tried the name, then fell back to the interface for an
// unnamed row — and where that interface is also ANOTHER channel's name, the name-first rule sent
// the generator to that other channel, on another wire (codex round 3 on #97). Every such
// collision is the same defect, so the candidate is CHECKED rather than reasoned about: it is
// accepted only if resolving it lands on the target's own interface and names either the target
// or nobody. "Nobody" is the pre-existing shared-wire state, which transmits and is warned about;
// naming somebody ELSE never is.
//
// NONE MEANS THE PROJECT CANNOT SAY IT. An unnamed row whose interface is another channel's name
// has no spelling in this format: the caller must refuse and say so, rather than storing a value
// that goes somewhere the operator did not pick. Naming the row fixes it, which is what to tell
// them.
pub fn sender_bus_value(target Channel, own Channel, chs []Channel) ?string {
	if target.name == own.name && target.iface == own.iface {
		return '' // its own channel — the one value that needs no spelling
	}
	for cand in [target.name, target.iface] {
		if cand == '' {
			continue
		}
		r := resolve_sender_bus(cand, own, chs)
		if r.iface == target.iface && (r.chan == target.name || r.chan == '') {
			return cand
		}
	}
	return none
}

// sender_bus_needs_v4 reports whether a build released before #97 would send this generator
// somewhere ELSE. That is the only question the schema label is about, and asking it directly is
// what keeps the label honest.
//
// The old rule was the whole of the old reader: `bus:` IS the interface, whatever any channel is
// called. So the test is simply whether the resolved interface still equals the written value —
// if it does, an older build opens exactly the same wire and the file means what it always did.
//
// ASKING WHICH FORM THE VALUE IS IN would be wrong, and measurably so: for socketcan a row's name
// defaults to its address and `compose_iface` returns that address bare, so a channel named
// `vcan1` sits on the interface `vcan1` and the legacy `bus: vcan1` is BOTH forms at once. It
// resolves to the same wire either way, so it is not a v4 file — but a which-form test labels it
// one, and every old build then warns about a project whose meaning has not changed.
pub fn sender_bus_needs_v4(bus string, own Channel, chs []Channel) bool {
	if bus == '' {
		return false
	}
	return resolve_sender_bus(bus, own, chs).iface != bus
}

// sender_bus_warnings says, once per Start, what a project's `bus:` values could not settle.
// Beside generator_source_warnings and fd_capability_warnings, and called from the same place,
// because a generator that transmits on a wire nobody owns is exactly the kind of misleading
// partial experiment those exist to announce.
//
// A `.bare` target is NOT a warning: targeting a wire with no channel row is a supported
// arrangement, and Start opens a tap for it deliberately. `.iface` is not one either — it is a
// file written to the documentation of its day, and it resolves to exactly one channel.
//
// ONCE PER GENERATOR, and named WITHOUT an owning channel, because both follow from what the
// warning says. The GUI's runtime rows attribute an unowned generator to every channel on the
// wire it targets — it has to, or its other warnings would go unsaid — so a line keyed by
// channel would be repeated once per sharer, and a warning repeated for no reason is one an
// operator learns to skip past (codex #183 r2). Naming a channel would be worse than repetitive:
// the finding IS that no channel owns these frames.
pub fn sender_bus_warnings(chs []Channel) []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	for c in chs {
		for s in c.senders {
			r := resolve_sender_bus(s.bus, c, chs)
			if r.note == '' {
				continue
			}
			// The generator's own identity, not the row it was found in.
			key := '${s.name}\0${s.bus}'
			if key in seen {
				continue
			}
			seen[key] = true
			out << 'generator ${s.name}: ${r.note}'
		}
	}
	return out
}
