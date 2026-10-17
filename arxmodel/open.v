module arxmodel

import flatxml
import os
import strings

// Opened is a model opened for reading: its files merged into one view, and every referrable
// element by its AUTOSAR path. It is what a program that reads a model, rather than checks it,
// starts from: elements by path and by kind, references followed, positions in the files.
//
// The merge is by the schema the files declare where a schema directory (or a rules file made
// from one) is given: the AUTOSAR merge model, exactly. Without one it is by the built-in
// identity rules (identity.toml), which key every named element by its SHORT-NAME: right for one
// file, and for most splits, but not the specification's rules. `rules` says which was read by.
@[heap]
pub struct Opened {
pub mut:
	model &Model          = unsafe { nil }
	view  &flatxml.Merged = unsafe { nil }
	index &PathIndex      = unsafe { nil }
	rules string   // what the files were merged by: a schema's name, a rules file, or the built-in rules
	notes []string // what choosing the rules had to say (a rules file made for another release)
	// the files the rules were read from: the rules file; or the configuration file that named
	// the schema directory (OpenOptions.config) and every schema document the files declare that
	// was found, with what they import (inside the schema directory or not)
	rule_files []string
	findings   []Finding // what the merge found, with the policy's severities
	// the elements one file describes more than once (a key repeated among siblings), merged
	// into one as the identity rules merge any: `path: file:line, file:line`
	repeated []string
mut:
	by_kind map[u32][]u32 // local name id -> the referrable merged nodes of it, document order
}

@[params]
pub struct OpenOptions {
pub:
	jobs       int      // threads to parse with; 0 for `default_jobs`
	exclude    []string // file globs left out of the input set
	schema_dir string   // where the schemas the files declare are; '' for none
	rules_file string   // a rules file to merge by instead of a schema (`arxmodel rules --emit`)
	policy     string   // `spec` (the default), `automat`, or a policy file
	// the configuration file schema_dir was read from (`configured_schema_dir`); '' for none
	config string
}

// Source is a document given as bytes, named by its path: for a caller that has read it already.
pub struct Source {
pub:
	path string
	data []u8
}

// open reads the input set at the paths (see `load`) and opens it. A file that fails to parse is
// in `model.failed`, and the rest are opened all the same: whether that is an error is the
// caller's to decide.
pub fn open(paths []string, opts OpenOptions) !&Opened {
	mut m := load(paths, jobs: opts.jobs, exclude: opts.exclude)!
	return open_model(m, opts) or {
		m.free()
		return err
	}
}

// open_sources opens documents given as bytes, in the order given: the order a merge keeps the
// first value of where they differ. A document that does not parse, or whose namespaces do not
// resolve, is an error.
pub fn open_sources(srcs []Source, opts OpenOptions) !&Opened {
	mut set := flatxml.DocSet.new()
	mut files := []string{cap: srcs.len}
	mut bytes := i64(0)
	for s in srcs {
		mut d := flatxml.parse_bytes(s.data, s.path) or {
			set.free()
			return err
		}
		d.resolve_namespaces() or {
			d.free()
			set.free()
			return error('${s.path}: ${err.msg()}')
		}
		set.add(mut d)
		files << s.path
		bytes += s.data.len
	}
	mut m := &Model{
		set:   set
		files: files
		bytes: bytes
	}
	return open_model(m, opts) or {
		m.free()
		return err
	}
}

