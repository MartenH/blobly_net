module nm

// window_ms is how far back a node's timeline reaches.
pub const window_ms = 60_000.0

// max_segments bounds one node's timeline; past it the oldest segment goes.
pub const max_segments = 512

// max_nodes bounds one wire's reporters; a frame from one more is counted in `dropped`.
pub const max_nodes = 256

// Seg is a stretch of one phase: from the frame that opened it to the last frame that continued
// it. It is shown until `last_ms + timeout`, or until the next segment begins.
pub struct Seg {
pub mut:
	from_ms f64
	last_ms f64
	phase   Phase
}

// Node is one reporter on the cluster: a CAN id and the NID its frames carry.
pub struct Node {
pub mut:
	id         u32
	ext        bool
	nid        u8
	decl       int = -1 // its entry in Config.declared; -1 when nothing declares it
	first_ms   f64
	last_ms    f64
	count      u64
	last_iv_ms f64 // the latest interval between two of its frames; 0 before the second
	iv_sum_ms  f64 // the intervals within the timeout, whose mean is the cadence
	iv_n       u64
	cbv        u8 // its latest control bit vector
	pn         u64
	has_pn     bool
	segs       []Seg
}

// mean_ms is the node's cadence: the mean of its intervals that were within the timeout (a
// longer one is the network having slept, not the node's cycle); 0 before there is one.
pub fn (n Node) mean_ms() f64 {
	return if n.iv_n == 0 { 0.0 } else { n.iv_sum_ms / f64(n.iv_n) }
}

// live: heard within the timeout at `now`.
pub fn (n Node) live(now f64, timeout_ms int) bool {
	return n.count > 0 && now - n.last_ms <= f64(timeout_ms)
}

// ready_to_sleep: its latest frame released the network.
pub fn (n Node) ready_to_sleep() bool {
	return n.cbv & cbv_ready_to_sleep != 0
}

// BusState is the cluster's state as the frames on it say.
pub enum BusState {
	asleep    // nothing heard within the timeout (or nothing yet)
	awake     // a node heard within the timeout requests the network
	releasing // every node heard within the timeout is ready to sleep
}

pub fn (s BusState) str() string {
	return match s {
		.asleep { 'asleep' }
		.awake { 'awake' }
		.releasing { 'releasing' }
	}
}

// Wake is the frame that ended a silence: which node, when, and whether it said active wake-up.
pub struct Wake {
pub:
	node   int
	t_ms   f64
	active bool
}

// Tracker is one wire's NM listener, fed every frame of the wire with its host time. Pure over
// the times it is given; the caller holds whatever lock guards it.
pub struct Tracker {
pub mut:
	cfg        Config
	nodes      []Node // in the order first heard
	index      map[u64]int
	last_ms    f64 = -1.0 // the last NM frame; -1 before the first
	frames     u64
	malformed  u64
	last_error string
	dropped    u64 // frames from reporters past max_nodes
	woke       ?Wake
}

pub fn new_tracker(cfg Config) Tracker {
	return Tracker{
		cfg: cfg
	}
}

// note feeds one frame. Answers whether it was in the NM range (and so taken); a frame in the
// range that does not parse is counted as malformed.
pub fn (mut t Tracker) note(id u32, ext bool, data []u8, t_ms f64) bool {
	if !t.cfg.covers(id, ext) {
		return false
	}
	pdu := t.cfg.pdu_at(id, ext).pdu_of(data)
	p := parse(pdu) or {
		t.malformed++
		t.last_error = 'id 0x${id:X}: ${err.msg()}'
		return true
	}
	key := (frame_key(id, ext) << 8) | u64(p.nid)
	mut i := t.index[key] or { -1 }
	if i < 0 {
		if t.nodes.len >= max_nodes {
			t.dropped++
			return true
		}
		i = t.nodes.len
		t.nodes << Node{
			id:       id
			ext:      ext
			nid:      p.nid
			decl:     t.cfg.declared_index(p.nid, id, ext)
			first_ms: t_ms
			last_ms:  t_ms
		}
		t.index[key] = i
	}
	timeout := f64(t.cfg.timeout_ms)
	// a frame after a silence longer than the timeout woke the network; the first frame heard
	// did only if it says so (active wake-up), since the bus may have been awake before listening began
	if (t.last_ms < 0 && p.cbv & cbv_active_wakeup != 0) || (t.last_ms >= 0 && t_ms - t.last_ms > timeout) {
		t.woke = Wake{
			node:   i
			t_ms:   t_ms
			active: p.cbv & cbv_active_wakeup != 0
		}
	}
	if t_ms > t.last_ms {
		t.last_ms = t_ms
	}
	t.frames++
	mut n := &t.nodes[i]
	if n.count > 0 && t_ms < n.last_ms {
		// older than what this node already said (an unsorted recording): counted, and its
		// state is not taken back to it
		n.count++
		return true
	}
	if n.count > 0 {
		iv := t_ms - n.last_ms
		n.last_iv_ms = iv
		if iv <= timeout {
			n.iv_sum_ms += iv
			n.iv_n++
		}
	}
	n.last_ms = t_ms
	n.count++
	n.cbv = p.cbv
	n.pn = p.pn
	n.has_pn = p.has_pn
	ph := p.phase()
	if n.segs.len > 0 && n.segs.last().phase == ph && t_ms - n.segs.last().last_ms <= timeout {
		n.segs[n.segs.len - 1].last_ms = t_ms
	} else {
		n.segs << Seg{
			from_ms: t_ms
			last_ms: t_ms
			phase:   ph
		}
	}
	// what ended before the window is dropped
	mut drop := 0
	for drop < n.segs.len - 1 && n.segs[drop].last_ms + timeout < t_ms - window_ms {
		drop++
	}
	if drop > 0 {
		n.segs.delete_many(0, drop)
	}
	// a node that flips every frame is held to the cap by folding its two oldest segments into
	// one of the greater phase — what a timeline column shows anyway — never by dropping them
	for n.segs.len > max_segments {
		a := n.segs[0]
		b := n.segs[1]
		n.segs[1] = Seg{
			from_ms: a.from_ms
			last_ms: b.last_ms
			phase:   if int(a.phase) > int(b.phase) { a.phase } else { b.phase }
		}
		n.segs.delete(0)
	}
	return true
}

