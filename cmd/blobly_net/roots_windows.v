module main

#include <windows.h>

fn C.GetLogicalDrives() u32

// The registry, through the W entry points vlib already declares (builtin/cfns.c.v) plus the
// one it does not; advapi32 is on the link line already (vgui.v).
fn C.RegEnumKeyExW(hkey voidptr, idx u32, name &u16, len &u32, r voidptr, cls &u16, clen &u32, ft voidptr) int

// drive_roots: this platform's roots are drives (pickrule.parent's `windows`).
const drive_roots = true

// fs_roots is what the picker lists at the level above a drive root (pickrule.drives): every
// drive the OS reports, spelled `X:\`. From GetLogicalDrives' bitmask — bit n is letter n — and
// NOT from probing `A:\`..`Z:\` with is_dir, which on a removable drive with no medium raises the
// system's "no disk" box in the middle of a file picker.
fn fs_roots() []string {
	mask := C.GetLogicalDrives()
	mut out := []string{}
	for i in 0 .. 26 {
		if mask & (u32(1) << u32(i)) != 0 {
			out << '${rune(`A` + i)}:\\'
		}
	}
	return out
}

// wsl_roots is one entry per WSL distribution, `\\wsl.localhost\<distro>\`, which is how a file
// under WSL is reached from Windows (#306) — `\\wsl.localhost` itself is not listable, so the
// picker cannot discover them by walking. The names come from the registry
// (HKCU\...\Lxss\<guid>\DistributionName), not from `wsl.exe -l`, which is a console process a
// GUI would flash a window for. Empty where WSL is not installed.
fn wsl_roots() []string {
	mut lxss := unsafe { nil }
	if C.RegOpenKeyExW(C.HKEY_CURRENT_USER,
		'Software\\Microsoft\\Windows\\CurrentVersion\\Lxss'.to_wide(), 0, u32(C.KEY_READ), &lxss) != 0 {
		return []
	}
	defer {
		C.RegCloseKey(lxss)
	}
	mut out := []string{}
	for i := u32(0); i < 64; i++ {
		mut name := [256]u16{}
		mut nlen := u32(255)
		if C.RegEnumKeyExW(lxss, i, &name[0], &nlen, unsafe { nil }, unsafe { nil },
			unsafe { nil }, unsafe { nil }) != 0 {
			break
		}
		mut sub := unsafe { nil }
		if C.RegOpenKeyExW(lxss, &name[0], 0, u32(C.KEY_READ), &sub) != 0 {
			continue
		}
		mut data := [512]u16{}
		mut dlen := u32(1022) // bytes
		mut typ := u32(0)
		if C.RegQueryValueExW(sub, 'DistributionName'.to_wide(), unsafe { nil }, &typ, &u8(&data[0]), &dlen) == 0
			&& typ == 1 {
			distro := unsafe { string_from_wide(&data[0]) }
			if distro != '' {
				out << wsl_prefix + distro + '\\'
			}
		}
		C.RegCloseKey(sub)
	}
	out.sort()
	return out
}

// wsl_prefix is how Windows reaches a distribution's files: `\\wsl.localhost\` since Windows 10
// 21H2 (build 19044), `\\wsl$\` before — chosen by the build number, not by probing the share,
// which starts the distribution's VM (codex #307 r12). Stated once; root_label reads it.
const wsl_prefix = wsl_prefix_for_build(windows_build())

fn wsl_prefix_for_build(build int) string {
	return if build >= 19044 { '\\\\wsl.localhost\\' } else { '\\\\wsl$\\' }
}

// windows_build is HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\CurrentBuildNumber, or 0
// when it cannot be read — which selects the newer spelling, the one a current Windows serves.
fn windows_build() int {
	mut key := unsafe { nil }
	if C.RegOpenKeyExW(C.HKEY_LOCAL_MACHINE,
		'SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'.to_wide(), 0, u32(C.KEY_READ), &key) != 0 {
		return 0
	}
	defer {
		C.RegCloseKey(key)
	}
	mut data := [64]u16{}
	mut dlen := u32(126)
	mut typ := u32(0)
	if C.RegQueryValueExW(key, 'CurrentBuildNumber'.to_wide(), unsafe { nil }, &typ, &u8(&data[0]), &dlen) != 0
		|| typ != 1 {
		return 0
	}
	return unsafe { string_from_wide(&data[0]) }.int()
}

// root_label is the drive row's button text for a root: the drive as is, a WSL distribution
// by name.
fn root_label(r string) string {
	if r.starts_with(wsl_prefix) {
		return 'wsl: ' + r.all_after(wsl_prefix).trim_right('\\')
	}
	return r
}
