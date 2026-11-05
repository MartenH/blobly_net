// ldf — what an LDF (blobly/lindb) means in bus terms: the length and checksum model each frame
// is read with, the entries a simulated node publishes, and a schedule table as headers on a
// grid. lindb states the file; this is the one place it becomes Entries and Slots.
module lin

import blobly.lindb

// model_of is the codec's checksum model for the LDF's.
fn model_of(c lindb.Checksum) Model {
	return if c == .classic { .classic } else { .enhanced }
}

// expects_of is every frame's length and checksum model, keyed by id: what a decoder or a
// subscriber reads a response by. A frame whose model the LDF cannot state is left out, so it is
// read as a monitor reads an unknown id.
pub fn expects_of(l &lindb.Ldf) map[u8]Expect {
	mut out := map[u8]Expect{}
	for f in l.frames {
		m := l.checksum_model_for(f.id) or { continue }
		out[f.id] = Expect{
			len:   f.length
			model: model_of(m)
		}
	}
	return out
}

// publish_entries is a publish entry for every unconditional frame `node` publishes, its data
// the frame's template (every signal at its init value).
pub fn publish_entries(l &lindb.Ldf, node string) ![]Entry {
	mut out := []Entry{}
	for f in l.frames {
		if f.kind != .unconditional || f.publisher != node {
			continue
		}
		m := l.checksum_model_for(f.id) or {
			return error('lin: frame ${f.name} (0x${f.id:02X}) of ${node}: ${err.msg()}')
		}
		out << Entry{
			id:    f.id
			dir:   .publish
			len:   f.length
			model: model_of(m)
			data:  l.template(f)
		}
	}
	return out
}

// LdfSchedule is a schedule table as headers on a grid, and what of it v1 does not send.
pub struct LdfSchedule {
pub:
	slots []Slot
	notes []string
}

// schedule_of is the named schedule table as slots. A slot v1 does not send — a diagnostic
// frame, an event-triggered or sporadic frame, a configuration command — still lasts its delay:
// that time is added to the slot before it (or, for the first, to the table's last slot, since
// a table repeats), so the frames that are sent keep their place on the grid. Each is noted.
pub fn schedule_of(l &lindb.Ldf, name string) !LdfSchedule {
	table := l.schedule(name) or {
		names := l.schedules.map(it.name)
		return error('lin: no schedule table `${name}` in the LDF (it has ${if names.len == 0 {
			'none'
		} else {
			names.join(', ')
		}})')
	}
	mut ids := []u8{}
	mut delays := []f64{}
	mut lead := 0.0
	mut notes := []string{}
	for s in table {
		if s.kind == .frame {
			if f := l.frame(s.frame) {
				ids << f.id
				delays << s.delay_ms
				continue
			}
		}
		what := match s.kind {
			.frame { 'frame ${s.frame}, which the LDF does not define,' }
			.diagnostic { 'diagnostic frame ${s.frame}' }
			.event_triggered { 'event-triggered frame ${s.frame}' }
			.sporadic { 'sporadic frame ${s.frame}' }
			.command { 'command ${s.command}' }
		}
		notes << 'schedule ${name}: ${what} is not sent; its ${lindb.fmt_num(s.delay_ms)} ms are kept as a gap'
		if delays.len == 0 {
			lead += s.delay_ms
		} else {
			delays[delays.len - 1] += s.delay_ms
		}
	}
	if ids.len == 0 {
		return error('lin: schedule table `${name}` has no unconditional frame to send')
	}
	delays[delays.len - 1] += lead
	mut slots := []Slot{cap: ids.len}
	for i, id in ids {
		slots << Slot{
			id:       id
			delay_ms: delays[i]
		}
	}
	return LdfSchedule{
		slots: slots
		notes: notes
	}
}
