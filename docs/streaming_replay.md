# Streaming replay — design

> Status: design, not built. The window's cell (`canlog.Row`, the arena) exists; the decoder
> that fills it from disk does not. Written after #299/#300 took the replay's allocation rate
> from 1,140 MB/s to ~28 and the arena took the collector's pause length down with it; what
> remains is a recording that does not fit in memory at all. Each step below is measured with
> `cmd/blobly_net/probe.v` before and after.

## Why

A replay today loads the WHOLE file: `mf4.load_file` reads the bytes, decodes every channel
group, sorts globally and hands the rows to the player. With the arena that is ~80 bytes a
frame in one block the collector never walks — fine for the tens-of-MB files on the bench,
impossible for the tens-of-GB ones a long drive produces (a 10 GB file is 250–700 M frames).
The maintainer's requirement: read one or two seconds ahead of the play head, release what has
played, FIFO. The arena is the cell of that window, not something the window replaces.

## What the file allows

- **Sorted data groups** (one channel group per DG, `rec_id_size == 0`): fixed-size records,
  so record k sits at `k × stride` in the concatenated data chain — seekable by arithmetic
  once the chain's block lengths are known from a header-only walk. A VLSD payload is an
  offset into a separate SD chain, reached the same way.
- **Unsorted data groups** (`rec_id_size > 0`): one interleaved stream of record-id-prefixed
  records of several channel groups, VLSD records inline with a length prefix. Not seekable by
  arithmetic; an index is needed.
- **Data chains**: `DT`/`DV`/`SD` blocks stream from disk in fixed chunks with a carry for a
  record straddling two chunks; a `DL` list is walked block by block; a `DZ` block must be
  read and inflated WHOLE (zlib is one stream, and `zip_type 1` transposes the entire block),
  so it is the unit of memory — capped, and inflated into a reused buffer.
- **Order**: the in-memory loader sorts by `(t_s, order)` where `order` is the record's
  position in its data group's stream, ranges disjoint and increasing across DGs. So the
  file-wide order is `(t_s, DG index, stream position)` and a streaming merge needs no
  ordinals: earlier DG wins a tie, then earlier position. This order was hardened over
  several review rounds (cross-bus interleave of equal-timestamp frames); the golden test is
  that the stream reproduces `parse_log` exactly.
- **One caveat**: an unsorted DG's interleaved stream is time-monotone per CHANNEL GROUP, not
  necessarily across them (a writer can skew two groups sharing one stream). The global sort
  today puts them in time order; a streaming cursor over an unsorted DG is therefore a
  per-group merge fed from one sequential reader, with bounded lookahead queues and a named
  failure when the skew exceeds the cap. The survey measures the skew so the cap is a number.

## The shape

1. **Survey pass** (one bounded pass, nothing retained): bus labels and counts, the span
   (`t0`, `end`), monotonicity, the maximum skew, and a seek index (one entry per ~1 s of
   recording: each DG's raw position and the last emitted key). Needed because labels come
   from record contents, the plan's subtraction report is printed BEFORE Start, `resolve_bus`
   needs the label list and the Replay panel needs the duration. Costs one decode of the
   file; a sidecar cache keyed on size and mtime makes the second open free.
2. **Cursors**: one per DG (`SortedCursor`, `UnsortedCursor`), each yielding rows in
   nondecreasing time; a k-way merge over them by `(t, DG index, position)`.
3. **Window** (`player.Window`): a ring of `canlog.Row` (one no-scan block), head/tail
   counters, a label table fixed by the survey, a cap in rows AND in seconds ahead (both:
   seconds keep the lookahead honest, rows bound memory when a second holds 100 k frames).
   A pass boundary is a marker row (a reserved flag bit); the producer rewinds and keeps
   filling, so a loop wrap has no gap.
4. **A decoder thread** fills the window: decode one row outside the lock, copy it in under
   it. Not the worker's tick — a DZ inflate is tens of milliseconds of burst that would land in
   the cadence histogram. Backpressure is the space check; a consumer that finds the window
   empty with the producer not at EOF counts an underrun and polls.
5. **Per-row decisions at decode time**: the bus mapping (`spec_of` by bus index), the
   rest-bus verdict (`Decider.verdict`, `Tally.add` — already frame-shaped, unchanged) and the
   relabel (the window's label table IS the destination table, as `relabelled` does today).
6. **The player over a cursor**: `Player` stops holding `log`/`sel` and drives a private
   `Cursor` interface — `LogCursor` (today's behaviour, every existing test unchanged) and
   `WindowCursor`. `due_into` releases the previous batch's cells at the start of the next
   call, which is the existing contract (the batch is consumed before the next call).
7. **Seek** v1: rewind and skip forward (correct, O(position)); v2: the survey's index —
   reposition every chain, rebuild the unsorted queues, discard rows at or before the last
   emitted key. **Loop**: the marker prefill.
8. **The switch**: in-memory below a file-size threshold (`BLOBLY_MF4_STREAM_MB`, default
   64; `0` forces streaming for tests and probe runs), streaming above. One player code path
   either way; only the source differs.

## What stays

`canlog.Row`/`Log` (the cell), `restbus.Decider`/`Tally`/`census`/`subtract`, every test
that builds `[]canlog.LogEntry`, `mf4.parse`/`load_file` for tests and small files (refactored
INTERNALLY to share one `decode_record` with the stream), `player/control.v`, the trace
import (whole-file by design, 2000-row cap).

## Hazards

- File offsets are `int` in four helpers of `mf4.v` (`block_links`, `data_off`,
  `read_data_block`, `dz_decompress`); the stream uses `u64` end to end and indexes `int`
  only inside a bounded chunk. A `[]u8` over 2 GB is impossible in V regardless.
- `os.File` is not safe to share between threads (one position); the decoder and the survey
  each open their own.
- `read_bytes_into` swallows the seek error and returns a short count at EOF: a short read is
  EOF or corruption, never zeros.
- Under `-prod`, the fill loop must hold the window and the source by pointer
  (`docs/known_issues.md`, the scope pin).
- `mf4.v`'s doc comment says VLSD groups in unsorted streams are skipped; the code handles
  them. Fix the comment with the first PR.

## PR sequence

1. `mf4.Stream` reproduces `parse_log` order — cursors, merge, the new test-image builders
   (unsorted DG with skew, a DL chain with a straddling record, DZ both types, `UnFinMF`),
   the golden test, `cmd/mf4_dump --stream` printing peak heap for both paths. No GUI change.
2. `survey()`; `restbus --list` over the stream; golden against `load_recording`.
3. `Player` over `Cursor` with `LogCursor` only — a pure refactor, probe within noise.
4. `Window`, `WindowCursor`, the decoder thread, `StreamPlan`; tests: cap never exceeded,
   clock-script equivalence against the in-memory player, seek while starved.
5. The GUI worker and the CLI over the threshold switch; window fill and underruns in the
   probe summary; probe with `BLOBLY_MF4_STREAM_MB=0` on the bench file.
6. The seek index and the survey cache.
