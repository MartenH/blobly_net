module sim

import math
import blobly.candb
import blobly.project
import blobly.transport

// gencontrol.v — a running generator controlled from a script (Lua's gen.*, Python's
// Project.generators): what a script is told about one, the rules an edit is held to, and the
// interface the run that owns the generators answers (headless.Run). The edits are the ones the
// GUI's Generators panel makes: fire, cyclic on and off, the cycle, a signal's value or source —
// and a signal taken off the list, and a raw generator's payload.

// gen_cycle_max_ms is the longest cycle a generator may be given: an hour.
pub const gen_cycle_max_ms = 3_600_000

// gen_fire_wait_ms is how long a fire waits for its bus at most: a first fire opens it.
pub const gen_fire_wait_ms = 5000

// GenErrorKind is how a generator call failed.
pub enum GenErrorKind {
	refused // no such generator, a bad argument, nothing to send on, a send the bus refused
	stopped // the run is stopping or stopped: nothing is sent
	timeout // the generator's bus did not take the frame in time (its open or its send)
}

// GenError is a generator call's failure, typed so a binding can tell its kinds apart.
pub struct GenError {
	Error
pub:
	kind GenErrorKind
	text string
}

pub fn (e GenError) msg() string {
	return e.text
}

pub fn gen_error(kind GenErrorKind, text string) IError {
	return GenError{
		kind: kind
		text: text
	}
}

// GenInfo is one generator of a run, as a script sees it.
pub struct GenInfo {
pub:
	name     string
	channel  string // the channel it is written under
	message  string // its DBC message, '' for a raw frame
	id       u32    // the frame's id (the message's, when it has one)
	ext      bool
	trigger  string // as the project writes it: manual | key | cyclic
	cycle_ms int    // 0 when it has none
	running  bool   // sending on its cycle now
	sent     i64    // frames the bus took, by fire and cycle alike
	// the last frame the bus took was built after the last edit of what it sends (a signal's
	// value or source, a signal unset, its payload); true before any edit
	applied bool
	data    []u8   // a raw generator's payload, empty for a message's
	target  string // the interface it sends on, '' when it has none
	note    string // why it cannot send, '' when it can
}

// GenControl is a run's generators, by index into `generators()`. A host that runs none answers
// every call with a refusal (NoGens).
pub interface GenControl {
mut:
	generators() []GenInfo
	gen_info(g int) !GenInfo
	gen_fire(g int, until u64) !
	gen_start(g int, cycle_ms int) !
	gen_stop(g int) !
	gen_cycle(g int, ms int) !
	gen_value(g int, signal string, value f64) !
	gen_source(g int, signal string, w project.GenCfg) !
	gen_signals(g int) ![]project.SenderSig
	gen_unset(g int, signal string) !
	gen_data(g int, data []u8) !
}

// NoGens is a host with no generator control: the GUI, whose generators are its panel's.
pub struct NoGens {}

const no_gens = 'no generators to control here: gen.* reaches the run cmd/script (or the Python package) starts'

pub fn (mut n NoGens) generators() []GenInfo {
	return []GenInfo{}
}

pub fn (mut n NoGens) gen_info(g int) !GenInfo {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_fire(g int, until u64) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_start(g int, cycle_ms int) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_stop(g int) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_cycle(g int, ms int) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_value(g int, signal string, value f64) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_source(g int, signal string, w project.GenCfg) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_signals(g int) ![]project.SenderSig {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_unset(g int, signal string) ! {
	return gen_error(.refused, no_gens)
}

pub fn (mut n NoGens) gen_data(g int, data []u8) ! {
	return gen_error(.refused, no_gens)
}

// gen_find is the generator `sel` names: its name, or `channel/name`. A selector that answers to
// more than one — two of one name, or one whose name is spelled like another's qualified form — is
// refused, naming the qualified forms that answer to one alone, else saying to reach it by
// position.
pub fn gen_find(gs []GenInfo, sel string) !int {
	hits := gen_selected(gs, sel)
	if hits.len == 1 {
		return hits[0]
	}
	if hits.len == 0 {
		names := gs.map('"${it.name}"')
		return gen_error(.refused, 'no generator "${sel}" (the run has ${if names.len == 0 {
			'none'
		} else {
			names.join(', ')
		}})')
	}
	forms := hits.map('${gs[it].channel}/${gs[it].name}').filter(gen_selected(gs, it).len == 1)
	how := if forms.len == hits.len {
		'name it as ${forms.map('"${it}"').join(' or ')}'
	} else {
		'reach it by its position in the list'
	}
	return gen_error(.refused, 'generator "${sel}" answers to ${hits.len} generators: ${how}')
}

// gen_selected is every generator `sel` answers to, by name or by `channel/name`.
fn gen_selected(gs []GenInfo, sel string) []int {
	mut out := []int{}
	for i, g in gs {
		if g.name == sel || '${g.channel}/${g.name}' == sel {
			out << i
		}
	}
	return out
}

// gen_cycle_check refuses a cycle outside 1 .. gen_cycle_max_ms.
pub fn gen_cycle_check(ms int) ! {
	if ms < 1 || ms > gen_cycle_max_ms {
		return gen_error(.refused, 'cycle ${ms} ms: a cycle is 1 .. ${gen_cycle_max_ms} ms')
	}
}

// gen_message is the generator's message in its databases, or the reason it has none to edit.
fn gen_message(s project.Sender, dbs []candb.Database) !candb.Message {
	if s.message == '' {
		return gen_error(.refused, 'generator "${s.name}" sends a raw frame: it has no signals')
	}
	for db in dbs {
		if m := db.message_named(s.message) {
			return m
		}
	}
	return gen_error(.refused, 'generator "${s.name}": message "${s.message}" is not in its channel databases')
}

