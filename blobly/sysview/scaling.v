module sysview

import math
import strconv

// scaling.v — a field's raw integer as what a tester reads and writes: a physical number through
// linear segments (ODX's LINEAR and SCALE-LINEAR), or a label through a text table (TEXTTABLE).
// The DID codec asks it per field (`DidDesc.scaling`), so a value is read and written one way.

// Scaling is how a field's raw value becomes its text: `segments` to a number, else `labels`.
pub struct Scaling {
pub:
	segments []Linear
	labels   []TextEntry
	fallback string // the label of a raw value no entry names ('' = shown as its number)
	unit     string
}

// Linear is one segment: physical = (v0 + v1 * raw) / d, for a raw value in lo..hi.
pub struct Linear {
pub:
	lo i64 = min_i64
	hi i64 = max_i64
	v0 f64
	v1 f64
	d  f64 = 1
}

// TextEntry is one label: a raw value in lo..hi reads as `text`, which is written as `write`.
pub struct TextEntry {
pub:
	lo    i64
	hi    i64
	text  string
	write i64
}

// kind is what the field's text holds: a number, or a label.
pub fn (s Scaling) kind() PartKind {
	return if s.segments.len > 0 { PartKind.number } else { PartKind.label }
}

fn (g Linear) physical(raw i64) f64 {
	return (g.v0 + g.v1 * f64(raw)) / g.d
}

// text is a raw value's text: its physical number (refused for a raw value in no segment), or its
// label (the fallback, else the raw number, for one no entry names).
fn (s Scaling) text(raw i64, lim Range) !string {
	if s.segments.len == 0 {
		for e in s.labels {
			if raw >= e.lo && raw <= e.hi {
				return e.text
			}
		}
		return if s.fallback != '' { s.fallback } else { '${raw}' }
	}
	for g in s.segments {
		if raw >= g.lo && raw <= g.hi {
			p := g.physical(raw)
			// fifteen digits drop the binary noise of a decimal factor; the exact form only where
			// those would write back another raw value
			short := '${p:.15g}'
			back := s.raw(short, lim) or { -1 }
			return if back == raw { short } else { p.str() }
		}
	}
	return error('raw ${raw} is in no scale of the description')
}

// raw is a text's raw value: a number as the raw value whose physical value is nearest it — the
// first segment's on a tie, one between two segments' values the nearer of them —, or a label's
// value (a decimal integer stands for itself where it is no label).
fn (s Scaling) raw(text string, lim Range) !i64 {
	t := text.trim_space()
	if s.segments.len == 0 {
		for e in s.labels {
			if e.text == t {
				if e.write < lim.min || e.write > lim.max {
					return error('"${t}" is written as ${e.write}, outside ${lim.min}..${lim.max}')
				}
				return e.write
			}
		}
		if t != '' && t == s.fallback {
			return error('"${t}" names no value to write')
		}
		v := strconv.parse_int(t, 10, 64) or {
			return error('"${t}" is not one of ${s.labels.map(it.text).join(', ')}')
		}
		if v < lim.min || v > lim.max {
			return error('${v} is outside ${lim.min}..${lim.max}')
		}
		return v
	}
	p := strconv.atof64(t) or { return error('"${t}" is not a number') }
	if t == '' || math.is_nan(p) || math.is_inf(p, 0) {
		return error('"${t}" is not a number')
	}
	mut best := i64(0)
	mut best_d := math.inf(1)
	mut held := false
	for g in s.segments {
		a, b := g.within(lim) or { continue }
		r := (p * g.d - g.v0) / g.v1
		// the segment's raw value nearest the text: the rounded one where the segment holds it,
		// else its end on the side the text lies
		mut cand := if r < f64(a) { a } else { b }
		if math.abs(r) <= 9.0e18 {
			raw := i64(math.round(r))
			if raw >= a && raw <= b {
				cand = raw
				held = true
			}
		}
		d := math.abs(g.physical(cand) - p)
		if d < best_d {
			best, best_d = cand, d
		}
	}
	lo, hi := s.bounds(lim)
	if held || (p >= lo && p <= hi) {
		return best
	}
	return error('${t} is outside ${s.span(lim)}')
}

// within is the segment's raw values that also lie in `lim`, none when none do.
fn (g Linear) within(lim Range) ?(i64, i64) {
	a := if g.lo > lim.min { g.lo } else { lim.min }
	b := if g.hi < lim.max { g.hi } else { lim.max }
	if a > b {
		return none
	}
	return a, b
}

// bounds is the lowest and highest physical value the segments give over `lim` (lo > hi: none).
fn (s Scaling) bounds(lim Range) (f64, f64) {
	mut lo := math.inf(1)
	mut hi := math.inf(-1)
	for g in s.segments {
		a, b := g.within(lim) or { continue }
		for r in [a, b] {
			p := g.physical(r)
			lo = math.min(lo, p)
			hi = math.max(hi, p)
		}
	}
	return lo, hi
}

// span is the physical values the segments give over `lim`, lowest first, with the unit.
fn (s Scaling) span(lim Range) string {
	lo, hi := s.bounds(lim)
	if lo > hi {
		return 'no value'
	}
	u := if s.unit != '' { ' ${s.unit}' } else { '' }
	return '${lo:.15g}..${hi:.15g}${u}'
}

// hint is what the field accepts: `number -40..6513.5 °C`, `one of Off, On, Auto`.
fn (s Scaling) hint(lim Range) string {
	if s.segments.len > 0 {
		return 'number ${s.span(lim)}'
	}
	return 'one of ${s.labels.map(it.text).join(', ')}'
}