// open_model merges a loaded model and indexes its paths: by a rules file, else by the schema
// governing the files, else by the built-in identity rules. A schema directory given in which no
// schema governs the files is an error, not a quiet fall back to other rules. The XML schema,
// multiplicity and reference layers are not run: they are a check's, not a reader's. The
// findings are the policy's, its filters applied. On an error the model is the caller's to free.
pub fn open_model(m &Model, opts OpenOptions) !&Opened {
	p := named_policy(if opts.policy == '' { 'spec' } else { opts.policy })!
	mut flat := Flat{}
	mut st := p.settings()
	mut name := ''
	mut notes := []string{}
	mut ty := &Typing(unsafe { nil })
	mut rule_files := []string{}
	if opts.rules_file != '' {
		text := os.read_file(opts.rules_file) or { return error('${opts.rules_file}: ${err.msg()}') }
		f, pv, fst := parse_rules_file(text) or { return error('${opts.rules_file}: ${err.msg()}') }
		notes << rules_file_check(declare_schemas(m), pv, fst, p) or {
			return error('${opts.rules_file}: ${err.msg()}')
		}
		flat, st, name = f, fst, 'rules file ${os.file_name(opts.rules_file)} (${pv.schema})'
		rule_files << opts.rules_file
	} else if opts.schema_dir != '' {
		sc := compile_schemas(m, opts.schema_dir, policy: p)
		if opts.config != '' {
			rule_files << opts.config
		}
		rule_files << sc.files()
		why := 'merging by the schemas in ${opts.schema_dir}'
		f, gname := governing_flat(sc) or { return error('${why}: ${err.msg()}') }
		gov := governing_use(sc) or { return error('${why}: ${err.msg()}') }
		flat, name = f, 'schema ${gname}'
		ty = new_typing(gov.schema)
	} else {
		flat, name = identity_flat(builtin_identity(), [m]), 'built-in identity rules'
	}
	// a reader reads in the order the files are written: siblings as first written, not by key.
	// The rules name the local namespace already (the schema's, or the model's for the built-in
	// rules), so `ar:X` in one file is X in another, as check merges them
	flat.rules = flatxml.RuleSet{
		...flat.rules
		written_order: true
	}
	copts := CheckOptions{
		skip_xml:          true
		skip_multiplicity: true
		skip_references:   true
	}
	mut c := check_typed(m, flat, name, st, p, copts, ty)!
	if opts.rules_file == '' && opts.schema_dir == '' {
		nm := naming(flat.rules.local_ns, [m])
		_, ignored := st.apply(m, copts)
		mut ignore := ignored_identities(ignored, [m])
		for a in ignored {
			ignore[a] = true
		}
		c.findings << singles_differ(mut c.view, c.index, p, &nm, ignore)
	}
	c.filter(p, copts, m)
	mut o := &Opened{
		model:      m
		view:       c.view
		index:      c.index
		rules:      name
		notes:      notes
		rule_files: rule_files
		findings:   c.findings
	}
	// by the id the merge names a node by: its local name's, in the document's namespace
	for k in c.index.nodes {
		o.by_kind[c.view.node(k).tag()] << k
	}
	// the outermost of what one file repeats: below a repeated element everything repeats with
	// it, and is the one repetition (a parent's index is below its children's)
	mut v := c.view
	mut repeats := []bool{len: v.len()}
	for i in 0 .. v.len() {
		n := v.node(u32(i))
		if n.fragment_count() < 2 {
			continue
		}
		frags := n.fragments()
		mut docs := map[voidptr]bool{}
		for f in frags {
			docs[voidptr(f.doc)] = true
		}
		if docs.len < frags.len {
			repeats[i] = true
			up := n.parent()
			if !(up.ok() && repeats[up.i]) {
				o.repeated << '${merged_path(n, c.index)}: ${frags.map(v.pos(it)).join(', ')}'
			}
		}
	}
	return o
}

// singles_differ are what the built-in rules' merge cannot say. They match an unnamed element by
// its place, each file's apart; so under a merged element, the children of one name and
// attributes that each file gives once (a frame's FRAME-LENGTH) are one element of the model,
// read from the first file, and content in which they differ is a finding, as the merge makes
// one. Attributes the merge ignores (ignore: by name, and by the identity any document gives a
// name ignored) are no part of either.
fn singles_differ(mut v flatxml.Merged, index &PathIndex, p Policy, nm &Naming, ignore map[string]bool) []Finding {
	mut out := []Finding{}
	mut slots := map[voidptr]int{}
	for i in 0 .. v.len() {
		n := v.node(u32(i))
		if n.fragment_count() < 2 {
			continue
		}
		mut number := map[string]int{} // a group's identity -> its number, in the order met
		mut groups := [][]flatxml.MNode{}
		mut seen := map[u64]bool{} // group number << 32 | document number: a member of the group
		mut repeated := []bool{}
		for ch in n.children() {
			if ch.keyed() || ch.fragment_count() != 1 {
				continue
			}
			f := ch.fragment(0)
			mut sb := strings.new_builder(32)
			write_open(mut sb, f, nm, ignore)
			id := sb.str()
			gi := number[id] or {
				number[id] = groups.len
				groups << []flatxml.MNode{}
				repeated << false
				groups.len - 1
			}
			member := u64(gi) << 32 | u64(doc_number(mut slots, f.doc))
			if member in seen {
				repeated[gi] = true
			}
			seen[member] = true
			groups[gi] << ch
		}
		for gi, g in groups {
			if g.len < 2 || repeated[gi] {
				continue
			}
			first := canonical(g[0].fragment(0), nm, ignore)
			if g[1..].all(canonical(it.fragment(0), nm, ignore) == first) {
				continue
			}
			what := nm.node_name(g[0].fragment(0))
			out << Finding{
				layer:    .merge
				kind:     'value_differs'
				what:     what
				severity: p.merge_severity('value_differs', what, false)
				path:     merged_path(g[0], index)
				message:  '${what} differs between the files; the first is read'
				at:       g.map(v.pos(it.fragment(0)))
			}
		}
	}
	return out
}

// doc_number is a document's number, given in the order asked.
fn doc_number(mut slots map[voidptr]int, d &flatxml.Doc) int {
	if k := slots[voidptr(d)] {
		return k
	}
	slots[voidptr(d)] = slots.len
	return slots.len - 1
}

