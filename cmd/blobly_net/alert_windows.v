module main

#include <windows.h>
#flag windows -luser32

fn C.MessageBoxW(hwnd voidptr, text &u16, caption &u16, typ u32) int

// alert shows a message the operator must read before the app goes on, for what stops it before
// it has a window: on the GUI-subsystem exe stderr goes nowhere.
fn alert(msg string) {
	C.MessageBoxW(unsafe { nil }, msg.to_wide(), 'blobly_net'.to_wide(), u32(C.MB_OK | C.MB_ICONERROR))
}
