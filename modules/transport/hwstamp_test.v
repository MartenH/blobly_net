module transport

import time

// THE RECEIVE STAMP CONTRACT (#149): every received frame either names the clock that read it, or
// says it has none.

fn test_a_socketcan_frame_carries_the_kernel_receive_stamp() {
	// LIVE, on vcan0 — the one backend this can be checked on without hardware. Where vcan0 cannot
	// be opened there is nothing to check (CI has no vcan by design), so the test does nothing.
	$if linux {
		mut rx := open('vcan0') or { return }
		defer {
			rx.close()
		}
		mut tx := open('vcan0') or { return }
		defer {
			tx.close()
		}
		payload := [u8(0x14), 0x9e, 0x57, 0x4a] // distinctive: vcan0 may carry other traffic
		before := i64(time.sys_mono_now())
		// vcan0 can exist and be DOWN (before setup_vcan.sh): the open succeeds and the send is
		// refused. Nothing to check then, the same as no vcan0 at all.
		tx.send(CanFrame{ id: 0x149, data: payload }) or { return }
		mut got := CanFrame{}
		// A deadline rather than a count: another session's traffic on vcan0 must not crowd it out.
		for i64(time.sys_mono_now()) - before < 1_000_000_000 {
			f := rx.recv(200) or { continue }
			if f.id == 0x149 && f.data == payload {
				got = f
				break
			}
		}
		after := i64(time.sys_mono_now())
		assert got.id == 0x149, 'the frame never arrived'
		assert got.hw_domain == socketcan_domain
		// on the MONOTONIC clock (the shim converts the kernel's wall-clock stamp), stamped between
		// our send and our read
		assert got.hw_ns >= before && got.hw_ns <= after
	}
}

fn test_a_software_bus_frame_says_it_has_no_stamp() {
	// An in-process bus has no clock but ours. It says so, rather than a host time — or another
	// bus's stamp — standing in for a wire time that does not exist.
	mut rx := open('inproc:hwstamp') or { panic(err) }
	defer {
		rx.close()
	}
	mut tx := open('inproc:hwstamp') or { panic(err) }
	defer {
		tx.close()
	}
	// A frame that arrived stamped from another bus and is forwarded here — the first version of
	// this test sent an unstamped one, and so passed whatever the bus did.
	tx.send(CanFrame{ id: 0x149, data: [u8(1)], hw_ns: 123_456_789, hw_domain: socketcan_domain }) or {
		panic(err)
	}
	f := rx.recv(1000) or { panic(err) }
	assert f.hw_domain == ''
	assert f.hw_ns == 0
}
