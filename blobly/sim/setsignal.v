// Setting one signal of a simulated node's message at run time: the rest bus as the database
// describes it, with a pedal pressed or a door opened. A value set is kept until changed or
// cleared, in a process-wide table keyed like the fault table (fault_key) and stamped onto the
// engine with the faults every pass (apply_injected), so the GUI's simulation loop and the
// headless runner both serve it. It is written after the generators and before protection, so
// the checksum covers it, and the other signals, the cycle and the alive counter stay as they are.
module sim

import blobly.candb
import math
import sync

// SetValue is one signal of a message held at a physical value.
pub struct SetValue {
pub:
	signal string
	value  f64
}

// set_values is THE table of values set on simulated messages for the process.
__global set_values = &ValueTable{}

// ValueTable is the values set on simulated messages, by fault_key, each message's in the order
// they were first set. Behind a mutex: a script writes it while a simulation loop reads it.
pub struct ValueTable {
mut:
	mu     sync.Mutex
	values map[string][]SetValue
}

// put holds `signal` of the message under `key` at `value`, replacing a value set before.
fn (mut t ValueTable) put(key string, signal string, value f64) {
	t.mu.lock()
	mut vs := t.values[key] or { []SetValue{} }
	mut i := 0
	for i < vs.len && vs[i].signal != signal {
		i++
	}
	if i < vs.len {
		vs[i] = SetValue{signal, value}
	} else {
		vs << SetValue{signal, value}
	}
	t.values[key] = vs
	t.mu.unlock()
}

// drop lets go of `signal` of the message under `key`; '' lets go of every one.
fn (mut t ValueTable) drop(key string, signal string) {
	t.mu.lock()
	vs := (t.values[key] or { []SetValue{} }).filter(signal != '' && it.signal != signal)
	if vs.len == 0 {
		t.values.delete(key)
	} else {
		t.values[key] = vs
	}
	t.mu.unlock()
}

fn (mut t ValueTable) get(key string) []SetValue {
	t.mu.lock()
	vs := t.values[key] or { []SetValue{} }
	t.mu.unlock()
	return vs
}

fn (mut t ValueTable) clear() {
	t.mu.lock()
	t.values.clear()
	t.mu.unlock()
}

// apply_to stamps the table onto an engine: each message's set values, none where nothing is set.
fn (mut t ValueTable) apply_to(iface string, mut e Engine) {
	t.mu.lock()
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].messages.len; j++ {
			k := fault_key(iface, e.ecus[i].name, e.ecus[i].messages[j].msg.name)
			e.ecus[i].messages[j].set = t.values[k] or { []SetValue{} }
		}
	}
	t.mu.unlock()
}

// set_value / clear_value / signal_values are the table's public face, keyed as faults are.
pub fn set_value(iface string, node string, msg string, signal string, value f64) {
	set_values.put(fault_key(iface, node, msg), signal, value)
}

// clear_value lets go of `signal` of the message ('' every signal of it).
pub fn clear_value(iface string, node string, msg string, signal string) {
	set_values.drop(fault_key(iface, node, msg), signal)
}

// signal_values is what is set on the message, in the order first set.
pub fn signal_values(iface string, node string, msg string) []SetValue {
	return set_values.get(fault_key(iface, node, msg))
}

// clear_signal_values lets go of every value set, on every message.
pub fn clear_signal_values() {
	set_values.clear()
}

// apply_set writes the set values onto a payload: the multiplexor switch first, since it decides
// which multiplexed signals the frame carries, then every other set signal the frame carries.
pub fn apply_set(msg candb.Message, set []SetValue, mut data []u8) {
	if set.len == 0 {
		return
	}
	sw := msg.multiplexor_index()
	if sw >= 0 {
		for v in set {
			if v.signal == msg.signals[sw].name {
				msg.signals[sw].encode(mut data, v.value)
			}
		}
	}
	carried := msg.carried(data)
	for v in set {
		for i, sig in msg.signals {
			if sig.name == v.signal {
				if i != sw && carried[i] {
					sig.encode(mut data, v.value)
				}
				break
			}
		}
	}
}