// gen_signal_slot is the index of `signal` in the generator's signals — its last entry, the one
// the frame takes — appended at its static 0 when the message has it and the generator did not
// list it yet. A signal the message's payload does not hold, within the `cap` bytes a frame on the
// generator's wire carries, is refused: it would never be sent.
fn gen_signal_slot(mut s project.Sender, dbs []candb.Database, cap int, signal string) !int {
	m := gen_message(s, dbs)!
	sig := m.signal_named(signal) or {
		return gen_error(.refused, '${m.name} has no signal "${signal}"')
	}
	// a value is encoded as a 64-bit scalar: a wider signal cannot carry one
	why := sig.scalar_refusal()
	if why != '' {
		return gen_error(.refused, why)
	}
	// a generator names its signals by name, which two of one name do not tell apart
	if m.signals.filter(it.name == signal).len > 1 {
		return gen_error(.refused, '${m.name} has ${m.signals.filter(it.name == signal).len} signals named "${signal}": a generator cannot tell them apart')
	}
	// what a frame on the generator's wire carries of the message
	n := if m.payload_len() > cap { cap } else { m.payload_len() }
	if !m.holds(sig, n) {
		return gen_error(.refused, '${m.name} sends ${n} bytes, which do not hold ${signal}: it is never sent')
	}
	sw := m.multiplexor_index()
	if sig.is_multiplexed && sw >= 0 && m.signals[sw].length < 64
		&& (sig.multiplexor_value < 0 || u64(sig.multiplexor_value) >= u64(1) << m.signals[sw].length) {
		return gen_error(.refused, '${signal} is sent where ${m.signals[sw].name} is ${sig.multiplexor_value}, which its ${m.signals[sw].length} bits cannot hold: it is never sent')
	}
	for i := s.signals.len - 1; i >= 0; i-- {
		if s.signals[i].name == signal {
			return i
		}
	}
	s.signals << project.SenderSig{
		name: signal
	}
	return s.signals.len - 1
}

// gen_set_value sends `signal` at the static `value` from the next frame on, its value source
// (if it had one) dropped — the GUI's `value` pick.
pub fn gen_set_value(mut s project.Sender, dbs []candb.Database, cap int, signal string, value f64) ! {
	if math.is_nan(value) || math.is_inf(value, 0) {
		return gen_error(.refused, '${signal}: ${value} is not a value a signal can carry')
	}
	i := gen_signal_slot(mut s, dbs, cap, signal)!
	s.signals[i].value = value
	s.signals[i].wave = project.GenCfg{
		typ: ''
	}
}

// gen_set_source gives `signal` the value source `w` from the next frame on: one of
// project.wave_kinds, refused where project.gen_source_invalid finds it cannot be evaluated. The
// static value stays, as the fallback the GUI keeps.
pub fn gen_set_source(mut s project.Sender, dbs []candb.Database, cap int, signal string, w project.GenCfg) ! {
	if w.typ == '' {
		return gen_error(.refused, '${signal}: a source names its type (${project.wave_kinds.join(', ')}); a static value is gen_set_value')
	}
	why := project.gen_source_invalid(w)
	if why != '' {
		return gen_error(.refused, '${signal}: ${why}')
	}
	for v in [w.value, w.offset, w.amplitude, w.freq, w.phase, w.min, w.max, w.period, w.start,
		w.step, w.modulo, w.count, w.base] {
		if math.is_nan(v) || math.is_inf(v, 0) {
			return gen_error(.refused, '${signal}: a ${w.typ} source of non-finite parameters')
		}
	}
	i := gen_signal_slot(mut s, dbs, cap, signal)!
	mut src := w
	src.signal = signal
	s.signals[i].wave = src
}

// gen_signals is the signals generator `s` lists, each once, in the order first listed, with its
// last entry: the one its frame takes. A raw generator lists none.
pub fn gen_signals(s project.Sender) []project.SenderSig {
	mut out := []project.SenderSig{}
	mut at := map[string]int{}
	for sig in s.signals {
		if i := at[sig.name] {
			out[i] = sig
		} else {
			at[sig.name] = out.len
			out << sig
		}
	}
	return out
}

// gen_unset takes `signal` off the generator's list, every entry of its name, so from the next
// frame it carries what the message's template holds. A signal it does not list is refused.
pub fn gen_unset(mut s project.Sender, signal string) ! {
	if s.message == '' {
		return gen_error(.refused, 'generator "${s.name}" sends a raw frame: it has no signals')
	}
	if !s.signals.any(it.name == signal) {
		return gen_error(.refused, 'generator "${s.name}" lists no signal "${signal}"')
	}
	s.signals = s.signals.filter(it.name != signal)
}

// gen_set_data sends the payload `data` from the next frame: a raw generator's alone, of at most
// `cap` bytes, what a frame on its wire carries, and past 8 bytes of a length a CAN-FD DLC
// expresses, which every bus can send (a vendor backend refuses any other, a software bus pads it).
pub fn gen_set_data(mut s project.Sender, cap int, data []u8) ! {
	if s.message != '' {
		return gen_error(.refused, 'generator "${s.name}" sends message ${s.message}: set its signals, not its bytes')
	}
	if data.len > cap {
		return gen_error(.refused, 'generator "${s.name}": ${data.len} bytes, where a frame on its wire carries at most ${cap}')
	}
	if data.len !in transport.fd_lengths {
		return gen_error(.refused, 'generator "${s.name}": ${data.len} bytes is not a CAN-FD payload size — a DLC expresses ${transport.fd_lengths}')
	}
	s.data = data.clone()
}
