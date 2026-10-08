module project

import candb
import os

// What a project file SAYS about the files it uses (#440): a database, a telemetry manifest, a
// replay recording. resolve_asset reads a reference against the project's directory first; these
// write one, so a project names its files from where it lives rather than from wherever the
// program happened to be started — which is what the GUI wrote until #440, so a project opened
// from another directory loaded an empty database.

// asset_ref is how a project in `dir` names the file at `path`: relative to `dir`, climbing with
// `../` where the two share more than the root, and absolute where they do not (a different
// drive, or nothing in common). An unsaved project has no directory (`dir` == ''): its references
// are relative to the working directory where the file lies under it, as they always were, and
// save_as rebases them once the project has a home. Separators are `/`, so the file is portable.
pub fn asset_ref(dir string, path string) string {
	abs := slash(os.abs_path(path))
	if dir == '' {
		cwd := slash(os.getwd())
		return if abs.starts_with(cwd + '/') { abs[cwd.len + 1..] } else { abs }
	}
	base := slash(os.abs_path(dir))
	a := abs.split('/')
	b := base.split('/')
	mut common := 0
	for common < a.len - 1 && common < b.len && a[common] == b[common] {
		common++
	}
	// only the root (`''` on Unix, the drive on Windows) or less in common: name it absolutely
	if common <= 1 {
		return abs
	}
	mut parts := []string{len: b.len - common, init: '..'}
	parts << a[common..]
	return parts.join('/')
}

fn slash(p string) string {
	return p.replace('\\', '/').trim_right('/')
}

// rebase_ref is `ref`, written for a project in `old_dir`, as a project in `new_dir` names the
// same file. Only a reference that RESOLVED against the old directory moves: an absolute one names
// its file from anywhere, and one that resolves only from the working directory (the convention
// before #440) is left as it was written, since nothing here knows where that was. A database's
// `#Cluster` fragment rides along.
pub fn rebase_ref(old_dir string, new_dir string, ref string, is_database bool) string {
	if ref == '' {
		return ref
	}
	file, frag := if is_database { candb.split_database_ref(ref) } else { ref, '' }
	if os.is_abs_path(file) {
		return ref
	}
	whole := if old_dir == '' { file } else { os.join_path(old_dir, file) }
	if !os.exists(whole) {
		return ref
	}
	moved := asset_ref(new_dir, whole)
	return if frag == '' { moved } else { '${moved}#${frag}' }
}

// rebase_assets rewrites every file reference in the project for a move from `old_dir` to
// `new_dir` — what Save As must do once references are relative to the project's directory, or
// saving a project elsewhere would silently point every one of them at nothing.
pub fn (mut p Project) rebase_assets(old_dir string, new_dir string) {
	for mut ch in p.channels {
		ch.databases = ch.databases.map(rebase_ref(old_dir, new_dir, it, true))
		ch.manifest = rebase_ref(old_dir, new_dir, ch.manifest, false)
		if r := ch.replay {
			ch.replay = Replay{
				...r
				source: rebase_ref(old_dir, new_dir, r.source, false)
			}
		}
	}
}
