// settings.v — what a software channel chooses for itself on the wire: the padding of the frames it
// sends, the Flow Control it answers a First Frame with as a receiver (#635, #636), the length of
// the frames it sends a long message in (TX_DL, #637) and their format (#608). One rule
// (`settings_with`) for every host that states them: the Lua uds.open / isotp.open, bb.h's
// bb_isotp_check_settings and Python's ch.uds / ch.isotp keywords.
module isotp

import math
import blobly.transport

// tx_dls are the frame lengths a channel may send in (ISO 15765-2:2016's TX_DL): 8 a classic
// frame, the rest CAN-FD.
pub const tx_dls = [8, 12, 16, 20, 24, 32, 48, 64]

// no_padding is the padding a host states for frames as long as their content.
pub const no_padding = -1

// Settings is a software channel's own choices. The zero value of each field but `padded` is the
// default; `Settings{}` is what a channel does when nothing is stated: 8-byte frames padded with
// 0x00 in the row's declared format, and a Flow Control of 30 00 00 (block size 0, STmin 0).
pub struct Settings {
pub:
	padded     bool = true // every frame padded to 8 bytes; false: each as long as its content
	pad        u8 // the padding byte, when padded
	block_size u8 // Consecutive Frames asked for per block; 0 is the whole remainder at once
	stmin      u8 // the STmin code asked for (stmin_code)
	tx_dl      u8 = 8 // the length of the frames a long message is sent in (tx_dls)
	format     transport.FrameFormat // the format stated on every frame sent; .wire states none
}

// is_default is whether `s` is what a channel does when nothing is stated.
pub fn (s Settings) is_default() bool {
	return s == Settings{}
}

// padding is the padding as a host states it: the byte, or no_padding.
pub fn (s Settings) padding() int {
	return if s.padded { int(s.pad) } else { no_padding }
}

// stmin_ms is the STmin asked for in milliseconds, as a host states it (stmin_code's inverse).
pub fn (s Settings) stmin_ms() f64 {
	return f64(stmin_micros(s.stmin)) / 1000.0
}

// settings_of is settings_with at the default TX_DL and format.
pub fn settings_of(padding i64, block_size i64, stmin_ms f64) !Settings {
	return settings_with(padding, block_size, stmin_ms, 8, .wire)
}

// settings_with is what a host states, checked: `padding` a byte 0..255 or no_padding, `block_size`
// 0..255, `stmin_ms` as stmin_code reads it, `tx_dl` one of tx_dls, and a classic `format` only
// with a TX_DL of 8 (a classic frame carries at most 8 bytes, as FrameFormat.stamp refuses).
pub fn settings_with(padding i64, block_size i64, stmin_ms f64, tx_dl i64, format transport.FrameFormat) !Settings {
	if tx_dl !in tx_dls.map(i64(it)) {
		return error('tx_dl ${tx_dl}: give 8, 12, 16, 20, 24, 32, 48 or 64')
	}
	if format == .classic && tx_dl > 8 {
		return error('tx_dl ${tx_dl} with format classic: a classic frame carries at most 8 bytes — choose fd or fd_brs')
	}
	if padding != no_padding && (padding < 0 || padding > 0xFF) {
		return error('padding ${padding}: give a byte 0 .. 255, or none for frames as long as their content')
	}
	if block_size < 0 || block_size > 0xFF {
		return error('block_size ${block_size}: give 0 .. 255 (0 asks for the whole remainder at once)')
	}
	return Settings{
		padded:     padding != no_padding
		pad:        if padding == no_padding { u8(0) } else { u8(padding) }
		block_size: u8(block_size)
		stmin:      stmin_code(stmin_ms)!
		tx_dl:      u8(tx_dl)
		format:     format
	}
}

// row_refusal is why these settings cannot be used on a row that declares CAN-FD (`row_fd`) or
// not: a TX_DL above 8 needs CAN-FD frames, stated by `format` or declared by the row.
pub fn (s Settings) row_refusal(row_fd bool) ?string {
	if s.tx_dl > 8 && s.format == .wire && !row_fd {
		return 'tx_dl ${s.tx_dl} on a classic row: a frame longer than 8 bytes is CAN-FD — declare the row CAN-FD, or state format fd or fd_brs'
	}
	return none
}

// stmin_code is the STmin byte for a separation of `ms` milliseconds: a whole 0 .. 127 is
// 0x00 .. 0x7F, and 0.1 .. 0.9 the 100 .. 900 µs codes 0xF1 .. 0xF9 (stmin_micros reads it back).
// Nothing else is a separation ISO 15765-2 lets a receiver ask for.
pub fn stmin_code(ms f64) !u8 {
	if !math.is_nan(ms) && !math.is_inf(ms, 0) {
		if ms > 0 && ms < 1 {
			tenths := math.round(ms * 10)
			if math.abs(ms * 10 - tenths) < 1e-9 && tenths >= 1 && tenths <= 9 {
				return u8(0xF0 + int(tenths))
			}
		} else if ms >= 0 && ms <= 127 && ms == math.floor(ms) {
			return u8(int(ms))
		}
	}
	return error('stmin_ms ${ms}: give a whole 0 .. 127 ms, or 0.1 .. 0.9 for 100 .. 900 µs')
}
