module canlog

import transport

// THE ARENA. A loaded recording used to be a []LogEntry: 80 bytes per frame, each holding a
// pointer to its own cloned payload and one to its bus label — for a 1.23 M-frame file, 454 MB
// live and millions of objects for the collector to mark on every pass, which is what made each
// stop-the-world pause 150–370 ms long once #299 and #300 had taken the allocation rate down
// (the frequency). A Row is pointer-free, so V allocates the block it sits in no-scan and a
// collection never looks inside it: a million rows measured at 76 MB, and five full collections
// with the block live took 1 ms in all. Entries are handed out as VIEWS (`at`) whose payload
// aliases the row, so nothing is copied to play a frame; a consumer that keeps an entry past the
// Log's life copies it (`copy_at`), and a consumer that needs the old shape gets it (`entries`).
//
// Eighty bytes, eight-aligned: t_s, then id, then the four one-and-two-byte fields, then the
// payload. `dir` rides in the flags rather than in a byte of its own, which is what keeps the
// struct at 80 rather than 88.
pub struct Row {
pub mut:
	t_s   f64
	id    u32
	len   u8
	flags u8  // b0 extended, b1 rtr, b2 fd, b3 brs, b4 esi, b5..b6 the Dir ordinal
	bus   u16 // index into Log.labels
	data  [64]u8
}

// max_row_payload is what a Row carries: the CAN-FD maximum, and nothing a wire carries is
// longer. The parsers refuse anything longer before a row is built (canlog.parse_line, the
// mf4 loader's max_can_payload), so the cut in row_of is a last line of defence for an entry
// built by hand, never a path a file reaches.
pub const max_row_payload = 64

// Log is a recording: its frames as rows, and the bus labels the rows name by index.
pub struct Log {
pub mut:
	rows   []Row
	labels []string
}

pub fn (l &Log) len() int {
	return l.rows.len
}

pub fn (l &Log) t_s(i int) f64 {
	return l.rows[i].t_s
}

pub fn (l &Log) iface(i int) string {
	return l.labels[l.rows[i].bus]
}

// max_labels is how many buses a Log can name: the bus index is a u16. A recording names a
// dozen; a file whose bus field carries junk could name more, and past this the index would
// wrap onto bus 0 — so intern refuses instead and the loader drops the record, counted.
pub const max_labels = 65535

// index_of is the ONE label-to-index rule: the first label equal to `iface`, or none.
// Labels are unique by construction (intern adds a label only when index_of fails), which is
// what lets a plan relabel by index and a selection filter by index.
pub fn (l &Log) index_of(iface string) ?int {
	for j, s in l.labels {
		if s == iface {
			return j
		}
	}
	return none
}

// intern is the index of a bus label, adding it on first sight, or none once the table is
// full. A recording names a dozen buses, so a linear scan is the right structure; the loader
// keeps its own per-bus cache anyway and asks once per bus, not once per record.
pub fn (mut l Log) intern(iface string) ?u16 {
	if j := l.index_of(iface) {
		return u16(j)
	}
	if l.labels.len >= max_labels {
		return none
	}
	l.labels << iface
	return u16(l.labels.len - 1)
}

// all is the selection that plays every row in stored order — what a bare Log means.
pub fn (l &Log) all() []u32 {
	return []u32{len: l.rows.len, init: u32(index)}
}

// pack_flags is the ONE spelling of the flag byte, for the loader and for row_of alike.
pub fn pack_flags(extended bool, rtr bool, fd bool, brs bool, esi bool, dir Dir) u8 {
	mut b := u8(0)
	if extended {
		b |= 1
	}
	if rtr {
		b |= 2
	}
	if fd {
		b |= 4
	}
	if brs {
		b |= 8
	}
	if esi {
		b |= 16
	}
	b |= u8(int(dir) & 3) << 5
	return b
}

