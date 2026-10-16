module arxmodel

import flatxml
import os

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
	model    &Model          = unsafe { nil }
	view     &flatxml.Merged = unsafe { nil }
	index    &PathIndex      = unsafe { nil }
	rules    string    // what the files were merged by: a schema's name, a rules file, or the built-in rules
	notes    []string  // what choosing the rules had to say (a rules file made for another release)
	findings []Finding // what the merge found, with the policy's severities
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
	if opts.rules_file != '' {
		text := os.read_file(opts.rules_file) or { return error('${opts.rules_file}: ${err.msg()}') }
		f, pv, fst := parse_rules_file(text) or { return error('${opts.rules_file}: ${err.msg()}') }
		notes << rules_file_check(declare_schemas(m), pv, fst, p) or {
			return error('${opts.rules_file}: ${err.msg()}')
		}
		flat, st, name = f, fst, 'rules file ${os.file_name(opts.rules_file)} (${pv.schema})'
	} else if opts.schema_dir != '' {
		sc := compile_schemas(m, opts.schema_dir, policy: p)
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
	c.filter(p, copts, m)
	mut o := &Opened{
		model:    m
		view:     c.view
		index:    c.index
		rules:    name
		notes:    notes
		findings: c.findings
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
