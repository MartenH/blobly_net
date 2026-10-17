module arxmodel

import flatxml
import os

// Export of a merged model as one document: the merged view written by flatxml (each node once,
// what came from one file and was not merged into copied byte for byte, conflicts resolved as the
// view resolves them: the first fragment's value). The root is the first document's; in its
// `xsi:schemaLocation`, the pair for the model's namespace names the schema of the release whose
// rules merged it, as the first document declaring that release does, the other pairs kept.

// export writes the merged model c of m to path ('-' for standard output), and returns what it
// says about the root's schema location.
pub fn export(c &Checked, m &Model, sc &Schemas, path string) ![]string {
	root := c.view.root()
	if !root.ok() {
		return error('the merged model is empty')
	}
	first := root.fragment(0)
	attrs, notes := root_location(c, m, sc, first.doc, first.i, path)
	if path == '-' {
		mut out := os.stdout()
		c.view.write(mut out, root_attrs: attrs)!
	} else {
		c.view.write_file(path, root_attrs: attrs)!
	}
	return notes
}

// root_location is the attributes root element i of d is written with so that it names the
// governing release's schema for its namespace; none when it already does.
fn root_location(c &Checked, m &Model, sc &Schemas, d &flatxml.Doc, i u32, path string) ([]flatxml.EAttr, []string) {
	ns := d.ns_uri(d.ns_of(i))
	mut docs := []int{}
	for u in sc.uses {
		if u.name == c.governing && u.ns == ns {
			docs << u.docs
		}
	}
	if docs.len == 0 {
		return []flatxml.EAttr{}, [
			"no file declares ${c.governing}, which merged the model; the root's xsi:schemaLocation is the first file's",
		]
	}
	docs.sort()
	gd := m.set.docs[docs[0]]
	location, note := relocate(declared_schema(gd).location, gd.path, path)
	mut notes := if note == '' { []string{} } else { [note] }
	pair := '${ns} ${location}'
	if a := schema_location_attr(d, i) {
		words := d.attr_value(a).fields()
		if words.len % 2 != 0 {
			notes << "the first file's xsi:schemaLocation is not namespace and location pairs; written as ${pair}"
			return [flatxml.EAttr{d.attr_name(a), pair}], notes
		}
		mut out := []string{}
		mut found := false
		for k := 0; k < words.len; k += 2 {
			if words[k] == ns {
				if words[k + 1] == location {
					return []flatxml.EAttr{}, notes
				}
				out << pair
				found = true
			} else {
				out << '${words[k]} ${words[k + 1]}'
			}
		}
		if !found {
			out << pair
		}
		return [flatxml.EAttr{d.attr_name(a), out.join(' ')}], notes
	}
	// no xsi:schemaLocation: by a prefix bound to its namespace, else a free one declared
	mut bound := map[string]string{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		name := d.attr_name(a)
		if name.starts_with('xmlns:') {
			p := name['xmlns:'.len..]
			if d.attr_value(a) == xsi_ns_uri {
				return [flatxml.EAttr{'${p}:schemaLocation', pair}], notes
			}
			bound[p] = d.attr_value(a)
		}
	}
	mut p := 'xsi'
	for k := 1; p in bound; k++ {
		p = 'xsi${k}'
	}
	return [flatxml.EAttr{'xmlns:${p}', xsi_ns_uri}, flatxml.EAttr{'${p}:schemaLocation', pair}], notes
}

// relocate is location, as the file at from writes it, written from the file at to: a relative
// one that names a file beside from is made relative to to's directory; any other is kept, and
// said when the two directories differ.
fn relocate(location string, from string, to string) (string, string) {
	if location.contains('://') || location.starts_with('file:') || os.is_abs_path(location) {
		return location, ''
	}
	if to == '-' {
		return location, 'xsi:schemaLocation names ${location} as ${from} does, relative to that file'
	}
	from_dir := os.real_path(os.dir(from))
	to_dir := os.real_path(os.dir(os.abs_path(to)))
	if from_dir == to_dir {
		return location, ''
	}
	target := os.join_path(from_dir, location)
	if !os.exists(target) {
		return location, 'xsi:schemaLocation names ${location} as ${from} does: no such file beside it to locate from ${to_dir}'
	}
	return relative_path(to_dir, os.real_path(target)), ''
}

// relative_path is the path of target from directory dir, both absolute.
fn relative_path(dir string, target string) string {
	a := dir.split(os.path_separator).filter(it != '')
	b := target.split(os.path_separator).filter(it != '')
	mut k := 0
	for k < a.len && k < b.len && a[k] == b[k] {
		k++
	}
	if k == 0 && os.path_separator == '\\' {
		// another drive: no relative path
		return target
	}
	mut parts := []string{len: a.len - k, init: '..'}
	parts << b[k..]
	return parts.join('/')
}

// output_clash says why out may not be written given the inputs: it is one of them, or lies in a
// directory read as one, so the next run would read it back.
pub fn output_clash(out string, inputs []string) ?string {
	if out == '-' {
		return none
	}
	target := if os.exists(out) {
		os.real_path(out)
	} else {
		os.join_path(os.real_path(os.dir(os.abs_path(out))), os.file_name(out))
	}
	for p in inputs {
		real := os.real_path(p)
		if os.is_dir(p) {
			if target.starts_with(real.trim_right(os.path_separator) + os.path_separator) {
				return '${out} is inside ${p}, which is read as input'
			}
		} else if target == real {
			return '${out} is ${p}, which is read as input'
		}
	}
	return none
}
