module logfile

import os
import time

// THE SESSION LOG: one plain-text file per launch, always on, the same lines the Log panel
// shows plus what used to go to stderr — which on the Windows GUI-subsystem exe goes nowhere,
// as two hunts on 2026-08-29 found the hard way. No levels, no framework: a file somebody can
// paste into an issue. Frames never come here; that is the Trace and recordings.
//
// This sub-module is GUI-free so its rules have tests CI runs (like ../saverule): where the
// file lives, what it is called, how many are kept, and what the header says.

// keep is how many session logs survive a launch: the newest `keep`, older ones deleted.
pub const keep = 10

// dir is where the logs live: the per-user local data directory, never beside the exe (a
// bundle directory is deleted with the bundle, Program Files is read-only).
//   Windows  %LocalAppData%\blobly_net\logs
//   Linux    $XDG_STATE_HOME/blobly_net/logs, else ~/.local/state/blobly_net/logs
pub fn dir() string {
	$if windows {
		// Explicitly LocalAppData — machine-local, never the roaming profile a domain drags
		// along — rather than trusting a library helper to mean the same (codex round 1 on
		// #259).
		local := os.getenv('LocalAppData')
		base := if local != '' { local } else { os.join_path(os.home_dir(), 'AppData', 'Local') }
		return os.join_path(base, 'blobly_net', 'logs')
	} $else {
		state := os.getenv('XDG_STATE_HOME')
		base := if state != '' { state } else { os.join_path(os.home_dir(), '.local', 'state') }
		return os.join_path(base, 'blobly_net', 'logs')
	}
}

// file_name is the session file for a launch at `t` by process `pid`: sortable by name, safe
// on every file system (no colons — Windows), unmistakably ours, and ONE PER LAUNCH — two
// instances started in the same second would otherwise append into one file, headers and all
// (codex round 1 on #259); the pid tells them apart.
pub fn file_name(t time.Time, pid int) string {
	return 'blobly_net-${t.year:04}-${t.month:02}-${t.day:02}T${t.hour:02}-${t.minute:02}-${t.second:02}-${pid}.log'
}

// is_session_log is whether a name in the directory is one of ours — rotation touches
// nothing else that may live there. `blobly_net-<date>T<time>-<pid>.log`, digits and dashes.
pub fn is_session_log(name string) bool {
	if !name.starts_with('blobly_net-') || !name.ends_with('.log') {
		return false
	}
	body := name['blobly_net-'.len..name.len - '.log'.len]
	if body.len < '2026-08-29T16-23-43-1'.len || body[10] != `T` {
		return false
	}
	for i, c in body {
		if i == 10 {
			continue
		}
		if !(c.is_digit() || c == `-`) {
			return false
		}
	}
	return true
}

// to_delete is which of `names` (ours, any order) rotation removes so that `keep_n` remain,
// oldest first — the name carries the time, so lexical order is chronological.
pub fn to_delete(names []string, keep_n int) []string {
	mut ours := names.filter(is_session_log(it))
	ours.sort()
	if ours.len <= keep_n {
		return []
	}
	return ours[..ours.len - keep_n]
}

// Facts is what the header states about this launch. Gathered by the caller (the GUI knows
// its version and project; this module knows nothing it cannot test), rendered here.
pub struct Facts {
pub:
	version  string
	os_name  string
	os_ver   string
	arch     string
	cpus     int
	v_hash   string
	project  string
	args     []string
	started  time.Time
	log_path string
}

// header is the first lines of every session log. Written before anything else happens, so a
// launch that dies on its first frame still leaves the facts a bug report needs.
pub fn header(f Facts) string {
	mut b := []string{}
	b << '# blobly_net ${f.version}'
	b << '# started ${f.started.format_ss()}  log ${f.log_path}'
	b << '# os ${f.os_name} ${f.os_ver}  arch ${f.arch}  cpus ${f.cpus}  v ${f.v_hash}'
	b << '# project ${f.project}'
	b << '# args ${f.args.join(' ')}'
	return b.join('\n') + '\n'
}

// Session is an open session log.
pub struct Session {
pub:
	path string
mut:
	f os.File
}

// open creates the directory, rotates, opens this launch's file and writes the header. An
// error here is the caller's to report and to live without: a log that cannot be written must
// never keep the app from starting.
pub fn open(f Facts) !Session {
	d := dir()
	os.mkdir_all(d)!
	for old in to_delete(os.ls(d) or { [] }, keep - 1) {
		os.rm(os.join_path(d, old)) or {}
	}
	path := os.join_path(d, file_name(f.started, os.getpid()))
	mut file := os.open_append(path)!
	file.write_string(header(Facts{ ...f, log_path: path }))!
	file.flush()
	return Session{
		path: path
		f:    file
	}
}

// line appends one line and flushes: the file is read after a crash, so nothing may sit in a
// buffer. A write that fails is dropped silently — there is nowhere else to say so.
pub fn (mut s Session) line(text string) {
	s.f.write_string(text + '\n') or { return }
	s.f.flush()
}

pub fn (mut s Session) close() {
	s.f.close()
}
