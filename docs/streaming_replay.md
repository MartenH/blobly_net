# Streaming replay — design

> Status: step 1 of the PR sequence is built — `mf4.Stream` (`stream.v`, `chain.v`) reproduces
> `parse_log`'s order from the file a chunk at a time, pinned by the golden test over the images
> in its golden list (sorted MLSD and VLSD, DLC and DataLength, 32- and 64-bit offsets, remote
> and invalidated frames, a DL chain with a straddling record, DZ both types, an unsorted group
> with skew, an unsorted group's VLSD channel group, a DL-of-DZ signal-data chain, UnFinMF) and
> the tracked samples; `cmd/mf4_dump --stream` reads through it and prints the heap
> high-water mark of either path. The window's cell (`canlog.Row`, the arena) exists; the window,
> the decoder thread and the player over a cursor (steps 3–8) do not yet. Written after
> #299/#300 took the replay's allocation rate from 1,140 MB/s to ~28 and the arena took the
> collector's pause length down with it; what remains is a recording that does not fit in memory
> at all. Each step below is measured with `cmd/blobly_net/probe.v` before and after.

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
  that the stream reproduces `parse_log` exactly — for a writer whose disorder is within the
  merge's look-ahead window (`unsorted_lookahead_s`, step 2); a clock that steps back opens a
  new EPOCH and is counted, since no stream can put the rows after it ahead of the rows before.
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

1. **Built.** `mf4.Stream` reproduces `parse_log` order — cursors, merge, the new test-image
   builders (unsorted DG with skew, a DL chain with a straddling record, DZ both types,
   `UnFinMF`), the golden test, `cmd/mf4_dump --stream` printing peak heap for both paths. No
   GUI change. What it settled beyond the design: the header helpers take `u64` offsets end to
   end (the hazard below), `read_data_block` is the chain concatenated so the loader and the
   stream resolve a link through ONE walker, `decode_row` reads a VLSD payload through a
   `VlsdBytes` source (the whole block in memory, a `ChainView` over the signal-data chain, or a
   bounded `RingVlsd` of an unsorted group's VLSD records — CANedge writes the payload record
   immediately before the frame that names it, so a bounded tail suffices and a release is
   counted, `evicted`), and the unsorted merge reads ahead until every frame group has a row
   queued, capped at `unsorted_readahead` rows with a forced emission counted (`forced`) rather
   than hidden, until the survey makes the cap a measured number. Two things the loader assumed
   that a stream cannot: a group whose time runs backwards is sorted right by the loader and
   COUNTED by the stream (`out_of_order`); a broken block fails the loader whole and stops the
   stream's cursor with the reason (`err`), so a half-played file is never a clean end. A length
   field is checked against the chain's remaining bytes before it sizes a read or a slice — the
   filler an unfinalized file's extended last block decodes as records reads as 0xFFFFFFF0.
   Codex's first round (#342) added what a demuxing loader never notices: a frame record may name
   a payload record that has not gone past yet, so it is DEFERRED until the bytes arrive (decoded
   in record order; at the end, or past the cap, decoded as it is and counted, `unresolved`); a
   VLSD record past `max_vlsd_record` is stepped over rather than buffered; the finalized
   `cg_cycle_count` caps an unsorted group too; the payload source's failure stops the cursor
   (`VlsdBytes.failure()`), a short read is an error and a DZ block has a real inflated-size cap.
   Round 2: a fixed record nobody decodes is skipped like an oversized VLSD record (and a frame
   group's stride is capped, `max_record_stride`, in both readers), a skip still inflates every DZ
   block it crosses, the unsorted view path queues nothing after a failure, a block length that
   wraps the address space is clamped like any over-long one, and `mf4_dump --stream` prints
   `unresolved` and samples its heap mark after the same conversion the loader branch includes.
   Round 3: deferred frames are bounded in BYTES too (`max_deferred_bytes`); a group past its
   declared count is exhausted, not waited for, and the rest of its chain is still stepped over so
   a corrupt trailing block fails the stream as it fails the loader (sorted `drain`, unsorted
   `exhausted_all`); a TX/MD text is bounded by its block. And a loader defect the new fixture
   found: an unsorted VLSD group with no records made the frame group's payload link a data link
   to a CG block, failing the whole file. Round 4: the loader's block read is exact (a short read
   was zero-filled into records); a skipped plain span is probed at its last byte; `max_dz_block`
   is 16 MiB — the format's 4 MB rule times four — because it is the memory PER DATA GROUP, and a
   served DZ block is released at once; record ordinals are u64. Round 5: the signal-data chain is
   validated whole when the cursor finishes (`ChainView.validate`), the unsorted cursor finishes
   the same way after an unknown record id or a corrupt length (`finish`), a duplicate claimant of
   a record id is not waited for, and the text bound subtracts the link array (a defect of round
   3's fix). Round 6: nothing deferred is flushed after a read failure; past a deferral cap only
   the OLDEST frames are evicted (`evict`), not the whole backlog; and a FAILED read in the header
   walk is the parse's failure (`ByteSource.failure()`), where the zero-filling helpers had read it
   as an empty recording. Round 7: the deferred flush moved INTO `finish`, after the validation
   (the round-6 fix had the order right for a read failure and wrong for a clean stop); a link
   count is bounded by the block and the file, not a fixed 65,536 (`link_count`); a zero-length DZ
   block is validated at the walk. Round 8: the DL is walked one link at a time, never
   materialized (header blocks keep a bounded array, `max_header_links`); a VLSD group gets a
   ring only where a decoded frame group reads it. Round 9: the rings of one data group share one
   byte budget (`ring_budget`); and a claimed underflow in `skip` at a finished plain block did
   not hold — the probe reads the block's last byte, which exists — pinned by a test. Round 10:
   the merge returns none as soon as any cursor has failed; a ring is trimmed to its cap; a
   zero-width record is consumed rather than the end (and a width past an int is corrupt in both
   readers, `record_size`). Round 11: a DZ block's header and compressed bytes are read exactly
   (`exact_at`); `FileSource` sizes the handle, not the path; a record id width outside 0/1/2/4/8
   is refused by both readers. The review stopped there by the maintainer's decision, as #329
   did; the class test is #345, for step 2.
2. **Built.** `mf4.survey()` / `survey_file()` (`survey.v`): one pass over the stream retaining
   counts and labels and nothing else, answering what the loader answered from the whole
   recording — the buses (label, `cg_tx_acq_name`, frames; `tally_buses`' rule for a label with
   two names and `parse_recording`'s for a name covering two labels, reproduced and pinned by a
   golden test on every image and sample), the span (earliest and latest time, since the
   stream counts a backwards clock rather than sorting it), the data-group count — plus the
   stream's counters and two high-water marks: `max_queued` (rows queued ahead of an emission,
   what `unsorted_readahead` bounds) and `max_disorder_s` (the writer's disorder: how far a
   record was behind one read before it, what the merge must look ahead). `restbus --list`
   reads through it, so a file that does not fit in memory can still say what buses it has.
   **What the measurement changed.** On the CANedge sample `parked.mf4` (one bus at 350
   frames/s, one at 28) the row-capped merge read to the sparse bus's NEXT frame before every
   emission — 142,220 of 150,411 emissions forced at the 8,192-row cap, the order right only
   because the writer's stream is time-ordered anyway. A row cap is the wrong instrument for a
   sparse group. The merge now also stops reading when the earliest queued row is a
   `unsorted_lookahead_s` (2 s) behind the latest row read (`settled`), the row cap staying as
   the memory bound: parked reads with 961 rows queued at most, 0 forced, and a measured
   writer disorder of 293 ms (a CANedge flushes its channels' buffers by turns) — the window is
   seven times that; `out_of_order` (rows behind a row already handed out, which the loader would
   have placed earlier) says when it is not enough on another recorder. The self-review then
   took the window's first shape apart: measured from an all-time maximum time, one clock step
   back pinned it for the rest of the file and the merge stopped reading ahead; it ignored
   deferred frames; and a deferred frame flushed late read as disorder. So `settled` measures
   from the record read LAST, never while the earliest waiting row is a deferred one, over a
   cached earliest head (recomputed once per emission, not per record); disorder is measured
   at READ time against the record read just before; and a step back by more than the window
   opens a new EPOCH (`clock_steps`, counted apart from disorder) — rows merge by (epoch, time,
   position), so everything before the step goes out first and the rows after it interleave
   again, the most a stream can do where the loader's sort put them first. The bus-name policy
   is ONE (`note_bus_name`, `fold_buses`) for the loader and the survey. The six
   private multi-bus recordings (13–15 buses, 0.6–1.24 M frames each, ~60 s) are all SORTED
   data groups: disorder 0, nothing queued, every counter 0, and the survey's buses equal
   `load_recording`'s on each. The heap marks of `mf4_dump` are within a megabyte for the two
   paths, as they must be: the dump materializes the rows either way, and the memory win is
   the window's, step 4. The seek index the design listed here waits for seek (step 6).
3. `Player` over `Cursor` with `LogCursor` only — a pure refactor, probe within noise.
4. `Window`, `WindowCursor`, the decoder thread, `StreamPlan`; tests: cap never exceeded,
   clock-script equivalence against the in-memory player, seek while starved.
5. The GUI worker and the CLI over the threshold switch; window fill and underruns in the
   probe summary; probe with `BLOBLY_MF4_STREAM_MB=0` on the bench file.
6. The seek index (one entry per ~1 s: each DG's raw position and the last emitted key) and the
   survey cache — with seek, where they are used.
