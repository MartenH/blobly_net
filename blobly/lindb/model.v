// model — what a LIN Description File (LIN 2.2A §9, ISO 17987-3) says about a cluster, as read
// by `parse_ldf`. Everything here is a fact of the file; nothing is guessed. A field the reader
// refused is absent (an option left none, an element left out) and `Ldf.notes` says why.
module lindb

// Checksum is the LIN checksum model a frame is sent with: classic over the data bytes alone
// (LIN 1.x, and the diagnostic frames always), enhanced over the protected id too (LIN 2.x).
pub enum Checksum {
	classic
	enhanced
}

pub enum FrameKind {
	unconditional
	diagnostic // MasterReq (0x3C) or SlaveResp (0x3D)
}

// SlotKind is what a schedule-table slot sends.
pub enum SlotKind {
	frame           // an unconditional frame
	diagnostic      // MasterReq or SlaveResp
	event_triggered // an event-triggered frame (parsed, not run by v1)
	sporadic        // a sporadic frame (parsed, not run by v1)
	command         // a node configuration command (AssignNAD, ...), carried for its delay only
}

pub enum EncKind {
	logical  // one raw value, with an optional description
	physical // a raw range lo..hi, read as raw * scale + offset in `text` (the unit)
	bcd      // a byte array, one decimal digit per byte, most significant first
	ascii    // a byte array of ASCII characters
}

pub struct Master {
pub mut:
	name         string
	time_base_ms ?f64
	jitter_ms    ?f64
}

// Signal is one entry of Signals or Diagnostic_signals. A byte array (`is_array`) is declared
// with a brace init and has a width of 8..64 bits in whole bytes; its init is `init_bytes`.
pub struct Signal {
pub mut:
	name        string
	width       int
	is_array    bool
	init        u64
	init_bytes  []u8
	publisher   string
	subscribers []string
	diagnostic  bool
	encoding    string // the Signal_encoding_types entry Signal_representation gives it, or ''
}

// Mapped is a signal placed in a frame: its least significant bit at bit `offset` of the frame,
// bits counted LSB first from byte 0 (LIN is little-endian).
pub struct Mapped {
pub:
	name   string
	offset int
}

pub struct Frame {
pub mut:
	name      string
	id        u8
	publisher string // the master's name for MasterReq; '' for SlaveResp (any slave answers)
	length    int
	kind      FrameKind
	signals   []Mapped
}

pub struct EventFrame {
pub mut:
	name   string
	table  string // the collision-resolving schedule table; '' where the file names none (LIN 2.0)
	id     u8
	frames []string
}

pub struct SporadicFrame {
pub mut:
	name   string
	frames []string
}

// ProductId is a node's product_id; the variant is optional in the file and none where absent.
pub struct ProductId {
pub:
	supplier u16
	function u16
	variant  ?u8
}

// ConfigurableFrame is one entry of a node's configurable_frames; LIN 2.0 states a message id.
pub struct ConfigurableFrame {
pub:
	name       string
	message_id ?u16
}

// Node is one entry of Node_attributes. The diagnostic timings are none where the file does not
// state them; the accessors give the LIN default then.
pub struct Node {
pub mut:
	name                string
	protocol            string
	configured_nad      ?u8
	initial_nad         ?u8
	product             ?ProductId
	response_error      string
	fault_state_signals []string
	p2_min_ms           ?f64
	st_min_ms           ?f64
	n_as_timeout_ms     ?f64
	n_cr_timeout_ms     ?f64
	configurable_frames []ConfigurableFrame
}

// EncRule is one line of a Signal_encoding_types entry; which fields mean what is by `kind`.
pub struct EncRule {
pub:
	kind   EncKind
	lo     u64 // logical: the value; physical: the lowest raw value
	hi     u64 // logical: the value; physical: the highest raw value
	scale  f64
	offset f64
	text   string // logical: the description; physical: the unit
}

pub struct Encoding {
pub mut:
	name  string
	rules []EncRule
}

// Slot is one schedule-table entry: what is sent and how long the slot lasts. A configuration
// command has no frame of its own here (`frame` is ''); its name is `command`.
pub struct Slot {
pub:
	kind     SlotKind
	frame    string
	command  string
	delay_ms f64
}

