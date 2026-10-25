# Streaming replay — design

> Status: built — all four steps of the PR sequence. `mf4.Stream` (`stream.v`, `chain.v`)
> reproduces `parse_log`'s order from the file a chunk at a time, pinned by the golden test over
> the images in its golden list (sorted MLSD and VLSD, DLC and DataLength, 32- and 64-bit
> offsets, remote and invalidated frames, a DL chain with a straddling record, DZ both types, an
> unsorted group with skew, an unsorted group's VLSD channel group, a DL-of-DZ signal-data chain,
> UnFinMF) and the tracked samples; `cmd/mf4_dump --stream` reads through it and prints the heap
> high-water mark of either path; `mf4.survey()` is the one-pass survey; `player.Chunker` plays a
> recording a chunk at a time; and (step 4) every replay — the GUI's Replay panel and Scan,
> `cmd/restbus`, Lua's `replay.*`, the C ABI and Python's `net.replays` — opens its recording
> through `replay.open_recording`, which streams an `.mf4` from `BLOBLY_MF4_STREAM_MB` (64 MiB)
> up. **This shipped differently from *The shape* below**: no window ring, no decoder thread
> filling one and no cursor interface (items 3–8); step 3's reader thread queuing chunks replaced
> them. Written after #299/#300 took the replay's allocation rate from 1,140 MB/s to ~28 and the
> arena took the collector's pause length down with it; what remained was a recording that does
> not fit in memory at all. Each step below is measured with `cmd/blobly_net/probe.v` before and
> after.

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
INTERNALLY to share one `decode_row` with the stream), `player/control.v`, the trace
import (whole-file by design, 2000-row cap).

## Hazards

- File offsets are `u64` end to end, the header helpers included (`block_links`, `data_off`,
  `read_data_block`, `dz_decompress`); `int` indexes only inside a bounded chunk. A `[]u8` over
  2 GB is impossible in V regardless.
- `os.File` is not safe to share between threads (one position); the decoder and the survey
  each open their own.
- `read_bytes_into` swallows the seek error and returns a short count at EOF: a short read is
  EOF or corruption, never zeros.
- Under `-prod`, the fill loop must hold the window and the source by pointer
  (`docs/known_issues.md`, the scope pin).

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
   from the EPOCH's latest time read, never while the earliest waiting row is a deferred one,
   over a cached earliest head (recomputed once per emission or per deferred change, not per
   record); disorder is measured at READ time against the epoch's latest time, which is what
   the window has to cover (against the record read just before, a staircase of half-second
   hops read as half a second); and a step back by more than the window opens a new EPOCH
   (`clock_steps`, counted apart from disorder) — rows merge by (epoch, time, position), so
   everything before the step goes out first and the rows after it interleave again, the most a
   stream can do where the loader's sort put them first. The record's time is decoded ONCE per
   record (`time_at`, `decode_row_at`), the acquisition name looked up in ONE place (`acq_name`),
   and the bus-name policy is ONE (`note_bus_name`, `fold_buses`) for the loader and the survey.
   Codex round 1 (#348): the cached head is keyed by (epoch, time, POSITION) — the merge's own
   key — so two heads at one millisecond are told apart and the deferred flag is the true
   head's; and every channel the decoder reads must lie inside the record (`chan_fits`, checked
   once in `resolve_layout` for both readers), since a master-time channel declared past the
   record was an out-of-bounds read where every other malformed layout is a refused group. The six
   private multi-bus recordings (13–15 buses, 0.6–1.24 M frames each, ~60 s) are all SORTED
   data groups: disorder 0, nothing queued, every counter 0, and the survey's buses equal
   `load_recording`'s on each. The heap marks of `mf4_dump` are within a megabyte for the two
   paths, as they must be: the dump materializes the rows either way, and the memory win is
   the chunked player's, step 3. The seek index the design listed here waits for step 4.
