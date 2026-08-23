// Which port may this test bind?
//
// One answer, in one place. A test that binds a FIXED port collides two ways — with another test
// in the same suite, and with another suite run (or anything else on the machine) holding it —
// and both surface as one intermittent failure that passes on every re-run afterwards. That is
// what #112 was filed for and could not identify: one test failed once, five immediate re-runs
// passed, and the output had been filtered to its summary line so even the name was lost.
//
// Deriving the port from the pid is the fix, and the arithmetic is easy to get subtly wrong. It
// was, in three files at once: `base + pid + slot` gives adjacent pids OVERLAPPING numbers —
// process N's slot 1 is process N+1's slot 0 — and a test runner spawns its files with pids a few
// apart, so that is the likely case rather than the unlucky one. Three copies of one wrong
// formula is why this module exists rather than a helper per file.
//
// The shape that works:
//
//   * the pid picks a BLOCK, and the slot indexes INSIDE it, so no two processes can overlap
//     whatever their pids;
//   * each file gets its own BAND, because two files in one run are also two processes with
//     near-adjacent pids running the same formula;
//   * every band stays below 32768, clear of the range the OS assigns ephemeral ports from, so a
//     bound test port cannot be handed to an unrelated socket asking for "any".
//
// Bands are declared together, in `bands` below, because disjointness is a property of the SET —
// it cannot be checked one file at a time, and `testports_test.v` checks it here for all of them.
//
// Where a test owns its listener outright, none of this is needed: bind port 0 and read back what
// the OS assigned (`doip/net_test.v:free_listener`), which cannot collide at all. This module is
// for the cases that cannot — a server binding TCP and UDP to the SAME number, or a UDP socket
// whose peer has to be told where to write before either exists.
module testports

import os

// Band is one test file's reserved range.
pub struct Band {
pub:
	name  string // the file it belongs to, so a clash reports something you can act on
	base  int    // first port in the band
	slots int    // ports ONE process takes here — the block size, and the slot ceiling
	procs int    // distinct blocks; pids alias modulo this, and the band is procs*slots wide
}

// The bands. Adding one means adding it here, where the test can see it — a band declared beside
// its own test file is a band nothing compares against the others.
pub const doip = Band{
	name:  'doip/net_test.v'
	base:  20000 // above 13400, DoIP's registered port, which may be in real use on this machine
	slots: 4
	procs: 700
}

pub const someip = Band{
	name:  'someip/rpc_client_net_test.v'
	base:  23000
	slots: 2
	procs: 1500
}

pub const udp_bus = Band{
	name:  'transport/udpbus_test.v'
	base:  26000
	slots: 4
	procs: 1600
}

pub const bands = [doip, someip, udp_bus]

// port is the port for `slot` in THIS process's block.
pub fn (b Band) port(slot int) int {
	return b.port_of(os.getpid(), slot)
}

// port_of takes the pid rather than reading it, so the test can check the arithmetic for pids
// this process does not have — adjacent ones above all, which is the case that was broken.
pub fn (b Band) port_of(pid int, slot int) int {
	return b.base + (pid % b.procs) * b.slots + slot
}

// last is the highest port the band can hand out. Its ceiling, for the test to check.
pub fn (b Band) last() int {
	return b.base + (b.procs - 1) * b.slots + b.slots - 1
}

// group_of is a multicast group for `pid`, for the software-bus tests: two processes that share a
// group AND a port see each other's frames, which the self-filter assertion reads as a failure.
// Disjoint ports already prevent that; a per-pid group is the second lock.
//
// 239.x is the administratively-scoped block, the right place for something this local. The low
// byte is 1..254 — never .0 or .255, which some stacks treat specially — and stepping it with the
// pid keeps it injective across 254 consecutive pids. Forcing the low bit instead, as this did,
// mapped pids 100 and 101 onto one group.
pub fn group_of(pid int) string {
	return '239.13.${(pid >> 8) & 0xFF}.${1 + (pid % 254)}'
}

// group is the multicast group for THIS process.
pub fn group() string {
	return group_of(os.getpid())
}
