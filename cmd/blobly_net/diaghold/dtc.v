module diaghold

// dtc.v — the DTC tab's rules: when its auto-refresh reads the list again, what of an auto-refresh
// is said in the log, and which session a DTC-setting press has to establish first.

// autorefresh_ms is how often the DTC tab's auto-refresh reads the DTC list.
pub const autorefresh_ms = 2000

// autorefresh_due: the tab asks for its list again — the tick is on, the tab is on screen, no
// press is in flight (a refresh queued behind one would only repeat it), and the last read of
// this target is `autorefresh_ms` old. `last_ms` 0 means never read: due at once.
pub fn autorefresh_due(on bool, shown bool, busy bool, last_ms i64, now_ms i64) bool {
	if !on || !shown || busy {
		return false
	}
	return last_ms == 0 || now_ms - last_ms >= autorefresh_ms
}

// autorefresh_logged: an auto-refresh is said in the log only when it read something other than
// the last read did, or failed — a line every two seconds saying nothing changed would bury the
// presses. A press is always said.
pub fn autorefresh_logged(auto bool, failed bool, prev string, now string) bool {
	return !auto || failed || prev != now
}

// dtc_setting_session is the session a ControlDTCSetting (0x85) press switches to first: the
// extended one, for turning the setting OFF when the connection is in the default session or none
// is known — the service is served in the non-default sessions only (ISO 14229-1's default, and
// blobly_emb's). Turning it ON never switches: entering the default session turns it on already,
// so in the default session there is nothing to turn on, and the ECU's refusal says so. 0 = stay.
pub fn dtc_setting_session(session u8, on bool) u8 {
	if on {
		return 0
	}
	return if session == 0 || session == default_session { u8(0x03) } else { u8(0) }
}

// Deferred is what becomes of a DTC row clicked while a press was in flight.
pub enum Deferred {
	none // nothing deferred
	wait // still in flight: ask later
	send // ask for its records now
	drop // the target changed since the click: that row was another ECU's, never asked of this one
}

// deferred_selection decides a deferred row click: asked only of the target it was clicked on
// (`clicked_key`, captured at the click), once nothing is in flight, and dropped the moment the
// selected target is another.
pub fn deferred_selection(pending bool, busy bool, clicked_key string, selected_key string) Deferred {
	if !pending {
		return .none
	}
	if clicked_key != selected_key {
		return .drop
	}
	return if busy { Deferred.wait } else { Deferred.send }
}