// write_open writes an element's name and attributes, as the merge names them, the attributes
// sorted (their order tells nothing apart) and those in ignore left out; each part
// length-prefixed, so no text can pass for a part.
fn write_open(mut sb strings.Builder, n flatxml.Node, nm &Naming, ignore map[string]bool) {
	write_part(mut sb, nm.node_name(n))
	lo, hi := n.doc.attr_range(n.i)
	mut attrs := []string{}
	for a := lo; a < hi; a++ {
		if n.doc.is_ns_decl(a) {
			continue
		}
		id := n.doc.tab.name(n.doc.attr_id(a))
		if id in ignore || n.doc.attr_name(a) in ignore {
			continue
		}
		mut ab := strings.new_builder(id.len + 16)
		write_part(mut ab, id)
		write_part(mut ab, n.doc.attr_value(a))
		attrs << ab.str()
	}
	attrs.sort()
	sb.write_string('${attrs.len}@')
	for x in attrs {
		sb.write_string(x)
	}
}

fn write_part(mut sb strings.Builder, s string) {
	sb.write_string('${s.len}:')
	sb.write_string(s)
}

// canonical is an element's whole content, as one string: its name and attributes (write_open),
// its own text in each slot among its children (the runs of one slot joined, then trimmed) and
// its children so, in document order.
fn canonical(n flatxml.Node, nm &Naming, ignore map[string]bool) string {
	mut sb := strings.new_builder(64)
	write_canonical(mut sb, n, nm, ignore)
	return sb.str()
}

fn write_canonical(mut sb strings.Builder, n flatxml.Node, nm &Naming, ignore map[string]bool) {
	sb.write_u8(`<`)
	write_open(mut sb, n, nm, ignore)
	runs := n.text_runs()
	mut r := 0
	mut slot := 0
	mut kids := []flatxml.Node{}
	for c in n.children() {
		kids << c
	}
	for {
		mut text := strings.new_builder(16)
		for r < runs.len && runs[r].slot == slot {
			text.write_string(runs[r].text)
			r++
		}
		t := text.str()
		write_part(mut sb, t.trim_space())
		if slot >= kids.len {
			break
		}
		write_canonical(mut sb, kids[slot], nm, ignore)
		slot++
	}
	sb.write_u8(`>`)
}

// model_namespace is the namespace a model is in: the one most of its documents' roots are in,
// the first such in the documents' order on a tie, which a merge by the built-in rules names by
// local names (flatxml's local_ns); a document whose root is in another is not merged. '' for
// none, or documents whose namespaces are not resolved.
pub fn model_namespace(models []&Model) string {
	mut count := map[string]int{}
	mut order := []string{}
	for m in models {
		for d in m.set.docs {
			if d.ns.len != d.tag.len {
				return ''
			}
			uri := d.ns_uri(d.ns_of(d.root()))
			if uri !in count {
				order << uri
			}
			count[uri]++
		}
	}
	mut best := ''
	mut most := 0
	for uri in order {
		if count[uri] > most {
			best, most = uri, count[uri]
		}
	}
	return best
}

// free releases the documents. Nothing opened from them may be used after.
pub fn (mut o Opened) free() {
	if o.model != unsafe { nil } {
		o.model.free()
	}
}

// root is the merged root element.
pub fn (o &Opened) root() flatxml.MNode {
	return o.view.root()
}

// at is the element at an AUTOSAR path (`/Pkg/Name`), the first of them in document order where
// the merge keeps several apart (`holders`); an empty handle where there is none.
pub fn (o &Opened) at(path string) flatxml.MNode {
	hs := o.index.holders(path)
	return if hs.len == 0 { flatxml.MNode{} } else { o.view.node(hs[0]) }
}

// holders are every element at an AUTOSAR path, in document order: more than one where elements
// the merge keeps apart share it (a model's own finding).
pub fn (o &Opened) holders(path string) []flatxml.MNode {
	return o.index.holders(path).map(o.view.node(it))
}

// path_of is a referrable element's AUTOSAR path; '' for one that is not referrable.
pub fn (o &Opened) path_of(n flatxml.MNode) string {
	return o.index.path_of(n.i) or { '' }
}

// of_kind is every referrable element of a name, compared without its prefix, in document order.
pub fn (o &Opened) of_kind(name string) []flatxml.MNode {
	id := o.view.set.tab.id(name) or { return [] }
	return (o.by_kind[id] or { return [] }).map(o.view.node(it))
}

// target is the element a reference points at: the reference element's text as an absolute
// AUTOSAR path. none for an empty, relative (BASE, or not from the root) or dangling one.
pub fn (o &Opened) target(ref flatxml.MNode) ?flatxml.MNode {
	path := ref.text().trim_space()
	if !path.starts_with('/') || ref.attr(base_attribute) != '' {
		return none
	}
	n := o.at(path)
	return if n.ok() { n } else { none }
}

// pos is `file:line:column` of an element's first contribution.
pub fn (mut o Opened) pos(n flatxml.MNode) string {
	return if n.ok() { o.view.pos(n.fragment(0)) } else { '' }
}
