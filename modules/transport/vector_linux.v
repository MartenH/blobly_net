// The Linux half of vector_driver_status. There is no XL driver here — Vector ships vxlapi for
// Windows, and WSL cannot reach the Windows one — so the answer is fixed. It exists as a real
// function rather than a `$if` at the call site because the caller is asking about the machine,
// and every other backend answers that question from its own file.
module transport

// vector_driver_status: -1, the same code vector_windows.v returns for "vxlapi64.dll absent".
pub fn vector_driver_status() int {
	return -1
}

// vector_driver_path: nothing is ever loaded here. See vector_driver_status.
pub fn vector_driver_path() string {
	return ''
}

// The Linux halves. There is no XL driver here, so there is nothing to enumerate or assign.
pub struct VectorHw {
pub:
	hw_type    int
	hw_index   int
	hw_channel int
	mask       u64
}

pub fn vector_hardware() []VectorHw {
	return []
}

pub fn vector_assign(app_channel int, hw VectorChannel) ! {
	return error('the Vector XL backend is Windows-only')
}

pub struct VectorChannel {
pub:
	name        string
	transceiver string
	hw_type     int
	hw_index    int
	hw_channel  int
	serial      u32
	bus_type    u32
	bitrate     u32
	on_bus      bool
	trx_state   int
	// Mirrors the Windows struct so callers compile on both. Always false here: there is no XL
	// driver to ask, and `vector_channels()` below returns nothing anyway.
	fd_iso   bool
	fd_bosch bool
	// Mirrors the Windows field. Always false: there is no XL driver here to ask, and
	// vector_channels() returns nothing anyway.
	can_capable bool
}

// fd_capable / fd_note mirror the Windows side so a front end can call them unguarded. The
// answers are the honest ones for a machine with no XL driver: this channel list is empty, so
// nothing ever reaches them.
pub fn (c VectorChannel) fd_capable() bool {
	return c.fd_iso
}

pub fn (c VectorChannel) fd_note() string {
	return if c.fd_iso && c.fd_bosch {
		'iso+bosch'
	} else if c.fd_iso {
		'iso'
	} else if c.fd_bosch {
		'bosch-only'
	} else {
		''
	}
}

// VectorMapping mirrors the Windows type so a front end compiles unguarded. There is no XL driver
// here, so vector_mappings() is empty — the honest answer on a machine with no Vector hardware.
pub struct VectorMapping {
pub:
	hw  VectorChannel
	app int
	// Mirrors the Windows field.
}

pub fn vector_mappings() []VectorMapping {
	return []VectorMapping{}
}

// No XL driver here, so nothing can answer. False means "nothing answered", which is exactly
// true on this platform — see the Windows side for why that is evidence rather than a verdict.
pub fn vector_application_seen() !bool {
	return false
}

// No channels to sweep here, so nothing is known about any of them.
pub fn vector_app_slot(app int) AppSlot {
	return .unknown
}

pub fn vector_app_slots() []AppSlot {
	return []AppSlot{}
}

pub fn vector_error_frames() int {
	return 0
}

pub fn vector_channels() []VectorChannel {
	return []
}

pub struct VectorChipState {
pub:
	bus_status int
	tx_errors  int
	rx_errors  int
}

pub fn chip_state_of(b Bus) ?VectorChipState {
	return none
}

pub fn vector_verbose(on bool) {}

pub const vector_busy_msg = 'vector: busy'

pub fn vector_assignment(app_channel int) !(VectorChannel, bool) {
	return error('the Vector XL backend is Windows-only')
}

pub fn vector_unassign(app_channel int) ! {
	return error('the Vector XL backend is Windows-only')
}

pub fn vector_borrow_lock() ! {}

// The impatient variant the GUI uses. Both succeed here for the same reason: there is no XL
// driver, so there are no application-channel assignments for two processes to interleave and
// nothing to wait for.
//
// MIRRORED BECAUSE THE CALLER IS CROSS-PLATFORM. cmd/blobly_net compiles on Linux, and a helper
// added beside the Windows driver is invisible to it — which is the whole reason vector_names.v
// exists as a separate file. CI caught this one; the Windows build here cannot.
pub fn vector_borrow_lock_now() ! {}

pub fn vector_borrow_unlock() {}