pub struct Schedule {
pub mut:
	name  string
	slots []Slot
}

// Ldf is a read LIN Description File. `notes` says everything the reader did not take as
// written: a refused value, a reference to nothing, a section parsed and not modelled.
pub struct Ldf {
pub mut:
	protocol_version string // as written ("2.2", "ISO17987:2015"); '' when missing or refused
	language_version string
	speed_bps        ?int
	channel          string
	master           Master
	slaves           []string
	signals          []Signal
	frames           []Frame // unconditional and diagnostic
	event_frames     []EventFrame
	sporadic_frames  []SporadicFrame
	nodes            []Node
	schedules        []Schedule
	encodings        []Encoding
	notes            []string
}

// The LIN 2.x defaults for a node's diagnostic timings (LIN 2.2A §9.2.2.2).
pub const default_p2_min_ms = 50.0
pub const default_st_min_ms = 0.0
pub const default_n_as_timeout_ms = 1000.0
pub const default_n_cr_timeout_ms = 1000.0

pub fn (n Node) p2_min() f64 {
	return n.p2_min_ms or { default_p2_min_ms }
}

pub fn (n Node) st_min() f64 {
	return n.st_min_ms or { default_st_min_ms }
}

pub fn (n Node) n_as_timeout() f64 {
	return n.n_as_timeout_ms or { default_n_as_timeout_ms }
}

pub fn (n Node) n_cr_timeout() f64 {
	return n.n_cr_timeout_ms or { default_n_cr_timeout_ms }
}

// initial NAD is the configured one where the file states none (LIN 2.1 §9.2.2.2)
pub fn (n Node) initial() ?u8 {
	if v := n.initial_nad {
		return v
	}
	return n.configured_nad
}

pub fn (l &Ldf) frame(name string) ?Frame {
	for f in l.frames {
		if f.name == name {
			return f
		}
	}
	return none
}

pub fn (l &Ldf) frame_by_id(id u8) ?Frame {
	for f in l.frames {
		if f.id == id {
			return f
		}
	}
	return none
}

pub fn (l &Ldf) signal(name string) ?Signal {
	for s in l.signals {
		if s.name == name {
			return s
		}
	}
	return none
}

pub fn (l &Ldf) node(name string) ?Node {
	for n in l.nodes {
		if n.name == name {
			return n
		}
	}
	return none
}

pub fn (l &Ldf) encoding(name string) ?Encoding {
	for e in l.encodings {
		if e.name == name {
			return e
		}
	}
	return none
}

pub fn (l &Ldf) event_frame(name string) ?EventFrame {
	for e in l.event_frames {
		if e.name == name {
			return e
		}
	}
	return none
}

pub fn (l &Ldf) event_frame_by_id(id u8) ?EventFrame {
	for e in l.event_frames {
		if e.id == id {
			return e
		}
	}
	return none
}

// Response is what the LDF calls a response to a header: the frame of that id, or, for an
// event-triggered frame's id, the event frame and the carried frame whose protected id the
// response's first byte is (none when it is empty or names none of them).
pub struct Response {
pub:
	name  string
	frame ?Frame
}

// response_for names the response `data` to the header `id`; none when the LDF has no frame or
// event-triggered frame of that id. The one rule the row's view and lin_monitor both read by.
pub fn (l &Ldf) response_for(id u8, data []u8) ?Response {
	if f := l.frame_by_id(id) {
		return Response{
			name:  f.name
			frame: f
		}
	}
	e := l.event_frame_by_id(id) or { return none }
	if data.len > 0 {
		for n in e.frames {
			if f := l.frame(n) {
				if protected_id(f.id) == data[0] {
					return Response{
						name:  '${e.name} ${f.name}'
						frame: f
					}
				}
			}
		}
	}
	return Response{
		name: e.name
	}
}

// schedule is the slots of the table `name`, in order.
pub fn (l &Ldf) schedule(name string) ?[]Slot {
	for s in l.schedules {
		if s.name == name {
			return s.slots
		}
	}
	return none
}

