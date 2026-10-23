module replay

import os
import strings
import sync
import time
import blobly.canlog
import blobly.transport
import blobly.wiretap

// how long a recorder's reader waits in one receive before it looks at its stop flag
const rec_slice_ms = 50

// the most lines held behind a send its driver has not answered: past it the send is written
// as sent, so a stalled driver cannot grow the backlog without bound
const max_backlog = 65536

// the files recorders are writing now, by absolute path: a second recorder on one would truncate
// it under the first
__global (
	rec_mu    sync.Mutex
	rec_paths map[string]bool
)

// Counts is what a recording holds.
pub struct Counts {
pub:
	frames u64 // lines written
	ours   u64 // frames this process sent (` T`): the tester, a simulated ECU, a replay
	theirs u64 // frames nobody here sent (` R`)
	missed u64 // frames this process sent that never came back to the recorder (not written)
	// frames the recorder's own handles lost before it read them (Bus.diagnostics), counted as
	// each closes
	dropped u64
}

// Recorder writes what its channels carry to a candump `.log` (canlog.format_line, the writer the
// GUI's Record uses), one line per frame, labelled with the channel's name and the time it was
// read on the host's monotonic clock in seconds, so the file's times rise in its order. Every line ends with its origin as candump -x and
// python-can write a direction: ` T` for a frame this process sent — whoever sent it here, so the
// tester and a simulated ECU are both T, which the format cannot tell apart — and ` R` for the
// rest. What this process sends is learned from transport.watch_sends and matched against what
// comes back (blobly/wiretap), as the GUI's trace tells its own frames from the ECU's.
@[heap]
pub struct Recorder {
mut:
	mu       sync.Mutex
	f        os.File
	open     bool
	out      chan Chunk = chan Chunk{cap: 1024} // flushed text, for the writer
	writing  bool // the writer runs: it closes the file when it ends
	rings    []wiretap.Ring // per target: its sends noted, waiting to come back
	seq      u64
	lines    []Line // in file order; written from the front while settled
	c        Counts
	err      string // the first write or receive that failed
	stopping bool
	// sys_mono_now by which a stopping reader stops waiting for its sends to come back
	stop_until u64
	stopped    bool // a stop has returned
	readers  int  // receive loops still running
	watches  []int
	keys     []string // what rec_paths holds for this file
pub mut:
	// asked while stop waits: true gives the wait up (a script's deadline); the readers still end
	give_up fn () bool = unsafe { nil }
pub:
	path string
}

// Line is one line waiting for the file: `seq` is a send on a wire that does not echo, not yet
// taken by its driver (0: settled), so a reply read meanwhile is written after its request.
struct Line {
	e   canlog.LogEntry
	seq u64
}

