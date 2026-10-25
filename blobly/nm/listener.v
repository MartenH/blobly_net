module nm

// Listener is a script's NM reading of one channel: a Tracker fed the frames the script's own
// handle reads, and the moment up to which it has read them. The reading is taken at that moment
// (`at_ms`), never at the wall clock's now: a channel nobody has read for a while reads as it was
// at its last read, not as asleep, since what it carries meanwhile is still queued unread.
pub struct Listener {
pub mut:
	trk   Tracker
	at_ms f64 // the handle's latest read: a frame's receive time, or a read that found nothing
	// what moved() last answered for: the cluster's frames (parsed, malformed, dropped) and the moment
	asked_frames u64
	asked_ms     f64 = -1.0
}

// ask_ms is how far the reading's moment may move before a wait asks about it again.
pub const ask_ms = 5.0

pub fn new_listener(cfg Config) &Listener {
	return &Listener{
		trk: new_tracker(cfg)
	}
}

// feed gives the listener a frame its handle read, at its receive time. A remote frame carries
// no PDU; a frame outside the cluster only moves the reading's moment on.
pub fn (mut l Listener) feed(id u32, ext bool, rtr bool, data []u8, t_ms f64) {
	if !rtr {
		l.trk.note(id, ext, data, t_ms)
	}
	if t_ms > l.at_ms {
		l.at_ms = t_ms
	}
}

// idle: a read of the handle found nothing queued at `now_ms`, so the reading is complete to then.
pub fn (mut l Listener) idle(now_ms f64) {
	if now_ms > l.at_ms {
		l.at_ms = now_ms
	}
}

// moved: the reading may have changed since the last moved() said so — a frame in the cluster
// came (parsed or not), or its
// moment moved on by ask_ms. A frame of another id moves the reading only by its time, so a wait
// on a busy wire need not build a reading per frame.
pub fn (mut l Listener) moved() bool {
	seen := l.trk.frames + l.trk.malformed + l.trk.dropped
	if seen == l.asked_frames && l.asked_ms >= 0 && l.at_ms - l.asked_ms < ask_ms {
		return false
	}
	l.asked_frames = seen
	l.asked_ms = l.at_ms
	return true
}

// reading is the cluster as read up to the handle's latest read, with no timeline columns.
pub fn (l &Listener) reading() View {
	return l.trk.view(l.at_ms, 0)
}

// explicit is the configuration a script states: an inclusive id range (29-bit at most, lo at or
// below hi; a range above 0x7FF is 29-bit, `ext` says so below it) and a timeout of 1 ms to a
// minute — the rule a row's own `nm:` is read by (project.parse_nm). It declares no node.
pub fn explicit(lo i64, hi i64, ext bool, timeout_ms i64) !Config {
	if lo < 0 || hi < 0 || lo > 0x1FFFFFFF || hi > 0x1FFFFFFF {
		return error('an NM range is of CAN ids, 0..0x1FFFFFFF: lo ${lo}, hi ${hi}')
	}
	if lo > hi {
		return error('the NM range lo 0x${lo:X} is above hi 0x${hi:X}')
	}
	if timeout_ms < 1 || timeout_ms > 60000 {
		return error('an NM timeout is 1..60000 ms, not ${timeout_ms}')
	}
	return Config{
		lo:         u32(lo)
		hi:         u32(hi)
		ext:        ext || extended_range(u32(hi))
		timeout_ms: int(timeout_ms)
		source:     .script
		origin:     'the script'
	}
}
