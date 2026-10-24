// ifaces.v — bb.h's "Interfaces" block: what is present to open (transport.interfaces, a CANsub
// browse) and the Vector channels with their assignments, each a listing the host reads row by
// row and then frees; and Vector assignment by transport.vector_assign_checked, the Discover
// dialog's rule.
module main

import blobly.transport

// Listing is what one listing call found: interfaces, or Vector channels.
struct Listing {
	ifaces []transport.Interface
	vector []transport.VectorMapping
	note   string
}

__global (
	bb_listings     map[int]Listing
	bb_listing_next int
)

// keep_listing holds `l` for the host and answers its handle.
fn keep_listing(l Listing) i32 {
	bb_mu.lock()
	id := bb_listing_next
	bb_listing_next++
	bb_listings[id] = l
	bb_mu.unlock()
	ok()
	return i32(id)
}

fn listing(list i32) ?Listing {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	return bb_listings[int(list)] or { return none }
}

@[export: 'bb_ifaces']
pub fn bb_ifaces() i32 {
	return keep_listing(Listing{
		ifaces: transport.interfaces()
	})
}

@[export: 'bb_ifaces_cansub']
pub fn bb_ifaces_cansub(window_ms i32) i32 {
	rows, note := transport.discover_cansub_within(int(window_ms)) or {
		return fail(bb_err, 'CANsub browse: ${err.msg()}')
	}
	return keep_listing(Listing{
		ifaces: rows
		note:   note
	})
}

@[export: 'bb_vector_hardware']
pub fn bb_vector_hardware() i32 {
	if _ := transport.vector_driver_refusal() {
		return keep_listing(Listing{})
	}
	return keep_listing(Listing{
		vector: transport.vector_mappings()
	})
}

@[export: 'bb_listing_count']
pub fn bb_listing_count(list i32) i32 {
	l := listing(list) or { return fail(bb_err_handle, 'no listing ${list}') }
	return ok_count(l.ifaces.len + l.vector.len)
}

@[export: 'bb_listing_note']
pub fn bb_listing_note(list i32, buf &char, cap i32) i32 {
	l := listing(list) or { return fail(bb_err_handle, 'no listing ${list}') }
	return put(l.note, buf, cap)
}

// iface_row is row `i` of interface listing `list`.
fn iface_row(list i32, i i32) !transport.Interface {
	l := listing(list) or { return error_with_code('no listing ${list}', int(bb_err_handle)) }
	if i < 0 || int(i) >= l.ifaces.len {
		return error('interface ${i}: listing ${list} has ${l.ifaces.len}')
	}
	return l.ifaces[int(i)]
}

@[export: 'bb_iface_info']
pub fn bb_iface_info(list i32, i i32, out &C.bb_iface) i32 {
	if isnil(out) {
		return fail(bb_err, 'iface info: nowhere to put it')
	}
	f := iface_row(list, i) or { return refused(err) }
	unsafe {
		out.fd = match f.fd {
			.unknown { i32(C.BB_FD_UNKNOWN) }
			.no { i32(C.BB_FD_NO) }
			.yes { i32(C.BB_FD_YES) }
		}
		out.bitrate = i32(f.bitrate)
		out.is_virtual = u8(f.virtual)
	}
	return ok()
}

@[export: 'bb_iface_text']
pub fn bb_iface_text(list i32, i i32, which i32, buf &char, cap i32) i32 {
	f := iface_row(list, i) or { return refused(err) }
	s := match which {
		i32(C.BB_IFACE_ADDRESS) { f.address }
		i32(C.BB_IFACE_KIND) { f.kind }
		i32(C.BB_IFACE_DESC) { f.desc }
		i32(C.BB_IFACE_STATE) { f.state }
		else { return fail(bb_err, 'iface text: no field ${which}') }
	}
	return put(s, buf, cap)
}

// vector_row is row `i` of Vector listing `list`.
fn vector_row(list i32, i i32) !transport.VectorMapping {
	l := listing(list) or { return error_with_code('no listing ${list}', int(bb_err_handle)) }
	if i < 0 || int(i) >= l.vector.len {
		return error('Vector channel ${i}: listing ${list} has ${l.vector.len}')
	}
	return l.vector[int(i)]
}

@[export: 'bb_vector_info']
pub fn bb_vector_info(list i32, i i32, out &C.bb_vector_hw) i32 {
	if isnil(out) {
		return fail(bb_err, 'vector info: nowhere to put it')
	}
	m := vector_row(list, i) or { return refused(err) }
	unsafe {
		out.hw_type = i32(m.hw.hw_type)
		out.hw_index = i32(m.hw.hw_index)
		out.hw_channel = i32(m.hw.hw_channel)
		out.serial = m.hw.serial
		out.bitrate = m.hw.bitrate
		out.app = i32(m.app)
		out.owner_known = u8(m.owner_known)
		out.can = u8(m.hw.can_capable)
		out.fd_iso = u8(m.hw.fd_iso)
		out.fd_bosch = u8(m.hw.fd_bosch)
		out.on_bus = u8(m.hw.on_bus)
	}
	return ok()
}

@[export: 'bb_vector_text']
pub fn bb_vector_text(list i32, i i32, which i32, buf &char, cap i32) i32 {
	m := vector_row(list, i) or { return refused(err) }
	s := match which {
		i32(C.BB_VECTOR_NAME) { m.hw.name }
		i32(C.BB_VECTOR_TRANSCEIVER) { m.hw.transceiver }
		else { return fail(bb_err, 'vector text: no field ${which}') }
	}
	return put(s, buf, cap)
}

@[export: 'bb_listing_free']
pub fn bb_listing_free(list i32) i32 {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if int(list) !in bb_listings {
		return fail(bb_err_handle, 'no listing ${list}')
	}
	bb_listings.delete(int(list))
	return ok()
}

@[export: 'bb_vector_driver']
pub fn bb_vector_driver(buf &char, cap i32) i32 {
	return put(transport.vector_driver_refusal() or { '' }, buf, cap)
}

@[export: 'bb_vector_slot']
pub fn bb_vector_slot(app i32) i32 {
	if why := transport.vector_driver_refusal() {
		return fail(bb_err, why)
	}
	if app < 1 || app > 64 {
		return fail(bb_err, 'Vector application channels are numbered 1 to 64, not ${app}')
	}
	return ok_count(match transport.vector_app_slot(int(app)) {
		.unreadable { int(C.BB_VECTOR_UNREADABLE) }
		.absent { int(C.BB_VECTOR_ABSENT) }
		.empty { int(C.BB_VECTOR_EMPTY) }
		.taken { int(C.BB_VECTOR_TAKEN) }
	})
}

@[export: 'bb_vector_assign']
pub fn bb_vector_assign(app i32, hw_type i32, hw_index i32, hw_channel i32, create i32) i32 {
	transport.vector_assign_checked(int(app), int(hw_type), int(hw_index), int(hw_channel),
		create != 0) or { return fail(bb_err, 'vector assign: ${err.msg()}') }
	return ok()
}
