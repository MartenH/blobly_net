module nm

// Row is one line of a wire's NM table, computed at one moment: a reporter, or a declared node
// that has not reported.
pub struct Row {
pub:
	name       string
	id         u32
	ext        bool
	has_id     bool // a missing declaration may state no id
	nid        int  // -1 when not known (a missing node declared by id)
	missing    bool // declared, never reported
	unknown    bool // reports, and the configuration declares its members and not it
	ago_ms     f64  // since its last frame
	stale      bool // its last frame is past the timeout
	count      u64
	mean_ms    f64
	last_iv_ms f64 // the latest interval
	bits       []string
	cbv        u8 // its latest control bit vector; 0 for a missing node
	pn         u64
	has_pn     bool
	timeline   []Phase
}

// View is a wire's NM reading at one moment: what the panel draws, built under the caller's
// lock so the drawing needs none.
pub struct View {
pub:
	cfg         Config
	state       BusState
	keepers     []string
	keeper_rows []int // the rows of `keepers`, in its order
	woke        string // the node whose frame ended the last silence; '' before any
	woke_ago    f64
	woke_active bool // that frame said active wake-up
	woke_row    int = -1 // the row of `woke`; -1 before any
	repeaters   []string
	repeater_rows []int // the rows of `repeaters`
	heard       bool
	last_ago    f64 // since the last NM frame on the wire
	rows        []Row
	frames      u64
	malformed   u64
	last_error  string
	dropped     u64
}

// view is the tracker's reading at `now`, with `cols` timeline columns per reporter.
pub fn (t &Tracker) view(now f64, cols int) View {
	mut rows := []Row{cap: t.nodes.len + t.cfg.declared.len}
	for i, n in t.nodes {
		ago := now - n.last_ms
		rows << Row{
			name:       t.name_of(i)
			id:         n.id
			ext:        n.ext
			has_id:     true
			nid:        int(n.nid)
			unknown:    t.unknown(i)
			ago_ms:     ago
			stale:      ago > f64(t.cfg.timeout_ms)
			count:      n.count
			mean_ms:    n.mean_ms()
			last_iv_ms: n.last_iv_ms
			bits:       bit_words(n.cbv)
			cbv:        n.cbv
			pn:         n.pn
			has_pn:     n.has_pn && n.pn != 0
			timeline:   t.strip(i, now, cols)
		}
	}
	for d in t.missing() {
		decl := t.cfg.declared[d]
		rows << Row{
			name:     if decl.name != '' { decl.name } else { 'NID 0x${decl.nid:02X}' }
			id:       if decl.id >= 0 { u32(decl.id) } else { 0 }
			ext:      decl.ext
			has_id:   decl.id >= 0
			nid:      decl.nid
			missing:  true
			timeline: []Phase{len: if cols > 0 { cols } else { 0 }, init: Phase.silent}
		}
	}
	mut woke := ''
	mut woke_ago := 0.0
	mut woke_active := false
	mut woke_row := -1
	if w := t.woke {
		woke = t.name_of(w.node)
		woke_ago = now - w.t_ms
		woke_active = w.active
		woke_row = w.node // the reporters are the first rows, in node order
	}
	keepers := t.keepers(now)
	repeaters := t.with_bit(now, cbv_repeat_request)
	return View{
		cfg:         t.cfg
		state:       t.state(now)
		keepers:     keepers.map(t.name_of(it))
		keeper_rows: keepers
		woke:        woke
		woke_ago:    woke_ago
		woke_active: woke_active
		woke_row:    woke_row
		repeaters:   repeaters.map(t.name_of(it))
		repeater_rows: repeaters
		heard:       t.last_ms >= 0
		last_ago:    if t.last_ms >= 0 { now - t.last_ms } else { 0.0 }
		rows:        rows
		frames:      t.frames
		malformed:   t.malformed
		last_error:  t.last_error
		dropped:     t.dropped
	}
}
