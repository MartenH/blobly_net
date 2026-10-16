// arxmodel — AUTOSAR models (ARXML) read the way AUTOSAR tools see them: many files, one model.
//
// Loading reads every .arxml below the paths given into one flatxml document set, in parallel,
// namespaces resolved. Each file's declared schema is found in a directory the user gives and
// compiled once; its annotations are read into merge rules (rules.v).
module arxmodel

import flatxml
import os
import runtime
import time

// Model is the files of one load: the document set, and what could not be read.
@[heap]
pub struct Model {
pub mut:
	set      &flatxml.DocSet = unsafe { nil }
	failed   []flatxml.LoadError
	files    []string // every file found, in the order loaded (sorted by path)
	warnings []string // globs and directories that matched nothing
	bases    []string // the directories the files came from (see find_arxml)
	bytes    i64
	took     time.Duration
}

@[params]
pub struct LoadOptions {
pub:
	jobs    int      // threads; 0 for the default (`default_jobs`), at most 16
	exclude []string // file globs: files they match are left out
}

// Found is the .arxml files at some paths, the directories that could not be read, and what was
// asked for and matched nothing.
pub struct Found {
pub mut:
	lists    []string // the @FILE lists read, nested ones included
	files    []string
	failed   []flatxml.LoadError
	warnings []string
	bases    []string // the directories the files came from: what relative file globs are read from
}

// The input set: what the paths given become, one rule for every command that reads models.
//
// - `@FILE` is replaced by the paths listed in FILE: one a line, blank lines and lines starting
//   with `#` ignored, the rest trimmed (no shell splitting or quoting: a line is one path, spaces
//   and all); a relative path is read from FILE's directory; a listed `@FILE` is read the same
//   way.
// - A path with `*` or `?` is a glob, expanded here: `*` and `?` within one name, `**` any number
//   of directories; it may match files and directories alike. A glob that matches nothing is a
//   warning.
// - A directory is every .arxml file below it, recursively (`DIR/*.arxml` for its own files
//   only). A directory with none is a warning.
// - A file is itself; a path that does not exist is an error.
// - `--exclude GLOB` leaves out every file it matches: a relative glob against the path as found,
//   an absolute one against the absolute path.
// - A file reached twice (overlapping paths, two spellings of one file) is one file.
// - The set is sorted by path, as found: the order (and so which file's value a merge keeps where
//   files differ) depends on neither the order of the arguments nor the file system.

// is_glob reports whether a path argument is a glob.
pub fn is_glob(path string) bool {
	return path.contains_any('*?')
}

// is_list reports whether an `@x` argument, spelled literal with x spelled file, names a list:
// unless `@x` is a file and `x` is not.
fn is_list(literal string, file string) bool {
	return !os.is_file(literal) || os.is_file(file)
}

// is_set_arg reports whether a path argument names a set of files (a directory, a glob, a list)
// rather than one file, by the rules find_arxml reads it by: a file is itself.
pub fn is_set_arg(p string) bool {
	if os.is_dir(p) {
		return true
	}
	if p.starts_with('@') {
		return is_list(p, p[1..])
	}
	return is_glob(p) && !os.is_file(p)
}

// expand_lists replaces each `@FILE` by the paths it lists.
// The directories of the lists read come second.
pub fn expand_lists(args []string) !([]string, []string) {
	mut out := []string{}
	mut lists := []string{}
	mut files := []string{}
	mut seen := map[string]bool{}
	expand_into(args, '', mut out, mut lists, mut files, mut seen)!
	return out, lists
}

// expand_lists_read is expand_lists with the list files themselves, every one read, nested ones
// included: what a description read from them depends on besides the files they name.
pub fn expand_lists_read(args []string) !([]string, []string, []string) {
	mut out := []string{}
	mut lists := []string{}
	mut files := []string{}
	mut seen := map[string]bool{}
	expand_into(args, '', mut out, mut lists, mut files, mut seen)!
	return out, lists, files
}

