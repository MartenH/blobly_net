module player

import time

#flag windows -lwinmm
#include <windows.h>
#include <mmsystem.h>

fn C.timeBeginPeriod(u32) u32

// raise_timer_resolution asks Windows for a 1 ms scheduler quantum for this process. Without it
// every Sleep() rounds up to 15.6 ms — a floor under the replay pacing, the RX loops' timeouts
// and the probe's stall detector alike. Per process since Windows 10 2004, dropped at exit;
// Windows 11 ignores it for a minimised window, so a replay behind one paces at the quantum.
pub fn raise_timer_resolution() {
	C.timeBeginPeriod(1)
}

// wait_until_ms holds the caller until `due_ms` on its stopwatch.
//
// On Windows a sleep below a millisecond is Sleep(0) — it returns at once — so a worker that
// slept its whole gap SPUN between frames 150 us apart (80 million ticks in a 70 s replay, each
// taking the app's mutex, measured on #300) while reading as if it slept; and a longer sleep is
// only as fine as the quantum raise_timer_resolution asks for. So: sleep in whole milliseconds
// while more than one and a half remain, and wait out the rest on the stopwatch. That last stretch
// costs a core, as the spin already did; the sleeps cost nothing.
pub fn wait_until_ms(mut sw time.StopWatch, due_ms f64) {
	for {
		rem := due_ms - f64(i64(sw.elapsed())) / 1e6
		if rem <= 0 {
			return
		}
		if rem > 1.5 {
			time.sleep(i64(rem - 1.0) * time.millisecond)
		}
	}
}
