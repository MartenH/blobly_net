module transport

// vector_assign_checked points application channel `app` (vector:<app>) at the physical channel
// the driver lists at (hw_type, hw_index, hw_channel), as the Discover dialog's Assign does: under
// the interprocess borrow lock, the named channel and the hardware re-read inside it, refused
// where the driver cannot be used, the hardware is not a CAN channel, the application channel is
// taken or unreadable (or absent, unless `create_ok` says creating it is meant: assign_refusal),
// or the hardware has an owner already (hw_owner_refusal). The mapping persists across reboots.
// Returns the channel it now points at.
pub fn vector_assign_checked(app int, hw_type int, hw_index int, hw_channel int, create_ok bool) !VectorChannel {
	if why := vector_driver_refusal() {
		return error(why)
	}
	vector_borrow_lock_now()!
	defer {
		vector_borrow_unlock()
	}
	hw := vector_channel_of(vector_channels(), hw_type, hw_index, hw_channel) or {
		return error('the Vector driver lists no channel at hwType ${hw_type}, hwIndex ${hw_index}, hwChannel ${hw_channel}')
	}
	if !hw.can_capable {
		return error('${hw.name} is not a CAN channel — it cannot be assigned as one')
	}
	if why := assign_refusal(app, vector_app_slot(app), create_ok) {
		return error(why)
	}
	if why := hw_owner_refusal(hw, vector_mappings()) {
		return error(why)
	}
	vector_assign(app, hw)!
	return hw
}
