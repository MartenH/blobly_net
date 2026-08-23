module testports

// The properties the scheme rests on. Each is a way the allocation has actually been wrong, and
// none of them is visible from a passing run — a collision shows up once, on somebody else's
// machine, as a failure that re-runs green.

// The candidates a caller walks must all be usable and all be different, or "try the next one"
// retries a port it has already been refused.
fn test_candidates_are_distinct_and_inside_the_band() {
	for b in bands {
		for pid in [1, 4000, 4001, 65535, 123456] {
			cands := b.candidates_for(pid)
			assert cands.len == b.tries, '${b.name}: offered ${cands.len} candidates'
			mut seen := map[int]bool{}
			for p in cands {
				assert p >= b.base && p <= b.last(), '${b.name}: candidate ${p} escapes the band'
				assert p !in seen, '${b.name}: offered ${p} twice'
				seen[p] = true
			}
		}
	}
}

// The defect this module was written for: `base + pid + slot` gave adjacent pids OVERLAPPING
// ports, because process N's slot 1 IS process N+1's slot 0. A test runner spawns its files with
// pids a few apart, so adjacent is the common case, not the unlucky one. Starting points must
// differ — a shared start would send both processes down the same path in the same order.
fn test_adjacent_pids_start_somewhere_different() {
	for b in bands {
		for pid in 4000 .. 4128 {
			for other in [pid + 1, pid + 2, pid + 3] {
				assert b.candidates_for(pid)[0] != b.candidates_for(other)[0], '${b.name}: pids ${pid} and ${other} start together'
			}
		}
	}
}

// Aliasing is REAL and cannot be arithmetic'd away: pids exactly a band apart start on the same
// port. This pins the weakness rather than pretending it is absent, so a later "improvement" to
// the arithmetic cannot be mistaken for a fix — on TCP the recovery is binding, and on UDP, where
// a bind proves nothing, this is the residue that remains.
fn test_pids_a_band_apart_alias_and_no_formula_fixes_it() {
	b := doip
	assert b.candidates_for(4000)[0] == b.candidates_for(4000 + b.count)[0]
	// the TCP recovery: the next candidate is somewhere the first process is not sitting
	assert b.candidates_for(4000)[1] != b.candidates_for(4000)[0]
	assert b.tries > 1, 'a single candidate leaves nothing to fall back to'
}

// The UDP half, where binding cannot verify anything and prediction is all there is. Blocks must
// be disjoint between processes — the defect this module was written for was that they were not.
fn test_slot_blocks_are_disjoint_between_adjacent_pids() {
	for b in bands {
		for stride in [2, 4] {
			for pid in 4000 .. 4064 {
				mut mine := map[int]bool{}
				for slot in 0 .. stride {
					mine[b.slot_for(pid, stride, slot)] = true
				}
				assert mine.len == stride, '${b.name}: a block of ${stride} held ${mine.len} ports'
				for other in [pid + 1, pid + 2, pid - 1, pid - 2] {
					for slot in 0 .. stride {
						p := b.slot_for(other, stride, slot)
						assert p !in mine, '${b.name}/${stride}: pids ${pid} and ${other} share ${p}'
					}
				}
			}
		}
	}
}

// A block that wraps across the band's end is split, and its halves land in two different
// processes' blocks. Every band must divide by every stride used against it.
fn test_bands_divide_by_the_strides_in_use() {
	for b in bands {
		for stride in [2, 4] {
			assert b.count % stride == 0, '${b.name}: ${b.count} ports do not divide into blocks of ${stride}'
		}
	}
}

// Slots stay inside the band, wrap included.
fn test_slots_stay_inside_the_band() {
	for b in bands {
		for pid in [1, 999, b.count - 1, b.count, b.count + 1, 65535] {
			for slot in 0 .. 4 {
				p := b.slot_for(pid, 4, slot)
				assert p >= b.base && p <= b.last(), '${b.name}: slot escaped to ${p}'
			}
		}
	}
}

// Two FILES in one run are two processes with near-adjacent pids running the same code, so the
// bands have to be disjoint as ranges.
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

// Below the range the OS assigns ephemeral ports from (32768 on Linux), or a test's port can also
// be handed to an unrelated socket that merely asked for "any" — the same collision, arriving
// from outside the suite where nothing in here can see it.
fn test_bands_stay_clear_of_the_ephemeral_range() {
	for b in bands {
		assert b.base > 1024, '${b.name}: ${b.base} is a privileged port'
		assert b.last() < 32768, '${b.name}: reaches ${b.last()}, inside the ephemeral range'
	}
}

// The group's low byte was forced odd, which mapped pids 100 and 101 onto ONE group: a 2:1
// collapse in the very place two processes are being kept apart. Multicast cannot verify by
// binding, so this is the only lock there is.
fn test_adjacent_pids_get_different_groups() {
	for pid in 4000 .. 4256 {
		assert group_of(pid) != group_of(pid + 1), 'pids ${pid} and ${pid + 1} share a group'
	}
}

// .0 and .255 are treated specially by some stacks; neither is ours to use.
fn test_group_low_byte_is_never_zero_or_broadcast() {
	for pid in 0 .. 2048 {
		g := group_of(pid)
		last := g.all_after_last('.')
		assert last != '0' && last != '255', 'pid ${pid} gives ${g}'
	}
}
