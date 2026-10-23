// The DBC catalog a script reads: a channel's messages and signals as its databases define them
// (dbc.messages / dbc.message / dbc.signal in the prelude), from the candb model decode and
// bus.send_message use, so nothing reads a database a second time.
module script

import blobly.lua
import blobly.candb

// push_message leaves a message's description on the stack: name, id, ext, dlc (the length an
// encoding has), j1939 (the database declares it), and its signals in their order.
fn push_message(l lua.State, m candb.Message) {
	l.new_table()
	l.set_str('name', m.name)
	l.set_int('id', m.id)
	l.set_bool('ext', m.ext)
	l.set_int('dlc', m.payload_len())
	l.set_bool('j1939', m.j1939)
	l.new_table()
	for i, s in m.signals {
		push_signal(l, s)
		l.set_index(i + 1)
	}
	l.set_field('signals')
}

// push_signal leaves a signal's description on the stack. `labels` is the value table keyed by
// the physical value decode reads for each raw key (the first entry where two keys give one
// value), `raw_labels` keyed by the raw key itself: the field's bits as a Lua integer, which
// decode(..., "raw") returns.
fn push_signal(l lua.State, s candb.Signal) {
	l.new_table()
	l.set_str('name', s.name)
	l.set_int('start_bit', s.start_bit)
	l.set_int('length', s.length)
	l.set_str('byte_order', if s.byte_order == .big_endian { 'big' } else { 'little' })
	l.set_bool('signed', s.is_signed)
	l.set_num('factor', s.factor)
	l.set_num('offset', s.offset)
	l.set_num('minimum', s.minimum)
	l.set_num('maximum', s.maximum)
	l.set_str('unit', s.unit)
	l.set_bool('multiplexor', s.is_multiplexor)
	l.set_bool('multiplexed', s.is_multiplexed)
	if s.is_multiplexed {
		l.set_int('mux_value', s.multiplexor_value)
	}
	l.new_table()
	mut seen := []f64{}
	for raw, text in s.values {
		v := s.phys_from_raw(raw)
		if v != v || v in seen {
			continue
		}
		seen << v
		l.push_str(text)
		l.set_numkey(v)
	}
	l.set_field('labels')
	l.new_table()
	for raw, text in s.values {
		l.push_str(text)
		l.set_index(i64(raw))
	}
	l.set_field('raw_labels')
}

// __dbc_messages(channel): every message of the channel's databases, described, in their order.
fn l_dbc_messages(l lua.State) i32 {
	env := env_of(l)
	ci := env.find_chan(l.arg_str(1)) or { return l.fail(err.msg()) }
	l.new_table()
	for i, m in env.chans[ci].db.messages {
		push_message(l, m)
		l.set_index(i + 1)
	}
	return 1
}

// __dbc_message(channel, by_id, key, ext): one message, by name or by id as decode finds it; nil
// for none.
fn l_dbc_message(l lua.State) i32 {
	env := env_of(l)
	ci := env.find_chan(l.arg_str(1)) or { return l.fail(err.msg()) }
	db := env.chans[ci].db
	found := if l.arg_bool(2) {
		db.lookup_frame(u32(l.arg_int(3)), l.arg_bool(4))
	} else {
		db.message_named(l.arg_str(3))
	}
	m := found or {
		l.push_nil()
		return 1
	}
	push_message(l, m)
	return 1
}

// DecodeAs is what decode reports for each signal a frame carries.
enum DecodeAs {
	physical // raw * factor + offset
	raw      // the field's bits, the key raw_labels is keyed by
	label    // the value table's text for the raw value; a signal with none is left out
}

fn decode_as(mode string) !DecodeAs {
	return match mode {
		'', 'physical' { .physical }
		'raw' { .raw }
		'label' { .label }
		else { error('decode: no mode "${mode}" (physical, raw or label)') }
	}
}

// __decode(channel, id, ext, data, as): { Signal = value } for each signal the frame carries
// (Message.active_signals), or nil for a frame of no message.
fn l_decode(l lua.State) i32 {
	mut env := env_of(l)
	ci := env.find_chan(l.arg_str(1)) or { return l.fail(err.msg()) }
	mode := decode_as(l.arg_str(5)) or { return l.fail(err.msg()) }
	data := l.arg_bytes(4)
	msg := env.chans[ci].db.lookup_frame(u32(l.arg_int(2)), l.arg_bool(3)) or {
		l.push_nil()
		return 1
	}
	l.new_table()
	for s in msg.active_signals(data) {
		match mode {
			.physical {
				l.set_num(s.name, s.physical(data))
			}
			.raw {
				l.set_int(s.name, i64(s.raw_value(data)))
			}
			.label {
				raw := s.raw_value(data)
				if raw in s.values {
					l.set_str(s.name, s.values[raw])
				}
			}
		}
	}
	return 1
}