// encodable_refusal says why `value` cannot go into `sig` as it is, if it cannot: not a finite
// number, or a raw value the signal's width does not hold (the encoder would clamp it to another
// value). A value past the DBC's declared range is not refused: a tester sends one on purpose.
pub fn encodable_refusal(sig candb.Signal, value f64) ?string {
	if math.is_nan(value) || math.is_inf(value, 0) {
		return '${value} is not a value a signal can carry'
	}
	r := math.round((value - sig.offset) / sig.factor)
	if math.is_nan(r) || math.is_inf(r, 0) {
		return '${value} has no raw value in "${sig.name}" (factor ${sig.factor})'
	}
	if sig.length <= 0 || sig.length > 64 {
		return '"${sig.name}" is ${sig.length} bits wide'
	}
	lo, hi := raw_bounds(sig)
	if r < lo || r > hi {
		kind := if sig.is_signed { 'signed' } else { 'unsigned' }
		a, b := phys_of(sig, lo), phys_of(sig, hi)
		return '${value} is past what the ${sig.length}-bit ${kind} "${sig.name}" holds (${math.min(a, b)} .. ${math.max(a, b)})'
	}
	return none
}

// raw_bounds is the raw integer range a signal's width holds, as f64.
fn raw_bounds(sig candb.Signal) (f64, f64) {
	if sig.is_signed {
		top := math.pow(2, f64(sig.length - 1))
		return -top, top - 1
	}
	return 0, math.pow(2, f64(sig.length)) - 1
}

// phys_of is a raw bound as the physical value it decodes to.
fn phys_of(sig candb.Signal, raw f64) f64 {
	return raw * sig.factor + sig.offset
}

// set_signal holds `signal` of `node`'s `msg` on this channel at `value` from the next frame on,
// until changed or cleared. Refused, with nothing stored: a channel nothing simulates on, a node
// not simulated here, a message it does not send, a signal the message does not have, one its
// protection overwrites or its payload does not hold, and a value the signal cannot carry.
pub fn (t FaultTarget) set_signal(node string, msg string, signal string, value f64) ! {
	sig := t.settable(node, msg, signal)!
	if why := encodable_refusal(sig, value) {
		return error('${signal} on "${msg}": ${why}')
	}
	set_value(t.iface, node, msg, signal, value)
}

// clear_signal lets go of the value set on `signal` of `node`'s `msg` on this channel ('' every
// signal of it), which then goes out from the project's source again; refused as set_signal
// refuses a node, message or signal.
pub fn (t FaultTarget) clear_signal(node string, msg string, signal string) ! {
	if signal == '' {
		t.sent_by(node, msg)!
	} else {
		t.settable(node, msg, signal)!
	}
	clear_value(t.iface, node, msg, signal)
}

// sent_by is `node`'s messages named `msg` on this channel, refused when there is none to simulate.
fn (t FaultTarget) sent_by(node string, msg string) ![]candb.Message {
	if t.not_can != '' {
		return error('"${t.channel}" is a ${t.not_can} channel — nothing simulates on it')
	}
	if !t.nodes.any(it.name == node) {
		return error('"${node}" is not simulated on ${t.channel}')
	}
	m := t.db.messages_from(node).filter(it.name == msg)
	if m.len == 0 {
		return error('"${node}" does not send "${msg}" on ${t.channel}')
	}
	return m
}

// settable is `signal` of `node`'s `msg` where a value set on it reaches the wire: the message
// has it, protection does not overwrite it and the payload holds it.
fn (t FaultTarget) settable(node string, msg string, signal string) !candb.Signal {
	ms := t.sent_by(node, msg)!
	prot := t.protection(node, msg)
	if signal != '' && (signal == prot.counter || signal == prot.crc) {
		return error('"${signal}" on "${msg}" is stamped by its E2E protection, which overwrites a value set on it')
	}
	mut found := ?candb.Signal(none)
	for m in ms {
		s := m.signal_named(signal) or { continue }
		if why := past_payload(m, signal) {
			return error('${why} — a value set on it would change nothing')
		}
		if found == none {
			found = s
		}
	}
	return found or { error('"${msg}" has no signal "${signal}"') }
}
