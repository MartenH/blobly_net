module main

#include <windows.h>

fn C.GetLogicalDrives() u32

// drive_roots: this platform's roots are drives (pickrule.parent's `windows`).
const drive_roots = true

// fs_roots is what the picker lists at the level above a drive root (pickrule.drives): every
// drive the OS reports, spelled `X:\\`. From GetLogicalDrives' bitmask — bit n is letter n — and
// NOT from probing `A:\\`..`Z:\\` with is_dir, which on a removable drive with no medium raises the
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
