module j1939

import time
import blobly.transport

// lanes.v — J1939-21 lets a node have one broadcast in progress per source address, and a wire's
// senders in this process (simulated nodes, generators, background senders, scripts) are each
// their own sender; so a BAM's LANE, a source address on a wire, is claimed process-wide, and a
// second sender's BAM from that address waits until the first has ended.

// lane_hold_ms is how long a claim lasts without a frame sent under it: J1939-21's T1, after
// which the transfer is lost to its receivers anyway — the bound on a claim whose sender has gone.
pub const lane_hold_ms = 750

struct Lane {
	owner u64
	until u64 // mono ns: busy for anyone but its owner until then
}

struct LaneTable {
mut:
	by   map[string]Lane
	next u64
}

__global (
	tp_lanes shared LaneTable
)

// lane_key is the process-wide lane of source address `sa` on `wire` (the wire as
// transport.destination_key names it); '' for no wire, which claims nothing.
pub fn lane_key(wire string, sa u8) string {
	if wire == '' {
		return ''
	}
	return '${transport.destination_key(wire)}#${sa}'
}

// lane_owner is a new claimant's identity.
fn lane_owner() u64 {
	lock tp_lanes {
		tp_lanes.next++
		return tp_lanes.next
	}
	return 0
}

// lane_take claims `key` for `owner` until `hold_ns` from `now`, or refreshes its claim: false
// while another owner's claim, or the gap after it, still runs. '' is always granted.
fn lane_take(key string, owner u64, now u64, hold_ns u64) bool {
	if key == '' {
		return true
	}
	lock tp_lanes {
		if l := tp_lanes.by[key] {
			if l.owner != owner && now < l.until {
				return false
			}
		}
		tp_lanes.by[key] = Lane{
			owner: owner
			until: now + hold_ns
		}
	}
	return true
}

// lane_keep refreshes `owner`'s claim of `key` until `hold_ns` from `now`, for a transfer in
// progress: false once the claim is lost — another owner took it, or it lapsed. '' is always kept.
fn lane_keep(key string, owner u64, now u64, hold_ns u64) bool {
	if key == '' {
		return true
	}
	mut kept := false
	lock tp_lanes {
		if l := tp_lanes.by[key] {
			if l.owner == owner && now < l.until {
				tp_lanes.by[key] = Lane{
					owner: owner
					until: now + hold_ns
				}
				kept = true
			}
		}
	}
	return kept
}

// lane_free ends `owner`'s claim of `key`: anyone else may start `gap_ns` after `now`.
fn lane_free(key string, owner u64, now u64, gap_ns u64) {
	if key == '' {
		return
	}
	lock tp_lanes {
		if l := tp_lanes.by[key] {
			if l.owner == owner {
				tp_lanes.by[key] = Lane{
					owner: owner
					until: now + gap_ns
				}
			}
		}
	}
}

// sa_of is the source address of a transfer's frames.
fn sa_of(frames []transport.CanFrame) u8 {
	return if frames.len > 0 { u8(frames[0].id & 0xFF) } else { u8(0) }
}

// hold_ns is lane_hold_ms in ns.
fn hold_ns() u64 {
	return u64(lane_hold_ms) * u64(time.millisecond)
}
