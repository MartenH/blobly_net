// E2E on the frames a script reads and sends (Lua's bus.*, the C ABI's bus handles): a frame it
// reads is judged by the verifier the trace's verify: uses, and a message it sends by name is
// stamped with what its database declares, as the simulation stamps it (declared_e2e, E2e.apply).
module sim

import blobly.candb
import blobly.project
import blobly.transport

// receive_checks is what a frame received on a row is judged by, per message: the row's verify:
// entry for it, else its database's declaration (declared_e2e). Both are contracts a receiver
// holds a sender to; a node's protect: entry is not, being the simulated sender's own word, which
// may deviate from the declaration on purpose.
pub fn receive_checks(db candb.Database, verify []project.ProtectCfg) VerifySet {
	mut s := verifiers_for(db, [], verify)
	for m in db.messages {
		k := vkey(m.id, m.ext)
		if k in s.by_key {
			continue
		}
		ws := declared_e2e(m)
		if ws.len > 0 {
			s.by_key[k] = new_verifier(m, ws)
		}
	}
	return s
}

// unjudged_most bounds the ids a reader remembers as judged by nothing.
const unjudged_most = 4096

// E2eReader judges the frames one reader receives on a row by receive_checks, keeping what each
// message's check carries from frame to frame: its last counter, and when its last valid frame
// came. Its frames in the order received, every frame of a checked id: one it was not given
// reads, at the next, as a counter that skipped.
@[heap]
pub struct E2eReader {
mut:
	set      VerifySet
	dbs      []candb.Database
	unjudged map[string]bool // ids that resolve to no checked message
	windows  []WindowVerdict // each window's verdict on the last frame judged, none for none
}

// new_e2e_reader is a reader of a row whose database is `db` and its verify: entries `verify`.
pub fn new_e2e_reader(db candb.Database, verify []project.ProtectCfg) &E2eReader {
	return &E2eReader{
		set: receive_checks(db, verify)
		dbs: [db]
	}
}

// judges is how many messages its frames are judged for; 0, and judge answers none for every one.
pub fn (r &E2eReader) judges() int {
	return r.set.by_key.len
}

// judge is the verdict on a received frame, none for a frame of no checked message or a remote
// frame (no payload). Its time against E2ETimeout is its raw receive stamp (hw_ns in hw_domain),
// not its placement on the host's clock, which an estimate that improves can move between two
// frames; a frame with no stamp is timed only by its reading, and judged on its bytes alone.
pub fn (mut r E2eReader) judge(f transport.CanFrame) ?Violation {
	r.windows = []
	if f.rtr || r.set.by_key.len == 0 {
		return none
	}
	k := vkey(f.id, f.extended)
	if k in r.unjudged {
		return none
	}
	key := r.set.resolve(r.dbs, f.id, f.extended) or {
		if r.unjudged.len >= unjudged_most {
			r.unjudged.clear()
		}
		r.unjudged[k] = true
		return none
	}
	mut v := r.set.by_key[key] or { return none }
	got := v.check_at(f.data, f.hw_domain, f.hw_ns)
	r.set.by_key[key] = v
	r.windows = v.labelled()
	return got
}

// last_windows is each window's verdict on the frame judge last judged, by its name (E2e.label:
// a signal group's, else the message's) — empty where that frame was not judged. judge's verdict
// is the worst of these.
pub fn (r &E2eReader) last_windows() []WindowVerdict {
	return r.windows
}

// E2eStamper stamps what one sender sends by name with each message's declared E2E, counting
// that message's sends as a simulated sender counts its own: the first carries counter 0.
@[heap]
pub struct E2eStamper {
mut:
	sent map[u64]u64 // by stamp_key
}

// stamp_key is what a stamper counts a message's sends under: its id and kind.
fn stamp_key(id u32, ext bool) u64 {
	return u64(id) | if ext { u64(1) << 32 } else { u64(0) }
}

// stamp writes `m`'s declared counter and checksum into `data`, its encoded payload, in every
// window it declares (#615), and counts the send; false, `data` unchanged, when m declares no
// E2E, and an error when a declaration cannot be applied (declared_set), which sent unstamped
// would go out unprotected unsaid, or when `data` is shorter than m's payload, which holds no
// field to stamp.
pub fn (mut s E2eStamper) stamp(m candb.Message, mut data []u8) !bool {
	if !m.e2e_declared() {
		return false
	}
	short_frame(m, data)!
	s.apply(m, declared_windows(m)!, mut data)
	return true
}

// stamp_windows is stamp with `m`'s declared windows `ws` (declared_windows) found once, by a
// sender that stamps the one message every period: building them is most of a stamp. False,
// `data` unchanged, for no windows.
pub fn (mut s E2eStamper) stamp_windows(m candb.Message, ws []E2e, mut data []u8) !bool {
	if ws.len == 0 {
		return false
	}
	short_frame(m, data)!
	s.apply(m, ws, mut data)
	return true
}

// declared_windows is the windows `m` declares (declared_set), or the error a declaration that
// cannot be applied is refused with: sent unstamped it would go out unprotected unsaid.
pub fn declared_windows(m candb.Message) ![]E2e {
	ws, refused := declared_set(m)
	if refused.len > 0 {
		r := refused[0]
		return error('${r.decl.where_in(m)} declares E2E that cannot be stamped: ${r.why}; send it as encoded instead')
	}
	return ws
}

// short_frame refuses a payload shorter than `m`'s, which holds no field to stamp.
fn short_frame(m candb.Message, data []u8) ! {
	if data.len < m.payload_len() {
		return error('a frame of ${data.len} bytes is shorter than ${m.name} (${m.payload_len()})')
	}
}

// apply writes `m`'s counter and checksum in each of windows `ws` and counts the send.
fn (mut s E2eStamper) apply(m candb.Message, ws []E2e, mut data []u8) {
	k := stamp_key(m.id, m.ext)
	n := s.sent[k] or { u64(0) }
	for e in ws {
		e.apply(m, mut data, int(n))
	}
	s.sent[k] = n + 1
}
