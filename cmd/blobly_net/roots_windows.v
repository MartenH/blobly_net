module main

#include <windows.h>
#flag windows -ladvapi32

fn C.GetLogicalDrives() u32

fn C.RegOpenKeyExA(hkey voidptr, sub &char, opts u32, sam u32, out &voidptr) int
fn C.RegEnumKeyExA(hkey voidptr, idx u32, name &char, len &u32, r voidptr, cls &char, clen &u32, ft voidptr) int
fn C.RegQueryValueExA(hkey voidptr, name &char, r voidptr, typ &u32, data &u8, len &u32) int
fn C.RegCloseKey(hkey voidptr) int

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
	// HKEY_CURRENT_USER is (HKEY)(ULONG_PTR)(LONG)0x80000001 — sign-extended on 64-bit.
	hkcu := unsafe { voidptr(usize(0xFFFFFFFF80000001)) }
	key_read := u32(0x20019) // KEY_READ
	mut lxss := unsafe { nil }
	if C.RegOpenKeyExA(hkcu, c'Software\\Microsoft\\Windows\\CurrentVersion\\Lxss', 0, key_read,
		&lxss) != 0 {
		return []
	}
	defer {
		C.RegCloseKey(lxss)
	}
	mut out := []string{}
	for i := u32(0); i < 64; i++ {
		mut name := [256]u8{}
		mut nlen := u32(255)
		if C.RegEnumKeyExA(lxss, i, &char(&name[0]), &nlen, unsafe { nil }, unsafe { nil },
			unsafe { nil }, unsafe { nil }) != 0 {
			break
		}
		mut sub := unsafe { nil }
		if C.RegOpenKeyExA(lxss, &char(&name[0]), 0, key_read, &sub) != 0 {
			continue
		}
		mut data := [512]u8{}
		mut dlen := u32(511)
		mut typ := u32(0)
		if C.RegQueryValueExA(sub, c'DistributionName', unsafe { nil }, &typ, &data[0], &dlen) == 0
			&& typ == 1 {
			distro := unsafe { cstring_to_vstring(&char(&data[0])) }
			if distro != '' {
				out << '\\\\wsl.localhost\\' + distro + '\\'
			}
		}
		C.RegCloseKey(sub)
	}
	out.sort()
	return out
}