// row_of packs an entry into a row that names its bus by `bus`.
pub fn row_of(e LogEntry, bus u16) Row {
	mut r := Row{
		t_s:   e.t_s
		id:    e.frame.id
		flags: pack_flags(e.frame.extended, e.frame.rtr, e.frame.fd, e.frame.brs, e.frame.esi,
			e.dir)
		bus:   bus
	}
	mut n := e.frame.data.len
	if n > max_row_payload {
		n = max_row_payload
	}
	r.len = u8(n)
	if n > 0 {
		unsafe { vmemcpy(&r.data[0], e.frame.data.data, n) }
	}
	return r
}

// push appends an entry, or refuses it (false) when its bus cannot be named — see max_labels.
pub fn (mut l Log) push(e LogEntry) bool {
	b := l.intern(e.iface) or { return false }
	l.rows << row_of(e, b)
	return true
}

// frame is row i as a CanFrame VIEW: its data is a header over the row's bytes, not a copy.
// Read it, send it, clone it to keep it — writing through it writes the recording.
pub fn (l &Log) frame(i int) transport.CanFrame {
	r := &l.rows[i]
	return transport.CanFrame{
		id:       r.id
		extended: r.flags & 1 != 0
		rtr:      r.flags & 2 != 0
		fd:       r.flags & 4 != 0
		brs:      r.flags & 8 != 0
		esi:      r.flags & 16 != 0
		data:     unsafe { (&u8(&r.data[0])).vbytes(int(r.len)) }
	}
}

// at is row i as an entry VIEW — see frame. A view does not dangle: V's collector recognises
// interior pointers, so a view kept anywhere PINS the whole row block for as long as it is
// kept. That is the rule for every seam a frame leaves the replay through — clone what you
// keep (`owned`), never hold a view past the run.
pub fn (l &Log) at(i int) LogEntry {
	r := &l.rows[i]
	return LogEntry{
		t_s:   r.t_s
		iface: l.labels[r.bus]
		dir:   unsafe { Dir(int((r.flags >> 5) & 3)) }
		frame: l.frame(i)
	}
}

// owned is this entry with a payload of its own: the ONE spelling of "keep a copy of a
// view", for the arena's consumers and for a frame received off an in-process bus alike.
pub fn (e LogEntry) owned() LogEntry {
	return LogEntry{
		t_s:   e.t_s
		iface: e.iface
		dir:   e.dir
		frame: transport.CanFrame{
			...e.frame
			data: e.frame.data.clone()
		}
	}
}

// copy_at is row i as an entry that owns its payload: what a consumer keeps.
pub fn (l &Log) copy_at(i int) LogEntry {
	return l.at(i).owned()
}

// entries_of materialises a selection in the old shape: O(n) and every payload cloned.
pub fn (l &Log) entries_of(sel []u32) []LogEntry {
	mut out := []LogEntry{cap: sel.len}
	for i in sel {
		out << l.copy_at(int(i))
	}
	return out
}

// entries materialises the whole recording in the old shape. For tests and small callers;
// the replay path never asks for it.
pub fn (l &Log) entries() []LogEntry {
	return l.entries_of(l.all())
}

// from_entries is the ONE conversion the other way: what the candump parser, the player's
// entry-taking constructors and the tests build a Log with.
pub fn from_entries(es []LogEntry) Log {
	mut l := Log{
		rows: []Row{cap: es.len}
	}
	for e in es {
		l.push(e)
	}
	return l
}

// relabelled is the same rows under other labels — how a replay plan maps recorded buses onto
// live ones without copying a frame: the rows are SHARED, only the label table is new. The
// table is positional (index i names the same bus as before) and may repeat a label, since
// two recorded buses can map onto one live one; index_of over such a table answers the
// first, which is why a plan is filtered by INDEX and never by label.
pub fn (l &Log) relabelled(labels []string) Log {
	return Log{
		rows:   l.rows
		labels: labels
	}
}
