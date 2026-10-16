module arxmodel

import flatxml
import flatxml.xsd

// --- XML schema --------------------------------------------------------------------------------

// xml_findings checks each document against the XML schema it declares, or the governing one
// where its own is not at hand: every partial model must be valid on its own ([TPS_GST_00423]).
// Documents are checked in parallel; a schema is only read. Also returns how many documents were
// checked against the governing schema because their own is not at hand. Each finding comes with
// the document and element it is on (doc -1 when it is on no element); its path is the element's
// names from the root, which check replaces by the merged node's AUTOSAR path.
pub fn xml_findings(m &Model, sc &Schemas, jobs_asked int) ([]XmlFound, int) {
	mut gov := &xsd.Schema(unsafe { nil })
	if u := governing_use(sc) {
		gov = u.schema
	}
	mut schema_of := []&xsd.Schema{len: m.set.docs.len, init: unsafe { nil }}
	mut fallback := 0
	for u in sc.uses {
		for k in u.docs {
			schema_of[k] = if u.schema != unsafe { nil } { u.schema } else { gov }
			if u.schema == unsafe { nil } && gov != unsafe { nil } {
				fallback++
			}
		}
	}
	mut jobs := jobs_or_default(jobs_asked)
	jobs = if jobs > 16 {
		16
	} else if jobs < 1 {
		1
	} else {
		jobs
	}
	mut threads := []thread []XmlFound{}
	for w in 0 .. jobs {
		threads << spawn validate_every(m, schema_of, w, jobs, sc.policy)
	}
	mut out := []XmlFound{}
	for t in threads {
		out << t.wait()
	}
	return out, fallback
}

// XmlFound is an XML schema finding and the element it is on.
pub struct XmlFound {
pub:
	finding Finding
	doc     int = -1
	node    u32
}

fn validate_every(m &Model, schema_of []&xsd.Schema, first int, step int, p Policy) []XmlFound {
	mut out := []XmlFound{}
	// a checker per schema, kept for this thread's documents: what it works out about the schema
	// (each type's index and automaton, each pattern's) is the same for every document, and
	// worked out again per document it was most of this layer's time
	mut checkers := map[voidptr]&xsd.Checker{}
	for k := first; k < m.set.docs.len; k += step {
		s := schema_of[k]
		if s == unsafe { nil } {
			continue
		}
		mut d := m.set.docs[k]
		mut c := checkers[voidptr(s)] or {
			// every finding kept: one past a cap would be an error lost
			nc := xsd.new_checker(s, max_findings: max_i32)
			checkers[voidptr(s)] = nc
			nc
		}
		v := c.validate(mut d) or {
			out << XmlFound{
				finding: Finding{
					layer:    .xml_schema
					kind:     'not_checked'
					severity: p.severity(.xml_schema, 'not_checked', '')
					path:     d.path
					message:  err.msg()
					at:       [d.path]
				}
			}
			continue
		}
		// a position from the document's line index, made on its first finding (none for a
		// document without one)
		for f in v.findings {
			kind := f.kind.str()
			line, col := d.line_col(f.node)
			what := d.name(f.node)
			out << XmlFound{
				finding: Finding{
					layer:    .xml_schema
					kind:     kind
					what:     what
					severity: p.severity(.xml_schema, kind, what)
					path:     '#' + doc_names(d, f.node)
					message:  f.msg
					at:       ['${d.path}:${line}:${col}']
				}
				doc:     k
				node:    f.node
			}
		}
	}
	return out
}

// --- multiplicities ----------------------------------------------------------------------------

