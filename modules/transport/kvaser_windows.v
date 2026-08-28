// kvaser_windows.v — Kvaser CANlib backend (real CAN hardware on Windows),
// implementing the platform-agnostic `Bus` interface. Windows-only (`_windows.v`
// suffix gates compilation). canlib32.dll (shipped with the free Kvaser drivers) is
// loaded at RUNTIME via kvaser_shim.h — no SDK, no import lib.
//
// Interface string: `kvaser:<channel>[@<arb>[/<data>]]`
//   channel : Kvaser channel number (0,1,…). Virtual channels (available once the
//             Kvaser drivers are installed, NO hardware needed) appear as channel
//             numbers too — find them in the Kvaser Device Guide.
//   arb     : arbitration bits/s (default 500000)   e.g. kvaser:0@250000
//   data    : CAN-FD DATA-phase bits/s. Naming it IS the FD flag -- there is no separate
//             `,fd`, so no address can claim FD while naming one rate. 500k/1M/2M/4M/8M.
//             e.g. kvaser:0@500000/2000000  (64-byte payloads, bit-rate switched)
//
// Because Kvaser offers software virtual channels, this backend can be verified
// end-to-end with no physical adapter (open two handles on the same virtual channel
// number, send on one, recv on the other). See docs/windows_can_hardware.md.
//
// Bench-verified on a Kvaser USBcan Pro 5xHS, connector CH1 to CH2 over real transceivers with
// two 120 ohm terminators: classic CAN, and CAN-FD with BRS at data rates 500k, 1M, 2M, 4M and
// 8M, at payload lengths 8, 12, 16, 24, 32, 48 and 64 bytes, with zero error frames and both
// controllers error-active throughout. `cmd/kvasercheck --ladder` is that run. The remaining FD
// lengths (0..7 and 20) are exercised only by the length rule in kvaser_fd_test.v, not on copper.
// See docs/windows_can_hardware.md.
module transport

import sync

#include "kvaser_shim.h"

fn C.ct_kvaser_load() int
fn C.ct_kvaser_open(int, int, int) int
fn C.ct_kvaser_open_fd(int, int, int, int) int
fn C.ct_kvaser_write_fd(int, u32, u8, &u8, int, int) int
fn C.ct_kvaser_has_fd() int
fn C.ct_kvaser_write(int, u32, u8, &u8, int, int) int
fn C.ct_kvaser_read(int, &u32, &u8, &u8, &u32, u32) int
fn C.ct_kvaser_close(int)
fn C.ct_kvaser_status(int, &u32) int
fn C.ct_kvaser_count() int
fn C.ct_kvaser_descr(int, &char, int) int
fn C.ct_kvaser_is_virtual(int) int
fn C.ct_kvaser_set_silent_all(&int, int, int) int

// KvaserBus is one open + bus-on CANlib channel handle.
// kvaser_wires is every handle THIS PROCESS holds, per wire; `kvaser_handles` reads it.
//
// It exists because the channel's output mode cannot be changed through one handle while its
// siblings are on the bus — canlib accepts the call and ignores it (see ct_kvaser_set_silent_all).
// So a mode change has to know about all of them, and this is the only place that does.
//
// NOT `shared.v`. A second `kvaser:` open is a second SUBSCRIBER — each handle has its own receive
// queue in the driver, so canlib already fans out and the hub would add nothing but a second copy.
// (Until #221 the registry also lost frames to competing readers, which was the original reason;
// that is fixed, and the reason that remains is that Kvaser needs no help.) The handles stay
// separate; only the mode change is coordinated.
struct KvaserWires {
mut:
	mu  sync.Mutex
	byw map[string][]int
}

__global kvaser_wires = &KvaserWires{}

fn kvaser_register(iface string, handle int) {
	kvaser_wires.mu.lock()
	defer {
		kvaser_wires.mu.unlock()
	}
	kvaser_wires.byw[wire_key(iface)] << handle
}

fn kvaser_unregister(iface string, handle int) {
	kvaser_wires.mu.lock()
	defer {
		kvaser_wires.mu.unlock()
	}
	k := wire_key(iface)
	if mut hs := kvaser_wires.byw[k] {
		idx := hs.index(handle)
		if idx >= 0 {
			hs.delete(idx)
		}
		if hs.len == 0 {
			kvaser_wires.byw.delete(k)
		} else {
			kvaser_wires.byw[k] = hs
		}
	}
}

