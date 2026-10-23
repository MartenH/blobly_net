module sim

import math
import blobly.candb
import blobly.project

// gencontrol.v — a running generator controlled from a script (Lua's gen.*, Python's
// Project.generators): what a script is told about one, the rules an edit is held to, and the
// interface the run that owns the generators answers (headless.Run). The edits are the ones the
// GUI's Generators panel makes: fire, cyclic on and off, the cycle, a signal's value or source.

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
	target   string // the interface it sends on, '' when it has none
	note     string // why it cannot send, '' when it can
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
