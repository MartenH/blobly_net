// kvaser_windows.v — Kvaser CANlib backend (real CAN hardware on Windows),
// implementing the platform-agnostic `Bus` interface. Windows-only (`_windows.v`
// suffix gates compilation). canlib32.dll (shipped with the free Kvaser drivers) is
// loaded at RUNTIME via kvaser_shim.h — no SDK, no import lib.
//
// Interface string: `kvaser:<channel>[@<bitrate>]`
//   channel : Kvaser channel number (0,1,…). Virtual channels (available once the
//             Kvaser drivers are installed, NO hardware needed) appear as channel
//             numbers too — find them in the Kvaser Device Guide.
//   bitrate : bits/s (default 500000)  e.g. kvaser:0@250000
//
// Because Kvaser offers software virtual channels, this backend can be verified
// end-to-end with no physical adapter (open two handles on the same virtual channel
// number, send on one, recv on the other). See docs/windows_can_hardware.md.
//
// NOTE: written from the documented CANlib ABI; NOT yet verified against hardware.
// Compile-checked via the Windows CI.
module transport

#include "kvaser_shim.h"

fn C.ct_kvaser_load() int
fn C.ct_kvaser_open(int, int) int
fn C.ct_kvaser_write(int, u32, u8, &u8, int) int
fn C.ct_kvaser_read(int, &u32, &u8, &u8, &int, u32) int
fn C.ct_kvaser_close(int)
fn C.ct_kvaser_count() int
fn C.ct_kvaser_descr(int, &char, int) int

// KvaserBus is one open + bus-on CANlib channel handle.
pub struct KvaserBus {
mut:
	handle int
}

// open_kvaser parses `kvaser:<channel>[@<bitrate>]`, loads canlib32.dll, opens the
// channel and goes bus-on. Referenced only from open_windows.v.
pub fn open_kvaser(spec string) !&KvaserBus {
	parts := spec.split('@')
	ch := parts[0].trim_space().int()
	bitrate := if parts.len > 1 { parts[1].int() } else { 500000 }
	code := kvaser_bitrate_code(bitrate)!
	if C.ct_kvaser_load() != 0 {
		return error('canlib32.dll not found — install the Kvaser drivers')
	}
	hnd := C.ct_kvaser_open(ch, code)
	if hnd < 0 {
		return error('canOpenChannel/SetBusParams/BusOn failed on channel ${ch} (canStatus ${hnd})')
	}
	return &KvaserBus{
		handle: hnd
	}
}

pub fn (mut b KvaserBus) send(f CanFrame) ! {
	// CAN-FD is not implemented on this backend: the vendor call below writes a classic frame,
	// so an FD frame would go out truncated and report success. Refuse — a bench that silently
	// changes what it transmits is worse than one that stops.
	if f.fd {
		return error('Kvaser: CAN-FD frames are not supported by this backend yet (id 0x${f.id:X}, ${f.data.len} bytes)')
	}
	mut n := f.data.len
	if n > 8 {
		n = 8
	}
	ext := if f.extended { 1 } else { 0 }
	st := C.ct_kvaser_write(b.handle, f.id, u8(n), f.data.data, ext)
	if st < 0 {
		return error('canWrite failed (canStatus ${st})')
	}
}

pub fn (mut b KvaserBus) recv(timeout_ms int) !CanFrame {
	// canReadWait takes an unsigned timeout; map "block forever" (negative) to a
	// large value, since the Bus contract allows timeout_ms < 0 = block.
	to := if timeout_ms < 0 { u32(0xFFFF_FFFF) } else { u32(timeout_ms) }
	mut id := u32(0)
	mut ln := u8(0)
	mut ext := 0
	mut data := [8]u8{}
	r := C.ct_kvaser_read(b.handle, &id, &ln, &data[0], &ext, to)
	if r == 1 {
		return error('timeout')
	}
	if r < 0 {
		return error('canReadWait failed (canStatus ${r})')
	}
	mut out := []u8{len: int(ln)}
	for i in 0 .. int(ln) {
		out[i] = data[i]
	}
	return CanFrame{
		id:       id & 0x1FFF_FFFF
		extended: ext != 0
		data:     out
	}
}

pub fn (mut b KvaserBus) close() {
	C.ct_kvaser_close(b.handle)
}

// kvaser_bitrate_code maps a bit rate to a canBITRATE_* code (negative constants
// CANlib accepts directly as the freq arg of canSetBusParams).
fn kvaser_bitrate_code(bitrate int) !int {
	return match bitrate {
		1000000 { -1 } // canBITRATE_1M
		500000 { -2 }  // canBITRATE_500K
		250000 { -3 }  // canBITRATE_250K
		125000 { -4 }  // canBITRATE_125K
		100000 { -5 }  // canBITRATE_100K
		62500 { -6 }   // canBITRATE_62K
		50000 { -7 }   // canBITRATE_50K
		83000 { -8 }   // canBITRATE_83K
		10000 { -9 }   // canBITRATE_10K
		else { error('unsupported Kvaser bitrate ${bitrate} (use 10k/50k/62k/83k/100k/125k/250k/500k/1M)') }
	}
}

// kvaser_list enumerates attached Kvaser channels (physical + virtual) for discovery.
// Returns [] when canlib32.dll is absent (drivers not installed) or has no channels.
fn kvaser_list() []Iface {
	mut out := []Iface{}
	n := C.ct_kvaser_count()
	if n <= 0 {
		return out
	}
	for ch in 0 .. n {
		mut buf := [64]u8{}
		ptr := unsafe { &char(&buf[0]) }
		mut name := 'Kvaser ch${ch}'
		if C.ct_kvaser_descr(ch, ptr, 64) == 0 {
			d := unsafe { cstring_to_vstring(ptr) }.trim_space()
			if d != '' {
				name = '${d} (ch${ch})'
			}
		}
		out << Iface{
			name:    name
			iface:   'kvaser:${ch}'
			kind:    'can'
			virtual: false
		}
	}
	return out
}
