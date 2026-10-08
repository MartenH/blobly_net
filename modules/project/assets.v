module project

import os

// What a project file SAYS about the files it uses (#440): a database, a telemetry manifest, a
// replay recording. resolve_asset reads a reference against the project's directory first; these
// write one, so a project names its files from where it lives rather than from wherever the
// program happened to be started — which is what the GUI wrote until #440, so a project opened
// from another directory loaded an empty database.

// asset_ref is how a project in `dir` names the file at `path`: relative to `dir`, climbing with
// `../` where the two share more than their root, and absolute where they do not (another drive,
// another share, or nothing in common). An unsaved project has no directory (`dir` == ''): its
// references are relative to the working directory where the file lies under it, as they always
// were, and Save As rebases them once the project has a home. Computed over REAL paths where they
// exist, because the kernel walks a `../` physically: through a symlinked directory a lexical
// climb lands somewhere else. A database's `#Cluster` rides on the last component untouched
// (it never holds a `/`). Separators are `/`, so the file is portable.
pub fn asset_ref(dir string, path string) string {
	// a UNC path stays absolute: resolve_asset joins with os.join_path, which collapses the
	// `\\server` prefix, so a relative reference under a share would resolve nowhere
	if is_unc(path) || (dir != '' && is_unc(dir)) {
		return path
	}
	abs := slash(physical(path))
	if dir == '' {
		cwd := slash(physical(os.getwd()))
		return if abs.starts_with(cwd + '/') { abs[cwd.len + 1..] } else { abs }
	}
	base := slash(physical(dir))
	a := abs.split('/')
	b := base.split('/')
	mut common := 0
	for common < a.len - 1 && common < b.len && same_component(a[common], b[common]) {
		common++
	}
	// the root is one component (`''` on Unix, `C:` on Windows): sharing only that names
	// nothing a climb can reach usefully, so share more or go absolute
	if common <= 1 {
		return abs
	}
	mut parts := []string{len: b.len - common, init: '..'}
	parts << a[common..]
	return parts.join('/')
}

// physical is `p` made absolute with its symlinks resolved — the existing part of it, so a
// `#Cluster` on a file that exists, or a file that does not exist yet, keeps its spelling. Made
// absolute by concatenation, not os.abs_path, which collapses `..` on paper before real_path can
// walk it: `link/../x` through a symlink names the file beside the link's TARGET.
fn physical(p string) string {
	abs := if os.is_abs_path(p) { p } else { os.getwd() + os.path_separator + p }
	if os.exists(abs) {
		return os.real_path(abs)
	}
	parent := os.dir(abs)
	if parent != abs && os.exists(parent) {
		// concatenated, not os.join_path, which rewrites a literal `\\` in a Unix name
		return os.real_path(parent) + os.path_separator + os.file_name(abs)
	}
	return os.abs_path(abs)
}

// slash spells a path with `/`. On Windows only: on Unix a backslash is a character of the name.
fn slash(p string) string {
	$if windows {
		return p.replace('\\', '/').trim_right('/')
	} $else {
		return p.trim_right('/')
	}
}

fn is_unc(p string) bool {
	return p.starts_with('\\\\') || p.starts_with('//')
}

fn same_component(a string, b string) bool {
	$if windows {
		return a.to_lower() == b.to_lower()
	} $else {
		return a == b
	}
}

// rebase_ref is `ref`, written for a project in `old_dir`, as a project in `new_dir` names the
// same thing. Read by resolve_asset's own rule — the whole reference first, then a database
// fragment split off, then the working directory — so the file it names now is the file it names
// after. A reference that resolves nowhere today keeps naming the place resolve_asset would look
// first (the old project's directory), so a file that appears later is still found. An absolute
// reference is left alone, except in a project never saved, where it is what asset_ref wrote for a
// file outside the working directory and the first Save As gives it a relative spelling.
pub fn rebase_ref(old_dir string, new_dir string, ref string) string {
	if ref == '' {
		return ref
	}
	if os.is_abs_path(ref) {
		return if old_dir == '' { asset_ref(new_dir, ref) } else { ref }
	}
	from_dir := resolve_asset(old_dir, ref)
	if from_dir != ref {
		return asset_ref(new_dir, from_dir)
	}
	// what the loader does with a reference resolve_asset returned unchanged: open it from the
	// working directory, as written (a literal `\\` in a Unix name included)
	if os.exists(ref) {
		return asset_ref(new_dir, ref)
	}
	from_cwd := resolve_asset(os.getwd(), ref)
	if from_cwd != ref {
		return asset_ref(new_dir, from_cwd)
	}
	return asset_ref(new_dir, if old_dir == '' { ref } else { old_dir + os.path_separator + ref })
}

// AssetRefs is one channel's file references, as rebase_assets found them.
pub struct AssetRefs {
pub:
	databases     []string
	manifest      string
	replay_source string
}

// rebase_assets rewrites every file reference in the project for a move from `old_dir` to
// `new_dir` — what Save As must do once references are relative to the project's directory, or
// saving a project elsewhere would point every one of them at nothing — and returns what they
// were, so a Save As that does not write can put back exactly these and nothing else.
pub fn (mut p Project) rebase_assets(old_dir string, new_dir string) []AssetRefs {
	mut was := []AssetRefs{cap: p.channels.len}
	for mut ch in p.channels {
		was << AssetRefs{
			databases:     ch.databases.clone()
			manifest:      ch.manifest
			replay_source: if r := ch.replay { r.source } else { '' }
		}
		ch.databases = ch.databases.map(rebase_ref(old_dir, new_dir, it))
		ch.manifest = rebase_ref(old_dir, new_dir, ch.manifest)
		if r := ch.replay {
			ch.replay = Replay{
				...r
				source: rebase_ref(old_dir, new_dir, r.source)
			}
		}
	}
	return was
}

// restore_assets puts back what rebase_assets returned, by channel index — the reference fields
// only, so whatever else changed since (a generator synced in) stays.
pub fn (mut p Project) restore_assets(was []AssetRefs) {
	for i, w in was {
		if i >= p.channels.len {
			break
		}
		p.channels[i].databases = w.databases
		p.channels[i].manifest = w.manifest
		if r := p.channels[i].replay {
			p.channels[i].replay = Replay{
				...r
				source: w.replay_source
			}
		}
	}
}