// multiplicity_findings counts, in the merged model, each role of each element whose type is
// known, against the meta-model's fewest and most ([constr_2502]). The XML schema makes lower
// bounds 0 so a model may be split, so a role below its fewest can only be found here, after
// merging; that is its own kind (below_min), above the most another (above_max). A role that is
// one alternative of a choice in its holder's content has no fewest of its own.
// What the merge already reported on a role (too many, a collision) is not said again. A wrapper
// holding its items' content has no element per item to count: such roles are not checked, and
// counted as such.
pub fn (rs &RuleSet) multiplicity_findings(mut v flatxml.Merged, ix &PathIndex, p Policy) ([]Finding, int) {
	s := rs.schema
	tab := v.set.tab
	// per complex type: the roles held; per complex type and child name id: the child's type
	mut rules_of := [][]int{len: s.complex_types.len}
	for k, r in rs.rules {
		for ct in r.held_by {
			rules_of[ct] << k
		}
	}
	// roles that are alternatives of a choice in their holder's content (mixed content, a
	// content class): one of several, so none is required on its own
	// per holder type and declaration, since a group's declarations are shared between holders
	mut alternative := map[u64]bool{}
	for t, ct in s.complex_types {
		if ct.particle != xsd.no_particle {
			rs.mark_alternatives(u32(t), ct.particle, false, mut alternative)
		}
	}
	// the merge's problems by node and element: what it said needs no second finding
	mut reported := map[string]bool{}
	for pr in v.problems {
		reported['${pr.node} ${pr.what}'] = true
	}
	mut unchecked := 0
	mut child_type := map[u64]xsd.TypeRef{}
	for t, ct in s.complex_types {
		if ct.particle == xsd.no_particle {
			continue
		}
		mut occ := []Occ{}
		rs.walk(ct.particle, 1, mut occ)
		for o in occ {
			e := s.elements[o.decl]
			id := tab.id(s.names[e.name.local]) or { continue }
			key := u64(t) << 32 | id
			if key !in child_type {
				child_type[key] = e.typ
			}
		}
	}
	// the name ids a role is counted by: its element, or a wrapper's items
	mut counted := [][]u32{len: rs.rules.len}
	mut wrapper_id := []u32{len: rs.rules.len}
	for k, r in rs.rules {
		wrapper_id[k] = tab.id(r.element) or { 0 }
		if r.wrapper && !r.flat {
			counted[k] = r.items.map(tab.id(it.element) or { u32(0) })
		}
	}
	mut out := []Finding{}
	root := v.root()
	if !root.ok() {
		return out, 0
	}
	mut root_type := xsd.TypeRef{}
	mut found := false
	for d in s.global_elements() {
		if s.names[s.elements[d].name.local] == root.name() {
			root_type = s.elements[d].typ
			found = true
			break
		}
	}
	if !found || root_type.kind != .complex {
		return out, 0
	}
	mut stack := [root.i]
	mut types := [root_type.idx]
	// one node's children, a list kept between nodes: made per node, it was most of this
	// layer's allocation
	mut kids := []flatxml.MNode{}
	for stack.len > 0 {
		n := v.node(stack.pop())
		ct := types.pop()
		kids.clear()
		for c in n.children() {
			kids << c
		}
		for k in rules_of[ct] {
			r := rs.rules[k]
			if r.flat {
				if kids.any(it.tag() == wrapper_id[k]) {
					unchecked++
				}
				continue
			}
			mut count := u32(0)
			for c in kids {
				if c.tag() != wrapper_id[k] {
					continue
				}
				if r.wrapper {
					for item in c.children() {
						if item.tag() in counted[k] {
							count++
						}
					}
				} else {
					count++
				}
			}
			decl := rs.outer_of[r.decl] or { r.decl }
			if count < r.min && (u64(ct) << 32 | decl) !in alternative {
				out << rs.count_finding(mut v, ix, n, r, 'below_min', 'fewer than the fewest, ${r.min}: ${count}', p)
			} else if r.max != unbounded && count > r.max
				&& !rs.merge_said(kids, wrapper_id[k], n, r, reported) {
				out << rs.count_finding(mut v, ix, n, r, 'above_max', 'more than the most, ${r.max}: ${count}', p)
			}
		}
		for c in kids {
			t := child_type[u64(ct) << 32 | c.tag()] or { continue }
			if t.kind == .complex {
				stack << c.i
				types << t.idx
			}
		}
	}
	return out, unchecked
}

fn (rs &RuleSet) count_finding(mut v flatxml.Merged, ix &PathIndex, n flatxml.MNode, r Rule, kind string, msg string, p Policy) Finding {
	return Finding{
		layer:    .multiplicity
		kind:     kind
		what:     r.element
		severity: p.severity(.multiplicity, kind, r.element)
		path:     merged_path(n, ix)
		message:  '${r.name} (${r.element}): ${msg}'
		at:       n.fragments().map(v.pos(it))
	}
}

// mark_alternatives marks, for holder type ct, the element declarations under a choice of
// several alternatives in its content.
fn (rs &RuleSet) mark_alternatives(ct u32, p u32, under bool, mut out map[u64]bool) {
	pt := rs.schema.particles[p]
	if pt.kind == .element {
		if under {
			out[u64(ct) << 32 | pt.term] = true
		}
		return
	}
	kids := rs.schema.particle_children(p)
	choice := pt.kind == .choice && kids.len > 1
	for c in kids {
		rs.mark_alternatives(ct, c, under || choice, mut out)
	}
}

// merge_said reports whether the merge already reported a role on node n: on n for its element,
// or, for a wrapper, on the wrapper for an item.
fn (rs &RuleSet) merge_said(kids []flatxml.MNode, wrapper u32, n flatxml.MNode, r Rule, reported map[string]bool) bool {
	if '${n.i} ${r.element}' in reported {
		return true
	}
	for c in kids {
		if r.wrapper && c.tag() == wrapper && r.items.any('${c.i} ${it.element}' in reported) {
			return true
		}
	}
	return false
}

// doc_names is an element's names from its document's root, `A/B/C`.
fn doc_names(d &flatxml.Doc, i u32) string {
	mut names := []string{}
	mut cur := d.node(i)
	for cur.ok() {
		names << cur.name()
		cur = cur.parent()
	}
	return names.reverse().join('/')
}