// state is the cluster's state at `now`.
pub fn (t &Tracker) state(now f64) BusState {
	mut any := false
	for n in t.nodes {
		if !n.live(now, t.cfg.timeout_ms) {
			continue
		}
		if !n.ready_to_sleep() {
			return .awake
		}
		any = true
	}
	return if any { .releasing } else { .asleep }
}

// keepers are the nodes keeping the network awake at `now`: heard within the timeout with
// ready-to-sleep clear. The declared ones in the order the configuration declares them, then the
// others in the order first heard, so the answer does not depend on when listening began.
pub fn (t &Tracker) keepers(now f64) []int {
	mut out := []int{}
	for i, n in t.nodes {
		if n.live(now, t.cfg.timeout_ms) && !n.ready_to_sleep() {
			out << i
		}
	}
	out.sort_with_compare(fn [t] (a &int, b &int) int {
		ra := t.declared_rank(*a)
		rb := t.declared_rank(*b)
		if ra != rb {
			return if ra < rb { -1 } else { 1 }
		}
		return if *a < *b { -1 } else if *a > *b { 1 } else { 0 }
	})
	return out
}

// declared_rank orders node `i` by its declaration: its index there, past every declaration when
// nothing declares it.
fn (t &Tracker) declared_rank(i int) int {
	d := t.nodes[i].decl
	return if d >= 0 { d } else { t.cfg.declared.len }
}

// with_bit are the nodes heard within the timeout whose latest CBV carries `bit` — the active
// wake-up or the repeat request.
pub fn (t &Tracker) with_bit(now f64, bit u8) []int {
	mut out := []int{}
	for i, n in t.nodes {
		if n.live(now, t.cfg.timeout_ms) && n.cbv & bit != 0 {
			out << i
		}
	}
	return out
}

// missing are the declared entries no reporter has matched.
pub fn (t &Tracker) missing() []int {
	mut heard := []bool{len: t.cfg.declared.len}
	for n in t.nodes {
		if n.decl >= 0 && n.decl < heard.len {
			heard[n.decl] = true
		}
	}
	mut out := []int{}
	for i, h in heard {
		if !h {
			out << i
		}
	}
	return out
}

// unknown: the node reports in a cluster whose configuration declares its members, and no
// declaration is this node. A configuration declaring nobody (a project's own range) makes
// nothing unknown.
pub fn (t &Tracker) unknown(i int) bool {
	return t.cfg.declared.len > 0 && t.nodes[i].decl < 0
}

// name_of is the node's name: its declaration's, else `NID 0x13`.
pub fn (t &Tracker) name_of(i int) string {
	n := t.nodes[i]
	if n.decl >= 0 && n.decl < t.cfg.declared.len && t.cfg.declared[n.decl].name != '' {
		return t.cfg.declared[n.decl].name
	}
	return 'NID 0x${n.nid:02X}'
}

// strip is node `i`'s timeline over the window ending at `now`, in `cols` equal columns, oldest
// first: each column the greatest phase any part of it was in.
pub fn (t &Tracker) strip(i int, now f64, cols int) []Phase {
	return timeline(t.nodes[i].segs, now, f64(t.cfg.timeout_ms), cols)
}

// timeline renders segments into columns over [now - window_ms, now].
pub fn timeline(segs []Seg, now f64, timeout f64, cols int) []Phase {
	if cols <= 0 {
		return []Phase{}
	}
	mut out := []Phase{len: cols, init: Phase.silent}
	start := now - window_ms
	w := window_ms / f64(cols)
	for k, s in segs {
		mut end := s.last_ms + timeout
		if k + 1 < segs.len && segs[k + 1].from_ms < end {
			end = segs[k + 1].from_ms
		}
		if end > now {
			end = now
		}
		if end <= start || s.from_ms >= now {
			continue
		}
		from := if s.from_ms > start { s.from_ms } else { start }
		mut c0 := int((from - start) / w)
		mut c1 := int((end - start) / w)
		if f64(c1) * w + start >= end && c1 > c0 {
			c1-- // a segment ending exactly on a column edge does not paint the next column
		}
		if c0 < 0 {
			c0 = 0
		}
		if c1 >= cols {
			c1 = cols - 1
		}
		for c in c0 .. c1 + 1 {
			if int(s.phase) > int(out[c]) {
				out[c] = s.phase
			}
		}
	}
	return out
}