fn expand_into(args []string, dir string, mut out []string, mut lists []string, mut files []string, mut seen map[string]bool) ! {
	for a in args {
		p := if dir != '' && !os.is_abs_path(a) && !a.starts_with('@') {
			os.norm_path(os.join_path(dir, a))
		} else {
			a
		}
		// a file is itself: `@x` names a list unless `@x` is a file and `x` is not, both read from
		// the list's directory when the entry is a relative one inside a list
		// (`@x` itself is always relative, whether or not x is)
		mut file := if p.starts_with('@') { p[1..] } else { p }
		mut literal := p
		if p.starts_with('@') && dir != '' {
			literal = os.norm_path(os.join_path(dir, p))
			if !os.is_abs_path(file) {
				file = os.norm_path(os.join_path(dir, file))
			}
		}
		if !p.starts_with('@') || !is_list(literal, file) {
			out << literal
			continue
		}
		real := os.real_path(file)
		if real in seen {
			return error('${file}: listed in itself')
		}
		seen[real] = true
		text := os.read_file(file) or { return error('${file}: ${err.msg()}') }
		mut listed := []string{}
		for raw in text.split_into_lines() {
			line := raw.trim_space()
			if line != '' && !line.starts_with('#') {
				listed << line
			}
		}
		lists << os.dir(file)
		files << file
		expand_into(listed, os.dir(file), mut out, mut lists, mut files, mut seen)!
		seen.delete(real)
	}
}

// glob_base is the directory a glob's fixed part names ('.' where it has none), and the rest
// of the glob, as segments.
fn glob_base(pattern string) (string, []string) {
	norm := pattern.replace('\\', '/')
	parts := norm.split('/').filter(it != '' && it != '.')
	mut k := 0
	for k < parts.len && !is_glob(parts[k]) {
		k++
	}
	mut base := parts[..k].join('/')
	if norm.starts_with('//') {
		base = '//' + base // a UNC path, \\server\share
	} else if norm.starts_with('/') {
		base = '/' + base
	} else if base == '' {
		base = '.'
	}
	return base, parts[k..]
}

// glob_paths are the .arxml files (any case of the extension) and the directories a glob matches,
// under the directory its fixed part names, spelled from that part; a glob whose last name has no
// wildcard names its files explicitly, whatever their extension. A directory that cannot be read
// is in failed.
pub fn glob_paths(pattern string, mut failed []flatxml.LoadError) []string {
	base, pat := glob_base(pattern)
	if !os.is_dir(base) || pat.len == 0 {
		return []
	}
	explicit := !is_glob(pat.last())
	mut out := []string{}
	walk_glob(base, pat, [], explicit, mut out, mut failed)
	out.sort()
	return out
}

fn walk_glob(dir string, pat []string, rel []string, explicit bool, mut out []string, mut failed []flatxml.LoadError) {
	names := os.ls(dir) or {
		failed << flatxml.LoadError{dir, '${dir}: ${err.msg()}'}
		return
	}
	deep := '**' in pat
	for name in names {
		path := if dir == '.' { name } else { os.join_path(dir, name) }
		mut segs := rel.clone()
		segs << name
		is_dir := os.is_dir(path)
		if glob_files(pat, segs) && (is_dir || explicit || is_arxml(name)) {
			out << path
			continue
		}
		// below a directory only where the pattern can still reach
		if is_dir && !os.is_link(path) && (deep || segs.len < pat.len) {
			walk_glob(path, pat, segs, explicit, mut out, mut failed)
		}
	}
}

