module script

import math
import blobly.isotp
import blobly.lua

// int_arg is argument i as an integer in lo..hi, a whole-number float as its integer; else an
// error naming the argument (`what`) and what was given. For an identity or a handle, to which 0
// is a value, so a nil, a string (numeric or not) or 1.5 must not become one.
fn int_arg(l lua.State, i int, what string, lo i64, hi i64) !i64 {
	return read_int(l, i, what, lo, hi, false)
}

// id_arg is int_arg for an identifier, its value and range written in hex.
fn id_arg(l lua.State, i int, what string, lo i64, hi i64) !i64 {
	return read_int(l, i, what, lo, hi, true)
}

fn read_int(l lua.State, i int, what string, lo i64, hi i64, hex bool) !i64 {
	v := if l.arg_is_number(i) { l.arg_int_exact(i) } else { none }
	n := v or { return error('${what} is ${l.arg_given(i)}, not an integer') }
	if n < lo || n > hi {
		return error('${what} ${int_text(n, hex)} is outside ${int_text(lo, hex)}..${int_text(hi, hex)}')
	}
	return n
}

// int_text is v in decimal, or in hex when it is a non-negative identifier.
fn int_text(v i64, hex bool) string {
	return if hex && v >= 0 { '0x${v:X}' } else { v.str() }
}

// handle_arg is argument i as a handle a primitive answered (an index into its table).
fn handle_arg(l lua.State, i int, what string) !int {
	return int(int_arg(l, i, what, 0, max_i32)!)
}

// can_id_arg is argument i as a CAN identifier, 11- or 29-bit (the frame's width is the
// transport's to check against its ext flag).
fn can_id_arg(l lua.State, i int) !u32 {
	return u32(id_arg(l, i, 'the id', 0, 0x1FFF_FFFF)!)
}

// byte_arg is argument i as one request byte.
fn byte_arg(l lua.State, i int, what string) !u8 {
	return u8(int_arg(l, i, what, 0, 0xFF)!)
}

// did_id_arg is argument i as a 16-bit data identifier.
fn did_id_arg(l lua.State, i int) !u16 {
	return u16(id_arg(l, i, 'the DID', 0, 0xFFFF)!)
}

// conn_arg is the open UDS connection argument i names, and its handle.
fn (mut env Env) conn_arg(l lua.State, i int) !(&UdsConn, int) {
	h := handle_arg(l, i, 'the uds handle')!
	c := env.conn(h) or { return error('the uds handle ${h} is not an open connection') }
	return c, h
}

// ms_up is argument i as a wait or a duration in whole milliseconds, a fraction rounded UP (a
// wait of 0.5 ms is not a look), a negative one -1 (for ever, where the reader has one) and
// anything not a number 0; capped at what a backend's int wait holds (about 24 days).
fn ms_up(l lua.State, i int) i64 {
	f := l.arg_num(i)
	if f < 0 {
		return -1
	}
	if !(f > 0) {
		return 0
	}
	return i64(math.ceil(math.min(f, f64(max_i32))))
}

// isotp_settings_arg is arguments i .. i+2 as an ISO-TP channel's settings (isotp.settings_of):
// padding a byte or false for none, block_size, stmin_ms; nil or absent is the default of each.
fn isotp_settings_arg(l lua.State, i int) !isotp.Settings {
	mut padding := i64(0)
	if l.arg_is_bool(i) && !l.arg_bool(i) {
		padding = isotp.no_padding
	} else if !l.arg_absent(i) {
		padding = read_int(l, i, 'padding', 0, 0xFF, true) or {
			return error('padding is ${l.arg_given(i)}, not a byte or false')
		}
	}
	block_size := if l.arg_absent(i + 1) {
		i64(0)
	} else {
		int_arg(l, i + 1, 'block_size', min_i64, max_i64)!
	}
	mut stmin_ms := 0.0
	if !l.arg_absent(i + 2) {
		if !l.arg_is_number(i + 2) {
			return error('stmin_ms is ${l.arg_given(i + 2)}, not a number')
		}
		stmin_ms = l.arg_num(i + 2)
	}
	return isotp.settings_of(padding, block_size, stmin_ms)!
}
