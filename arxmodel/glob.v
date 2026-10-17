module arxmodel

import os

// File globs, one matcher for the input set's globs and excludes and the filters' `file`: `*`
// and `?` within one name, `**` any number of directories. Path case counts (as the file system
// has it), but for the extension `.arxml`, matched in any case as a directory walk takes it.

// glob_file_name reports whether a file name matches a name pattern, `.arxml` in any case.
fn glob_file_name(pat string, name string) bool {
	if pat.to_lower().ends_with('.arxml') && name.to_lower().ends_with('.arxml') {
		return glob_name(pat[..pat.len - 6], name[..name.len - 6])
	}
	return glob_name(pat, name)
}

// is_arxml reports whether a file name has the extension .arxml, in any case.
pub fn is_arxml(name string) bool {
	return name.to_lower().ends_with('.arxml')
}

// FileGlob is a file glob, compiled: its segments, and whether it is absolute.
pub struct FileGlob {
pub:
	src string
	pat []string
	abs bool
}

// compile_file_glob compiles a file glob. An absolute one is normalized as the absolute path it
// is matched against is: `a/../b` is `b`, where a is a name and not a wildcard.
pub fn compile_file_glob(glob string) FileGlob {
	abs := os.is_abs_path(glob)
	norm := glob.replace('\\', '/')
	segs := norm.split('/').filter(it != '' && it != '.')
	// the volume an absolute path is on (a drive, or a UNC share's server and share), which `..`
	// never leaves: at the root it stays there, as the file system has it
	mut volume := 0
	$if windows {
		if abs && segs.len > 0 {
			if norm.starts_with('//') {
				volume = if segs.len < 2 { segs.len } else { 2 }
			} else if segs[0].len == 2 && segs[0][1] == `:` && segs[0][0].is_letter() {
				volume = 1
			}
		}
	}
	mut pat := []string{cap: segs.len}
	for seg in segs {
		if abs && seg == '..' && pat.len >= volume && (pat.len == volume || (pat.last() != '..'
			&& !pat.last().contains_any('*?'))) {
			if pat.len > volume {
				pat.delete_last()
			}
		} else {
			pat << seg
		}
	}
	return FileGlob{
		src: glob
		pat: pat
		abs: abs
	}
}

// FileNames is a file as file globs read it, worked out once: its segments as written, absolute,
// and relative to each root it lies under.
pub struct FileNames {
pub:
	written  []string
	absolute []string
	relative [][]string
}

// abs_roots are roots as file_names takes them: absolute, `/`-separated.
fn abs_roots(roots []string) []string {
	return roots.map(os.abs_path(it).replace('\\', '/').trim_right('/'))
}

// file_names is a file's names for globs, against roots given by abs_roots.
fn file_names(file string, roots []string) FileNames {
	a := os.abs_path(file).replace('\\', '/')
	mut rel := [][]string{}
	for r in roots {
		if a == r {
			rel << [os.file_name(a)]
		} else if a.starts_with(r + '/') {
			rel << a[r.len + 1..].split('/').filter(it != '')
		}
	}
	return FileNames{
		written:  file.replace('\\', '/').split('/').filter(it != '' && it != '.')
		absolute: a.split('/').filter(it != '')
		relative: rel
	}
}

// matches reports whether a file matches the glob: an absolute glob its absolute path, a relative
// one the path as written or relative to any root.
pub fn (g &FileGlob) matches(n FileNames) bool {
	if g.abs {
		return glob_files(g.pat, n.absolute)
	}
	if glob_files(g.pat, n.written) {
		return true
	}
	return n.relative.any(glob_files(g.pat, it))
}

// file_glob reports whether a file matches a file glob, relative ones read from the roots too.
pub fn file_glob(pattern string, file string, roots []string) bool {
	return compile_file_glob(pattern).matches(file_names(file, abs_roots(roots)))
}
