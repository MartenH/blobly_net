module xsd

import flatxml

// Content models: the order and number of an element's children (XSD 1.0 Part 1, 3.8 and 3.9).
// Most are decided by an automaton (dfa.v). The rest, and every refusal's explanation, are the
// walker's: it follows the model's own tree with a stack of frames, one per sequence or choice
// being matched, each counting its occurrences, so nothing is unrolled and maxOccurs="5000" costs
// a counter, not 5,000 states. The schema's content models are deterministic (Unique Particle
// Attribution, checked when the schema compiles), so each child is matched without looking ahead.

// FirstSet is what a particle can begin with: element names, and for a choice the branch each
// name starts.
struct FirstSet {
mut:
	keys map[u64]int
}

// Frame is a sequence or choice being matched: its occurrences completed, whether one is in
// progress, and within it the current item (a sequence's) or branch (a choice's) and how many
// times that item, when it is an element, has occurred.
struct Frame {
	p u32
mut:
	occ    u32
	inside bool
	pos    int
	count  u32
}

// first_of is the first set of particle p, made on first use.
fn (mut vr Validator) first_of(p u32) &FirstSet {
	if !isnil(vr.firsts[p]) {
		return vr.firsts[p]
	}
	mut fs := &FirstSet{}
	pt := vr.s.particles[p]
	// a particle that can occur no times begins with nothing
	if pt.max == 0 {
		vr.firsts[p] = fs
		return fs
	}
	match pt.kind {
		.element {
			fs.keys[vr.s.elements[pt.term].name.key()] = 0
		}
		.choice {
			for b, ch in vr.s.particle_children(p) {
				for k, _ in vr.first_of(ch).keys {
					if k !in fs.keys {
						fs.keys[k] = b
					}
				}
			}
		}
		else {
			// a sequence begins with its first item, and with the next while those before can be empty
			for ch in vr.s.particle_children(p) {
				for k, _ in vr.first_of(ch).keys {
					fs.keys[k] = 0
				}
				if !vr.s.nullable(ch) {
					break
				}
			}
		}
	}
	vr.firsts[p] = fs
	return fs
}

// nullable reports whether particle p can match no elements at all.
@[inline]
pub fn (s &Schema) nullable(p u32) bool {
	return s.empties[p] & 2 != 0
}

// body_nullable reports whether one occurrence of particle p can be empty.
@[inline]
fn (s &Schema) body_nullable(p u32) bool {
	return s.empties[p] & 1 != 0
}

// compute_empties works out, for every particle, whether one occurrence can be empty and whether
// the particle can match nothing, children first (group references are resolved and cycles
// refused by now), so the walker reads them instead of recomputing them for every child.
fn (mut s Schema) compute_empties() {
	s.empties = []u8{len: s.particles.len}
	mut done := []bool{len: s.particles.len}
	for p in 1 .. s.particles.len {
		s.empty_of(u32(p), mut done)
	}
}

fn (mut s Schema) empty_of(p u32, mut done []bool) u8 {
	if done[p] {
		return s.empties[p]
	}
	pt := s.particles[p]
	mut body := false
	if pt.kind == .choice {
		for ch in s.particle_children(p) {
			if s.empty_of(ch, mut done) & 2 != 0 {
				body = true
			}
		}
	} else if pt.kind == .sequence {
		body = true
		for ch in s.particle_children(p) {
			if s.empty_of(ch, mut done) & 2 == 0 {
				body = false
			}
		}
	}
	mut bits := u8(0)
	if body {
		bits |= 1
	}
	if pt.min == 0 || body {
		bits |= 2
	}
	s.empties[p] = bits
	done[p] = true
	return bits
}

// check_content matches the element children of element i, of complex type ct, against its
// content model, reporting the first problem: a child not expected where it is, one too many, or
// one missing at the end. Children the type does not declare are left out: the typing pass
// reports them.
fn (mut vr Validator) check_content(i u32, ct u32) {
	dfa := vr.content_dfa(ct)
	if !isnil(dfa) && vr.dfa_accepts(dfa, vr.type_index(ct), i) {
		return
	}
	if !vr.walk_content(i, ct) && !isnil(dfa) {
		// the automaton refused what the walker found nothing wrong with: a defect, so not let pass
		if vr.keep() {
			vr.add(i, .unexpected_element, 'the children of <${vr.d.name(i)}> do not match its content model')
		}
	}
}

// walk_content is check_content by the walker; whether it found a problem.
fn (mut vr Validator) walk_content(i u32, ct u32) bool {
	root := vr.s.complex_types[ct].particle
	idx := vr.type_index(ct)
	// one stack for the whole validation, emptied for each element
	mut stack := unsafe { &vr.frames }
	stack.clear()
	stack << Frame{
		p: root
	}
	mut c := vr.d.first_child(i)
	// Each element child, in order, fed through the frames.
	for c != flatxml.no_node {
		key := if vr.d.is_element(c) { vr.key(c) or { u64(0) } } else { u64(0) }
		if slot := idx.children[key] {
			vr.v.decl[c] = idx.decls[slot] + 1
			if problem := vr.feed(mut stack, key) {
				if vr.keep() {
					vr.add(c, .unexpected_element, '<${vr.d.name(c)}> ${problem} in <${vr.d.name(i)}>')
				}
				return true
			}
		}
		c = vr.d.next_sibling(c)
	}
	if missing := vr.finish(mut stack) {
		if vr.keep() {
			vr.add(i, .missing_element, '<${vr.d.name(i)}> is missing ${missing}')
		}
		return true
	}
	return false
}