// find_arxml is the input set of the paths given (see above): the .arxml files, sorted by path,
// each once; the directories they came from (`bases`: a directory given, a glob's fixed part, a
// file's directory, a list's directory); the directories that could not be read; and the globs and
// directories that matched nothing, as warnings. A path that does not exist, or a list that cannot
// be read, is an error.
pub fn find_arxml(paths []string, opts LoadOptions) !Found {
	mut f := Found{}
	mut found := []string{}
	mut bases := []string{}
	args, lists, list_files := expand_lists_read(paths)!
	bases << lists
	f.lists = list_files
	for p in args {
		// a file is itself, even with * or ? in its name: a glob only where no such file is
		if is_glob(p) && !os.is_file(p) {
			base, _ := glob_base(p)
			bases << base
			matches := glob_paths(p, mut f.failed)
			if matches.len == 0 {
				f.warnings << '${p}: matches nothing'
			}
			for m in matches {
				if os.is_dir(m) {
					collect_arxml(m, mut found, mut f.failed)
				} else {
					found << m
				}
			}
		} else if os.is_dir(p) {
			bases << p
			before := found.len
			collect_arxml(p, mut found, mut f.failed)
			if found.len == before {
				f.warnings << '${p}: no .arxml file'
			}
		} else if os.exists(p) {
			bases << os.dir(p)
			found << p
		} else {
			return error('${p}: no such file or directory')
		}
	}
	found.sort()
	// each file once, by its real path, under its first spelling; left out where an exclude
	// matches any of its spellings
	excludes := opts.exclude.map(compile_file_glob(it))
	roots := abs_roots(bases)
	mut first := map[string]string{}
	mut order := []string{}
	mut out := map[string]bool{}
	for file in found {
		real := os.real_path(file)
		if real !in first {
			first[real] = file
			order << real
		}
		if excludes.len > 0 && excludes.any(it.matches(file_names(file, roots))) {
			out[real] = true
		}
	}
	for real in order {
		if real !in out {
			f.files << first[real]
		}
	}
	mut seen := map[string]bool{}
	for b in bases {
		if b !in seen {
			seen[b] = true
			f.bases << b
		}
	}
	return f
}

fn collect_arxml(dir string, mut out []string, mut failed []flatxml.LoadError) {
	names := os.ls(dir) or {
		failed << flatxml.LoadError{dir, '${dir}: ${err.msg()}'}
		return
	}
	for name in names {
		f := os.join_path(dir, name)
		if os.is_dir(f) && !os.is_link(f) {
			collect_arxml(f, mut out, mut failed)
		} else if is_arxml(name) && os.is_file(f) {
			out << f
		}
	}
}

// default_jobs is the threads used for loading and for the XML schema layer where none are asked
// for: one per CPU, at most 8, so a run leaves room for what shares the machine with it.
pub fn default_jobs() int {
	n := runtime.nr_cpus()
	return if n > 8 {
		8
	} else if n < 1 {
		1
	} else {
		n
	}
}

// jobs_or_default is the threads asked for, or the default where none are.
fn jobs_or_default(asked int) int {
	return if asked > 0 { asked } else { default_jobs() }
}

// load reads every .arxml at the paths given into one document set. A file that fails to parse,
// or a directory that cannot be read, is listed in failed; the rest load all the same.
pub fn load(paths []string, opts LoadOptions) !&Model {
	found := find_arxml(paths, opts)!
	sw := time.new_stopwatch()
	mut set := flatxml.DocSet.new()
	mut failed := found.failed.clone()
	failed << set.load(found.files, jobs: jobs_or_default(opts.jobs), namespaces: true)
	took := sw.elapsed()
	mut bytes := i64(0)
	for d in set.docs {
		bytes += d.src_len
	}
	return &Model{
		set:      set
		failed:   failed
		files:    found.files
		warnings: found.warnings
		bases:    found.bases
		bytes:    bytes
		took:     took
	}
}

// free releases the documents.
pub fn (mut m Model) free() {
	if m.set != unsafe { nil } {
		m.set.free()
	}
}

// element_count is the number of elements in all documents.
pub fn (m &Model) element_count() int {
	mut n := 0
	for d in m.set.docs {
		for i in 1 .. d.len() {
			if d.is_element(u32(i)) {
				n++
			}
		}
	}
	return n
}
