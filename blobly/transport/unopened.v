module transport

// UnopenedBus is the Bus a field holds before its bus is opened. V leaves an uninitialised
// interface field nil, and a read of it before the open crashes; this answers as a closed bus
// instead — the same choice SharedNoDriver makes for a shared wire still opening (#147's hazard,
// made loud). A sender gets `not_written`, so nothing reads it as a frame that went out.
pub struct UnopenedBus {}

pub fn (mut b UnopenedBus) send(_ CanFrame) ! {
	return not_written('bus is not open')
}

pub fn (mut b UnopenedBus) recv(_ int) !CanFrame {
	return error('bus is not open')
}

pub fn (mut b UnopenedBus) close() {}

pub fn (mut b UnopenedBus) health() BusHealth {
	return .unknown
}

pub fn (mut b UnopenedBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

pub fn (mut b UnopenedBus) reconcile_silence(_ bool) ! {
	return error('bus is not open')
}
