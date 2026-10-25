module transport

// CarrierGone is a receive that failed because the CARRIER can deliver nothing more: a bus
// closed or never opened, a socket not open or its interface gone or down (`carrier_errno` on
// Linux), a shared wire whose driver failed, a DoIP connection closed or out of step. Not a
// timeout, and not one frame or PDU that failed to parse: a caller draining what is queued (uds's pre-send drain)
// reads the type to stop and pass the failure on, rather than count the error as one more item
// taken off the channel. The message is the backend's own, unchanged.
pub struct CarrierGone {
	Error
pub:
	msg string
}

pub fn (e CarrierGone) msg() string {
	return e.msg
}

// carrier_gone is the error a receive returns when its carrier is gone.
pub fn carrier_gone(msg string) IError {
	return CarrierGone{
		msg: msg
	}
}