fn kvaser_handles(iface string) []int {
	kvaser_wires.mu.lock()
	defer {
		kvaser_wires.mu.unlock()
	}
	return kvaser_wires.byw[wire_key(iface)] or { []int{} }.clone()
}

pub struct KvaserBus {
mut:
	handle int
	// The wire this handle is, so the silence policy can be asked about it — see ensure_silence.
	iface string
	// The mode this handle was OPENED in. A channel opened classic cannot carry an FD frame
	// however the frame is flagged, so send() has to know -- and a channel opened FD still
	// carries classic frames, which is why recv reads the flags per frame rather than assuming.
	fd bool
}

// open_kvaser parses `kvaser:<channel>[@<arb>[/<data>]]`, loads canlib32.dll, opens the channel
// (classic, or CAN-FD when the address names a data rate) and goes bus-on.
// The address rules live in kvaser_names.v, where a CI runner with no adapter can check them.
// Referenced only from open_windows.v.
// kvaser_open_locked runs the driver open and the registration together under this wire's silence
// lock, and returns the handle (negative on failure).
//
// WHY THEY MUST BE ONE STEP. `apply_silence` holds the same lock across its driver call, and inside
// it the handle list is snapshotted and every handle taken bus-off before the mode is set. Opening
// outside that lock let a new handle appear BETWEEN the snapshot and the mode call and go bus-on
// while it was still invisible — so not every live handle was bus-off, canlib returned its
// documented no-op success, the transition recorded the requested mode, and this opener's own
// reconcile then skipped it as already applied. A listen-only wire acknowledging, again, by a
// narrower road (codex round 10 on #219).
//
// Under the lock, a concurrent transition sees this handle either not open at all or open AND
// registered, and never the state between. Lock order is wire lock -> handle registry, which is
// what close and the reconcile closure both use.
fn kvaser_open_locked(iface string, do_open fn () int) int {
	mut wl := wire_silence_lock(wire_key(iface))
	wl.@lock()
	defer {
		wl.unlock()
	}
	// `do_open`, not `open`: bare `open` is transport.open in this module, and V resolves the
	// parameter and the function ambiguously rather than shadowing.
	hnd := do_open()
	if hnd >= 0 {
		kvaser_register(iface, hnd)
	}
	return hnd
}

// kvaser_apply_wire_silence brings the WIRE's controller to `want` through every handle this
// process holds on it. The one shape of mode change that actually works — see
// ct_kvaser_set_silent_all for why "every handle" and not "the right handle".
fn kvaser_apply_wire_silence(iface string, want bool) ! {
	inner := iface
	apply_silence(inner, want, fn [inner] (silent bool) int {
		// Read inside the closure, so the list is the one that exists when the mode is actually
		// being changed rather than when the bus was built.
		hs := kvaser_handles(inner)
		if hs.len == 0 {
			return -100 // nothing open on this wire: nothing to reconcile, and nothing to claim
		}
		return C.ct_kvaser_set_silent_all(&hs[0], hs.len, if silent { 1 } else { 0 })
	})!
}

