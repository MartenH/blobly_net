module main

import os

// is_wsl reports whether we're under WSL, where no Linux browser or editor is around and the
// Windows side has to open the file.
fn is_wsl() bool {
	if os.getenv('WSL_DISTRO_NAME') != '' || os.getenv('WSL_INTEROP') != '' {
		return true
	}
	rel := os.read_file('/proc/sys/kernel/osrelease') or { return false }
	low := rel.to_lower()
	return low.contains('microsoft') || low.contains('wsl')
}

// system_open opens `path` with whatever the desktop associates with it. Under WSL that is the
// Windows side, through wslview (wslu) or explorer.exe with a wslpath UNC; elsewhere xdg-open.
// Nothing here WAITS on the GUI thread: xdg-open's generic fallback returns only when the
// application it launched exits, which for a text editor is the whole edit. A later failure
// (a nonzero exit) reaches `report` from the reaper thread.
fn system_open(path string, report fn (string)) (bool, string) {
	if is_wsl() {
		if exe := os.find_abs_path_of_executable('wslview') {
			launch_detached([exe, path], report) or { return false, err.msg() }
			return true, 'opened ${path} on the Windows side (wslview)'
		}
		if exe := os.find_abs_path_of_executable('explorer.exe') {
			// wslpath is a short synchronous conversion, not the launch
			win := os.execute('wslpath -w ' + os.quoted_path(path))
			if win.exit_code == 0 {
				launch_detached([exe, win.output.trim_space()], report) or {
					return false, err.msg()
				}
				return true, 'opened ${path} on the Windows side (explorer.exe)'
			}
		}
		return false, 'no way to open ${path} from WSL — install wslu for wslview, or set an editor in Settings ▸ Preferences…'
	}
	launch_detached(['xdg-open', path], report) or { return false, err.msg() }
	return true, 'opened ${path} (xdg-open)'
}

// launch_detached runs `argv` without waiting for it. The executable is resolved FIRST, so a
// command that does not exist is an error here and not an exec failure in a forked child
// (which vlib reports by printing in the child and exiting it — the parent's Process never
// learns). The child is reaped on its own thread: wait() is where a zombie ends and the exit
// code becomes known, and a nonzero one reaches `report`. What this cannot do: the child
// inherits every descriptor the GUI holds (fork, no close-on-exec anywhere in vlib's sockets),
// so an editor left open across Stop keeps a copy of the run's sockets — a CANsub channel,
// which admits one client, is refused to the next Start until the editor exits.
fn launch_detached(argv []string, report fn (string)) ! {
	exe := os.find_abs_path_of_executable(argv[0]) or {
		return error('${argv[0]}: not found on PATH — set the command in Settings ▸ Preferences…')
	}
	mut p := os.new_process(exe)
	p.set_args(argv[1..])
	p.run()
	spawn reap(mut p, argv[0], report)
}

fn reap(mut p os.Process, name string, report fn (string)) {
	p.wait()
	if p.code != 0 {
		report('${name} exited with ${p.code}')
	}
	p.close()
}