3. **Built** (#172), smaller than planned: no window ring and no cursor interface.
   `player.Chunker` (`chunked.v`) runs a READER THREAD that reads the stream, decides each row
   and queues chunks of rows (`chunk_rows` = 256, up to `chunk_ahead` = 64 ahead) on a channel.
   The `Player` plays a chunk the way it plays a loaded recording, and running out of rows with
   the pass still open means "take the next chunk". The per-row decision is `player.Planner`,
   factored out of `build_multi_log`, so both paths run one set of rest-bus rules. Its walkers
   hold J1939 transport sessions across chunk boundaries, so the planner lives for the whole
   pass.
   - **Loop, seek, stop.** The reader goes straight on into the next pass behind an end
     marker, so a loop wrap finds it queued. It reads at most one pass ahead of the player and
     blocks, never polls, while it is that far ahead; the owner's `close()` ends it. A seek (or a stop, or a restart) starts a new
     reader that replans from the top and skips rows before the target. That is seek v1,
     O(position), and the one way a stateful planner reaches the in-memory answer without
     saving its state. Until the new reader's first chunk arrives the clock holds, and the
     `due()` that finds it anchors the clock. The read therefore delays the jump; the frames it
     covers are not sent in one burst.
   - **Chunk memory.** Each chunk has rows of its own, because a batch already handed out
     holds views into them.
   - **The open pass.** `open_chunker` reads the file through once, keeping nothing, for the
     census and span. It refuses a file the stream cannot put in the loader's order
     (`out_of_order`), which then plays from memory.
   - **Stated limits, not handled.** (1) The hold ends when the new reader's first chunk
     arrives. A compressed block inflated right after that still lands on the tick once, since
     the reader reads ~50× faster than playback and is ahead from then on. (2) While a seek's
     read is pending, `sent()` counts from the last chunk taken; nothing but the tests reads
     it. (3) Since step 4, `replay/source_test.v` writes a J1939 MF4 (the
     `j1939-bam.log` pattern, 16 k frames) whose BAM transfers straddle chunk boundaries at
     every offset, and holds the streamed subtraction by PGN and by announcement to the loaded
     one. (4) The clock hold itself is exercised by the real-time harness, not by
     `chunked_test.v`, which waits for every chunk (`wait_ready`) so that the reader's timing
     never decides its output.
   - **Why a thread.** A read of the stream measured up to 60 ms, because a compressed block
     is inflated whole. On the worker's tick that is 60 ms of frames sent late and then all at
     once. The synchronous first version had exactly that, and codex found it.

   **Measured** on the six private recordings (0.6–1.24 M frames, 10–16 MB), with the scratch
   harness kept outside the repo:
   - **Identical output.** Playback in chunks of 1, 256 and 65536 rows is byte-identical to
     in-memory playback through a loop wrap, a seek, a paused seek, a stop and a restart:
     2–4.5 M output lines each.
   - **Memory.** Peak RSS for one pass of the 16 MB file is 295 MB in memory against 94 MB
     chunked, and the chunked figure does not grow with the file.
   - **Tick timing.** Over 20 s of real-time playback with a deep seek halfway, the worst
     `due()` is ~0.3 ms, the same as in memory. 99.7% of frames go out within 1 ms. The rest
     are at most 4.4 ms late, spread evenly and not tied to a read.
   - **Read speed.** The stream reads about 1 M rows/s (12 MB/s) under `gcc -O2`, the same as
     the loader. That speed is the cost of the open pass and of every seek: on a tens-of-GB
     file, both are minutes.

   The committed test is the same comparison over the tracked samples (`chunked_test.v`). It
   uses `wait_ready`, so the reader's timing never decides the output.
4. **Built** (#172): the front ends switch to the chunker by file size. `blobly/replay`'s
   `source.v` is the ONE door: `open_recording(path)` answers the recording's buses — from
   `mf4.survey()` when it streams, from the loader otherwise — and `Source.prepare(specs)`
   plans it, as `build_multi_log` in memory or as a `Chunker` whose open pass runs the same
   `Planner`, so both decide the same rest-bus subtraction (`Prepared.buses`); `Prepared.player`
   is the one player either way, so pause, seek, speed and loop go through `control.v` as before.
   The GUI's replay group, the Configure row's Scan (`replay.scan`: the census taken per bus as
   the survey reads, through `mf4.survey_into` and `player.Census`, the body `census_sel` runs
   too — one pass, nothing kept), `cmd/restbus` (whose single-bus path is now the one-mapping
   plan) and `replay.plan_for`/`start` (Lua, the C ABI, Python) all go through it.
   - **The switch**: an `.mf4` of at least `BLOBLY_MF4_STREAM_MB` MiB (default 64; `0` streams
     every `.mf4`) streams; below it, and for every candump `.log`, the whole file loads. A file
     whose stream would differ from the loader's rows (`replay.stream_differs`: rows out of time
     order, or frames whose payload the stream could not hold — `unresolved`, `evicted`) loads
     whole and says so. The Replay panel marks a streamed group. Both reads before the first
     frame (the survey and the chunker's open pass) ask a stop every 4096 rows — the GUI's run
     ending, a script's deadline (`give_up`) — so a Stop during a long open does not wait it out.
   - **Why 64 and not 0.** Measured with a scratch harness (open + plan + release every frame
     as fast as the player gives it; output hashed and identical in both paths on every file):

     | recording | size | in memory: first frame / peak RSS | streamed: first frame / peak RSS |
     |---|---|---|---|
     | six private 13–15-bus recordings | 11–17 MB | 0.5–1.2 s / 131–282 MB | 1.7–3.5 s / 22–31 MB |
     | CANedge `parked.mf4` (unsorted) | 3 MB | 0.07 s / 48 MB | 0.76 s / 19 MB |
     | CANedge `driving.mf4` | 5 MB | 0.08 s / 52 MB | 0.13 s / 26 MB |
     | synthetic, 4 buses, sorted | 48 MB | 0.76 s / 352 MB | 0.57 s / 26 MB |
     | synthetic, 4 buses, sorted | 397 MB | 5.8 s / 2,866 MB | 4.7 s / 34 MB |

     Streaming reads the file twice before the first frame (the survey, then the chunker's open
     pass) and replans from the top on every seek; in memory a seek is a binary search. On the
     dense real recordings that is two to three times slower to start, for memory the bench does
     not miss at that size. Past ~64 MB the in-memory path costs a gigabyte and more (about
     seven to seventeen times the file), and the streamed one stays flat.
   - **The bound.** A streamed replay holds the label table, the planner's state (J1939
     sessions, tallies) and at most `chunk_ahead` (64) chunks of `chunk_rows` (256) rows of
     80 bytes queued ahead of the player — about 1.3 MB — plus the stream's own caps per data
     group (`max_dz_block`, one inflated DZ block of up to 16 MiB; `ring_budget`;
     `max_deferred_bytes`). Measured: 34 MB peak RSS for the whole process on the 397 MB file,
     against 26 MB on 48 MB — it does not grow with the file.
   - **Probe** (40 s, Linux/WSLg, a 15-bus replay of one 17 MB private recording onto 15
     `inproc:` rows at 1×, looping): frames within 1 ms 69.1 % in memory, 68.0 % streamed;
     none later than 100 ms either way (worst 21.8 / 28.2 ms); live set after a collection
     247–249 MB in memory, 80–130 MB streamed. The cadence does not change with the source; the
     69 % is this bench at fifteen buses (the 99 % above was measured on Windows).
   - **Found on the way**: the chunker's reader read through a `FileSource` left in the frame
     of the function that opened it, since a `Stream` keeps a reference to its source; every pass
     past the first MiB of a file ended in `file not opened`. The samples `chunked_test.v` plays
     are 8 KB, which is how it survived. `mf4.open_file_source` puts the source on the heap, and
     `replay/source_test.v` streams a 2 MB recording it writes.
   - **Not handled**: a candump `.log` loads whole (a 96 MB file measured 931 MB); streaming one
     needs a line reader with the loader's time-order rule, which `.log` files do not promise.
     No sidecar cache for the survey and no seek index: a seek in a streamed file costs a read
     up to its target (~1 M rows/s), the clock held meanwhile.