pub fn open_kvaser(spec string, iface string) !&KvaserBus {
	s := kvaser_spec(spec)!
	// The arbitration code comes from a DIFFERENT family depending on the mode -- see
	// kvaser_fd_arb_code for why an FD channel must not take the classic constant.
	arb_code := if s.fd { kvaser_fd_arb_code(s.bitrate)! } else { kvaser_bitrate_code(s.bitrate)! }
	if C.ct_kvaser_load() != 0 {
		return error('canlib32.dll not found — install the Kvaser drivers')
	}
	// ASKED BEFORE THE CHANNEL IS OPENED, because canlib chooses the output mode while bus-off
	// and goes bus-on as part of opening. Applied afterwards it would leave a window in which a
	// listen-only row acknowledges on a live bus — see note_silence_applied.
	silent := is_listen_only(iface)
	// SET, OR NOT SET AT ALL — and the difference is recorded rather than guessed. A canlib with no
	// canSetBusOutputControl cannot apply either mode; answering "normal" for that would claim a
	// repair that never happened and suppress every later attempt (codex round 3 on #219). A SILENT
	// request on such a driver fails the open outright, below.
	// THE WIRE FIRST, IF ANYTHING IS ALREADY ON IT. Handles already open keep the channel in
	// whatever mode they were opened in, and a joiner's own in-open request is ignored — it does
	// not hold initialisation access. Reconciling only afterwards left the wire ACKNOWLEDGING for
	// the whole of the open, on a project that had already declared it silent (codex round 8 on
	// #219). Short, and on somebody's live vehicle.
	//
	// MEASURED THAT IT STICKS: with the post-open reconcile disabled, silentcheck's phase 5 still
	// passes, so a mode set here survives the joiner's canOpenChannel/canSetBusParams/canBusOn.
	//
	// Best-effort, and skipped when the wire is empty — not as a decision about who is "first", but
	// because there is simply nothing to reconcile through, and calling anyway would file a fault
	// against a wire whose only problem is that nobody is on it yet.
	if kvaser_handles(iface).len > 0 {
		kvaser_apply_wire_silence(iface, silent) or {}
	}
	if !s.fd {
		ch, code, sil := s.channel, arb_code, if silent { 1 } else { 0 }
		hnd := kvaser_open_locked(iface, fn [ch, code, sil] () int {
			return C.ct_kvaser_open(ch, code, sil)
		})
		if hnd < 0 {
			return error('Kvaser: could not open channel ${s.channel} — ${kvaser_open_refusal(hnd,
				s.channel, false)}')
		}
		// AND THE WIRE IS RECONCILED, ALWAYS, RATHER THAN THE OPEN BEING TRUSTED.
		//
		// THERE IS NO "FIRST OPENER" CASE ANY MORE, and removing it is the point. It was there
		// because a first opener's in-open mode request is the one canlib obeys, so recording it
		// saved a call — but "am I first?" was read before this handle registered, so two threads
		// opening one wire could both answer yes, and the later one would then cache a mode the
		// controller never took (codex round 9 on #219). Guarding that decision with another lock
		// would have been a third mechanism around a saving worth one driver call.
		//
		// Asking unconditionally is both simpler and race-free: `apply_silence` is serialised per
		// wire and compares against the record, so a second opener with the same policy does
		// nothing at all, and one arriving after a policy change writes through every handle. The
		// only cost is one redundant call on a wire's very first open.
		// FRESH, NOT THE OPEN-TIME SNAPSHOT. `silent` was read before the driver was touched, and
		// `replace_wire_policy` does not take this wire's lock — so a row enabled while this open
		// was in flight left the reconcile applying a value that was already out of date, and on a
		// transmit tap nobody reads from, nothing would correct it (codex round 11 on #219).
		// Reading again here costs one table lookup and is always at least as current.
		want := is_listen_only(iface)
		kvaser_apply_wire_silence(iface, want) or {
			if want {
				C.ct_kvaser_close(hnd)
				kvaser_unregister(iface, hnd)
				return error('Kvaser: channel ${s.channel} would not be set listen-only — ${err.msg()}; this wire is marked never-transmit and the controller would still acknowledge, so it is not opened')
			}
		}
		return &KvaserBus{
			handle: hnd
			iface:  iface
		}
	}
	// ASKED OF THE LIBRARY, not assumed from its version. canSetBusParamsFd is absent from a
	// canlib old enough to predate FD, and calling through a null pointer is a crash where a
	// sentence would do.
	if C.ct_kvaser_has_fd() == 0 {
		return error('Kvaser: this canlib32.dll has no CAN-FD API (canSetBusParamsFd missing) — update the Kvaser drivers')
	}
	data_code := kvaser_fd_data_code(s.data_bitrate)!
	ch, code, dcode, sil := s.channel, arb_code, data_code, if silent { 1 } else { 0 }
	hnd := kvaser_open_locked(iface, fn [ch, code, dcode, sil] () int {
		return C.ct_kvaser_open_fd(ch, code, dcode, sil)
	})
	if hnd < 0 {
		return error('Kvaser: could not open channel ${s.channel} for CAN-FD at ${s.bitrate}/${s.data_bitrate} — ${kvaser_open_refusal(hnd,
			s.channel, true)}')
	}
	// AND THE WIRE IS RECONCILED, ALWAYS, RATHER THAN THE OPEN BEING TRUSTED.
	//
	// THERE IS NO "FIRST OPENER" CASE ANY MORE, and removing it is the point. It was there
	// because a first opener's in-open mode request is the one canlib obeys, so recording it
	// saved a call — but "am I first?" was read before this handle registered, so two threads
	// opening one wire could both answer yes, and the later one would then cache a mode the
	// controller never took (codex round 9 on #219). Guarding that decision with another lock
	// would have been a third mechanism around a saving worth one driver call.
	//
	// Asking unconditionally is both simpler and race-free: `apply_silence` is serialised per
	// wire and compares against the record, so a second opener with the same policy does
	// nothing at all, and one arriving after a policy change writes through every handle. The
	// only cost is one redundant call on a wire's very first open.
	// FRESH, NOT THE OPEN-TIME SNAPSHOT — see the classic branch above.
	want := is_listen_only(iface)
	kvaser_apply_wire_silence(iface, want) or {
		if want {
			C.ct_kvaser_close(hnd)
			kvaser_unregister(iface, hnd)
			return error('Kvaser: channel ${s.channel} would not be set listen-only — ${err.msg()}; this wire is marked never-transmit and the controller would still acknowledge, so it is not opened')
		}
	}
	return &KvaserBus{
		handle: hnd
		iface:  iface
		fd:     true
	}
}