// record starts recording `targets` (a name and an interface each; one per wire) to `path`,
// created or truncated.
pub fn record(path string, targets []Target) !&Recorder {
	if targets.len == 0 {
		return error('record: no channel to record')
	}
	mut wires := map[string]string{}
	mut names := map[string]bool{}
	for t in targets {
		k := transport.wire_key(t.iface)
		if prev := wires[k] {
			return error('record: ${prev} and ${t.name} are one wire, which would record each frame twice')
		}
		// the label as the file spells it: '' is written `can`, so it is the same as a channel `can`
		label := canlog.iface_token(t.name)
		if label in names {
			return error('record: two channels written as ${label}, whose lines the file could not tell apart')
		}
		wires[k] = t.name
		names[label] = true
	}
	if path.contains_u8(0) {
		return error('record: a path cannot carry a NUL')
	}
	if os.exists(path) && os.inode(path).typ != .regular {
		return error('record: ${path} is not a regular file')
	}
	// the file by its directory's real path, so a symlinked directory names the same one, and an
	// existing file by its identity too, so a hard link to an active capture is that capture
	// joined, not normalised: `link/..` is the link target's parent, as the filesystem walks it
	joined := if os.is_abs_path(path) { path } else { os.getwd() + os.path_separator + path }
	mut first := os.join_path(os.real_path(os.dir(joined)), os.base(joined))
	$if windows {
		first = first.to_lower() // one file, whatever the case it is named in
	}
	mut keys := [first]
	if id := file_id(path) {
		keys << id
	}
	rec_mu.lock()
	for k in keys {
		if k in rec_paths {
			rec_mu.unlock()
			return error('record: ${path} is being recorded to already')
		}
	}
	for k in keys {
		rec_paths[k] = true
	}
	rec_mu.unlock()
	mut r := &Recorder{
		path:    path
		keys:    keys
		readers: targets.len
		rings:   []wiretap.Ring{len: targets.len, init: new_ring()}
	}
	// watched before the buses open, so no frame of ours reaches a reader unnoted
	for i, t in targets {
		r.watches << r.watch(i, t)
	}
	mut buses := []transport.Bus{}
	for t in targets {
		b := transport.open(t.iface) or {
			for mut ob in buses {
				ob.close()
			}
			r.readers = 0
			r.stop() or {}
			return error('record ${t.name}: cannot open ${t.iface}: ${err}')
		}
		buses << b
	}
	// created once the buses are open, so a start that fails leaves an earlier capture there;
	// created and reserved by its identity under one hold, so no other start comes between
	rec_mu.lock()
	r.f = os.create(path) or {
		rec_mu.unlock()
		for mut ob in buses {
			ob.close()
		}
		r.readers = 0
		r.stop() or {}
		return error('record: cannot create ${path}: ${err}')
	}
	if id := file_id(path) {
		if id !in r.keys {
			rec_paths[id] = true
			r.keys << id
		}
	}
	rec_mu.unlock()
	r.f.set_unbuffered()
	r.mu.lock()
	r.open = true
	r.writing = true
	r.mu.unlock()
	spawn r.write_out()
	// a send already past its watch when the watch was registered may still be landing: what is
	// queued 2 ms on is before the recording, not written, its notes consumed with it
	time.sleep(2 * time.millisecond)
	for i, t in targets {
		for _ in 0 .. 65536 {
			q := buses[i].recv(0) or {
				if transport.look_was_spent(err) {
					continue
				}
				break
			}
			r.mu.lock()
			r.rings[i].claim(i, t.iface, q, host_ms())
			r.mu.unlock()
		}
	}
	for i, t in targets {
		spawn r.read(i, t, buses[i])
	}
	return r
}

// new_ring holds a wire's sends until they come back: as many as a backlog of queued echoes can
// hold (an in-process queue is 8192 frames), so a burst is not evicted while its echoes wait
fn new_ring() wiretap.Ring {
	return wiretap.Ring{
		cap: 65536
	}
}

// file_id is an existing file's identity (device and inode), where the platform gives one.
fn file_id(path string) ?string {
	st := os.stat(path) or { return none }
	if st.inode == 0 {
		return none
	}
	return 'inode ${st.dev}:${st.inode}'
}

fn host_ms() f64 {
	return f64(time.sys_mono_now()) / 1e6
}

// watch registers what target `i`'s wire is sent by this process, as the driver is handed it: on
// a wire whose sends come back to another handle, noted before the driver has it and written when
// it comes back, in the order the wire carried it; elsewhere written in its place as it is sent,
// once the driver took it.
fn (mut r Recorder) watch(i int, t Target) int {
	echoes := transport.echoes_own_sends(t.iface)
	return transport.watch_sends(t.iface, transport.SendWatch{
		before: fn [mut r, i, t, echoes] (f transport.CanFrame) u64 {
			r.mu.lock()
			defer {
				r.mu.unlock()
			}
			r.seq++
			if echoes {
				r.missed(r.rings[i].note(r.seq, t.iface, f, host_ms(), [i], t.name, false).len)
			} else {
				r.lines << Line{
					e:   canlog.LogEntry{
						t_s:   f64(time.sys_mono_now()) / 1e9
						iface: t.name
						// esi is what a receiver read off the wire, not what a sender asked for
						frame: transport.CanFrame{
							...f
							data: f.data.clone()
							esi:  false
						}
						dir:   .tx
					}
					seq: r.seq
				}
			}
			return r.seq
		}
		after:  fn [mut r, i, echoes] (tok u64, out transport.Sent) {
			r.mu.lock()
			defer {
				r.mu.unlock()
			}
			if echoes {
				// a write that failed may still come back, as ours: its note waits out the window
				if out == .refused {
					r.rings[i].forget(tok)
				}
				return
			}
			for k, l in r.lines {
				if l.seq == tok {
					if out == .taken {
						r.lines[k] = Line{
							e: l.e
						}
					} else {
						r.lines.delete(k)
						r.missed(int(out == .unknown)) // perhaps sent, never seen
					}
					break
				}
			}
			r.flush()
		}
	})
}

// missed counts sends that will not come back; the caller holds `mu`.
fn (mut r Recorder) missed(n int) {
	if n > 0 {
		r.c = Counts{
			...r.c
			missed: r.c.missed + u64(n)
		}
	}
}

