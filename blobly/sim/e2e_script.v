// E2E on the frames a script reads and sends (Lua's bus.*, the C ABI's bus handles): a frame it
// reads is judged by the verifier the trace's verify: uses, and a message it sends by name is
// stamped with what its database declares, as the simulation stamps it (declared_e2e, E2e.apply).
module sim

import blobly.candb
import blobly.project
import blobly.transport

// receive_checks is what a frame received on a row is judged by, per message: the row's verify:
// entry for it, else its database's declaration (declared_e2e), else a protect: entry of a node
// simulated on the row — each with its message's E2ETimeout.
pub fn receive_checks(db candb.Database, nodes []project.NodeCfg, verify []project.ProtectCfg) VerifySet {
	mut s := verifiers_for(db, [], verify)
	for m in db.messages {
		k := vkey(m.id, m.ext)
		if k in s.by_key {
			continue
		}
		if e := declared_e2e(m) {
			s.by_key[k] = Verifier{
				msg: m
				e2e: e
			}
		}
	}
	for k, v in verifiers_for(db, nodes, []).by_key {
		if k !in s.by_key {
			s.by_key[k] = v
		}
	}
	for k in s.by_key.keys() {
		v := s.by_key[k] or { continue }
		s.by_key[k] = Verifier{
			msg:        v.msg
			e2e:        v.e2e
			timeout_ms: if v.msg.e2e.has_timeout { v.msg.e2e.timeout_ms } else { u32(0) }
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
}

// new_e2e_reader is a reader of a row whose database is `db`, its simulated nodes `nodes` and its
// verify: entries `verify`.
pub fn new_e2e_reader(db candb.Database, nodes []project.NodeCfg, verify []project.ProtectCfg) &E2eReader {
	return &E2eReader{
		set: receive_checks(db, nodes, verify)
		dbs: [db]
	}
}

// judges is how many messages its frames are judged for; 0, and judge answers none for every one.
pub fn (r &E2eReader) judges() int {
	return r.set.by_key.len
}

// judge is the verdict on a frame received at `t_ns` (transport.received_at), none for a frame
// of no checked message or a remote frame (no payload). Its time is judged against E2ETimeout
// only where it is the bus's own (transport.stamped).
pub fn (mut r E2eReader) judge(f transport.CanFrame, t_ns i64) ?Violation {
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
	got := v.check_at(f.data, t_ns, transport.stamped(f))
	r.set.by_key[key] = v
	return got
}

// E2eStamper stamps what one sender sends by name with each message's declared E2E, counting
// that message's sends as a simulated sender counts its own: the first carries counter 0.
@[heap]
pub struct E2eStamper {
mut:
	sent map[string]u64
}

// stamp writes `m`'s declared counter and checksum into `data`, its encoded payload, and counts
// the send; false, `data` unchanged, when m declares no E2E that can be stamped.
pub fn (mut s E2eStamper) stamp(m candb.Message, mut data []u8) bool {
	e := declared_e2e(m) or { return false }
	k := vkey(m.id, m.ext)
	n := s.sent[k] or { u64(0) }
	e.apply(m, mut data, int(n))
	s.sent[k] = n + 1
	return true
}