// reconcile_silence makes the CONTROLLER match this wire's silence policy — the half of
// listen-only that software refusal cannot do, because the ACK is the transceiver's. listen.v
// carries the whole reasoning; silence.v carries why the record of what was applied is keyed by
// WIRE, serialised per wire, and not held on this struct.
//
// MID-RUN ONLY. An open chooses the mode before the channel joins the bus (see open_kvaser), so
// by the time this can be reached the wire already matches — until somebody moves the mark, which
// is the case it exists for.
//
// canlib spells it `canSetBusOutputControl(canDRIVER_SILENT)`, and it may only be set while the
// channel is bus-OFF, so the shim bounces the bus around it. That bounce is why doing this once
// per WIRE rather than once per handle matters more here than on PCAN: the app holds several
// handles on one channel, and one operator tick used to drop traffic once for each of them.
pub fn (mut b KvaserBus) reconcile_silence(want bool) ! {
	// EVERY HANDLE ON THE WIRE, not just this one — see kvaser_apply_wire_silence and, for the
	// measurement behind it, ct_kvaser_set_silent_all.
	kvaser_apply_wire_silence(b.iface, want)!
}

pub fn (mut b KvaserBus) send(f CanFrame) ! {
	// NO RECONCILE HERE. `SilentBus.send` has already done it, with the ONE policy snapshot it also
	// refuses on — and doing it again here meant reading the policy a SECOND time. A mark set
	// between the two reads then reconciled the controller to silent and let this send continue
	// into the driver anyway, because only the wrapper decides whether to refuse: the first frame
	// after the toggle still went out (codex round 8 on #219).
	//
	// That is the same two-reads defect for the third time — #202 r3 inside the wrapper, round 3 of
	// this PR between wrapper and backend, and now below the backend. The cure is not another
	// parameter to thread: every bus this app hands out comes from `open`, which always wraps, so
	// the wrapper's reconcile is guaranteed to have run and this one could only ever disagree with
	// it. The RECEIVE path keeps its own reconcile — there is no second read to disagree with
	// there, and it is what retries a refusal.
	// A FRAME NO CONTROLLER COULD SEND is refused here as it is everywhere else. `esi` on a
	// classic frame arrived with the shared rules and this path never learned it, so the same
	// input was rejected by `inproc:`, `udp:`, PCAN and CANsub and accepted here — the flag
	// silently dropped, success reported, and the trace keeping a bit the wire never carried
	// (codex round 12 on #204).
	//
	// The IMPOSSIBLE rules only. What this backend does about a LENGTH is its own tier's business
	// and is unchanged — see frame_rules.v.
	if why := frame_send_refusal(f) {
		return error('Kvaser: ${why}')
	}
	// BRS WITHOUT FD IS NOT A FRAME. Bit-rate switching is a property of an FD frame's data
	// phase; a classic frame has no second phase to switch into. Left through, it goes out
	// classic and reports success while the trace records a switch that never happened — the
	// same silent disagreement between record and wire that the FD refusal below exists to
	// prevent. Vector refuses it for the same reason.
	if f.brs && !f.fd {
		return error('Kvaser: brs without fd (id 0x${f.id:X}) — bit-rate switching belongs to a CAN-FD frame\'s data phase, and a classic frame has none')
	}
	if f.fd {
		// THE CHANNEL DECIDES, not the frame. A handle opened classic cannot carry an FD frame
		// whatever the flags say -- canWrite would put a classic frame on the wire and report
		// success, which is the silent truncation this backend has always refused. Say what to
		// change, because the answer is in the address.
		if !b.fd {
			return error('Kvaser: this channel is classic — name a data rate to open it for CAN-FD (kvaser:${'N'}@500000/2000000), id 0x${f.id:X}')
		}
		if f.data.len !in fd_lengths {
			return error('Kvaser: ${f.data.len} bytes is not a CAN-FD length (id 0x${f.id:X}) — 0..8, 12, 16, 20, 24, 32, 48 or 64')
		}
		ext := if f.extended { 1 } else { 0 }
		brs := if f.brs { 1 } else { 0 }
		st := C.ct_kvaser_write_fd(b.handle, f.id, u8(f.data.len), f.data.data, ext, brs)
		if st == kvaser_err_txbufofl {
			return busy_error('Kvaser', f.id)
		}
		if st < 0 {
			return error('canWrite (FD) failed (canStatus ${st})')
		}
		return
	}
	// REFUSED, not truncated — a vendor interface is not clamps_to_classic(), so wire_frame()
	// gives the trace the frame AS ASKED: truncating here records nine bytes against eight on the
	// wire, and the echo can never match its own record.
	if f.data.len > 8 {
		return error('Kvaser: ${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — 8 is the maximum without FD')
	}
	n := f.data.len
	ext := if f.extended { 1 } else { 0 }
	// The shim still takes an `rtr` argument and is always passed 0: this app does not transmit
	// remote frames (frame_rules.v refuses them before this line). Kept in the C signature because
	// it mirrors canlib's own flags word, not because anything sets it.
	st := C.ct_kvaser_write(b.handle, f.id, u8(n), f.data.data, ext, 0)
	if st == kvaser_err_txbufofl {
		return busy_error('Kvaser', f.id)
	}
	if st < 0 {
		return error('canWrite failed (canStatus ${st})')
	}
}

