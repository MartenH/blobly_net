module testports

// The properties the whole scheme rests on. Each one is a way the allocation has actually been
// wrong, and none of them is visible from a passing test run — a collision shows up once, on
// somebody else's machine, as a failure that re-runs green.

// The defect this module was written for: `base + pid + slot` overlaps between adjacent pids,
// because process N's slot 1 IS process N+1's slot 0. A test runner spawns its files with pids a
// few apart, so adjacent is the common case, not the unlucky one.
fn test_adjacent_pids_get_disjoint_blocks() {
	for b in bands {
		for pid in 4000 .. 4064 {
			mut mine := map[int]bool{}
			for slot in 0 .. b.slots {
				mine[b.port_of(pid, slot)] = true
			}
			// every neighbour whose block could plausibly abut this one
			for other in [pid + 1, pid + 2, pid - 1, pid - 2] {
				for slot in 0 .. b.slots {
					p := b.port_of(other, slot)
					assert p !in mine, '${b.name}: pid ${pid} and pid ${other} both bind ${p}'
				}
			}
		}
	}
}

// A slot must stay inside its own block, or the same overlap returns by the back door.
fn test_every_slot_lands_inside_its_own_block() {
	for b in bands {
		for pid in [1, 999, 4321, 65535] {
			first := b.port_of(pid, 0)
			for slot in 0 .. b.slots {
				p := b.port_of(pid, slot)
				assert p >= first && p < first + b.slots, '${b.name}: slot ${slot} escapes its block'
			}
		}
	}
}

// Two FILES in one run are two processes with near-adjacent pids running the same formula, so
// per-process blocks are not enough on their own — the bands have to be disjoint as ranges.
fn test_bands_do_not_overlap_each_other() {
	for i, a in bands {
		for j, b in bands {
			if i >= j {
				continue
			}
			assert a.last() < b.base || b.last() < a.base, '${a.name} (${a.base}..${a.last()}) overlaps ${b.name} (${b.base}..${b.last()})'
		}
	}
}

// Below the range the OS assigns ephemeral ports from (32768 on Linux), or a test port can be
// handed out to an unrelated socket that merely asked for "any" — the collision this scheme is
// supposed to make impossible, arriving from outside the suite.
fn test_bands_stay_clear_of_the_ephemeral_range() {
	for b in bands {
		assert b.base > 1024, '${b.name}: ${b.base} is a privileged port'
		assert b.last() < 32768, '${b.name}: reaches ${b.last()}, inside the ephemeral range'
	}
}

// The group's low byte was forced odd, which mapped pids 100 and 101 onto ONE group: a 2:1
// collapse in the very place two processes are being kept apart.
fn test_adjacent_pids_get_different_groups() {
	for pid in 4000 .. 4128 {
		assert group_of(pid) != group_of(pid + 1), 'pids ${pid} and ${pid + 1} share a group'
	}
}

// .0 and .255 are treated specially by some stacks; neither is ours to use.
fn test_group_low_byte_is_never_zero_or_broadcast() {
	for pid in 0 .. 1024 {
		g := group_of(pid)
		last := g.all_after_last('.')
		assert last != '0' && last != '255', 'pid ${pid} gives ${g}'
	}
}
