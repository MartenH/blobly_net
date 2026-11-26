module sysview

import blobly.uds

// routines.v — a node's RoutineControl (0x31) services by name (an imported description's: ODX,
// odxnodes.v): each is one routine control — the routine's identifier, start, stop or request
// results, the gate its service asks for — with the record its request carries and the record its
// positive answer returns, each laid out for the DID codec (didcodec.v). A tester runs one by name
// with its option's parts as texts and reads the answer's parts back, the run refused before
// anything is sent as a gated write is (WriteGated). The Lua `uds.node`'s run_routine and the C
// ABI's bb_routine_* / bb_uds_routine_described answer by these.

// RoutineDesc is one routine control a node describes.
pub struct RoutineDesc {
pub mut:
	// its node unlocks by 0x29 Authentication: a gated run plans an authenticate
	authenticates bool
pub:
	name    string // the service's name
	id      u16    // the routine identifier
	control u8     // uds.routine_start, routine_stop or routine_results
	gate    Gate   // `declared` false: it runs in any session, unlocked
	// the request's record after `31 <control> <id>` and the positive answer's after
	// `71 <control> <id>`, laid out as a DID's value (`id` the routine's, `name` the service's); a
	// record of size 0 carries nothing
	option DidDesc
	answer DidDesc
}

// control_name is how a tester names the control: start, stop or results.
pub fn control_name(control u8) string {
	return match control {
		uds.routine_start { 'start' }
		uds.routine_stop { 'stop' }
		uds.routine_results { 'results' }
		else { '0x${control:02X}' }
	}
}

// label is how a refusal names the routine control: `0x31 01 0x0203 Start_SelfTest`.
pub fn (r RoutineDesc) label() string {
	return '0x31 ${r.control:02X} 0x${r.id:04X} ${r.name}'
}

// record_parts are a record's editable parts: none for a record of nothing.
pub fn record_parts(x DidDesc) []Part {
	return if x.size == 0 { []Part{} } else { x.parts() }
}

// option_parts / answer_parts are the parts a run takes and its answer is read as.
pub fn (r RoutineDesc) option_parts() []Part {
	return record_parts(r.option)
}

pub fn (r RoutineDesc) answer_parts() []Part {
	return record_parts(r.answer)
}

// by_label: a value of this record is its parts by label (several), else its one part's value or,
// of none, nothing.
pub fn record_by_label(x DidDesc) bool {
	return record_parts(x).len > 1
}

// encode_option is the option record the texts spell (one per option part): refused, naming the
// part, for one the layout does not hold.
pub fn (r RoutineDesc) encode_option(texts []string) ![]u8 {
	if r.option.size == 0 {
		if texts.len != 0 {
			return error('${texts.len} part(s) for none: its request carries nothing past the identifier')
		}
		return []u8{}
	}
	return r.option.encode(texts)
}

// answer_texts decodes an answer's record into one text per answer part: one the description
// cannot lay out (not its size, a raw value no scale reads) is uds.UndecodableAnswer.
pub fn (r RoutineDesc) answer_texts(data []u8) ![]string {
	if r.answer.size == 0 {
		if data.len != 0 {
			return uds.UndecodableAnswer{
				why:  'routine ${r.label()}: ${data.len} byte(s) past the identifier, the description says none'
				resp: data.clone()
			}
		}
		return []string{}
	}
	return r.answer.read_texts(data) or {
		if err is uds.UndecodableAnswer {
			return uds.UndecodableAnswer{
				why:  'routine ${r.label()}: ${err.why.all_after(': ')}'
				resp: data.clone()
			}
		}
		return err
	}
}

// plan is what the run needs first on a connection in state `st`: nothing for a routine of no
// gate, else the gate's session and level (uds.gate_plan, a write's rule), refused for a gate
// the description leaves unresolved or one that cannot be met.
pub fn (r RoutineDesc) plan(st uds.ConnState, can_unlock bool) uds.WritePlan {
	if !r.gate.declared {
		return uds.WritePlan{}
	}
	sessions := r.gate.session_ids('its gate', 'served') or {
		return uds.WritePlan{
			refusal: 'not run: ${err.msg()}'
		}
	}
	return uds.gate_plan(uds.GateWords{'its gate', 'not run'}, st.session, sessions,
		u8(r.gate.level), st.security.unlocked(), can_unlock, r.authenticates)
}

// listed_routine is the routine control called `name`: refused for a name none has (naming those
// there are) or two share.
pub fn (d &EcuDesc) listed_routine(name string) !RoutineDesc {
	hits := d.routines.filter(it.name == name)
	if hits.len == 1 {
		return hits[0]
	}
	if hits.len > 1 {
		return error('${hits.len} routine controls are called "${name}"; the description names them alike')
	}
	if d.routines.len == 0 {
		return error('no routine "${name}": the description names no routine')
	}
	return error('no routine "${name}" in the description; there are: ${d.routines.map('"${it.name}"').join(', ')}')
}

// run_described runs routine control `r` with its option's `texts` (one per option part) as the
// description lays it out and gates it: refused before anything is sent when the codec refuses a
// part, the gate cannot be met, or the connection has not established the session and level the
// gate needs (WriteGated — nothing is switched or unlocked here). Its answer's record, as
// answer_texts reads it, is returned whole.
pub fn run_described(mut cli uds.Client, r RoutineDesc, texts []string) ![]u8 {
	option := r.encode_option(texts) or { return error('${r.label()}: not sent — ${err.msg()}') }
	plan := r.plan(cli.state, true)
	if plan.refusal != '' {
		return error('${r.label()}: ${plan.refusal}')
	}
	if plan.session != 0 || plan.unlock != 0 {
		return WriteGated{
			what:          r.label()
			session:       plan.session
			level:         plan.unlock
			state:         cli.state
			authenticates: plan.authenticates
		}
	}
	return cli.routine(r.id, option, r.control)!
}