pub fn (mut b KvaserBus) recv(timeout_ms int) !CanFrame {
	// BEST EFFORT ON THE READ SIDE, deliberately: a receive that fails takes the wire's reader down
	// with it, and health.v already settles that a degraded wire must be degraded and never
	// removed.
	//
	// NOT DISCARDED, THOUGH. `apply_silence` records a refusal against the wire before returning
	// it, and the Buses panel reads that beside the row — because a PASSIVE listener never calls
	// send, so on a receive-only wire this `or {}` used to be the end of the story (codex round 3
	// on #219). Every receive retries, so a transient refusal clears itself.
	mut id := u32(0)
	mut ln := u8(0)
	mut flags := u32(0)
	// 64 BYTES ALWAYS, whichever mode this handle was opened in: the shim's reader copies a full
	// FD payload out, and a classic-sized array here would be overrun by the first 64-byte frame
	// on the wire.
	mut data := [64]u8{}
	// A BLOCKING RECEIVE IS SLICED, so that the reconcile above is not a once-per-CALL thing on a
	// call that may never return. The Bus contract allows timeout_ms < 0 = block forever, Lua and
	// `cmd/can_smoke` use it, and canReadWait would then sit in the driver for 0xFFFFFFFF ms — so a
	// wire marked listen-only during the wait stayed in normal mode until a frame arrived, and
	// ACKNOWLEDGED that frame on the way out (codex round 11 on #219). Sliced, the policy is
	// re-asked every 200 ms and the mark reaches the controller before the next frame does.
	//
	// A FINITE timeout is passed straight through: it already bounds itself, and cutting it into
	// slices would only add wakeups to the hot path every monitored wire runs.
	mut r := 0
	for {
		b.reconcile_silence(is_listen_only(b.iface)) or {}
		to := if timeout_ms < 0 { u32(200) } else { u32(timeout_ms) }
		r = C.ct_kvaser_read(b.handle, &id, &ln, &data[0], &flags, to)
		// 1 is "no message" from this shim; 0 is a frame and negative is an error. Only "no
		// message" is worth another slice, and only when the caller asked to block forever.
		if r != 1 || timeout_ms >= 0 {
			break
		}
	}
	if r == 1 {
		return error('timeout')
	}
	if r < 0 {
		return error('canReadWait failed (canStatus ${r})')
	}
	// ONE DECODE, IN V, pinned by a test — see kvaser_decode_flags. An error frame is not a frame
	// and is reported as nothing arriving, which is what the shim used to do with it.
	f := kvaser_decode_flags(flags)
	if f.error_frame {
		return error('timeout')
	}
	mut out := []u8{len: int(ln)}
	for i in 0 .. int(ln) {
		out[i] = data[i]
	}
	return CanFrame{
		id:       id & 0x1FFF_FFFF
		extended: f.extended
		// A remote frame is a request for data, and the send path has carried RTR since #177.
		// Reading it back is the other half: wiretap matches an echo on rtr, so a remote frame
		// that arrives unlabelled is our own request filed as somebody else's answer.
		rtr:  f.rtr
		fd:   f.fd
		brs:  f.brs
		esi:  f.esi
		data: out
	}
}