// checksum_model_for is the checksum a frame with this id is sent with. The diagnostic
// frames are classic always. A slave's frame is sent in its publisher's model — its
// LIN_protocol from Node_attributes, else the file's LIN_protocol_version — and every slave
// subscribing to it must check in that model too. A master's frame is sent in the model of the
// slaves subscribing to it, classic for LIN 1.x ones (LIN 2.2A §2.3.1.5), and in the file's
// where no slave subscribes; LIN 1.x and 2.x subscribers together have no one model. An
// event-triggered frame takes its frames' model; where they differ, the answering frame
// decides and there is no answer for the id.
pub fn (l &Ldf) checksum_model_for(id u8) !Checksum {
	if id == 0x3C || id == 0x3D {
		return .classic
	}
	if f := l.frame_by_id(id) {
		return l.frame_checksum(f)
	}
	e := l.event_frame_by_id(id) or { return error('no frame has id 0x${id:02X}') }
	mut models := []Checksum{}
	for name in e.frames {
		f := l.frame(name) or { continue }
		c := l.frame_checksum(f)!
		if c !in models {
			models << c
		}
	}
	if models.len != 1 {
		return error('event-triggered frame ${e.name} carries frames of ${if models.len == 0 {
			'no'
		} else {
			'different'
		}} checksum models; the answering frame decides')
	}
	return models[0]
}

fn (l &Ldf) frame_checksum(f Frame) !Checksum {
	subs := l.subscribing_slaves(f)
	if f.publisher != l.master.name {
		c := l.slave_checksum(f.publisher)!
		for s in subs {
			if s != f.publisher && l.slave_checksum(s)! != c {
				return error('frame ${f.name} is sent ${c} by ${f.publisher} and checked ${l.slave_checksum(s)!} by subscriber ${s}; no single checksum model serves both')
			}
		}
		return c
	}
	mut models := []Checksum{}
	for s in subs {
		c := l.slave_checksum(s)!
		if c !in models {
			models << c
		}
	}
	if models.len > 1 {
		return error('frame ${f.name} is subscribed by LIN 1.x and 2.x slaves; no single checksum model serves both')
	}
	if models.len == 1 {
		return models[0]
	}
	return l.file_checksum(f.name)
}

// slave_checksum is the model a slave speaks: its LIN_protocol, else the file's version.
fn (l &Ldf) slave_checksum(name string) !Checksum {
	if n := l.node(name) {
		if n.protocol != '' {
			return checksum_of(n.protocol)
		}
	}
	return l.file_checksum(name)
}

fn (l &Ldf) file_checksum(what string) !Checksum {
	if l.protocol_version == '' {
		return error("${what}: the file's LIN_protocol_version was not read, so its checksum model is unknown")
	}
	return checksum_of(l.protocol_version)
}

// subscribing_slaves are the slaves of Nodes subscribing to any signal the frame carries.
fn (l &Ldf) subscribing_slaves(f Frame) []string {
	mut out := []string{}
	for m in f.signals {
		s := l.signal(m.name) or { continue }
		for n in s.subscribers {
			if n in l.slaves && n !in out {
				out << n
			}
		}
	}
	return out
}

// is_tied: the frame is one an event-triggered frame carries, so its byte 0 is its own PID.
pub fn (l &Ldf) is_tied(name string) bool {
	return l.event_frames.any(name in it.frames)
}

// protected_id is a frame id with its parity bits: P0 = ID0^ID1^ID2^ID4 in bit 6 and
// P1 = !(ID1^ID3^ID4^ID5) in bit 7.
pub fn protected_id(id u8) u8 {
	b := [id & 1, (id >> 1) & 1, (id >> 2) & 1, (id >> 3) & 1, (id >> 4) & 1, (id >> 5) & 1]
	p0 := b[0] ^ b[1] ^ b[2] ^ b[4]
	p1 := (b[1] ^ b[3] ^ b[4] ^ b[5]) ^ 1
	return (id & 0x3F) | (p0 << 6) | (p1 << 7)
}

// checksum_of a version the reader accepted: LIN 1.x is classic, everything later enhanced.
fn checksum_of(version string) Checksum {
	major, _ := version_reading(version) or { return .enhanced }
	return if major == 1 { .classic } else { .enhanced }
}
