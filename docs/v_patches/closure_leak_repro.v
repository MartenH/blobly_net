// Minimal reproducer for the V closure leak (the root cause of the blobly_net
// data_grid memory leak — see docs/known_issues.md, "ROOT CAUSE NAILED").
//
//   v -path "@vlib|@vmodules|modules" run docs/v_patches/closure_leak_repro.v
//
// A V closure that CAPTURES heap data is allocated with `memdup_uncollectable`
// (gen/c/fn.v) and is reclaimed only by `closure_try_destroy`, which V emits
// only for closures passed straight to a call — never for STORED closures. So a
// loop that creates capturing closures and drops them leaks unboundedly under
// `-gc boehm`: `live` climbs linearly (~1 KB/iter = the captured array).
//
// The identical loop WITHOUT the closure (NOCLO=1) is dead flat — proving it is
// the closure context, not the captured array, that never gets collected.
module main

import os

fn rss_mb() int {
	s := os.read_file('/proc/self/status') or { return -1 }
	for line in s.split_into_lines() {
		if line.starts_with('VmRSS:') {
			return line.fields()[1].int() / 1024
		}
	}
	return -1
}

fn main() {
	noclo := os.getenv('NOCLO') != ''
	mut sink := 0
	for n in 0 .. 2_000_000 {
		big := []int{len: 200, init: index + n} // ~1.6 KB heap array
		if noclo {
			sink += big[n % big.len] // control: same array, no closure
		} else {
			h := fn [big] (x int) int { return big[x % big.len] } // captures big
			sink += h(n % 200) // use + drop
		}
		if n % 400_000 == 0 {
			gc_collect()
			println('n=${n:8} live=${gc_memory_use() / 1024 / 1024}MB RSS=${rss_mb()}MB')
		}
	}
	gc_collect()
	println('final live=${gc_memory_use() / 1024 / 1024}MB RSS=${rss_mb()}MB sink=${sink}')
}