pub fn (mut b KvaserBus) close() {
	// SERIALISED AGAINST A MODE CHANGE ON THIS WIRE, and the order inside matters as much as the
	// lock. Unregistering first opened a window in which a handle that was still BUS-ON was invisible
	// to kvaser_handles(): a concurrent reconcile would then skip it, collect the driver's documented
	// no-op success from the handles it could see, and record a mode the channel never took — after
	// which the surviving handles kept the old one and retries were suppressed (codex round 9 on
	// #219).
	//
	// Taking the wire's own silence lock makes closing and reconciling mutually exclusive, so a
	// reconcile either sees this handle bus-on and registered, or sees it gone and closed, and never
	// the state in between. It is the same lock apply_silence holds across the driver call, and
	// nothing acquires it while already holding it.
	mut wl := wire_silence_lock(wire_key(b.iface))
	wl.@lock()
	defer {
		wl.unlock()
	}
	C.ct_kvaser_close(b.handle)
	kvaser_unregister(b.iface, b.handle)
}

// health asks canReadStatus for the canSTAT_* ladder; -1 (symbol absent in an old canlib,
// or the call failing) reads as unknown, never as a state. Decode pinned in health.v.
pub fn (mut b KvaserBus) health() BusHealth {
	mut flags := u32(0)
	if C.ct_kvaser_status(b.handle, &flags) != 0 {
		return .unknown
	}
	return kvaser_status_health(flags)
}

// diagnostics: nothing this backend counts beyond frames and the health ladder (#213).
pub fn (mut b KvaserBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

// kvaser_list enumerates attached Kvaser channels (physical + virtual) for discovery.
// Returns [] when canlib32.dll is absent (drivers not installed) or has no channels.
fn kvaser_list() []Iface {
	mut out := []Iface{}
	n := C.ct_kvaser_count()
	if n <= 0 {
		return out
	}
	for ch in 0 .. n {
		mut buf := [64]u8{}
		ptr := unsafe { &char(&buf[0]) }
		mut name := 'Kvaser ch${ch}'
		if C.ct_kvaser_descr(ch, ptr, 64) == 0 {
			d := unsafe { cstring_to_vstring(ptr) }.trim_space()
			if d != '' {
				name = '${d} (ch${ch})'
			}
		}
		// ASKED OF THE DRIVER. Every Kvaser channel was reported as physical, including the
		// software ones the docs send people to when they have no adapter -- so the one field
		// that would have told them which number to use said the opposite.
		out << Iface{
			name:    name
			iface:   'kvaser:${ch}'
			kind:    'can'
			virtual: C.ct_kvaser_is_virtual(ch) == 1
		}
	}
	return out
}
