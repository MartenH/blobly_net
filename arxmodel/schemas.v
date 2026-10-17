module arxmodel

import flatxml
import flatxml.xsd
import os
import time

const xsi_ns_uri = 'http://www.w3.org/2001/XMLSchema-instance'

// Declared is the schema a document names in `xsi:schemaLocation` for its root's namespace.
pub struct Declared {
pub:
	ns       string // the root element's namespace
	location string // the schema's location as written ('' when none is declared)
	problem  string // why none could be read
}

// declared_schema reads what document d declares: the location paired with its root's
// namespace in `xsi:schemaLocation`.
pub fn declared_schema(d &flatxml.Doc) Declared {
	root := d.root()
	ns := d.ns_uri(d.ns_of(root))
	a := schema_location_attr(d, root) or {
		return Declared{
			ns:      ns
			problem: 'no xsi:schemaLocation'
		}
	}
	words := d.attr_value(a).fields()
	if words.len % 2 != 0 {
		return Declared{
			ns:      ns
			problem: 'xsi:schemaLocation is not namespace and location pairs'
		}
	}
	for k := 0; k < words.len; k += 2 {
		if words[k] == ns {
			return Declared{
				ns:       ns
				location: words[k + 1]
			}
		}
	}
	return Declared{
		ns:      ns
		problem: 'xsi:schemaLocation names no schema for ${ns}'
	}
}

// schema_location_attr is element i's `xsi:schemaLocation` attribute (namespaces resolved).
fn schema_location_attr(d &flatxml.Doc, i u32) ?u32 {
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if d.attr_ns_of(a) != flatxml.no_ns && d.ns_uri(d.attr_ns_of(a)) == xsi_ns_uri
			&& d.attr_local_name(a) == 'schemaLocation' {
			return a
		}
	}
	return none
}

// SchemaUse is one distinct declared schema: where it was found, what it compiled to, and the
// documents that declare it.
@[heap]
pub struct SchemaUse {
pub mut:
	name   string // the declared location's file name
	ns     string
	path   string // where it was found; '' when not found
	note   string // how it was found, when not by its exact name
	docs   []int  // indices into the set's documents
	schema &xsd.Schema = unsafe { nil }
	rules  &RuleSet    = unsafe { nil }
	error  string // why it was not found or did not compile
	took   time.Duration
}

// Schemas is every distinct schema a model's documents declare, and the documents that declare
// none.
pub struct Schemas {
pub mut:
	uses       []&SchemaUse
	undeclared map[int]string // document index -> why no schema could be read
	governing  []Governing    // per namespace, the schema whose rules govern
	policy     Policy         // the policy the schemas' rules were read with
}

// find_schema looks for a schema file named name in dir: dir/name, then dir/<stem>/name (one
// folder per release), then anywhere below dir; at each step a name differing only in case is
// accepted, and said.
pub fn find_schema(dir string, name string) (string, string) {
	base := os.file_name(name)
	stem := base.all_before_last('.')
	for cand in [os.join_path(dir, base), os.join_path(dir, stem, base)] {
		if os.is_file(cand) {
			return cand, ''
		}
	}
	mut exact := ''
	mut folded := ''
	mut all := os.walk_ext(dir, '').filter(it.to_lower().ends_with('.xsd'))
	all.sort()
	for f in all {
		fname := os.file_name(f)
		if fname == base && exact == '' {
			exact = f
		} else if fname.to_lower() == base.to_lower() && folded == '' {
			folded = f
		}
	}
	if exact != '' {
		return exact, ''
	}
	if folded != '' {
		return folded, 'found as ${os.file_name(folded)}, which differs in case'
	}
	return '', ''
}

// compile_schemas finds the schema each document of m declares in dir and compiles each distinct
// one once, in parallel, and reads its rules.
pub fn compile_schemas(m &Model, dir string, opts SchemaOptions) Schemas {
	mut out := declare_schemas(m)
	out.policy = opts.policy
	for mut u in out.uses {
		path, note := find_schema(dir, u.name)
		if path == '' {
			u.error = 'not found in ${dir}'
		}
		u.path = path
		u.note = note
	}
	mut threads := []thread{}
	for u in out.uses {
		if u.path != '' {
			threads << spawn compile_use(u, opts.policy)
		}
	}
	threads.wait()
	out.choose_governing()
	return out
}

@[params]
pub struct SchemaOptions {
pub:
	policy Policy = default_policy()
}

// files are the schema documents read for the uses: each found schema and every document it
// imports (one that failed to compile is its own file alone), in the order read, a document
// reached by several spellings once.
pub fn (s &Schemas) files() []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	for u in s.uses {
		if u.path == '' {
			continue
		}
		read := if u.schema != unsafe { nil } { u.schema.files } else { [u.path] }
		for f in read {
			real := os.real_path(f)
			if real !in seen {
				seen[real] = true
				out << f
			}
		}
	}
	return out
}

// declare_schemas lists the distinct schemas m's documents declare, and the documents that
// declare none, without finding or compiling any.
pub fn declare_schemas(m &Model) Schemas {
	mut out := Schemas{}
	mut by_name := map[string]int{}
	for k, d in m.set.docs {
		dec := declared_schema(d)
		if dec.location == '' {
			out.undeclared[k] = dec.problem
			continue
		}
		name := os.file_name(dec.location)
		key := '${dec.ns} ${name}'
		if key !in by_name {
			by_name[key] = out.uses.len
			out.uses << &SchemaUse{
				name: name
				ns:   dec.ns
			}
		}
		out.uses[by_name[key]].docs << k
	}
	return out
}

fn compile_use(u &SchemaUse, policy Policy) {
	mut w := unsafe { u }
	sw := time.new_stopwatch()
	s := xsd.load(u.path) or {
		w.error = err.msg()
		w.took = sw.elapsed()
		return
	}
	w.schema = s
	w.rules = read_rules_with(s, policy)
	w.took = sw.elapsed()
}