// feed matches one child named key, moving the frames on; a message when it cannot be matched.
fn (mut vr Validator) feed(mut stack []Frame, key u64) ?string {
	vr.too_many = false
	for {
		if stack.len == 0 {
			if vr.too_many {
				return 'occurs too often'
			}
			return 'is not expected here: the content is complete'
		}
		top := stack.len - 1
		p := stack[top].p
		pt := vr.s.particles[p]
		if !stack[top].inside {
			// start another occurrence, or let the group go
			branch := if stack[top].occ < pt.max { vr.first_of(p).keys[key] or { -1 } } else { -1 }
			if branch >= 0 {
				stack[top].inside = true
				stack[top].count = 0
				stack[top].pos = if pt.kind == .choice { branch } else { 0 }
			} else if stack[top].occ >= pt.min || vr.s.body_nullable(p) {
				vr.pop(mut stack)
				continue
			} else {
				return vr.unexpected(p)
			}
		}
		items := vr.s.particle_children(p)
		if pt.kind == .choice {
			item := items[stack[top].pos]
			if vr.s.particles[item].kind == .element {
				ip := vr.s.particles[item]
				if vr.s.elements[ip.term].name.key() == key && stack[top].count < ip.max {
					stack[top].count++
					return none
				}
				if stack[top].count < ip.min {
					return 'is not expected here: expected another ${vr.names_of(item)}'
				}
				stack[top].occ++
				stack[top].inside = false
				continue
			}
			stack << Frame{
				p: item
			}
			continue
		}
		// a sequence: find the item that takes key, passing items already satisfied
		mut moved := false
		for stack[top].pos < items.len {
			item := items[stack[top].pos]
			ip := vr.s.particles[item]
			if ip.kind == .element {
				same := vr.s.elements[ip.term].name.key() == key
				if same && stack[top].count < ip.max {
					stack[top].count++
					return none
				}
				if stack[top].count < ip.min {
					return vr.unexpected(item)
				}
				if same {
					vr.too_many = true
				}
				stack[top].pos++
				stack[top].count = 0
				continue
			}
			if key in vr.first_of(item).keys {
				stack << Frame{
					p: item
				}
				moved = true
				break
			}
			if !vr.s.nullable(item) {
				return vr.unexpected(item)
			}
			stack[top].pos++
			stack[top].count = 0
		}
		if moved {
			continue
		}
		// every item done: this occurrence is complete
		stack[top].occ++
		stack[top].inside = false
	}
	return none
}

// pop ends the top frame, a group item of the frame below, which moves past it.
fn (mut vr Validator) pop(mut stack []Frame) {
	stack.delete_last()
	if stack.len == 0 {
		return
	}
	top := stack.len - 1
	if vr.s.particles[stack[top].p].kind == .choice {
		stack[top].occ++
		stack[top].inside = false
	} else {
		stack[top].pos++
		stack[top].count = 0
	}
}

// finish checks, at the end of the children, that every frame can end: the items left in an
// occurrence can be empty, and each group has occurred often enough. It names what is missing.
fn (mut vr Validator) finish(mut stack []Frame) ?string {
	for stack.len > 0 {
		top := stack.len - 1
		p := stack[top].p
		pt := vr.s.particles[p]
		if stack[top].inside {
			items := vr.s.particle_children(p)
			start := stack[top].pos
			if start < items.len {
				item := items[start]
				ip := vr.s.particles[item]
				if ip.kind == .element && stack[top].count < ip.min {
					return vr.names_of(item)
				}
				// a group item not started (one that ran has been passed) must be able to be empty
				if ip.kind != .element && pt.kind != .choice && !vr.s.nullable(item) {
					return vr.names_of(item)
				}
				// a sequence's remaining items must all be able to be empty
				if pt.kind != .choice {
					for k in start + 1 .. items.len {
						if !vr.s.nullable(items[k]) {
							return vr.names_of(items[k])
						}
					}
				}
			}
			stack[top].occ++
			stack[top].inside = false
		}
		if stack[top].occ < pt.min && !vr.s.body_nullable(p) {
			return vr.names_of(p)
		}
		vr.pop(mut stack)
	}
	return none
}

// unexpected is the message for a child that does not fit where particle p is expected: too
// many of an element passed over, or something else where p belongs.
fn (mut vr Validator) unexpected(p u32) string {
	if vr.too_many {
		return 'occurs too often'
	}
	return 'is not expected here: expected ${vr.names_of(p)}'
}

// names_of is what particle p can begin with, as element names for a message.
fn (mut vr Validator) names_of(p u32) string {
	mut names := []string{}
	for k, _ in vr.first_of(p).keys {
		names << '<${vr.s.names[u32(k)]}>'
		if names.len == 4 {
			names << '...'
			break
		}
	}
	return names.join(' or ')
}
