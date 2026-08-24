// Which port may this test bind?
//
// One answer, in one place. A test that binds a FIXED port collides two ways — with another test
// in the same suite, and with another suite run (or anything else on the machine) holding it —
// and both surface as one intermittent failure that passes on every re-run afterwards. That is
// what #112 was filed for and could not identify: one test failed once, five immediate re-runs
// passed, and the output had been filtered to its summary line so even the name was lost.
//
// The worst version of that failure is not a red test. Two of these sites treated a failed bind
// as "no IPv6 loopback on this runner" and skipped, so a collision would have printed a plausible
// reason and dropped the coverage in silence.
//
// DERIVING a port from the pid is not the fix on its own. It cannot be: any formula over a finite
// band aliases, so two live processes whose pids differ by the band width get the same answer, and
// a first attempt here made that WORSE — narrowing the band to stay clear of the ephemeral range
// shortened the alias period from thousands of pids to a few hundred.
//
// The fix, where the protocol allows it, is to stop predicting and VERIFY: `candidates()` offers a
// sequence of ports starting where the pid points, and the caller takes the first it actually
// BINDS. An aliased pid finds its first candidate taken and moves on, so the alias period stops
// being a correctness property; two sites in one process settle the same way, since the first
// holds its socket. And "every candidate refused" becomes a real environment fact — no IPv6
// loopback here — rather than one unlucky number, which is what two skips in `doip/net_test.v`
// had been claiming while a collision could produce it.
//
// WHERE THE PROTOCOL ALLOWS IT means TCP, and that is not a detail to gloss:
//
//   * this V's `net.listen_udp` sets SO_REUSEADDR, so a second bind on a held UDP port SUCCEEDS.
//     Verified here, not assumed — two sockets bound 127.0.0.1:29111 in one process without
//     complaint. A UDP bind therefore proves nothing, and a "verify" built on it is a check that
//     always passes;
//   * multicast is worse still: two processes are SUPPOSED to share a group and port, and then
//     each sees the other's frames — which is exactly what a self-filter assertion reads as a
//     failure.
//
// So UDP predicts, and predicts properly: `slot_for` gives each process a disjoint BLOCK of
// `stride` ports, because the original defect was that `base + pid + slot` made process N's slot 1
// into process N+1's slot 0 — and a runner spawns its files with pids a few apart, so adjacent is
// the common case, not the unlucky one. Aliasing at the band width remains, and no arithmetic can
// remove it; the band is wide and the group varies too. That residue is stated rather than hidden.
//
// Each file gets its own BAND either way, so two files in one run — also two processes with
// near-adjacent pids — do not start on the same number. Bands are declared together, in `bands`
// below, because disjointness is a property of the SET: it cannot be checked one file at a time,
// and `testports_test.v` checks it here for all of them. Every band stays below 32768, clear of
// the range the OS assigns ephemeral ports from, so a bound test port cannot also be handed to an
// unrelated socket that merely asked for "any".
//
// Where a test owns its listener outright, none of this is needed: bind port 0 and read back what
// the OS assigned (`doip/net_test.v:free_listener`), which cannot collide at all, and is the first
// choice wherever the test only needs *a* port. This module is for the cases that cannot — a
// server binding TCP and UDP to the SAME number, and a UDP socket whose peer must be told where to
// write before either exists.
module testports

import os

// Band is one test file's reserved range of ports.
pub struct Band {
pub:
	name  string // the file it belongs to, so a clash reports something you can act on
	base  int    // first port in the band
	count int    // how many ports it holds
	tries int    // candidates offered before giving up — see candidates_for
}

// The bands. Adding one means adding it here, where the test can see it — a band declared beside
// its own test file is a band nothing compares against the others.
pub const doip = Band{
	name:  'doip/net_test.v'
	base:  20000 // above 13400, DoIP's registered port, which may be in real use on this machine
	count: 3000
	tries: 64
}

pub const someip = Band{
	name:  'someip/rpc_client_net_test.v'
	base:  23000
	count: 3000
	tries: 64
}

pub const udp_bus = Band{
	name:  'transport/udpbus_test.v'
	base:  26000
	count: 4000
	tries: 64
}

pub const bands = [doip, someip, udp_bus]

// last is the highest port the band can hand out.
pub fn (b Band) last() int {
	return b.base + b.count - 1
}

// candidates are ports to TRY, in order, for this process. Bind them until one works.
pub fn (b Band) candidates() []int {
	return b.candidates_for(os.getpid())
}

// candidates_for takes the pid rather than reading it, so the test can check the sequence for pids
// this process does not have.
//
// It starts where the pid points and steps by one, wrapping inside the band. Stepping by one is
// deliberate: the run that has to walk is the one whose neighbours are already bound, and walking
// into the next few ports finds free ones immediately. `tries` bounds it so a test on a machine
// where nothing can bind fails as a test rather than scanning three thousand ports first.
pub fn (b Band) candidates_for(pid int) []int {
	start := pid % b.count
	mut out := []int{cap: b.tries}
	for k in 0 .. b.tries {
		out << b.base + (start + k) % b.count
	}
	return out
}

// slot_for hands this process a disjoint BLOCK of `stride` ports and indexes inside it. For UDP,
// where binding cannot verify anything (see the head of this file), prediction is all there is —
// so it has to be prediction that cannot overlap between neighbouring pids.
//
// The pid picks the block; the slot indexes within it. NOT `pid + slot`, which is the defect this
// module was written for: that makes process N's slot 1 process N+1's slot 0.
//
// `count` must be a multiple of `stride`, or the wrap splits a block across the band's end and two
// processes share part of one. testports_test.v checks that for every band-and-stride in use.
pub fn (b Band) slot_for(pid int, stride int, slot int) int {
	return b.base + (pid * stride + slot) % b.count
}

// slot is slot_for, for THIS process.
pub fn (b Band) slot(stride int, slot_ int) int {
	return b.slot_for(os.getpid(), stride, slot_)
}

// group_of is a multicast group for `pid`.
//
// Multicast is the exception to everything above, because binding proves nothing there: two
// processes may both bind one group and port, and then each sees the other's frames — which is
// exactly what a self-filter assertion reads as a failure. There is no bind that fails to tell
// them apart, so the GROUP has to do the separating and it can only be predicted.
//
// 239.x is the administratively-scoped block, the right place for something this local. The low
// byte is 1..254 — never .0 or .255, which some stacks treat specially — and stepping it with the
// pid keeps it injective across 254 consecutive pids, which is the case that actually occurs: a
// runner spawns its files a few pids apart. Forcing the low bit instead, as this did, mapped pids
// 100 and 101 onto ONE group — a 2:1 collapse in the very place two processes were being kept
// apart. Two pids still meet if they agree in both bytes, and nothing here can prevent that; the
// port differs too, by slot_for, which is the second lock.
pub fn group_of(pid int) string {
	return '239.13.${(pid >> 8) & 0xFF}.${1 + pid % 254}'
}

// group is the multicast group for THIS process.
pub fn group() string {
	return group_of(os.getpid())
}