// flush writes the settled lines at the front, counted; the caller holds `mu`.
fn (mut r Recorder) flush() {
	mut n := 0
	mut text := strings.new_builder(256)
	mut ch := Chunk{}
	for n < r.lines.len && (r.lines[n].seq == 0 || r.lines.len - n > max_backlog) {
		e := r.lines[n].e
		n++
		text.write_string(canlog.format_line(e))
		text.write_u8(`\n`)
		ch.frames++
		ch.ours += u64(e.dir == .tx)
		ch.theirs += u64(e.dir == .rx)
	}
	if n == 0 {
		return
	}
	r.lines.delete_many(0, n)
	if !r.open {
		return
	}
	// to the writer, which writes outside this lock: a file that stalls stalls nobody's send; the
	// counts are the writer's to add, once the file took the lines
	ch.text = text.str()
	if r.out.try_push(ch) != .success && r.err == '' {
		r.err = 'write ${r.path}: the file is not keeping up; frames are missing from it'
	}
}

// Chunk is text for the file and the lines it holds.
struct Chunk {
mut:
	text   string
	frames u64
	ours   u64
	theirs u64
}

// write_out is the writer: what flush hands it, one write each, unbuffered so a failure is that
// write's; it closes the file once flush has handed over its last.
fn (mut r Recorder) write_out() {
	for {
		ch := <-r.out or { break }
		r.f.write_string(ch.text) or {
			r.fail('write ${r.path}: ${err}')
			continue
		}
		r.mu.lock()
		r.c = Counts{
			...r.c
			frames: r.c.frames + ch.frames
			ours:   r.c.ours + ch.ours
			theirs: r.c.theirs + ch.theirs
		}
		r.mu.unlock()
	}
	r.f.close()
	r.mu.lock()
	r.writing = false
	r.out = chan Chunk{} // its slots let go: a stopped recorder's handle is kept for its counts
	r.mu.unlock()
	r.release() // the file is free only once it is closed
}

// release gives up the reservation of this recorder's file, once.
fn (mut r Recorder) release() {
	rec_mu.lock()
	for k in r.keys {
		rec_paths.delete(k)
	}
	r.keys = [] // a second stop of this recorder frees nobody else's file
	rec_mu.unlock()
}

// read is target `i`'s receive loop: every frame read, ours if it matches a send noted on its
// wire; once stopping, what is queued is still read (its sends are still noted), then it ends.
fn (mut r Recorder) read(i int, t Target, bus transport.Bus) {
	mut b := bus
	defer {
		// its watch goes with it: a send it can no longer read back is not noted as one
		if i < r.watches.len {
			transport.unwatch_sends(r.watches[i])
		}
		b.close()
		d := b.diagnostics() // after the close, which books a shared wire's last gap
		r.mu.lock()
		r.c = Counts{
			...r.c
			dropped: r.c.dropped + d.dropped
		}
		r.readers--
		r.mu.unlock()
	}
	for {
		r.mu.lock()
		stop := r.stopping
		r.mu.unlock()
		if stop {
			// what is queued, then what is still coming back for a send of ours, until the stop's
			// deadline: an echo or an acknowledgement may follow its send by a while
			for _ in 0 .. 65536 {
				r.mu.lock()
				waiting := r.rings[i].unclaimed() > 0 && time.sys_mono_now() < r.stop_until
				r.mu.unlock()
				f := b.recv(if waiting { 20 } else { 0 }) or {
					if transport.look_was_spent(err) {
						continue
					}
					if err.msg() != 'timeout' {
						r.fail('${t.name}: ${err}')
						return
					}
					if waiting {
						continue
					}
					return
				}
				r.take(i, t, f)
			}
			return
		}
		f := b.recv(rec_slice_ms) or {
			if err.msg() == 'timeout' {
				// nothing queued on this wire: a note of its older than the window will not come back
				r.mu.lock()
				r.missed(r.rings[i].expire(host_ms()).len)
				r.mu.unlock()
				continue
			}
			r.fail('${t.name}: ${err}')
			if err.msg() == 'bus is closed' {
				return
			}
			time.sleep(rec_slice_ms * time.millisecond)
			continue
		}
		r.take(i, t, f)
	}
}

// fail keeps the first error the recording met.
fn (mut r Recorder) fail(why string) {
	r.mu.lock()
	if r.err == '' {
		r.err = why
	}
	r.mu.unlock()
}

// take writes a frame target `i` read: ours (T) when it matches a send noted on its wire, judged
// at the time it arrived, so a reader behind its queue does not age its notes out.
fn (mut r Recorder) take(i int, t Target, f transport.CanFrame) {
	at := f64(transport.received_now(f)) / 1e6
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	// written at the time it is observed, taken under the lock: the file is in observation order
	// and its times rise with it, across wires whose receive stamps differ (the trace's rule)
	t_s := f64(time.sys_mono_now()) / 1e9
	r.missed(r.rings[i].expire(at).len)
	if f.data.len > canlog.max_row_payload {
		// no candump line can carry it (a software bus carries what it is handed): said, not written
		if r.err == '' {
			r.err = 'record ${t.name}: a frame of ${f.data.len} bytes (id 0x${f.id:X}) cannot be written to a candump line'
		}
		r.rings[i].claim(i, t.iface, f, at)
		return
	}
	mut ours := false
	if c := r.rings[i].claim(i, t.iface, f, at) {
		ours = true
		r.rings[i].forget(c.seq) // one reader per ring: a claimed note is done, and kept it is scanned
	}
	r.lines << Line{
		e: canlog.LogEntry{
			t_s:   t_s
			iface: t.name
			frame: f
			dir:   if ours { canlog.Dir.tx } else { canlog.Dir.rx }
		}
	}
	r.flush()
}

// counts is what the recording holds so far.
pub fn (mut r Recorder) counts() Counts {
	r.mu.lock()
	c := r.c
	r.mu.unlock()
	return c
}

// stop ends the recording: its readers write what is queued and end, and the sends in flight are
// settled, waited for at most 2 s, then the file is closed. A send that never came back is counted
// missed. An error when a write or a receive failed on the way, or the wait ran out (a driver call
// that will not return keeps its bus until it does): the file holds what was written before.
pub fn (mut r Recorder) stop() !Counts {
	until := time.sys_mono_now() + u64(settle_ms) * 1_000_000
	r.mu.lock()
	if !r.stopping {
		r.stop_until = until - 100_000_000 // the readers end in time for the close
	}
	r.stopping = true
	r.mu.unlock()
	defer {
		r.mu.lock()
		r.stopped = true
		r.mu.unlock()
	}
	mut settled := false
	for {
		r.mu.lock()
		settled = r.readers == 0 && r.lines.len == 0
		r.mu.unlock()
		if settled || time.sys_mono_now() >= until || (!isnil(r.give_up) && r.give_up()) {
			break
		}
		time.sleep(time.millisecond)
	}
	// closed before the watches go: nothing read after a send they no longer note is written
	// as somebody else's
	r.mu.lock()
	if r.open {
		r.open = false
		r.out.close() // the writer writes what it was handed, then closes the file
		if !settled && r.err == '' {
			r.err = 'record: a reader or a send did not finish within ${settle_ms} ms; the file may lack its last frames'
		}
		// what is still unclaimed now will never be: every note aged out at once, the rings and
		// lines then let go (a stopped recorder's handle is kept for its counts)
		for k in 0 .. r.rings.len {
			r.missed(r.rings[k].expire(1e300).len)
		}
		r.rings = []wiretap.Ring{len: r.rings.len, init: wiretap.Ring{}} // let go: nothing is noted now
		r.lines = []
	}
	watches := r.watches
	r.watches = []
	r.mu.unlock()
	for id in watches {
		transport.unwatch_sends(id)
	}
	for {
		r.mu.lock()
		writing := r.writing
		r.mu.unlock()
		if !writing {
			break
		}
		if time.sys_mono_now() >= until || (!isnil(r.give_up) && r.give_up()) {
			r.fail('write ${r.path}: the file did not take its last lines within ${settle_ms} ms')
			break
		}
		time.sleep(time.millisecond)
	}
	r.mu.lock()
	writer_out := r.writing
	r.mu.unlock()
	if !writer_out {
		r.release() // else the writer releases it once it has closed the file
	}
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if r.err != '' {
		return error(r.err)
	}
	return r.c
}

// ended is whether every reader has let go of its bus: a stop that ran out of time leaves one
// letting go.
pub fn (mut r Recorder) ended() bool {
	r.mu.lock()
	e := r.readers == 0
	r.mu.unlock()
	return e
}

// stopped is whether a stop has returned (and said what went wrong, if anything did).
pub fn (mut r Recorder) stopped() bool {
	r.mu.lock()
	v := r.stopped
	r.mu.unlock()
	return v
}
